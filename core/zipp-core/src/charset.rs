//! Zeichensatz der Dateinamen in ZIP-Archiven erkennen.
//!
//! Ältere Windows-Programme (Explorer, ältere 7-Zip/WinRAR-Versionen) speichern
//! Dateinamen in der OEM-Codepage des Systems und setzen das UTF-8-Flag nicht:
//! CP850 in Westeuropa, CP437 in den USA, CP866 in Russland, Shift-JIS in
//! Japan, GBK in China. Die zip-Crate nimmt dann immer CP437 an, und aus
//! japanischen oder russischen Namen wird Zeichensalat.
//!
//! Erkannt wird einmal pro Archiv über alle Namen, die kein gültiges UTF-8 sind.

use encoding_rs::Encoding;

/// Wie Namen ohne gültiges UTF-8 dekodiert werden.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Legacy {
    Cp437,
    Cp850,
    Other(&'static Encoding),
}

impl Legacy {
    pub(crate) fn decode(self, raw: &[u8]) -> String {
        if let Ok(s) = std::str::from_utf8(raw) {
            return s.to_string();
        }
        match self {
            Self::Cp437 => decode_table(raw, &CP437),
            Self::Cp850 => decode_table(raw, &CP850),
            Self::Other(enc) => enc.decode_without_bom_handling(raw).0.into_owned(),
        }
    }

    /// Name für die Anzeige im Inspektor.
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Cp437 => "CP437 (DOS, USA)",
            Self::Cp850 => "CP850 (DOS, Westeuropa)",
            Self::Other(enc) => match enc.name() {
                "Shift_JIS" => "Shift-JIS (Japanisch)",
                "EUC-JP" => "EUC-JP (Japanisch)",
                "GBK" | "gb18030" => "GBK (Chinesisch, vereinfacht)",
                "Big5" => "Big5 (Chinesisch, traditionell)",
                "EUC-KR" => "EUC-KR (Koreanisch)",
                "IBM866" => "CP866 (DOS, Kyrillisch)",
                "windows-1251" => "Windows-1251 (Kyrillisch)",
                "windows-1252" => "Windows-1252 (Westeuropa)",
                other => other,
            },
        }
    }
}

/// Ergebnis der Erkennung für ein Archiv.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct NameCodec {
    pub(crate) legacy: Legacy,
    /// Gab es überhaupt Namen, die nicht UTF-8 sind?
    pub(crate) needed: bool,
}

impl NameCodec {
    pub(crate) fn decode(&self, raw: &[u8]) -> String {
        self.legacy.decode(raw)
    }
}

/// Wählt den Zeichensatz für alle Namen eines Archivs.
pub(crate) fn detect<'a>(names: impl IntoIterator<Item = &'a [u8]>) -> NameCodec {
    let legacy: Vec<&[u8]> = names
        .into_iter()
        .filter(|n| std::str::from_utf8(n).is_err())
        .collect();
    if legacy.is_empty() {
        return NameCodec {
            legacy: Legacy::Cp437,
            needed: false,
        };
    }

    let mut detector = chardetng::EncodingDetector::new(chardetng::Iso2022JpDetection::Deny);
    for name in &legacy {
        detector.feed(name, false);
        detector.feed(b"\n", false);
    }
    detector.feed(b"", true);
    let guess = detector.guess(None, chardetng::Utf8Detection::Deny);

    // Mehrbyte-Zeichensätze und Kyrillisch erkennt chardetng zuverlässig.
    let non_latin = [
        encoding_rs::SHIFT_JIS,
        encoding_rs::EUC_JP,
        encoding_rs::GBK,
        encoding_rs::GB18030,
        encoding_rs::BIG5,
        encoding_rs::EUC_KR,
        encoding_rs::IBM866,
        encoding_rs::WINDOWS_1251,
        encoding_rs::KOI8_R,
        encoding_rs::KOI8_U,
    ];
    let mut candidates: Vec<Legacy> = vec![
        Legacy::Cp850,
        Legacy::Cp437,
        Legacy::Other(encoding_rs::WINDOWS_1252),
    ];
    if non_latin.contains(&guess) {
        candidates.insert(0, Legacy::Other(guess));
    }

    // Unter den Kandidaten gewinnt der mit den plausibelsten Namen.
    // Bei Gleichstand der erste: also chardetngs Vorschlag, sonst CP850.
    let best = candidates
        .iter()
        .copied()
        .map(|c| (plausibility(c, &legacy), c))
        .fold(None::<(i64, Legacy)>, |best, (score, c)| match best {
            Some((s, _)) if s >= score => best,
            _ => Some((score, c)),
        })
        .map_or(Legacy::Cp850, |(_, c)| c);
    NameCodec {
        legacy: best,
        needed: true,
    }
}

