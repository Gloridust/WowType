//! 词典抽象与内存实现。
//!
//! 真实 WeType 词库是 LOUDS trie + 音节 ID 编码，后续解析器只需实现
//! Lexicon trait 即可接入；这里的 MemoryLexicon 同时提供 TSV 加载，便于
//! 先用导出的词表跑通整条链路。
//!
//! TSV 格式：拼音<TAB>词<TAB>频次
//! - 多音节拼音用空格或隔音符分隔，例如：xi an / xi'an
//! - 儿化用独立的 r 标记，例如：hua r
//! - 以 # 开头的行和空行会被忽略。

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Arc, RwLock};

use anyhow::{anyhow, bail, Context, Result};

use crate::syllable::{Syllable, SyllableId, SyllableQuery};

/// 词典条目。
#[derive(Clone, Debug, PartialEq)]
pub struct LexEntry {
    pub word: String,
    pub freq: f64,
    /// 规范音节键（全拼，含儿化标记）。
    pub keys: Vec<SyllableKey>,
    /// 每个音节的首字母，用于简拼匹配。
    pub initials: Vec<u8>,
}

/// 全拼音节键。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SyllableKey {
    pub id: SyllableId,
    pub erhua: bool,
}

impl SyllableKey {
    pub fn new(id: SyllableId, erhua: bool) -> Self {
        Self { id, erhua }
    }
}

/// 词典接口。
///
/// query 是一段连续音节；返回所有“音节序列恰好等于 query”的词。
/// 简拼查询用 SyllableQuery::Jianpin，匹配每个音节的首字母。
pub trait Lexicon: Send + Sync {
    /// 返回所有权值而非引用：这样「基础词库 + 用户词库」可以合并返回，
    /// 也能在运行时安全地增删用户词。命中数很小，克隆成本可接受。
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry>;

    /// 模糊音查询（z/zh、an/ang 等）。默认不支持。
    fn lookup_fuzzy(&self, _query: &[SyllableQuery]) -> Vec<LexEntry> {
        Vec::new()
    }

    fn total_freq(&self) -> f64;

    fn len(&self) -> usize;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 词的一元代价（越大越不可能）。缺省用 -ln(freq/total)。
    fn cost(&self, entry: &LexEntry) -> f64 {
        let total = self.total_freq().max(1.0);
        -((entry.freq.max(0.5)) / total).ln()
    }
}

/// 内存词典。
#[derive(Default)]
pub struct MemoryLexicon {
    entries: Vec<LexEntry>,
    full_index: HashMap<Vec<SyllableKey>, Vec<usize>>,
    jianpin_index: HashMap<Vec<u8>, Vec<usize>>,
    /// 模糊音索引：键是各音节的规范形式 ID。
    fuzzy_index: HashMap<Vec<SyllableId>, Vec<usize>>,
    by_length: HashMap<usize, Vec<usize>>,
    total_freq: f64,
}

impl MemoryLexicon {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入一个词。pinyin 使用空格/隔音符分隔音节。
    pub fn insert(&mut self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() {
            bail!("词不能为空");
        }
        if !freq.is_finite() || freq < 0.0 {
            bail!("频次必须是非负有限数，收到 {freq}");
        }
        let keys = parse_pinyin_keys(pinyin)?;
        let initials = keys
            .iter()
            .map(|k| {
                Syllable::from_id(k.id)
                    .map(|s| s.initial_letter())
                    .ok_or_else(|| anyhow!("未知音节 ID: {}", k.id))
            })
            .collect::<Result<Vec<_>>>()?;

        let idx = self.entries.len();
        self.entries.push(LexEntry {
            word: word.to_string(),
            freq,
            keys: keys.clone(),
            initials: initials.clone(),
        });
        if let Some(fuzzy) = keys
            .iter()
            .map(|k| crate::syllable::fuzzy_id(k.id))
            .collect::<Option<Vec<_>>>()
        {
            self.fuzzy_index.entry(fuzzy).or_default().push(idx);
        }
        self.full_index.entry(keys.clone()).or_default().push(idx);
        self.jianpin_index
            .entry(initials.clone())
            .or_default()
            .push(idx);
        self.by_length.entry(keys.len()).or_default().push(idx);
        self.total_freq += freq;
        Ok(())
    }

    /// 从 TSV 文本加载。
    pub fn from_tsv_str(data: &str) -> Result<Self> {
        let mut lex = Self::new();
        for (line_no, raw) in data.lines().enumerate() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let pinyin = cols.next().unwrap_or("");
            let word = cols.next().unwrap_or("");
            let freq = cols.next().unwrap_or("");
            if cols.next().is_some() || pinyin.is_empty() || word.is_empty() || freq.is_empty() {
                bail!("第 {} 行应为 3 列：拼音<TAB>词<TAB>频次", line_no + 1);
            }
            let freq: f64 = freq
                .parse()
                .with_context(|| format!("第 {} 行频次不是数字: {freq}", line_no + 1))?;
            lex.insert(pinyin, word, freq)
                .with_context(|| format!("第 {} 行加载失败", line_no + 1))?;
        }
        Ok(lex)
    }

    /// 从 TSV 文件加载。
    pub fn from_tsv_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let data = fs::read_to_string(path)
            .with_context(|| format!("读取词典失败: {}", path.display()))?;
        Self::from_tsv_str(&data)
    }
}

