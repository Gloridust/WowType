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

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::Path;
use std::sync::OnceLock;
use std::sync::{Arc, RwLock};

use anyhow::{anyhow, bail, Context, Result};

use crate::syllable::{Syllable, SyllableId, SyllableQuery};

/// 词库快照的魔数与格式版本。格式一变就改版本号，旧快照自动失效。
const CACHE_MAGIC: &[u8; 4] = b"WLC1";
const CACHE_VERSION: u32 = 1;

fn cache_path(path: &Path) -> std::path::PathBuf {
    let mut os = path.as_os_str().to_owned();
    os.push(".wcache");
    std::path::PathBuf::from(os)
}

/// 快照可能落的位置：先放词库旁边，写不进去（比如 /usr/share 只读）
/// 再放 XDG 缓存目录。
fn cache_paths(path: &Path) -> Vec<std::path::PathBuf> {
    let mut out = vec![cache_path(path)];
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".cache"))
        });
    if let Some(base) = base {
        // 用 FNV-1a 给路径算个短名字，避免不同词库撞在一起
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in path.to_string_lossy().as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
        out.push(base.join("wowtype").join(format!("{hash:016x}.wcache")));
    }
    out
}

/// 源文件的 (大小, 修改时间秒)。拿不到就不用缓存。
fn source_stamp(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some((meta.len(), mtime))
}

const KEY_HASH_SEED: u64 = 0xcbf2_9ce4_8422_2325;

