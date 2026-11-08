//! Fortschritt und Abbruch.
//!
//! Die App übergibt ein [`Progress`]-Objekt. Der Kern meldet höchstens alle
//! [`EMIT_INTERVAL`] einen Zwischenstand und fragt dabei ab, ob abgebrochen wurde.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::io::{self, Read, Write};
use std::time::{Duration, Instant};

const EMIT_INTERVAL: Duration = Duration::from_millis(60);

/// Empfänger für Fortschrittsmeldungen.
pub trait Progress: Send + Sync {
    /// `done` und `total` sind Bytes; `current` ist der Pfad des aktuellen Eintrags.
    fn update(&self, done: u64, total: u64, current: &str);
    /// Gibt `true` zurück, sobald der Nutzer abgebrochen hat.
    fn is_cancelled(&self) -> bool;
}

/// Fortschritt, der nichts meldet und nie abbricht.
pub struct NoProgress;

impl Progress for NoProgress {
    fn update(&self, _: u64, _: u64, _: &str) {}
    fn is_cancelled(&self) -> bool {
        false
    }
}

/// Markiert einen durch Abbruch ausgelösten `io::Error`.
#[derive(Debug)]
pub(crate) struct CancelMarker;

impl fmt::Display for CancelMarker {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("abgebrochen")
    }
}

impl std::error::Error for CancelMarker {}

pub(crate) fn cancelled_io() -> io::Error {
    io::Error::other(CancelMarker)
}

/// Zählt Bytes und gibt gedrosselt Fortschritt weiter.
pub(crate) struct Tracker<'a> {
    progress: &'a dyn Progress,
    done: Cell<u64>,
    total: Cell<u64>,
    last_emit: Cell<Instant>,
    current: RefCell<String>,
    /// Zählen die Ausgabe-Bytes (`true`) oder die gelesenen Archiv-Bytes (`false`, bei TAR)?
    count_output: Cell<bool>,
}

impl<'a> Tracker<'a> {
    pub(crate) fn new(progress: &'a dyn Progress, total: u64) -> Self {
        Self {
            progress,
            done: Cell::new(0),
            total: Cell::new(total),
            last_emit: Cell::new(Instant::now()),
            current: RefCell::new(String::new()),
            count_output: Cell::new(true),
        }
    }

    pub(crate) fn set_total(&self, total: u64) {
        self.total.set(total);
    }

    pub(crate) fn set_count_output(&self, value: bool) {
        self.count_output.set(value);
    }

    pub(crate) fn counts_output(&self) -> bool {
        self.count_output.get()
    }

    /// Neuer aktueller Eintrag. Meldet sofort und prüft auf Abbruch.
    pub(crate) fn set_current(&self, name: &str) -> io::Result<()> {
        name.clone_into(&mut self.current.borrow_mut());
        self.emit()
    }

    pub(crate) fn add(&self, n: u64) -> io::Result<()> {
        self.done.set(self.done.get().saturating_add(n));
        if self.last_emit.get().elapsed() >= EMIT_INTERVAL {
            self.emit()?;
        }
        Ok(())
    }

    /// Meldet den aktuellen Stand und bricht ab, falls gewünscht.
    pub(crate) fn emit(&self) -> io::Result<()> {
        self.last_emit.set(Instant::now());
        let total = self.total.get().max(self.done.get());
        self.progress
            .update(self.done.get(), total, &self.current.borrow());
        if self.progress.is_cancelled() {
            return Err(cancelled_io());
        }
        Ok(())
    }

    pub(crate) fn finish(&self) {
        let total = self.total.get().max(self.done.get());
        self.progress.update(total, total, "");
    }
}

/// Schreibt durch und zählt die Bytes (wenn der Tracker Ausgabe zählt).
pub(crate) struct ProgressWriter<'t, 'a, W> {
    inner: W,
    tracker: &'t Tracker<'a>,
}

impl<'t, 'a, W> ProgressWriter<'t, 'a, W> {
    pub(crate) fn new(inner: W, tracker: &'t Tracker<'a>) -> Self {
        Self { inner, tracker }
    }
}

impl<W: Write> Write for ProgressWriter<'_, '_, W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = self.inner.write(buf)?;
        if self.tracker.counts_output() {
            self.tracker.add(n as u64)?;
        }
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// Liest durch und zählt die Bytes immer.
pub(crate) struct ProgressReader<'t, 'a, R> {
    inner: R,
    tracker: &'t Tracker<'a>,
}

impl<'t, 'a, R> ProgressReader<'t, 'a, R> {
    pub(crate) fn new(inner: R, tracker: &'t Tracker<'a>) -> Self {
        Self { inner, tracker }
    }
}

impl<R: Read> Read for ProgressReader<'_, '_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.tracker.add(n as u64)?;
        Ok(n)
    }
}