impl Lexicon for MemoryLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }

        let all_full = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Full { .. }));
        let all_jianpin = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Jianpin { .. }));

        if all_full {
            let key: Vec<SyllableKey> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Full { id, erhua } => SyllableKey::new(*id, *erhua),
                    _ => unreachable!(),
                })
                .collect();
            return self
                .full_index
                .get(&key)
                .map(|idxs| idxs.iter().map(|&i| self.entries[i].clone()).collect())
                .unwrap_or_default();
        }

        if all_jianpin {
            let key: Vec<u8> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Jianpin { letter } => *letter,
                    _ => unreachable!(),
                })
                .collect();
            return self
                .jianpin_index
                .get(&key)
                .map(|idxs| idxs.iter().map(|&i| self.entries[i].clone()).collect())
                .unwrap_or_default();
        }

        // 混合全拼/简拼：骨架阶段先做线性扫描；真实词典应建前缀 trie。
        self.by_length
            .get(&query.len())
            .map(|idxs| {
                idxs.iter()
                    .filter(|&&i| entry_matches(&self.entries[i], query))
                    .map(|&i| self.entries[i].clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }
        let mut key = Vec::with_capacity(query.len());
        for q in query {
            match q {
                SyllableQuery::Full { id, erhua } => {
                    if *erhua {
                        return Vec::new();
                    }
                    match crate::syllable::fuzzy_id(*id) {
                        Some(canon) => key.push(canon),
                        None => return Vec::new(),
                    }
                }
                SyllableQuery::Jianpin { .. } => return Vec::new(),
            }
        }
        self.fuzzy_index
            .get(&key)
            .map(|idxs| idxs.iter().map(|&i| self.entries[i].clone()).collect())
            .unwrap_or_default()
    }

    fn total_freq(&self) -> f64 {
        self.total_freq
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// 给束搜索用的视图：精确查不到时回退到模糊音。
pub struct FuzzyLexicon<'a> {
    inner: &'a dyn Lexicon,
}

impl<'a> FuzzyLexicon<'a> {
    pub fn new(inner: &'a dyn Lexicon) -> Self {
        Self { inner }
    }
}

impl Lexicon for FuzzyLexicon<'_> {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let exact = self.inner.lookup(query);
        if !exact.is_empty() {
            return exact;
        }
        self.inner.lookup_fuzzy(query)
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.inner.lookup_fuzzy(query)
    }

    fn total_freq(&self) -> f64 {
        self.inner.total_freq()
    }

    fn len(&self) -> usize {
        self.inner.len()
    }
}

/// 用户词库：在基础词库之上叠加用户自己添加的词。
///
/// 用户词以 (拼音, 词, 频次) 保存，改动时重建一份小的 MemoryLexicon；
/// 用户词通常只有几百到几千条，重建成本可以忽略。
pub struct UserLexicon {
    base: Arc<dyn Lexicon>,
    words: RwLock<Vec<(String, String, f64)>>,
    snapshot: RwLock<Arc<MemoryLexicon>>,
}

impl UserLexicon {
    pub fn new(base: Arc<dyn Lexicon>) -> Self {
        Self {
            base,
            words: RwLock::new(Vec::new()),
            snapshot: RwLock::new(Arc::new(MemoryLexicon::new())),
        }
    }

    /// 添加或更新一个用户词。拼音可以是 ni hao / nihao / xi'an。
    pub fn add(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() || pinyin.trim().is_empty() {
            bail!("用户词的拼音和词都不能为空");
        }
        // 先单独校验一次，拼音非法时不要污染词库
        let probe = format!("{}\t{}\t{}\n", pinyin.trim(), word, freq);
        MemoryLexicon::from_tsv_str(&probe).context("用户词拼音无法解析")?;

        {
            let mut words = self.words.write().unwrap();
            if let Some(slot) = words.iter_mut().find(|(_, w, _)| w == word) {
                slot.0 = pinyin.trim().to_string();
                slot.2 = freq;
            } else {
                words.push((pinyin.trim().to_string(), word.to_string(), freq));
            }
        }
        self.rebuild();
        Ok(())
    }

    /// 删除用户词，返回是否删掉了东西。
    pub fn remove(&self, word: &str) -> bool {
        let removed = {
            let mut words = self.words.write().unwrap();
            let before = words.len();
            words.retain(|(_, w, _)| w != word);
            words.len() != before
        };
        if removed {
            self.rebuild();
        }
        removed
    }