/// Wie gut sehen die dekodierten Namen nach echten Dateinamen aus?
///
/// Buchstaben (auch CJK) zählen positiv, Rahmen- und Sonderzeichen,
/// Steuerzeichen und Ersatzzeichen (U+FFFD) negativ. Ein Wechsel zwischen
/// lateinischen und kyrillischen Buchstaben innerhalb eines Worts ist fast
/// immer ein Zeichen für die falsche Codepage.
fn plausibility(codec: Legacy, names: &[&[u8]]) -> i64 {
    let mut score = 0i64;
    for name in names {
        let decoded = codec.decode(name);
        let mut prev: Option<char> = None;
        for c in decoded.chars() {
            if c.is_ascii() {
                prev = Some(c);
                continue;
            }
            score += match c {
                '\u{FFFD}' => -20,
                c if c.is_control() => -10,
                c if is_cjk(c) => 3,
                c if c.is_alphabetic() && is_latin(c) => 2,
                c if c.is_alphabetic() && is_cyrillic(c) => 2,
                // Griechische Buchstaben in CP437 (α, Σ, Ω …) sind in Dateinamen selten.
                c if c.is_alphabetic() => -1,
                _ => -3,
            };
            if let Some(p) = prev
                && p.is_alphabetic()
                && ((is_cyrillic(c) && is_latin(p)) || (is_latin(c) && is_cyrillic(p)))
            {
                score -= 4;
            }
            prev = Some(c);
        }
    }
    score
}

fn is_latin(c: char) -> bool {
    c.is_ascii_alphabetic() || ('\u{00C0}'..='\u{024F}').contains(&c)
}

fn is_cyrillic(c: char) -> bool {
    ('\u{0400}'..='\u{04FF}').contains(&c)
}

fn is_cjk(c: char) -> bool {
    matches!(c,
        '\u{3040}'..='\u{30FF}'   // Hiragana, Katakana
        | '\u{3400}'..='\u{4DBF}' // CJK Erweiterung A
        | '\u{4E00}'..='\u{9FFF}' // CJK
        | '\u{AC00}'..='\u{D7AF}' // Hangul
        | '\u{FF66}'..='\u{FF9F}' // Halbbreite Katakana
    )
}

fn decode_table(raw: &[u8], table: &[char; 128]) -> String {
    raw.iter()
        .map(|&b| {
            if b < 0x80 {
                char::from(b)
            } else {
                table[usize::from(b - 0x80)]
            }
        })
        .collect()
}

#[rustfmt::skip]
const CP437: [char; 128] = [
    'Ç','ü','é','â','ä','à','å','ç','ê','ë','è','ï','î','ì','Ä','Å',
    'É','æ','Æ','ô','ö','ò','û','ù','ÿ','Ö','Ü','¢','£','¥','₧','ƒ',
    'á','í','ó','ú','ñ','Ñ','ª','º','¿','⌐','¬','½','¼','¡','«','»',
    '░','▒','▓','│','┤','╡','╢','╖','╕','╣','║','╗','╝','╜','╛','┐',
    '└','┴','┬','├','─','┼','╞','╟','╚','╔','╩','╦','╠','═','╬','╧',
    '╨','╤','╥','╙','╘','╒','╓','╫','╪','┘','┌','█','▄','▌','▐','▀',
    'α','ß','Γ','π','Σ','σ','µ','τ','Φ','Θ','Ω','δ','∞','φ','ε','∩',
    '≡','±','≥','≤','⌠','⌡','÷','≈','°','∙','·','√','ⁿ','²','■','\u{A0}',
];

