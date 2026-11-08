//! Schutz vor bösartigen Pfaden (Zip-Slip) und Symlinks.

use std::path::{Component, Path, PathBuf};

/// Wandelt einen Archivpfad in einen sicheren, relativen Pfad um.
///
/// Gibt `None` zurück, wenn der Pfad aus dem Zielordner herausführen würde
/// (`..`, absolute Pfade, Laufwerksbuchstaben) oder leer ist.
pub(crate) fn sanitize(path: &str) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for part in path.split(['/', '\\']) {
        match part {
            "" | "." => {}
            ".." => return None,
            p if p.contains('\0') => return None,
            // Windows-Laufwerk wie "C:" am Anfang
            p if out.as_os_str().is_empty() && p.len() == 2 && p.ends_with(':') => return None,
            p => out.push(p),
        }
    }
    if out.as_os_str().is_empty() || path.starts_with('/') || path.starts_with('\\') {
        return None;
    }
    Some(out)
}

/// Prüft, ob ein Symlink mit relativem Ziel innerhalb des Zielordners bleibt.
///
/// `link_rel` ist der (bereits bereinigte) relative Pfad des Links selbst.
pub(crate) fn symlink_target_is_safe(link_rel: &Path, target: &str) -> bool {
    if target.is_empty() || target.starts_with('/') || target.contains('\0') {
        return false;
    }
    // Tiefe des Ordners, in dem der Link liegt
    let mut depth: i64 = link_rel.components().count() as i64 - 1;
    for comp in Path::new(target).components() {
        match comp {
            Component::ParentDir => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    true
}

/// Bereinigt Archivpfade für die Anzeige: `/` als Trenner, ohne `./` und ohne
/// führende bzw. abschließende Schrägstriche.
pub(crate) fn normalize(path: &str) -> String {
    let mut out = String::with_capacity(path.len());
    for part in path.split(['/', '\\']) {
        if part.is_empty() || part == "." {
            continue;
        }
        if !out.is_empty() {
            out.push('/');
        }
        out.push_str(part);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_traversal() {
        assert!(sanitize("../etc/passwd").is_none());
        assert!(sanitize("a/../../b").is_none());
        assert!(sanitize("/etc/passwd").is_none());
        assert!(sanitize("C:/Windows").is_none());
        assert!(sanitize("").is_none());
        assert!(sanitize("./").is_none());
    }

    #[test]
    fn accepts_normal() {
        assert_eq!(sanitize("a/b/c.txt").unwrap(), PathBuf::from("a/b/c.txt"));
        assert_eq!(sanitize("./a//b\\c").unwrap(), PathBuf::from("a/b/c"));
    }

    #[test]
    fn symlinks() {
        assert!(symlink_target_is_safe(Path::new("a/link"), "b.txt"));
        assert!(symlink_target_is_safe(Path::new("a/link"), "../c.txt"));
        assert!(!symlink_target_is_safe(Path::new("a/link"), "../../c.txt"));
        assert!(!symlink_target_is_safe(Path::new("link"), "/etc/passwd"));
        assert!(!symlink_target_is_safe(Path::new("link"), "../x"));
    }

    #[test]
    fn normalizes() {
        assert_eq!(normalize("./a\\b//c/"), "a/b/c");
        assert_eq!(normalize("/abs/x"), "abs/x");
    }
}
