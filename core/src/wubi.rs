//! 五笔码表：`code<TAB>词<TAB>频次`（由 `tools/wubi2tsv.py` 从公开码表生成）。
//!
//! 五笔按码查词，不做拼音那种切分和组句：同一个码的词按频次排，输入更长的码时
//! 把以它开头的词组也带出来（简码 -> 全码）。

use std::collections::{HashMap, HashSet};
use std::path::Path;

#[derive(Clone, Debug)]
pub struct WubiEntry {
    pub code: String,
    pub word: String,
    pub freq: f64,
}

#[derive(Debug, Default)]
pub struct WubiDict {
    entries: Vec<WubiEntry>,
    /// 码 -> 条目下标，按频次从高到低。
    by_code: HashMap<String, Vec<u32>>,
    /// 去重后的码，按字典序（用来按前缀找）。
    codes: Vec<String>,
}

impl WubiDict {
    pub fn from_tsv_str(text: &str) -> Self {
        let mut entries = Vec::new();
        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split('\t');
            let (Some(code), Some(word), Some(freq)) =
                (fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            let Ok(freq) = freq.trim().parse::<f64>() else {
                continue;
            };
            let code = code.trim().to_ascii_lowercase();
            if code.is_empty() || word.is_empty() || freq <= 0.0 {
                continue;
            }
            entries.push(WubiEntry {
                code,
                word: word.to_string(),
                freq,
            });
        }
        let mut dict = Self {
            entries,
            by_code: HashMap::new(),
            codes: Vec::new(),
        };
        for (index, entry) in dict.entries.iter().enumerate() {
            dict.by_code
                .entry(entry.code.clone())
                .or_default()
                .push(index as u32);
        }
        let entries = &dict.entries;
        for indexes in dict.by_code.values_mut() {
            indexes.sort_by(|&a, &b| {
                entries[b as usize]
                    .freq
                    .partial_cmp(&entries[a as usize].freq)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        dict.codes = dict.by_code.keys().cloned().collect();
        dict.codes.sort();
        dict
    }

    pub fn load_tsv<P: AsRef<Path>>(path: P) -> std::io::Result<Self> {
        Ok(Self::from_tsv_str(&std::fs::read_to_string(path)?))
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// 输入一个码：先给精确匹配（按频次），再给以它开头的长码（简码带出全码）。
    pub fn candidates(&self, input: &str, limit: usize) -> Vec<(String, f64)> {
        let input = input.trim().to_ascii_lowercase();
        if input.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut out: Vec<(String, f64)> = Vec::new();
        let mut seen: HashSet<&str> = HashSet::new();
        if let Some(indexes) = self.by_code.get(&input) {
            for &index in indexes {
                let entry = &self.entries[index as usize];
                if seen.insert(&entry.word) {
                    out.push((entry.word.clone(), entry.freq));
                }
            }
        }

        let start = self.codes.partition_point(|code| code.as_str() < input.as_str());
        let mut prefix: Vec<(f64, &str)> = Vec::new();
        for code in &self.codes[start..] {
            if !code.starts_with(&input) {
                break;
            }
            if code == &input {
                continue;
            }
            for &index in &self.by_code[code] {
                let entry = &self.entries[index as usize];
                prefix.push((entry.freq, entry.word.as_str()));
            }
        }
        prefix.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        for (freq, word) in prefix {
            if out.len() >= limit {
                break;
            }
            if seen.insert(word) {
                out.push((word.to_string(), freq));
            }
        }
        out.truncate(limit);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict() -> WubiDict {
        WubiDict::from_tsv_str(
            "a\t工\t100\naa\t式\t50\naaaa\t工\t10\nb\t了\t90\ngg\t王\t80\n",
        )
    }

    #[test]
    fn exact_match_sorted_by_freq() {
        let d = dict();
        let c = d.candidates("a", 10);
        assert_eq!(c[0].0, "工");
        assert!(c.iter().any(|(w, _)| w == "式"), "前缀也要带出来: {c:?}");
    }

    #[test]
    fn prefix_matches_longer_codes() {
        let d = dict();
        let c = d.candidates("g", 10);
        assert!(c.iter().any(|(w, _)| w == "王"), "gg 以 g 开头: {c:?}");
    }

    #[test]
    fn unknown_code_is_empty() {
        assert!(dict().candidates("zzzz", 10).is_empty());
    }
}