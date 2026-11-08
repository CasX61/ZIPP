//! Umrechnung zwischen DOS-Zeit (lokal, ZIP/RAR) und Unix-Zeit (UTC).

use std::time::{SystemTime, UNIX_EPOCH};

/// Lokale Datums-/Zeitteile in Unix-Zeit umrechnen (berücksichtigt Sommerzeit).
pub(crate) fn local_parts_to_unix(
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    // SAFETY: `tm` ist ein reines C-Struct; `mktime` liest und normalisiert es nur.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        tm.tm_year = i32::from(year) - 1900;
        tm.tm_mon = i32::from(month) - 1;
        tm.tm_mday = i32::from(day);
        tm.tm_hour = i32::from(hour);
        tm.tm_min = i32::from(minute);
        tm.tm_sec = i32::from(second);
        tm.tm_isdst = -1;
        let t = libc::mktime(&raw mut tm);
        (t != -1).then_some(t)
    }
}

/// Gepackte DOS-Zeit (Datum im oberen, Uhrzeit im unteren Wort) umrechnen.
pub(crate) fn dos_packed_to_unix(value: u32) -> Option<i64> {
    let date = (value >> 16) as u16;
    let time = (value & 0xFFFF) as u16;
    local_parts_to_unix(
        ((date >> 9) & 0x7F) + 1980,
        ((date >> 5) & 0x0F) as u8,
        (date & 0x1F) as u8,
        ((time >> 11) & 0x1F) as u8,
        ((time >> 5) & 0x3F) as u8,
        ((time & 0x1F) * 2) as u8,
    )
}

/// Unix-Zeit in lokale Teile (Jahr, Monat, Tag, Stunde, Minute, Sekunde).
pub(crate) fn unix_to_local_parts(t: i64) -> Option<(u16, u8, u8, u8, u8, u8)> {
    // SAFETY: `localtime_r` füllt nur das übergebene Struct.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        let tt: libc::time_t = t;
        if libc::localtime_r(&raw const tt, &raw mut tm).is_null() {
            return None;
        }
        Some((
            u16::try_from(tm.tm_year + 1900).ok()?,
            u8::try_from(tm.tm_mon + 1).ok()?,
            u8::try_from(tm.tm_mday).ok()?,
            u8::try_from(tm.tm_hour).ok()?,
            u8::try_from(tm.tm_min).ok()?,
            u8::try_from(tm.tm_sec).ok()?,
        ))
    }
}

pub(crate) fn system_time_to_unix(t: SystemTime) -> Option<i64> {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_secs()).ok(),
        Err(e) => i64::try_from(e.duration().as_secs()).ok().map(|s| -s),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_local() {
        let t = local_parts_to_unix(2026, 11, 8, 14, 30, 10).unwrap();
        assert_eq!(unix_to_local_parts(t).unwrap(), (2026, 11, 8, 14, 30, 10));
    }

    #[test]
    fn dos_packed() {
        // 2024-03-15 10:20:30
        let date: u32 = ((2024 - 1980) << 9) | (3 << 5) | 15;
        let time: u32 = (10 << 11) | (20 << 5) | 15;
        let t = dos_packed_to_unix((date << 16) | time).unwrap();
        assert_eq!(unix_to_local_parts(t).unwrap(), (2024, 3, 15, 10, 20, 30));
    }
}