/// 音节键序列的滚动哈希（FNV-1a）。
fn key_hash_step(hash: u64, key: SyllableKey) -> u64 {
    let raw = u64::from(key.id) | (u64::from(key.erhua) << 16);
    let mut h = hash;
    for byte in raw.to_le_bytes().iter().take(3) {
        h ^= u64::from(*byte);
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

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

    /// 是否存在比 query 更长、且以 query 开头的词。
    ///
    /// 束搜索靠它剪掉不可能成词的音节串；不确定时返回 true（只影响速度，不影响结果）。
    fn has_longer(&self, _query: &[SyllableQuery]) -> bool {
        true
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
    ///
    /// 默认不构建——模糊音默认关闭，而 55 万词库下建这张表要占掉不少加载时间。
    /// 第一次模糊查询时再建。
    fuzzy_index: OnceLock<HashMap<Vec<SyllableId>, Vec<usize>>>,
    /// 全拼词条所有「真前缀」的哈希，供 has_longer 剪枝（哈希碰撞只会少剪，不会错剪）。
    full_prefixes: HashSet<u64>,
    /// 同上，按声母：简拼和「全拼混简拼」（kyi、yongzwen）的查询用它剪枝。
    initial_prefixes: HashSet<u64>,
    total_freq: f64,
    /// 加载时被跳过的行数（未知音节等）。
    skipped: usize,
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

        self.add_entry(keys, initials, word.to_string(), freq);
        Ok(())
    }

    /// 已经解析好音节的词条入口（缓存加载用，跳过拼音解析）。
    fn add_entry(&mut self, keys: Vec<SyllableKey>, initials: Vec<u8>, word: String, freq: f64) {
        let idx = self.entries.len();
        self.entries.push(LexEntry {
            word,
            freq,
            keys: keys.clone(),
            initials: initials.clone(),
        });
        self.full_index.entry(keys.clone()).or_default().push(idx);
        self.jianpin_index
            .entry(initials.clone())
            .or_default()
            .push(idx);
        let mut hash = KEY_HASH_SEED;
        for key in keys.iter().take(keys.len().saturating_sub(1)) {
            hash = key_hash_step(hash, *key);
            self.full_prefixes.insert(hash);
        }
        let mut hash = KEY_HASH_SEED;
        for &letter in initials.iter().take(initials.len().saturating_sub(1)) {
            hash = initial_hash_step(hash, letter);
            self.initial_prefixes.insert(hash);
        }
        self.total_freq += freq;
    }

    /// 从 TSV 加载，并在旁边维护一份二进制快照。
    ///
    /// 55 万词库的 TSV 解析要 1.3 秒，快照能把这部分省掉。快照按
    /// 「源文件大小 + mtime + 格式版本」校验，词库更新后自动重建。
    pub fn from_tsv_path_cached<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let Some((len, mtime)) = source_stamp(path) else {
            return Self::from_tsv_path(path);
        };
        let candidates = cache_paths(path);
        for cache in &candidates {
            if let Ok(data) = fs::read(cache) {
                if let Some(lex) = Self::read_cache(&data, len, mtime) {
                    return Ok(lex);
                }
            }
        }
        let lex = Self::from_tsv_path(path)?;
        // 写失败不算错误：只读目录会退到 XDG 缓存目录，那里也不行就算了
        for cache in &candidates {
            if lex.write_cache(cache, len, mtime).is_ok() {
                break;
            }
        }
        Ok(lex)
    }

    fn write_cache(&self, cache: &Path, src_len: u64, src_mtime: u64) -> Result<()> {
        let mut buf: Vec<u8> = Vec::with_capacity(self.entries.len() * 24);
        buf.extend_from_slice(CACHE_MAGIC);
        buf.extend_from_slice(&CACHE_VERSION.to_le_bytes());
        buf.extend_from_slice(&src_len.to_le_bytes());
        buf.extend_from_slice(&src_mtime.to_le_bytes());
        buf.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        for entry in &self.entries {
            let word = entry.word.as_bytes();
            buf.extend_from_slice(&(word.len() as u16).to_le_bytes());
            buf.extend_from_slice(word);
            buf.extend_from_slice(&entry.freq.to_le_bytes());
            buf.push(entry.keys.len() as u8);
            for key in &entry.keys {
                let raw = (key.id & 0x7fff) | (u16::from(key.erhua) << 15);
                buf.extend_from_slice(&raw.to_le_bytes());
            }
            buf.push(entry.initials.len() as u8);
            buf.extend_from_slice(&entry.initials);
        }
        if let Some(parent) = cache.parent() {
            fs::create_dir_all(parent).ok();
        }
        let tmp = cache.with_extension("wcache.tmp");
        fs::write(&tmp, &buf).with_context(|| format!("写词库快照失败: {}", tmp.display()))?;
        fs::rename(&tmp, cache)
            .with_context(|| format!("替换词库快照失败: {}", cache.display()))?;
        Ok(())
    }

    fn read_cache(data: &[u8], src_len: u64, src_mtime: u64) -> Option<MemoryLexicon> {
        if data.len() < 24 || &data[0..4] != CACHE_MAGIC {
            return None;
        }
        let version = u32::from_le_bytes(data[4..8].try_into().ok()?);
        if version != CACHE_VERSION {
            return None;
        }
        if u64::from_le_bytes(data[8..16].try_into().ok()?) != src_len
            || u64::from_le_bytes(data[16..24].try_into().ok()?) != src_mtime
        {
            return None;
        }
        let count = u32::from_le_bytes(data[24..28].try_into().ok()?) as usize;
        let mut cursor = 28usize;
        let mut lex = MemoryLexicon::new();
        for _ in 0..count {
            let word_len =
                u16::from_le_bytes(data.get(cursor..cursor + 2)?.try_into().ok()?) as usize;
            cursor += 2;
            let word = std::str::from_utf8(data.get(cursor..cursor + word_len)?)
                .ok()?
                .to_string();
            cursor += word_len;
            let freq = f64::from_le_bytes(data.get(cursor..cursor + 8)?.try_into().ok()?);
            cursor += 8;
            let n_keys = *data.get(cursor)? as usize;
            cursor += 1;
            let mut keys = Vec::with_capacity(n_keys);
            for _ in 0..n_keys {
                let raw = u16::from_le_bytes(data.get(cursor..cursor + 2)?.try_into().ok()?);
                cursor += 2;
                keys.push(SyllableKey::new(raw & 0x7fff, raw & 0x8000 != 0));
            }
            let n_initials = *data.get(cursor)? as usize;
            cursor += 1;
            let initials = data.get(cursor..cursor + n_initials)?.to_vec();
            cursor += n_initials;
            lex.add_entry(keys, initials, word, freq);
        }
        Some(lex)
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
            // 音节不认识（各地方言音、冷僻拼音）时跳过这一行，
            // 不要让一条脏数据毁掉整个词库。
            match lex.insert(pinyin, word, freq) {
                Ok(()) => {}
                Err(_) => lex.skipped += 1,
            }
        }
        Ok(lex)
    }

    fn build_fuzzy_index(&self) -> HashMap<Vec<SyllableId>, Vec<usize>> {
        let mut map: HashMap<Vec<SyllableId>, Vec<usize>> = HashMap::new();
        for (idx, entry) in self.entries.iter().enumerate() {
            if let Some(fuzzy) = entry
                .keys
                .iter()
                .map(|k| crate::syllable::fuzzy_id(k.id))
                .collect::<Option<Vec<_>>>()
            {
                map.entry(fuzzy).or_default().push(idx);
            }
        }
        map
    }

    /// 加载时被跳过的行数。
    pub fn skipped(&self) -> usize {
        self.skipped
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

        // 全拼混简拼（k yi -> 可以）：先按声母查，再逐个比对全拼的那几个音节
        let Some(initials) = query_initials(query) else {
            return Vec::new();
        };
        self.jianpin_index
            .get(&initials)
            .map(|idxs| {
                idxs.iter()
                    .filter(|&&i| entry_matches(&self.entries[i], query))
                    .map(|&i| self.entries[i].clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        if query.iter().any(|q| q.is_jianpin()) {
            // 简拼、混合查询按声母剪（只看声母会少剪一些，不会错剪）
            let Some(initials) = query_initials(query) else {
                return true;
            };
            let hash = initials
                .iter()
                .fold(KEY_HASH_SEED, |h, &letter| initial_hash_step(h, letter));
            return self.initial_prefixes.contains(&hash);
        }
        let mut hash = KEY_HASH_SEED;
        for q in query {
            if let SyllableQuery::Full { id, erhua } = q {
                hash = key_hash_step(hash, SyllableKey::new(*id, *erhua));
            }
        }
        self.full_prefixes.contains(&hash)
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
        let index = self.fuzzy_index.get_or_init(|| self.build_fuzzy_index());
        index
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
    /// 自定义词（设置里添加的，存在 custom.tsv）：只读，整份替换，不写回用户词库。
    custom: RwLock<Vec<(String, String, f64)>>,
    snapshot: RwLock<Arc<MemoryLexicon>>,
}

/// 自定义词默认频次：和最常用的词差不多，所以排在同音词前面。
pub const CUSTOM_WORD_FREQ: f64 = 5_000_000.0;

impl UserLexicon {
    pub fn new(base: Arc<dyn Lexicon>) -> Self {
        Self {
            base,
            words: RwLock::new(Vec::new()),
            custom: RwLock::new(Vec::new()),
            snapshot: RwLock::new(Arc::new(MemoryLexicon::new())),
        }
    }

    /// 添加或更新一个用户词。拼音可以是 ni hao / nihao / xi'an。
    pub fn add(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() || pinyin.trim().is_empty() {
            bail!("用户词的拼音和词都不能为空");
        }
        // 先单独校验一次，拼音非法时不要污染词库。
        // 注意不能借用 from_tsv_str：它对未知音节是「跳过」而不是报错。
        parse_pinyin_keys(pinyin.trim()).context("用户词拼音无法解析")?;

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

    /// 用一份自定义词整体替换现有的。格式 `拼音<TAB>词[<TAB>频次]`，
    /// 拼音不合法的行跳过。返回收下的条数。
    pub fn set_custom_tsv(&self, data: &str) -> usize {
        let mut custom = Vec::new();
        for line in data.lines() {
            let line = line.trim_end_matches('\r');
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let (pinyin, word) = (pinyin.trim(), word.trim());
            if pinyin.is_empty() || word.is_empty() || parse_pinyin_keys(pinyin).is_err() {
                continue;
            }
            let freq = cols
                .next()
                .and_then(|f| f.trim().parse::<f64>().ok())
                .filter(|f| f.is_finite() && *f > 0.0)
                .unwrap_or(CUSTOM_WORD_FREQ);
            custom.push((pinyin.to_string(), word.to_string(), freq));
        }
        let count = custom.len();
        if let Ok(mut slot) = self.custom.write() {
            *slot = custom;
        }
        self.rebuild();
        count
    }

    /// 从文件读自定义词（整体替换）；文件不存在就清空。
    pub fn load_custom<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let path = path.as_ref();
        match fs::read_to_string(path) {
            Ok(data) => Ok(self.set_custom_tsv(&data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(self.set_custom_tsv("")),
            Err(e) => Err(e).with_context(|| format!("读取自定义词失败: {}", path.display())),
        }
    }

    /// 是不是设置里添加的自定义词。
    pub fn is_custom(&self, word: &str) -> bool {
        self.custom
            .read()
            .map(|c| c.iter().any(|(_, w, _)| w == word))
            .unwrap_or(false)
    }

    pub fn custom_words(&self) -> Vec<(String, String, f64)> {
        self.custom.read().map(|w| w.clone()).unwrap_or_default()
    }

    fn rebuild(&self) {
        let mut words = self.words.read().map(|w| w.clone()).unwrap_or_default();
        words.extend(self.custom_words());
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

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        self.base.has_longer(query)
            || self
                .snapshot
                .read()
                .map(|s| s.has_longer(query))
                .unwrap_or(true)
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

/// 查询每个音节的声母（全拼音节取首字母，和词条的 initials 一样）。
fn query_initials(query: &[SyllableQuery]) -> Option<Vec<u8>> {
    query
        .iter()
        .map(|q| match q {
            SyllableQuery::Full { id, .. } => Syllable::from_id(*id).map(|s| s.initial_letter()),
            SyllableQuery::Jianpin { letter } => Some(*letter),
        })
        .collect()
}

fn initial_hash_step(hash: u64, letter: u8) -> u64 {
    (hash ^ u64::from(letter)).wrapping_mul(0x1000_0000_01b3)
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
    fn mixed_lookup_and_prune() {
        let mut lex = MemoryLexicon::new();
        lex.insert("zhong wen", "中文", 100.0).unwrap();
        lex.insert("zheng wen", "正文", 50.0).unwrap();
        lex.insert("zhong guo ren", "中国人", 80.0).unwrap();
        let wen = Syllable::from_text("wen").unwrap().query(false);
        let guo = Syllable::from_text("guo").unwrap().query(false);
        let z = SyllableQuery::Jianpin { letter: b'z' };
        let words: Vec<String> = lex.lookup(&[z, wen]).into_iter().map(|e| e.word).collect();
        assert_eq!(words.len(), 2, "{words:?}");
        assert!(words.contains(&"中文".to_string()));
        // 剪枝按声母：z guo 后面还有中国人，z wen 后面没有更长的词
        assert!(lex.has_longer(&[z, guo]));
        assert!(!lex.has_longer(&[z, wen]));
        assert!(lex.has_longer(&[z]));
        assert!(!lex.has_longer(&[SyllableQuery::Jianpin { letter: b'q' }]));
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

    #[test]
    fn lenient_loading_skips_unknown_syllables() {
        // 「cei」不在音节表里，整行跳过而不是让整个词库失败
        let lex = MemoryLexicon::from_tsv_str("ni hao\t你好\t100\ncei\t呲\t5\n").unwrap();
        assert_eq!(lex.len(), 1);
        assert_eq!(lex.skipped(), 1);
    }

    #[test]
    fn structural_errors_still_fail() {
        assert!(MemoryLexicon::from_tsv_str("只有两列\t词\n").is_err());
        assert!(MemoryLexicon::from_tsv_str("ni hao\t你好\tabc\n").is_err());
    }

    fn temp_lexicon(tag: &str, body: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("wowtype_lex_{}_{}.tsv", tag, std::process::id()));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(cache_path(&path));
        std::fs::write(&path, body).expect("写临时词库失败");
        path
    }

    fn cleanup(path: &std::path::Path) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(cache_path(path));
    }

    #[test]
    fn cache_roundtrip_matches_tsv() {
        let path = temp_lexicon("rt", "ni hao\t你好\t100\nzhong guo\t中国\t50\n");
        let first = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert!(cache_path(&path).exists(), "第一次加载应当写出快照");
        let second = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(first.len(), second.len());
        assert_eq!(first.entries, second.entries);
        assert_eq!(first.total_freq, second.total_freq);
        cleanup(&path);
    }

    #[test]
    fn stale_cache_is_ignored() {
        let path = temp_lexicon("stale", "ni hao\t你好\t100\n");
        let first = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(first.len(), 1);
        // 源文件变了（内容更长），旧快照必须失效
        std::fs::write(
            &path,
            "ni hao\t你好\t100\nzhong guo\t中国\t50\nshi jie\t世界\t30\n",
        )
        .unwrap();
        let second = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(second.len(), 3, "源文件更新后应当重新解析");
        cleanup(&path);
    }

    #[test]
    fn corrupt_cache_falls_back_to_tsv() {
        let path = temp_lexicon("corrupt", "ni hao\t你好\t100\n");
        let _ = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        std::fs::write(cache_path(&path), b"not a cache").unwrap();
        let lex = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(lex.len(), 1, "快照损坏时应回退到 TSV");
        cleanup(&path);
    }
}