#[rustfmt::skip]
const CP850: [char; 128] = [
    'Ç','ü','é','â','ä','à','å','ç','ê','ë','è','ï','î','ì','Ä','Å',
    'É','æ','Æ','ô','ö','ò','û','ù','ÿ','Ö','Ü','ø','£','Ø','×','ƒ',
    'á','í','ó','ú','ñ','Ñ','ª','º','¿','®','¬','½','¼','¡','«','»',
    '░','▒','▓','│','┤','Á','Â','À','©','╣','║','╗','╝','¢','¥','┐',
    '└','┴','┬','├','─','┼','ã','Ã','╚','╔','╩','╦','╠','═','╬','¤',
    'ð','Ð','Ê','Ë','È','ı','Í','Î','Ï','┘','┌','█','▄','¦','Ì','▀',
    'Ó','ß','Ô','Ò','õ','Õ','µ','þ','Þ','Ú','Û','Ù','ý','Ý','¯','´',
    '\u{AD}','±','‗','¾','¶','§','÷','¸','°','¨','·','¹','³','²','■','\u{A0}',
];

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_table(s: &str, table: &[char; 128]) -> Vec<u8> {
        s.chars()
            .map(|c| {
                if c.is_ascii() {
                    c as u8
                } else {
                    0x80 + table.iter().position(|&t| t == c).expect("Zeichen in Tabelle") as u8
                }
            })
            .collect()
    }

    fn detect_strs(names: &[Vec<u8>]) -> NameCodec {
        detect(names.iter().map(Vec::as_slice))
    }

    #[test]
    fn utf8_needs_nothing() {
        let names = vec!["Größe.txt".as_bytes().to_vec(), b"plain.txt".to_vec()];
        let codec = detect_strs(&names);
        assert!(!codec.needed);
        assert_eq!(codec.decode("Größe.txt".as_bytes()), "Größe.txt");
    }

    #[test]
    fn german_dos_names() {
        let originals = [
            "Übersicht März.xlsx",
            "Größe/Bücher.pdf",
            "Straße.doc",
            "Ärger.txt",
        ];
        let names: Vec<Vec<u8>> = originals.iter().map(|s| encode_table(s, &CP850)).collect();
        let codec = detect_strs(&names);
        assert!(codec.needed);
        for (raw, original) in names.iter().zip(originals) {
            assert_eq!(codec.decode(raw), original, "erkannt als {:?}", codec.legacy);
        }
    }

    #[test]
    fn danish_names_prefer_cp850() {
        // ø/Ø gibt es nur in CP850, in CP437 sind es ¢/¥
        let names = vec![encode_table("Søren Ørsted.txt", &CP850)];
        assert_eq!(detect_strs(&names).decode(&names[0]), "Søren Ørsted.txt");
    }

    #[test]
    fn japanese_names() {
        let originals = ["写真/夏休み.jpg", "請求書_2024年.pdf", "テスト資料.docx"];
        let names: Vec<Vec<u8>> = originals
            .iter()
            .map(|s| encoding_rs::SHIFT_JIS.encode(s).0.into_owned())
            .collect();
        let codec = detect_strs(&names);
        for (raw, original) in names.iter().zip(originals) {
            assert_eq!(codec.decode(raw), original, "erkannt als {:?}", codec.legacy);
        }
    }

    #[test]
    fn chinese_names() {
        let originals = ["文件/报告.docx", "照片集合.zip", "会议记录.txt"];
        let names: Vec<Vec<u8>> = originals
            .iter()
            .map(|s| encoding_rs::GBK.encode(s).0.into_owned())
            .collect();
        let codec = detect_strs(&names);
        for (raw, original) in names.iter().zip(originals) {
            assert_eq!(codec.decode(raw), original, "erkannt als {:?}", codec.legacy);
        }
    }

    #[test]
    fn russian_dos_names() {
        let originals = ["Документы/Отчёт за год.doc", "Фотографии.zip", "Привет мир.txt"];
        let names: Vec<Vec<u8>> = originals
            .iter()
            .map(|s| encoding_rs::IBM866.encode(s).0.into_owned())
            .collect();
        let codec = detect_strs(&names);
        for (raw, original) in names.iter().zip(originals) {
            assert_eq!(codec.decode(raw), original, "erkannt als {:?}", codec.legacy);
        }
    }
}
