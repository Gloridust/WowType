//! 双拼（自然码方案）。
//!
//! 每个音节用两个键表示：声母键 + 韵母键。声母 zh/ch/sh 分别落在 v/i/u，
//! 零声母音节用「韵母首字母 + 韵母键」。
//!
//! 自然码本身允许少量重叠（例如 `p` 既是 `ie` 也是 `un`），所以解码返回**变体列表**，
//! 上层把这几种可能的全拼都跑一遍再合并候选。

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::syllable::{split, SYLLABLES};

/// 变体上限，防止病态输入把候选数量炸开。
pub const MAX_VARIANTS: usize = 8;

fn initial_key(initial: &str) -> Option<u8> {
    let key = match initial {
        "" => return None,
        "zh" => 'v',
        "ch" => 'i',
        "sh" => 'u',
        other => other.as_bytes()[0] as char,
    };
    Some(key as u8)
}

fn final_key(final_: &str) -> Option<u8> {
    let key = match final_ {
        "a" => 'a',
        "o" => 'o',
        "e" => 'e',
        "ai" => 'l',
        "ei" => 'z',
        "ao" => 'k',
        "ou" => 'b',
        "an" => 'j',
        "en" => 'f',
        "ang" => 'h',
        "eng" => 'g',
        "er" => 'r',
        "i" => 'i',
        "ia" => 'x',
        "ie" => 'p',
        "iao" => 'n',
        "iu" => 'q',
        "ian" => 'm',
        "in" => 'c',
        "iang" => 'd',
        "ing" => 'y',
        "iong" => 's',
        "u" => 'u',
        "ua" => 'x',
        "uo" => 'o',
        "uai" => 'y',
        "ui" => 'v',
        "uan" => 'r',
        "un" => 'p',
        "uang" => 'd',
        "ong" => 's',
        "v" => 'v',
        "ve" => 't',
        "van" => 'r',
        "vn" => 'p',
        _ => return None,
    };
    Some(key as u8)
}

/// 把一个全拼音节编码成两键。
pub fn encode(syllable: &str) -> Option<[u8; 2]> {
    let (initial, final_) = split(syllable)?;
    let fin = final_key(final_)?;
    let ini = match initial_key(initial) {
        Some(k) => k,
        // 零声母：用韵母首字母作为首键
        None => final_.as_bytes().first().copied()?,
    };
    Some([ini, fin])
}

fn table() -> &'static HashMap<u16, Vec<&'static str>> {
    static TABLE: OnceLock<HashMap<u16, Vec<&'static str>>> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut map: HashMap<u16, Vec<&'static str>> = HashMap::new();
        for syllable in SYLLABLES {
            if let Some([a, b]) = encode(syllable) {
                map.entry(u16::from(a) << 8 | u16::from(b))
                    .or_default()
                    .push(*syllable);
            }
        }
        map
    })
}

/// 两键对应的所有可能音节（自然码有少量重叠）。
pub fn decode_all(a: u8, b: u8) -> &'static [&'static str] {
    if !a.is_ascii_lowercase() || !b.is_ascii_lowercase() {
        return &[];
    }
    table()
        .get(&(u16::from(a) << 8 | u16::from(b)))
        .map(|v| v.as_slice())
        .unwrap_or(&[])
}

/// 两键对应的首选音节。
pub fn decode(a: u8, b: u8) -> Option<&'static str> {
    decode_all(a, b).first().copied()
}

/// 把双拼串展开成若干条全拼（音节空格分隔）。
///
/// 奇数长度会丢掉最后一个不完整的键，保证已完成的音节仍能出候选。
pub fn to_full_pinyin_variants(input: &str) -> Vec<String> {
    let bytes: Vec<u8> = input.bytes().filter(|b| b.is_ascii_lowercase()).collect();
    let usable = bytes.len() - bytes.len() % 2;
    let mut variants: Vec<String> = vec![String::new()];
    for pair in bytes[..usable].chunks(2) {
        let options = decode_all(pair[0], pair[1]);
        if options.is_empty() {
            return Vec::new();
        }
        let mut next = Vec::new();
        for prefix in &variants {
            for syllable in options {
                if next.len() >= MAX_VARIANTS {
                    break;
                }
                let mut joined = prefix.clone();
                if !joined.is_empty() {
                    // 用隔音符明确音节边界，避免 "xi"+"an" 被重新拼成 "xian"
                    joined.push('\'');
                }
                joined.push_str(syllable);
                next.push(joined);
            }
        }
        variants = next;
    }
    variants
}

/// 便捷版本：只取第一条全拼。
pub fn to_full_pinyin(input: &str) -> String {
    to_full_pinyin_variants(input)
        .into_iter()
        .next()
        .unwrap_or_default()
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_known_syllables() {
        assert_eq!(encode("zhong"), Some([b'v', b's']));
        assert_eq!(encode("guo"), Some([b'g', b'o']));
        assert_eq!(encode("ni"), Some([b'n', b'i']));
        assert_eq!(encode("hao"), Some([b'h', b'k']));
        assert_eq!(encode("an"), Some([b'a', b'j']));
    }

    #[test]
    fn every_encodable_syllable_decodes_back() {
        let mut total = 0;
        let mut broken = Vec::new();
        for syllable in SYLLABLES {
            if let Some([a, b]) = encode(syllable) {
                total += 1;
                if !decode_all(a, b).contains(syllable) {
                    broken.push(*syllable);
                }
            }
        }
        assert!(total > 380, "可编码音节太少: {total}");
        assert!(broken.is_empty(), "无法还原: {broken:?}");
    }

    #[test]
    fn converts_text() {
        assert!(to_full_pinyin_variants("vsgo").contains(&"zhong'guo".to_string()));
        assert!(to_full_pinyin_variants("nihk").contains(&"ni'hao".to_string()));
        // 奇数长度丢掉最后一个键
        assert_eq!(to_full_pinyin("vsg"), "zhong");
        // 不存在的韵母键（b 不是合法韵母键）
        assert!(to_full_pinyin_variants("bb").is_empty());
    }

    #[test]
    fn ambiguous_codes_produce_variants() {
        // jp 既可能是 jun 也可能是 jie
        let v = to_full_pinyin_variants("jp");
        assert!(v.len() >= 2, "{v:?}");
    }
}
