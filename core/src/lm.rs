//! 二元语言模型接口与内存实现。
//!
//! 打分使用自然对数概率（<= 0）；未登录词回退到 unigram，再对未知词使用
//! 加零点五平滑。骨架阶段只有 bigram，后续可替换为 WeType 的 lmcnmac.bin
//! 解析器或神经语言模型。

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};

/// 语言模型接口。
pub trait LanguageModel: Send + Sync {
    /// 返回 ln P(cur | prev)。prev 为 None 表示句首。
    fn score(&self, prev: Option<&str>, cur: &str) -> f64;

    /// 一句话的累计对数概率。
    fn sequence_score(&self, words: &[&str]) -> f64 {
        let mut total = 0.0;
        for (i, word) in words.iter().enumerate() {
            let prev = if i == 0 { None } else { Some(words[i - 1]) };
            total += self.score(prev, word);
        }
        total
    }
}

/// 内存二元语言模型。
#[derive(Clone, Debug)]
pub struct BigramLm {
    unigram: HashMap<String, f64>,
    bigram: HashMap<String, HashMap<String, f64>>,
    total: f64,
    vocab: usize,
    /// 回退权重，乘在 unigram 概率上；默认 0.4。
    backoff: f64,
}

impl Default for BigramLm {
    fn default() -> Self {
        Self {
            unigram: HashMap::new(),
            bigram: HashMap::new(),
            total: 0.0,
            vocab: 0,
            backoff: 0.4,
        }
    }
}

impl BigramLm {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_backoff(mut self, backoff: f64) -> Self {
        if backoff > 0.0 && backoff <= 1.0 {
            self.backoff = backoff;
        }
        self
    }

    pub fn add_unigram(&mut self, word: &str, count: f64) {
        if count <= 0.0 {
            return;
        }
        let slot = self.unigram.entry(word.to_string()).or_insert(0.0);
        if *slot == 0.0 {
            self.vocab += 1;
        }
        *slot += count;
        self.total += count;
    }

    pub fn add_bigram(&mut self, prev: &str, cur: &str, count: f64) {
        if count <= 0.0 {
            return;
        }
        self.bigram
            .entry(prev.to_string())
            .or_default()
            .entry(cur.to_string())
            .and_modify(|c| *c += count)
            .or_insert(count);
    }

    pub fn vocab(&self) -> usize {
        self.vocab
    }

    pub fn total(&self) -> f64 {
        self.total
    }

    /// 粗略的 bigram TSV 加载：每行 prev<TAB>cur<TAB>count。
    ///
    /// 为了能直接查询，这里把每行的 prev/cur 也累加成 unigram 计数；
    /// 与真实词频不同，仅用于打通流程。
    pub fn from_bigram_tsv_str(data: &str) -> Result<Self> {
        let mut lm = Self::new();
        for (line_no, raw) in data.lines().enumerate() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let prev = cols.next().unwrap_or("");
            let cur = cols.next().unwrap_or("");
            let count = cols.next().unwrap_or("");
            if cols.next().is_some() || prev.is_empty() || cur.is_empty() || count.is_empty() {
                bail!("第 {} 行应为 3 列：prev<TAB>cur<TAB>count", line_no + 1);
            }
            let count: f64 = count
                .parse()
                .with_context(|| format!("第 {} 行计数不是数字: {count}", line_no + 1))?;
            lm.add_bigram(prev, cur, count);
            lm.add_unigram(prev, count);
            lm.add_unigram(cur, count);
        }
        Ok(lm)
    }

    pub fn from_bigram_tsv_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let data = fs::read_to_string(path)
            .with_context(|| format!("读取语言模型失败: {}", path.display()))?;
        Self::from_bigram_tsv_str(&data)
    }

    fn unigram_logprob(&self, word: &str) -> f64 {
        if self.total <= 0.0 {
            return 0.0;
        }
        let denom = self.total + 0.5 * self.vocab as f64;
        let count = self.unigram.get(word).copied().unwrap_or(0.0);
        ((count + 0.5) / denom).ln()
    }
}

impl LanguageModel for BigramLm {
    fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
        // 未加载任何数据时保持中性，避免骨架的排序被常数惩罚主导。
        if self.total <= 0.0 {
            return 0.0;
        }

        let unigram = self.unigram_logprob(cur);
        // 句首用 <s> 查 bigram；没有 <s> 时自然回退到 unigram。
        let prev_word = prev.unwrap_or("<s>");
        let bigram_count = self.bigram.get(prev_word).and_then(|m| m.get(cur)).copied();
        if let Some(count) = bigram_count {
            if count > 0.0 {
                if let Some(prev_count) = self.unigram.get(prev_word).copied() {
                    if prev_count > 0.0 {
                        return (count / prev_count).ln();
                    }
                }
            }
        }
        self.backoff.ln() + unigram
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_lm_is_neutral() {
        let lm = BigramLm::default();
        assert_eq!(lm.score(None, "你"), 0.0);
        assert_eq!(lm.sequence_score(&["你", "好"]), 0.0);
    }

    #[test]
    fn bigram_and_backoff() {
        let mut lm = BigramLm::new().with_backoff(0.4);
        lm.add_unigram("你", 10.0);
        lm.add_unigram("好", 5.0);
        lm.add_bigram("你", "好", 4.0);

        let hit = lm.score(Some("你"), "好");
        assert!((hit - (4.0f64 / 10.0).ln()).abs() < 1e-9);

        let backoff = lm.score(Some("好"), "你");
        let uni = lm.unigram_logprob("你");
        assert!((backoff - (0.4f64.ln() + uni)).abs() < 1e-9);
        assert!(backoff < 0.0);
    }

    #[test]
    fn sentence_start_bigram() {
        let mut lm = BigramLm::new();
        lm.add_unigram("<s>", 10.0);
        lm.add_unigram("你", 5.0);
        lm.add_bigram("<s>", "你", 3.0);
        assert!((lm.score(None, "你") - (0.3f64).ln()).abs() < 1e-9);
    }

    #[test]
    fn tsv_loader() {
        let lm = BigramLm::from_bigram_tsv_str("你\t好\t4\n好\t你\t1\n").unwrap();
        assert!(lm.total() > 0.0);
        assert_eq!(lm.vocab(), 2);
    }
}
