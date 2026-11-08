//! Formaterkennung anhand der ersten Bytes (nicht anhand der Endung).

use std::io::{self, BufReader, Read};
use std::path::Path;

use crate::error::{Result, ZippError};
use crate::model::{ArchiveFormat, Stream};
use crate::volume::{self, Source};

/// Erkennt das Archivformat einer Datei (bei mehrteiligen Archiven anhand des ersten Teils).
pub fn detect_format(path: &Path) -> Result<ArchiveFormat> {
    let path = &volume::first_volume(path);
    let mut head = [0u8; 512];
    let n = read_up_to(&mut Source::open(path)?, &mut head)?;
    let head = &head[..n];

    if head.starts_with(b"PK\x03\x04") || head.starts_with(b"PK\x05\x06") || head.starts_with(b"PK\x07\x08") {
        return Ok(ArchiveFormat::Zip);
    }
    if head.starts_with(b"7z\xBC\xAF\x27\x1C") {
        return Ok(ArchiveFormat::SevenZip);
    }
    if head.starts_with(b"Rar!\x1A\x07") {
        return Ok(ArchiveFormat::Rar);
    }
    if is_tar_header(head) {
        return Ok(ArchiveFormat::Tar);
    }

    let stream = if head.starts_with(&[0x1F, 0x8B]) {
        Stream::Gzip
    } else if head.starts_with(b"BZh") {
        Stream::Bzip2
    } else if head.starts_with(&[0xFD, b'7', b'z', b'X', b'Z', 0x00]) {
        Stream::Xz
    } else if head.starts_with(&[0x28, 0xB5, 0x2F, 0xFD]) {
        Stream::Zstd
    } else {
        // Selbstentpackende ZIPs u. Ä.: ZIP-Signatur irgendwo am Ende
        if zip::ZipArchive::new(BufReader::new(Source::open(path)?)).is_ok() {
            return Ok(ArchiveFormat::Zip);
        }
        return Err(ZippError::UnsupportedFormat);
    };

    // Steckt ein TAR in der Kompression?
    let mut inner = [0u8; 512];
    let inner_len = {
        let mut decoder = crate::formats::tarball::open_stream(Source::open(path)?, stream)?;
        read_up_to(&mut decoder, &mut inner).unwrap_or(0)
    };
    let looks_like_tar = is_tar_header(&inner[..inner_len]) || has_tar_extension(path);
    Ok(match (stream, looks_like_tar) {
        (Stream::Gzip, true) => ArchiveFormat::TarGz,
        (Stream::Bzip2, true) => ArchiveFormat::TarBz2,
        (Stream::Xz, true) => ArchiveFormat::TarXz,
        (Stream::Zstd, true) => ArchiveFormat::TarZst,
        (Stream::Gzip, false) => ArchiveFormat::Gzip,
        (Stream::Bzip2, false) => ArchiveFormat::Bzip2,
        (Stream::Xz, false) => ArchiveFormat::Xz,
        (Stream::Zstd, false) => ArchiveFormat::Zstd,
        (Stream::Plain, _) => ArchiveFormat::Tar,
    })
}

fn is_tar_header(block: &[u8]) -> bool {
    block.len() >= 262 && &block[257..262] == b"ustar"
}

fn has_tar_extension(path: &Path) -> bool {
    let name = volume::logical_name(path).to_lowercase();
    [
        ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz", ".tar.zst", ".tzst",
    ]
    .iter()
    .any(|ext| name.ends_with(ext))
}

pub(crate) fn read_up_to(reader: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}
