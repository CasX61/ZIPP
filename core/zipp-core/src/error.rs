//! Einheitlicher Fehlertyp für alle Formate.

use std::fmt;
use std::io;

use crate::progress::CancelMarker;

/// Ergebnis-Typ von zipp-core.
pub type Result<T> = std::result::Result<T, ZippError>;

/// Alle Fehler, die die App unterscheiden muss.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ZippError {
    /// Das Archiv (oder ein Eintrag) ist verschlüsselt, es wurde aber kein Passwort angegeben.
    #[error("Für dieses Archiv wird ein Passwort benötigt.")]
    PasswordRequired,
    /// Das angegebene Passwort ist falsch.
    #[error("Das Passwort ist falsch.")]
    WrongPassword,
    /// Die Datei ist kein bekanntes Archiv.
    #[error("Unbekanntes oder nicht unterstütztes Archivformat.")]
    UnsupportedFormat,
    /// Das Archiv ist beschädigt oder unvollständig.
    #[error("Das Archiv ist beschädigt: {0}")]
    Corrupt(String),
    /// Prüfsumme eines Eintrags stimmt nicht.
    #[error("Prüfsummenfehler bei „{0}“.")]
    ChecksumMismatch(String),
    /// Der Vorgang wurde vom Nutzer abgebrochen.
    #[error("Der Vorgang wurde abgebrochen.")]
    Cancelled,
    /// Die Funktion gibt es für dieses Format (noch) nicht.
    #[error("Für dieses Format nicht verfügbar: {0}")]
    Unsupported(String),
    /// Fehler beim Lesen oder Schreiben.
    #[error("Ein-/Ausgabefehler: {0}")]
    Io(String),
}

impl ZippError {
    pub(crate) fn corrupt(msg: impl fmt::Display) -> Self {
        Self::Corrupt(msg.to_string())
    }
}

impl From<io::Error> for ZippError {
    fn from(e: io::Error) -> Self {
        if e.get_ref().is_some_and(|inner| inner.is::<CancelMarker>()) {
            return Self::Cancelled;
        }
        // Fehler, die in Decodern verpackt durchgereicht werden.
        if let Some(inner) = e.get_ref()
            && let Some(z) = inner.downcast_ref::<ZippError>()
        {
            return z.clone();
        }
        Self::Io(e.to_string())
    }
}

impl From<walkdir::Error> for ZippError {
    fn from(e: walkdir::Error) -> Self {
        Self::Io(e.to_string())
    }
}

impl From<zip::result::ZipError> for ZippError {
    fn from(e: zip::result::ZipError) -> Self {
        use zip::result::ZipError as Z;
        match e {
            Z::InvalidPassword => Self::WrongPassword,
            Z::UnsupportedArchive(msg) if msg == Z::PASSWORD_REQUIRED => Self::PasswordRequired,
            Z::UnsupportedArchive(msg) => Self::Unsupported(msg.to_string()),
            Z::Io(io) => io.into(),
            Z::FileNotFound => Self::corrupt("Eintrag nicht gefunden"),
            other => Self::corrupt(other),
        }
    }
}

impl From<sevenz_rust2::Error> for ZippError {
    fn from(e: sevenz_rust2::Error) -> Self {
        use sevenz_rust2::Error as S;
        match e {
            S::PasswordRequired => Self::PasswordRequired,
            S::MaybeBadPassword(_) => Self::WrongPassword,
            S::ChecksumVerificationFailed | S::NextHeaderCrcMismatch => {
                Self::ChecksumMismatch("7z-Daten".into())
            }
            S::Io(io, _) | S::FileOpen(io, _) => io.into(),
            S::BadSignature(_) => Self::UnsupportedFormat,
            S::Unsupported(msg) => Self::Unsupported(msg.to_string()),
            S::UnsupportedCompressionMethod(m) => Self::Unsupported(format!("Kompressionsmethode {m}")),
            other => Self::corrupt(other),
        }
    }
}

impl From<unrar::error::UnrarError> for ZippError {
    fn from(e: unrar::error::UnrarError) -> Self {
        use unrar::error::Code as C;
        match e.code {
            C::MissingPassword => Self::PasswordRequired,
            C::BadPassword => Self::WrongPassword,
            C::BadData => Self::corrupt("Daten fehlerhaft (oder falsches Passwort)"),
            C::BadArchive | C::UnknownFormat => Self::UnsupportedFormat,
            C::EOpen => Self::Io("Archiv bzw. ein Teil davon kann nicht geöffnet werden".into()),
            C::ECreate | C::EWrite => Self::Io("Datei kann nicht geschrieben werden".into()),
            C::ERead => Self::Io("Archiv kann nicht gelesen werden".into()),
            other => Self::corrupt(format!("{other:?}")),
        }
    }
}