    pub fn words(&self) -> Vec<(String, String, f64)> {
        self.words.read().map(|w| w.clone()).unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut words) = self.words.write() {
            words.clear();
        }
        self.rebuild();
    }

    /// 把用户词写成 TSV（与 lexicon 格式一致）。
    pub fn save_tsv<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let words = self.words();
        if words.is_empty() {
            bail!("用户词库为空");
        }
        let mut out = String::from("# 用户词库\n");
        for (pinyin, word, freq) in words {
            out.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq as i64));
        }
        fs::write(path.as_ref(), out)
            .with_context(|| format!("写入用户词库失败: {}", path.as_ref().display()))
    }

    /// 从 TSV 载入用户词，追加到现有内容。
    pub fn load_tsv<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let data = fs::read_to_string(path.as_ref())
            .with_context(|| format!("读取用户词库失败: {}", path.as_ref().display()))?;
        let mut added = 0;
        for line in data.lines() {
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let freq = cols.next().and_then(|f| f.parse().ok()).unwrap_or(1000.0);
            if self.add(pinyin, word, freq).is_ok() {
                added += 1;
            }
        }
        Ok(added)
    }

    fn rebuild(&self) {
        let words = self.words.read().map(|w| w.clone()).unwrap_or_default();
        let mut tsv = String::new();
        for (pinyin, word, freq) in &words {
            tsv.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq));
        }
        if let Ok(lexicon) = MemoryLexicon::from_tsv_str(&tsv) {
            if let Ok(mut slot) = self.snapshot.write() {
                *slot = Arc::new(lexicon);
            }
        }
    }
}

impl Lexicon for UserLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup(query));
        }
        result
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup_fuzzy(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup_fuzzy(query));
        }
        result
    }

    fn total_freq(&self) -> f64 {
        self.base.total_freq() + self.snapshot.read().map(|s| s.total_freq()).unwrap_or(0.0)
    }

    fn len(&self) -> usize {
        self.base.len() + self.snapshot.read().map(|s| s.len()).unwrap_or(0)
    }
}

fn entry_matches(entry: &LexEntry, query: &[SyllableQuery]) -> bool {
    if entry.keys.len() != query.len() {
        return false;
    }
    query
        .iter()
        .zip(entry.keys.iter())
        .enumerate()
        .all(|(i, (q, key))| match q {
            SyllableQuery::Full { id, erhua } => key.id == *id && key.erhua == *erhua,
            SyllableQuery::Jianpin { letter } => entry.initials.get(i) == Some(letter),
        })
}

/// 解析词表里的拼音字段。
///
/// 允许：
/// - 单音节：xian
/// - 多音节：xi an / xi'an
/// - 儿化：hua r
///
/// 多音节不允许写成无分隔的连写，因为无法唯一切分（如 fangan）。
pub fn parse_pinyin_keys(pinyin: &str) -> Result<Vec<SyllableKey>> {
    let pinyin = pinyin.trim();
    if pinyin.is_empty() {
        bail!("拼音不能为空");
    }

    // 单音节优先：xian 必须解析成一个音节，而不是 xi + an。
    if !pinyin.contains([' ', '\t', '\'']) {
        let syl = Syllable::from_text(pinyin)
            .ok_or_else(|| anyhow!("未知音节: {pinyin}（多音节请用空格分隔）"))?;
        return Ok(vec![SyllableKey::new(syl.id, false)]);
    }

    let mut keys: Vec<SyllableKey> = Vec::new();
    for token in pinyin.split([' ', '\t', '\'']) {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        if token == "r" {
            match keys.last_mut() {
                Some(last) if !last.erhua => last.erhua = true,
                Some(_) => bail!("重复的儿化标记"),
                None => bail!("儿化标记 r 前面没有音节"),
            }
            continue;
        }
        let syl = Syllable::from_text(token).ok_or_else(|| anyhow!("未知音节: {token}"))?;
        keys.push(SyllableKey::new(syl.id, false));
    }
    if keys.is_empty() {
        bail!("拼音不能为空");
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lex() -> MemoryLexicon {
        MemoryLexicon::from_tsv_str(
            "xian\t先\t1000\nxi an\t西安\t500\nzhong guo\t中国\t800\nhua r\t花儿\t100\n",
        )
        .unwrap()
    }

    #[test]
    fn full_lookup() {
        let lex = lex();
        let xian = Syllable::from_text("xian").unwrap();
        let found = lex.lookup(&[xian.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "先");
    }

    #[test]
    fn apostrophe_and_multi_syllable() {
        let lex = lex();
        let xi = Syllable::from_text("xi").unwrap();
        let an = Syllable::from_text("an").unwrap();
        let found = lex.lookup(&[xi.query(false), an.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "西安");
    }

    #[test]
    fn jianpin_lookup() {
        let lex = lex();
        let found = lex.lookup(&[
            SyllableQuery::Jianpin { letter: b'z' },
            SyllableQuery::Jianpin { letter: b'g' },
        ]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "中国");
    }

    #[test]
    fn erhua_lookup() {
        let lex = lex();
        let hua = Syllable::from_text("hua").unwrap();
        let found = lex.lookup(&[hua.query(true)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "花儿");
        assert!(lex.lookup(&[hua.query(false)]).is_empty());
    }

    #[test]
    fn rejects_ambiguous_concatenation() {
        assert!(parse_pinyin_keys("fangan").is_err());
    }

    #[test]
    fn total_freq_and_cost() {
        let lex = lex();
        assert_eq!(lex.total_freq(), 2400.0);
        let entry = &lex.entries[0];
        assert!(lex.cost(entry) > 0.0);
    }
}
