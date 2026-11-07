//! Wowtype 拼音引擎骨架。
//!
//! 流水线：
//! 输入预处理 -> 音节图 -> 束搜索（词典 + 二元 LM） -> 特征/线性打分 -> 候选。
//! LTR / 神经重排 / MixRank 只在接口上预留，尚未接入真实模型。

pub mod beam;
pub mod convert;
pub mod ffi;
pub mod graph;
pub mod lexicon;
pub mod lm;
pub mod rank;
pub mod shuangpin;
pub mod syllable;
pub mod symbols;
pub mod train;

use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

pub use crate::beam::{beam_search, BeamConfig, BeamPath, BeamWord};
pub use crate::convert::Converter;
pub use crate::graph::{Edge, EdgeKind, GraphMode, GraphOptions, SyllableGraph};
pub use crate::lexicon::{
    FuzzyLexicon, LexEntry, Lexicon, MemoryLexicon, SyllableKey, UserLexicon,
};
pub use crate::lm::{ArpaLm, BigramLm, LanguageModel};
pub use crate::rank::{
    Feature, FeatureWeights, LinearRanker, LtrModel, Ranker, FEATURE_COUNT, FEATURE_NAMES,
};
pub use crate::syllable::{
    is_valid, parse, split, ParseError, ParsedInput, Syllable, SyllableId, SyllableQuery, SYLLABLES,
};

/// 最终候选。
#[derive(Clone, Debug)]
pub struct Candidate {
    pub text: String,
    pub pinyin: String,
    pub score: f64,
    pub features: Feature,
    pub words: Vec<CandidateWord>,
    /// 这个候选用掉了原始输入的前多少字节。
    ///
    /// 整句候选等于输入长度；句首词候选（长句先选「你好」，剩下的接着打）更短，
    /// 前端上屏后应把剩余部分留在输入框里继续转换。
    pub consumed: usize,
}

/// 候选内的一个分词。
#[derive(Clone, Debug)]
pub struct CandidateWord {
    pub text: String,
    pub pinyin: String,
    pub freq: f64,
    pub known: bool,
}

/// 引擎配置。
#[derive(Clone, Debug)]
pub struct EngineConfig {
    pub beam: BeamConfig,
    pub max_candidates: usize,
    /// 全拼走不通时是否尝试简拼（zg -> 中国）。
    pub jianpin_fallback: bool,
    /// 是否启用模糊音（z/zh、c/ch、s/sh、an/ang、en/eng、in/ing）。
    pub fuzzy: bool,
    /// 模糊候选的分数惩罚（自然对数），越大越靠后。
    pub fuzzy_penalty: f64,
    /// 是否使用双拼（自然码方案）。
    pub shuangpin: bool,
    /// 是否在候选末尾追加原始输入（英文/未登录串）。
    pub english_candidate: bool,
    /// 是否把候选转成繁体。
    pub traditional: bool,
    /// 选词达到阈值后自动加入用户词库。
    pub auto_learn: bool,
    /// 自动学习阈值（选多少次后进用户词库）。
    pub auto_learn_threshold: u32,
    /// 按错键纠错（相邻键、两键按反、多按/漏按）。双拼下不生效。
    pub typo_correction: bool,
    /// 句首词候选最多几个（0 表示不给）。长句打错时可以先选开头的词。
    pub prefix_candidates: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            beam: BeamConfig::default(),
            max_candidates: 10,
            jianpin_fallback: true,
            fuzzy: false,
            fuzzy_penalty: 2.5,
            shuangpin: false,
            english_candidate: true,
            traditional: false,
            auto_learn: true,
            auto_learn_threshold: 3,
            typo_correction: true,
            prefix_candidates: 12,
        }
    }
}

/// 用户历史里的一条记录。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub count: u32,
    /// 上次使用时间（epoch 毫秒）。
    pub last_used_ms: u64,
}

/// 当前时间（epoch 毫秒）。
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 拼音引擎。
pub struct Engine {
    /// 原始词库（只读）。
    base_lexicon: Arc<dyn Lexicon>,
    /// 基础词库 + 用户词的合并视图，束搜索实际用它。
    lexicon: Arc<UserLexicon>,
    lm: Arc<dyn LanguageModel>,
    ranker: Arc<dyn Ranker>,
    config: EngineConfig,
    /// 用户选词历史：候选文本 -> (次数, 上次时间)。
    history: RwLock<HashMap<String, HistoryEntry>>,
    /// 光标前已上屏的文本，用于上下文 bigram 特征。
    context: RwLock<String>,
    /// 简繁字符映射表。
    converter: RwLock<Arc<Converter>>,
    /// 英文词表：小写编码 -> 上屏形式（github -> GitHub）。
    english: RwLock<Arc<HashMap<String, String>>>,
}

impl Engine {
    pub fn new(lexicon: Arc<dyn Lexicon>, lm: Arc<dyn LanguageModel>) -> Self {
        let merged = Arc::new(UserLexicon::new(lexicon.clone()));
        Self {
            base_lexicon: lexicon,
            lexicon: merged,
            lm,
            ranker: Arc::new(LinearRanker::default()),
            config: EngineConfig::default(),
            history: RwLock::new(HashMap::new()),
            context: RwLock::new(String::new()),
            converter: RwLock::new(Arc::new(Converter::new())),
            english: RwLock::new(Arc::new(HashMap::new())),
        }
    }

    /// 设置光标前的文本（上一次上屏的内容）。
    pub fn set_context(&self, text: &str) {
        if let Ok(mut slot) = self.context.write() {
            slot.clear();
            slot.push_str(text);
        }
    }

    pub fn context(&self) -> String {
        self.context.read().map(|s| s.clone()).unwrap_or_default()
    }

    /// 记录一次选词，用于历史特征。时间戳取当前时间。
    pub fn record_selection(&self, word: &str) {
        self.record_selection_at(word, now_ms());
    }

    /// 记录选词；当同一个词选够次数后自动加入用户词库。
    ///
    /// pinyin 是这次上屏时输入的拼音（用于生成用户词条）。词库里已有的词也会被
    /// 加成用户词——这等价于「记住用户的偏好」，不会覆盖原词条。
    pub fn record_selection_with_pinyin(&self, word: &str, pinyin: Option<&str>) {
        self.record_selection(word);
        if !self.config.auto_learn || word.is_empty() {
            return;
        }
        let Some(pinyin) = pinyin.filter(|p| !p.trim().is_empty()) else {
            return;
        };
        let count = self.history_count(word);
        if count < self.config.auto_learn_threshold.max(1) {
            return;
        }
        // 双拼模式下上游传进来的是键位串（如 "vsgo"），要先展开成全拼，
        // 否则用户词会带着一串无效音节存进去，永远也打不出来。
        let pinyin = if self.config.shuangpin {
            crate::shuangpin::to_full_pinyin(pinyin)
        } else {
            pinyin.to_string()
        };
        if pinyin.trim().is_empty() {
            return;
        }
        // 频次随选用次数增长但有上限，避免用户词压过通用高频词
        let freq = (1000.0 * f64::from(count)).min(50_000.0);
        let _ = self.lexicon.add(&pinyin, word, freq);
    }

    /// 带时间戳的选词记录（方便测试）。
    pub fn record_selection_at(&self, word: &str, at_ms: u64) {
        if word.is_empty() {
            return;
        }
        if let Ok(mut history) = self.history.write() {
            let entry = history.entry(word.to_string()).or_insert(HistoryEntry {
                count: 0,
                last_used_ms: at_ms,
            });
            entry.count = entry.count.saturating_add(1);
            entry.last_used_ms = at_ms;
        }
    }

    pub fn history_count(&self, word: &str) -> u32 {
        self.history
            .read()
            .ok()
            .and_then(|h| h.get(word).map(|e| e.count))
            .unwrap_or(0)
    }

    pub fn with_config(mut self, config: EngineConfig) -> Self {
        self.config = config;
        self
    }

    pub fn with_ranker(mut self, ranker: Arc<dyn Ranker>) -> Self {
        self.ranker = ranker;
        self
    }

    pub fn set_beam_size(&mut self, beam_size: usize) {
        self.config.beam.beam_size = beam_size.max(1);
    }

    /// 开关模糊音。
    pub fn set_fuzzy(&mut self, on: bool) {
        self.config.fuzzy = on;
    }

    /// 开关双拼（自然码）。
    pub fn set_typo_correction(&mut self, on: bool) {
        self.config.typo_correction = on;
    }

    pub fn set_shuangpin(&mut self, on: bool) {
        self.config.shuangpin = on;
    }

    /// 开关繁体输出。
    pub fn set_traditional(&mut self, on: bool) {
        self.config.traditional = on;
    }

    /// 载入简繁映射表，返回条目数。
    /// 载入英文词表，返回词条数。
    ///
    /// 每行一个词；也直接接受 rime 的 en.dict.yaml（「上屏<TAB>编码」，
    /// 注释和 YAML 头会被跳过）。只收 2~32 个字母的编码。
    pub fn load_english<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let text = std::fs::read_to_string(path)?;
        Ok(self.load_english_str(&text))
    }

    /// 从字符串载入英文词表（追加），返回累计词条数。
    pub fn load_english_str(&self, text: &str) -> usize {
        let mut map: HashMap<String, String> = self
            .english
            .read()
            .map(|m| m.as_ref().clone())
            .unwrap_or_default();
        for line in text.lines() {
            let line = line.trim_end_matches('\r');
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let mut cols = line.split('\t');
            let word = cols.next().unwrap_or("").trim();
            let code = cols.next().map(str::trim).unwrap_or(word);
            if code.len() < 2 || code.len() > 32 || !code.bytes().all(|b| b.is_ascii_alphabetic()) {
                continue;
            }
            if word.is_empty() || !word.eq_ignore_ascii_case(code) {
                // 缩写（January<TAB>Jan）只认上屏与编码一致的条目
                continue;
            }
            let key = code.to_ascii_lowercase();
            match map.entry(key) {
                Entry::Vacant(slot) => {
                    slot.insert(word.to_string());
                }
                Entry::Occupied(mut slot) => {
                    // 同一个词有大小写两种写法时，留全小写的（march 而不是 March）
                    if word.bytes().all(|b| !b.is_ascii_uppercase()) {
                        slot.insert(word.to_string());
                    }
                }
            }
        }
        let len = map.len();
        if let Ok(mut slot) = self.english.write() {
            *slot = Arc::new(map);
        }
        len
    }

    pub fn english_len(&self) -> usize {
        self.english.read().map(|m| m.len()).unwrap_or(0)
    }

    pub fn load_conversion<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let conv = Converter::from_tsv_path(path)?;
        let len = conv.len();
        if let Ok(mut slot) = self.converter.write() {
            *slot = Arc::new(conv);
        }
        Ok(len)
    }

    /// 直接装载一张映射表（测试或程序内生成时用）。
    pub fn install_converter(&self, conv: Converter) {
        if let Ok(mut slot) = self.converter.write() {
            *slot = Arc::new(conv);
        }
    }

    pub fn conversion_len(&self) -> usize {
        self.converter.read().map(|c| c.len()).unwrap_or(0)
    }

    /// 把候选（含分词）转成繁体，并合并转换后重复的候选。
    fn apply_traditional(&self, candidates: &mut Vec<Candidate>) {
        let conv = match self.converter.read() {
            Ok(slot) if !slot.is_empty() => slot.clone(),
            _ => return,
        };
        let mut best: HashMap<String, Candidate> = HashMap::new();
        for mut candidate in std::mem::take(candidates) {
            candidate.text = conv.convert(&candidate.text);
            for word in &mut candidate.words {
                word.text = conv.convert(&word.text);
            }
            match best.entry(candidate.text.clone()) {
                Entry::Vacant(slot) => {
                    slot.insert(candidate);
                }
                Entry::Occupied(mut slot) => {
                    if candidate.score > slot.get().score {
                        slot.insert(candidate);
                    }
                }
            }
        }
        let mut list: Vec<Candidate> = best.into_values().collect();
        list.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        list.truncate(self.config.max_candidates.max(1));
        *candidates = list;
    }

    pub fn set_max_candidates(&mut self, max_candidates: usize) {
        self.config.max_candidates = max_candidates.max(1);
    }

    pub fn lexicon(&self) -> &Arc<UserLexicon> {
        &self.lexicon
    }

    pub fn base_lexicon(&self) -> &Arc<dyn Lexicon> {
        &self.base_lexicon
    }

    /// 添加用户词（拼音可以是 ni hao / nihao / xi'an）。
    pub fn add_user_word(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        self.lexicon.add(pinyin, word, freq)
    }

    /// 删除用户词，返回是否删掉了。
    pub fn remove_user_word(&self, word: &str) -> bool {
        self.lexicon.remove(word)
    }

    pub fn user_words(&self) -> Vec<(String, String, f64)> {
        self.lexicon.words()
    }

    pub fn save_user_dict<P: AsRef<std::path::Path>>(&self, path: P) -> Result<()> {
        self.lexicon.save_tsv(path)
    }

    pub fn load_user_dict<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        self.lexicon.load_tsv(path)
    }

    pub fn lm(&self) -> &Arc<dyn LanguageModel> {
        &self.lm
    }

    pub fn config(&self) -> &EngineConfig {
        &self.config
    }

    /// 输入拼音串，返回候选；解析失败时返回空列表。
    /// 基于上一词的候选预测（「预测词库」）。
    ///
    /// 返回 (词, 对数概率)，按概率降序。语言模型没接入预测能力时返回空。
    pub fn predict_next(&self, prev: &str, limit: usize) -> Vec<(String, f64)> {
        self.lm.top_next(prev, limit)
    }

    pub fn input(&self, raw: &str) -> Vec<Candidate> {
        self.input_at(raw, now_ms())
    }

    /// 带时间戳的输入：历史特征的时间衰减按 at_ms 计算，便于测试与回放。
    pub fn input_at(&self, raw: &str, at_ms: u64) -> Vec<Candidate> {
        self.try_input_at(raw, at_ms).unwrap_or_default()
    }

    /// 可返回错误的版本，供 CLI/FFI 使用。
    pub fn try_input(&self, raw: &str) -> Result<Vec<Candidate>> {
        self.try_input_at(raw, now_ms())
    }

    pub fn try_input_at(&self, raw: &str, at_ms: u64) -> Result<Vec<Candidate>> {
        let display = raw.trim();
        let normalized = display.to_ascii_lowercase();

        let mut result = if self.config.shuangpin {
            // 双拼：先把键位展开成全拼变体（自然码有少量重叠），每种都跑一遍再合并。
            let variants = crate::shuangpin::to_full_pinyin_variants(&normalized);
            let mut merged: HashMap<String, Candidate> = HashMap::new();
            for variant in &variants {
                for candidate in self.query_plain(variant, at_ms)? {
                    match merged.entry(candidate.text.clone()) {
                        Entry::Vacant(slot) => {
                            slot.insert(candidate);
                        }
                        Entry::Occupied(mut slot) => {
                            if candidate.score > slot.get().score {
                                slot.insert(candidate);
                            }
                        }
                    }
                }
            }
            let mut list: Vec<Candidate> = merged.into_values().collect();
            list.sort_by(|a, b| {
                b.score
                    .total_cmp(&a.score)
                    .then_with(|| a.text.cmp(&b.text))
            });
            list.truncate(self.config.max_candidates.max(1));
            list
        } else {
            self.query_plain(&normalized, at_ms)?
        };

        self.append_raw_candidate(display, &mut result);
        if self.config.traditional {
            self.apply_traditional(&mut result);
        }
        for candidate in &mut result {
            candidate.consumed = raw.len();
        }
        if !self.config.shuangpin && self.config.prefix_candidates > 0 {
            let leading = raw.len() - raw.trim_start().len();
            let mut prefix = self.prefix_candidates(&normalized)?;
            for candidate in &mut prefix {
                candidate.consumed = leading + letters_to_bytes(display, candidate.consumed);
                if self.config.traditional {
                    if let Ok(conv) = self.converter.read() {
                        if !conv.is_empty() {
                            candidate.text = conv.convert(&candidate.text);
                        }
                    }
                }
            }
            merge_prefix_candidates(&mut result, prefix);
        }
        Ok(result)
    }

    /// 句首词候选：从输入开头起、但没有用完整个输入的词。
    ///
    /// candidate.consumed 先存「用掉的字母数」，由调用方换算成字节。
    fn prefix_candidates(&self, normalized: &str) -> Result<Vec<Candidate>> {
        let Ok(parsed) = parse(normalized) else {
            return Ok(Vec::new());
        };
        if parsed.len() < 2 {
            return Ok(Vec::new());
        }
        let typo = self.config.typo_correction;
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo,
                completion: false,
            },
        );
        let graph = if full.has_exact_path() || !self.config.jianpin_fallback {
            full
        } else {
            let jianpin = SyllableGraph::build(
                &parsed,
                GraphOptions {
                    mode: GraphMode::Jianpin,
                    allow_erhua: false,
                    typo: false,
                    completion: false,
                },
            );
            if jianpin.has_complete_path() {
                jianpin
            } else {
                full
            }
        };
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if self.config.fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref());
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let words = crate::beam::first_words(
            &graph,
            lexicon,
            &self.config.beam,
            self.config.prefix_candidates,
        );
        Ok(words
            .into_iter()
            .map(|(word, cost)| Candidate {
                text: word.text.clone(),
                pinyin: word.pinyin.clone(),
                score: -cost,
                features: Feature {
                    typo_count: word.typos as f32,
                    typo: if word.typos > 0 { 1.0 } else { 0.0 },
                    ..Feature::default()
                },
                consumed: word.end,
                words: vec![CandidateWord {
                    text: word.text,
                    pinyin: word.pinyin,
                    freq: word.freq,
                    known: true,
                }],
            })
            .collect())
    }

    /// 全拼下输入能否不靠纠错、补全切成完整音节。
    fn is_plain_pinyin(&self, display: &str) -> bool {
        if self.config.shuangpin {
            return false;
        }
        let Ok(parsed) = parse(&display.to_ascii_lowercase()) else {
            return false;
        };
        SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo: false,
                completion: false,
            },
        )
        .has_complete_path()
    }

    /// 英文/未登录输入：保证原始输入本身可以作为候选上屏。
    ///
    /// 放在第几位：
    /// - 拼音完整、没纠错的中文排前面，原始串垫底（she -> 社 设 ……）；
    /// - 输入是已知英文词，而中文要靠纠错才凑得出来：英文排第一
    ///   （hello、github、python 不该被改成乱码中文）；中文只差最后一个音节没打完
    ///   （bug、diy）时排第二；拼音本身就完整（she、long）时排第三；
    /// - 不认识的串：中文全是未登录兜底时排第一，中文纠了 2 处以上排第二，其余垫底。
    ///
    /// 原始串一定留在列表里，不会被截断挤掉。
    fn append_raw_candidate(&self, display: &str, candidates: &mut Vec<Candidate>) {
        if !self.config.english_candidate || display.is_empty() || display.len() > 32 {
            return;
        }
        if !display.bytes().any(|b| b.is_ascii_alphabetic()) {
            return;
        }
        // 全小写输入且词表里有标准写法时用标准写法（github -> GitHub）
        let english = self
            .english
            .read()
            .ok()
            .and_then(|m| m.get(&display.to_ascii_lowercase()).cloned());
        let text = match &english {
            Some(word) if display.bytes().all(|b| !b.is_ascii_uppercase()) => word.clone(),
            _ => display.to_string(),
        };
        if candidates.iter().any(|c| c.text.eq_ignore_ascii_case(&text)) {
            return;
        }
        // 输入本身是不是一串完整的拼音（she、me、long），或者已经有不靠纠错和
        // 补全的完整中文候选（双拼下只能看后者）
        let exact = self.is_plain_pinyin(display)
            || candidates.iter().any(|c| {
                c.features.coverage_score >= 1.0
                    && c.features.typo_count == 0.0
                    && c.features.prefix_completion == 0.0
                    && !c.words.iter().any(|w| !w.known)
            });
        let top_typos = candidates
            .first()
            .map(|c| c.features.typo_count)
            .unwrap_or(0.0);
        let has_known_word = candidates
            .first()
            .map(|c| c.words.iter().any(|w| w.known))
            .unwrap_or(false);
        let position = if english.is_some() {
            if exact {
                Some(2)
            } else if top_typos == 0.0 && has_known_word {
                // 中文只是最后一个音节没打完（bug -> 不过、diy -> 第一），
                // 用户多半还在打拼音，英文排第二
                Some(1)
            } else {
                Some(0)
            }
        } else if exact {
            // 拼音完整的中文，原始拼音串没必要出现
            return;
        } else if !has_known_word {
            Some(0)
        } else if top_typos >= 2.0 {
            Some(1)
        } else {
            None
        };
        let max = self.config.max_candidates.max(1);
        let at = position.unwrap_or(candidates.len()).min(candidates.len());
        // 分数夹在前后两个候选之间，后面无论怎么重新排序（繁体转换会重排）位置都不变
        let score = match (at.checked_sub(1).and_then(|i| candidates.get(i)), candidates.get(at)) {
            (None, None) => -1.0,
            (None, Some(next)) => next.score + 1.0,
            (Some(prev), None) => prev.score - 1.0,
            (Some(prev), Some(next)) => (prev.score + next.score) / 2.0,
        };
        let raw = Candidate {
            text,
            pinyin: display.to_ascii_lowercase(),
            score,
            features: Feature::default(),
            words: vec![CandidateWord {
                text: display.to_string(),
                pinyin: String::new(),
                freq: 0.0,
                known: english.is_some(),
            }],
            consumed: display.len(),
        };
        candidates.insert(at, raw);
        if candidates.len() > max {
            // 截掉的是原始串以外的最后一个
            let drop = if at == candidates.len() - 1 {
                candidates.len() - 2
            } else {
                candidates.len() - 1
            };
            candidates.remove(drop);
        }
    }

    /// 单条全拼输入的完整查询（精确 + 可选模糊音）。
    fn query_plain(&self, normalized: &str, at_ms: u64) -> Result<Vec<Candidate>> {
        let exact = self.run_query(normalized, at_ms, false)?;
        if !self.config.fuzzy {
            return Ok(exact);
        }
        let fuzzy = self.run_query(normalized, at_ms, true)?;
        if fuzzy.is_empty() {
            return Ok(exact);
        }
        // 精确结果优先；模糊候选统一扣一点分，避免抢在精确命中前面。
        let mut merged: HashMap<String, Candidate> = HashMap::new();
        for candidate in exact {
            merged.insert(candidate.text.clone(), candidate);
        }
        for mut candidate in fuzzy {
            candidate.score -= self.config.fuzzy_penalty;
            match merged.entry(candidate.text.clone()) {
                Entry::Vacant(slot) => {
                    slot.insert(candidate);
                }
                Entry::Occupied(mut slot) => {
                    if candidate.score > slot.get().score {
                        slot.insert(candidate);
                    }
                }
            }
        }
        let mut result: Vec<Candidate> = merged.into_values().collect();
        result.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        result.truncate(self.config.max_candidates.max(1));
        Ok(result)
    }

    /// 跑一次查询；fuzzy=true 时查不到会回退模糊音。
    ///
    /// 末音节补全（zhongg -> 中国、zhonggu -> 中国）和纠错都做成了音节图里的边，
    /// 一次搜索就能同时给出精确、补全、纠错三类候选。
    fn run_query(&self, normalized: &str, at_ms: u64, fuzzy: bool) -> Result<Vec<Candidate>> {
        let parsed = parse(normalized)?;
        if parsed.is_empty() {
            return Ok(Vec::new());
        }
        let typo = self.config.typo_correction && !self.config.shuangpin;
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo,
                completion: true,
            },
        );
        // 不靠补全、纠错就能完整解析：直接用全拼
        if full.has_exact_path() {
            return self.query_once(&full, at_ms, fuzzy);
        }
        // 否则简拼（zg、jzm）与全拼补全/纠错都试，按分数合并
        let mut merged: Vec<Candidate> = Vec::new();
        if self.config.jianpin_fallback {
            let jianpin = SyllableGraph::build(
                &parsed,
                GraphOptions {
                    mode: GraphMode::Jianpin,
                    allow_erhua: false,
                    typo: false,
                    completion: false,
                },
            );
            if jianpin.has_complete_path() {
                merged.extend(self.query_once(&jianpin, at_ms, fuzzy)?);
            }
        }
        if full.has_complete_path() {
            merged.extend(self.query_once(&full, at_ms, fuzzy)?);
        }
        let mut result = dedupe_by_text(merged);
        result.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        result.truncate(self.config.max_candidates.max(1));
        Ok(result)
    }

    fn query_once(
        &self,
        graph: &SyllableGraph,
        at_ms: u64,
        fuzzy: bool,
    ) -> Result<Vec<Candidate>> {
        // fuzzy 时用包装视图：精确查不到再退到模糊音。
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref());
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let mut paths = beam_search(graph, lexicon, self.lm.as_ref(), &self.config.beam);
        if paths.is_empty() {
            return Ok(Vec::new());
        }

        // 有完整覆盖路径时只保留完整覆盖，避免 西an / xi安 这类半拼音候选。
        // 否则退而求其次，保留有部分词典命中的路径；全未登录时保留兜底路径。
        if paths.iter().any(|p| p.coverage >= 1.0) {
            paths.retain(|p| p.coverage >= 1.0);
        } else if paths.iter().any(|p| p.coverage > 0.0) {
            paths.retain(|p| p.coverage > 0.0);
        }

        let best_score = paths
            .iter()
            .map(|p| p.score)
            .fold(f64::NEG_INFINITY, f64::max);

        let candidates: Vec<Candidate> = paths
            .into_iter()
            .map(|path| self.make_candidate(path, best_score, at_ms))
            .collect();

        let mut deduped = dedupe_by_text(candidates);
        deduped.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        deduped.truncate(self.config.max_candidates.max(1));
        Ok(deduped)
    }

    fn make_candidate(&self, path: BeamPath, best_score: f64, at_ms: u64) -> Candidate {
        let feature = self.make_feature(&path, best_score, at_ms);
        let rank_score = self.ranker.score(&feature) as f64;
        let score = path.score + rank_score;
        Candidate {
            text: path.text,
            pinyin: path.pinyin,
            score,
            features: feature,
            words: path
                .words
                .into_iter()
                .map(|w| CandidateWord {
                    text: w.text,
                    pinyin: w.pinyin,
                    freq: w.freq,
                    known: w.known,
                })
                .collect(),
            consumed: 0,
        }
    }

    fn make_feature(&self, path: &BeamPath, best_score: f64, at_ms: u64) -> Feature {
        // 历史：整句命中与末词命中都算；时间差取 ln(1+秒) 做衰减。
        let (history_count, history_use, history_time_diff) = self
            .history
            .read()
            .ok()
            .map(|history| {
                let exact = history.get(&path.text).copied();
                let tail = path
                    .words
                    .last()
                    .and_then(|w| history.get(&w.text))
                    .copied();
                let merged = match (exact, tail) {
                    (Some(a), Some(b)) if b.count > a.count => b,
                    (Some(a), _) => a,
                    (None, Some(b)) => b,
                    (None, None) => HistoryEntry {
                        count: 0,
                        last_used_ms: at_ms,
                    },
                };
                let seconds = at_ms.saturating_sub(merged.last_used_ms) as f64 / 1000.0;
                (
                    merged.count as f32,
                    merged.count as f32,
                    (1.0 + seconds).ln() as f32,
                )
            })
            .unwrap_or((0.0, 0.0, 0.0));

        // 上下文：用候选首词去查二元分。
        //
        // 取键要同时试「上一个词」和「上一个字」：词级 LM 用前者，
        // 字级 LM（例如从语料统计的字二元）用后者。中文上下文通常没有空格，
        // 只取 split_whitespace().last() 会把整段文本当成一个词，查不到任何 bigram。
        let (with_context, context_bigram_score) = self
            .context
            .read()
            .map(|context| {
                let context = context.trim();
                let Some(candidate) = path.words.first() else {
                    return (0.0, 0.0);
                };
                if context.is_empty() {
                    return (0.0, 0.0);
                }
                let mut best: Option<f32> = None;
                let mut consider = |prev: &str| {
                    if prev.is_empty() {
                        return;
                    }
                    let score = self.lm.score(Some(prev), &candidate.text) as f32;
                    best = Some(best.map_or(score, |b: f32| b.max(score)));
                };
                if let Some(word) = context.split_whitespace().last() {
                    consider(word);
                }
                let mut buf = [0u8; 4];
                if let Some(ch) = context.chars().last() {
                    consider(ch.encode_utf8(&mut buf));
                }
                (1.0, best.unwrap_or(0.0))
            })
            .unwrap_or((0.0, 0.0));

        Feature {
            kind: if path.words.len() <= 1 { 0.0 } else { 1.0 },
            prob: (path.score - best_score).exp().clamp(0.0, 1.0) as f32,
            coverage_score: path.coverage,
            lm_score_with_previous_txt: path.lm_score as f32,
            full_jianpin: if path.jianpin { 1.0 } else { 0.0 },
            ltr_valid: if self.ranker.has_ltr() { 1.0 } else { 0.0 },
            history_count,
            history_use_count: history_use,
            history_time_diff,
            with_context,
            context_bigram_score,
            typo_count: path.typos as f32,
            prefix_completion: (path.completion as f32).min(3.0),
            typo: if path.typos > 0 { 1.0 } else { 0.0 },
            // 用户词、NNLM、补全等特征还没有数据源，保持 0。
            ..Feature::default()
        }
    }
}

/// 第 k 个字母之后在原始串里的字节位置（跳过紧随其后的隔音符）。
fn letters_to_bytes(raw: &str, letters: usize) -> usize {
    let bytes = raw.as_bytes();
    let mut seen = 0usize;
    let mut idx = 0usize;
    while idx < bytes.len() && seen < letters {
        if bytes[idx].is_ascii_alphabetic() {
            seen += 1;
        }
        idx += 1;
    }
    while idx < bytes.len() && bytes[idx] == b'\'' {
        idx += 1;
    }
    idx
}

/// 把句首词候选并入整句候选。
///
/// 整句是一个词时（shijie -> 世界）句首词放在最后；整句由多个词拼成时
/// （长句）第二名往后的整句只是小改动，价值不如句首词，所以句首词紧跟第一名。
fn merge_prefix_candidates(result: &mut Vec<Candidate>, prefix: Vec<Candidate>) {
    let mut prefix: Vec<Candidate> = prefix
        .into_iter()
        .filter(|p| !result.iter().any(|r| r.text == p.text))
        .collect();
    if prefix.is_empty() {
        return;
    }
    let mut seen: HashMap<String, ()> = HashMap::new();
    prefix.retain(|p| seen.insert(p.text.clone(), ()).is_none());
    // 4 个音节以上的长输入，整句常常不全对，先选开头的词更实用，放第二位；
    // 短输入（dejian）放在整句候选后面，别把「得见」挤出前几位
    let sentence = result
        .first()
        .map(|c| c.words.len() >= 2 && c.pinyin.split_whitespace().count() >= 4)
        .unwrap_or(false);
    let at = if sentence { 1.min(result.len()) } else { result.len() };
    let tail = result.split_off(at);
    result.extend(prefix);
    result.extend(tail);
}

fn dedupe_by_text(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut best: HashMap<String, Candidate> = HashMap::new();
    for candidate in candidates {
        match best.entry(candidate.text.clone()) {
            Entry::Vacant(slot) => {
                slot.insert(candidate);
            }
            Entry::Occupied(mut slot) => {
                if candidate.score > slot.get().score {
                    slot.insert(candidate);
                }
            }
        }
    }
    best.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexicon::MemoryLexicon;
    use crate::lm::BigramLm;

    fn engine(tsv: &str) -> Engine {
        let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(tsv).unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        Engine::new(lexicon, lm)
    }

    fn default_engine() -> Engine {
        engine(concat!(
            "xian\t先\t1000\n",
            "xi an\t西安\t500\n",
            "xi\t西\t400\n",
            "an\t安\t300\n",
            "zhong guo\t中国\t800\n",
            "ni hao\t你好\t100000\n",
            "hua r\t花儿\t100\n",
        ))
    }

    #[test]
    fn history_boosts_selection() {
        let e = engine("shi\t是\t900\nshi\t事\t800\n");
        let first = e.input_at("shi", 1_000_000);
        assert_eq!(first[0].text, "是", "默认按频次");

        for i in 0..5 {
            e.record_selection_at("事", 1_000_000 + i);
        }
        assert_eq!(e.history_count("事"), 5);

        let after = e.input_at("shi", 1_000_100);
        assert_eq!(
            after[0].text,
            "事",
            "选过多次的词应当排到前面: {:?}",
            after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn context_bigram_boosts_first_word() {
        let mut lm = BigramLm::new().with_backoff(0.001);
        lm.add_unigram("今天", 10.0);
        lm.add_unigram("天", 5.0);
        lm.add_unigram("田", 5.0);
        lm.add_bigram("今天", "天", 8.0);

        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("tian\t田\t200\ntian\t天\t100\n").unwrap());
        let e = Engine::new(lexicon, Arc::new(lm));

        let before = e.input_at("tian", 1);
        assert_eq!(before[0].text, "田", "没有上下文时按频次");

        e.set_context("今天");
        let after = e.input_at("tian", 1);
        assert_eq!(
            after[0].text,
            "天",
            "上下文应当把 天 提上来: {:?}",
            after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
        let tian = after.iter().find(|c| c.text == "天").unwrap();
        let tian_farm = after.iter().find(|c| c.text == "田").unwrap();
        assert!(tian.features.with_context == 1.0);
        assert!(
            tian.features.context_bigram_score > tian_farm.features.context_bigram_score,
            "{} vs {}",
            tian.features.context_bigram_score,
            tian_farm.features.context_bigram_score
        );
    }

    #[test]
    fn user_word_is_usable() {
        let e = engine("ni hao\t你好\t10\n");
        assert!(e.add_user_word("wo wo te", "我特", 5000.0).is_ok());
        assert_eq!(e.user_words().len(), 1);
        let cands = e.input("wowote");
        assert!(
            cands.iter().any(|c| c.text == "我特"),
            "用户词应当能输入: {:?}",
            cands.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
        assert!(e.remove_user_word("我特"));
        let after = e.input("wowote");
        assert!(!after.iter().any(|c| c.text == "我特"));
    }

    #[test]
    fn invalid_user_pinyin_rejected() {
        let e = engine("ni hao\t你好\t10\n");
        assert!(e.add_user_word("zzz", "坏词", 1.0).is_err());
        assert!(e.user_words().is_empty());
    }

    #[test]
    fn partial_tail_yields_completions() {
        let e = default_engine();
        let c = e.input("nih");
        assert!(
            c.iter().any(|x| x.text == "你好"),
            "nih 应当补全出 你好: {:?}",
            c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
        );
        let c = e.input("zhongg");
        assert!(
            c.iter().any(|x| x.text == "中国"),
            "zhongg 应当补全出 中国: {:?}",
            c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn incomplete_last_syllable_prefers_real_word() {
        let e = default_engine();
        let c = e.input("niha");
        assert_eq!(c[0].text, "你好", "niha 应当优先给出 你好");
    }

    #[test]
    fn fuzzy_matches_zh_z() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("zhi dao\t知道\t5000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        // 纠错会把 zidao 当成漏按 h，这里只测模糊音开关
        e.set_typo_correction(false);
        assert!(
            !e.input("zidao").iter().any(|c| c.text == "知道"),
            "默认关闭模糊音时不应命中"
        );
        e.set_fuzzy(true);
        assert!(
            e.input("zidao").iter().any(|c| c.text == "知道"),
            "开启后 zi dao 应当匹配 zhi dao"
        );
    }

    #[test]
    fn fuzzy_matches_nasal() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("shang dian\t商店\t5000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        e.set_fuzzy(true);
        assert!(
            e.input("sangdian").iter().any(|c| c.text == "商店"),
            "sang dian 应当匹配 shang dian"
        );
    }

    #[test]
    fn shuangpin_input() {
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\nni hao\t你好\t10000\n").unwrap(),
        );
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        assert!(
            !e.input("vsgo").iter().any(|c| c.text == "中国"),
            "默认全拼模式下 vsgo 不应命中"
        );
        e.set_shuangpin(true);
        assert!(
            e.input("vsgo").iter().any(|c| c.text == "中国"),
            "双拼 vsgo 应当命中 中国"
        );
        assert!(
            e.input("nihk").iter().any(|c| c.text == "你好"),
            "双拼 nihk 应当命中 你好"
        );
    }

    #[test]
    fn english_input_yields_raw_candidate() {
        let e = default_engine();
        let c = e.input("hello");
        assert_eq!(c.first().map(|x| x.text.as_str()), Some("hello"));
        assert!(c.iter().any(|x| x.text == "hello"));

        // 原始大小写要保留
        let c = e.input("Hello");
        assert_eq!(c[0].text, "Hello");

        // 只有未登录兜底时，原始串排最前
        let c = e.input("ok");
        assert_eq!(
            c[0].text,
            "ok",
            "{:?}",
            c.iter().map(|x| &x.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn known_english_word_beats_typo_corrected_chinese() {
        let e = engine(concat!(
            "he\t和\t9000\n",
            "lo\t咯\t500\n",
            "she\t设\t5000\n",
            "shen\t神\t9000\n",
            "ni hao\t你好\t100000\n",
        ));
        assert_eq!(e.load_english_str("hello\thello\nshe\tshe\nGitHub\tGitHub\nJanuary\tJan\n"), 3);
        let texts = |input: &str| -> Vec<String> {
            e.input(input).into_iter().map(|c| c.text).collect()
        };

        // 中文只能靠纠错凑出来时，已知英文词排第一
        assert_eq!(texts("hello")[0], "hello");
        // 全小写输入用词表里的写法，自己打了大写就照原样
        assert_eq!(texts("github")[0], "GitHub");
        assert_eq!(texts("Github")[0], "Github");
        // 本身就是完整拼音的英文词，中文在前，英文排第 3（候选不足时排最后）
        let she = texts("she");
        let pos = she.iter().position(|t| t == "she").expect("应当有 she");
        assert!(pos >= 1 && pos <= 2, "{she:?}");
        // 缩写编码（Jan -> January）不当作英文词
        assert!(!texts("jan").iter().any(|t| t == "January"));
    }

    #[test]
    fn raw_candidate_survives_a_full_list() {
        let mut e = engine(concat!(
            "he\t和\t9000\nhe\t何\t8000\nhe\t合\t7000\n",
            "lo\t咯\t500\nluo\t落\t400\n",
        ));
        e.set_max_candidates(3);
        // hrlo 不是拼音（r 是 e 的邻键），中文全靠纠错，列表还是满的
        let c = e.input("hrlo");
        assert!(
            c.iter().any(|x| x.text == "hrlo"),
            "原始串不该被截掉: {:?}",
            c.iter().map(|x| &x.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn full_pinyin_does_not_add_raw_candidate() {
        let e = default_engine();
        assert!(
            !e.input("nihao").iter().any(|c| c.text == "nihao"),
            "完整覆盖时不应插入原始拼音串"
        );
    }

    #[test]
    fn traditional_candidates() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
        assert_eq!(e.input("zhongguo")[0].text, "中国");
        e.set_traditional(true);
        assert_eq!(e.input("zhongguo")[0].text, "中國");
        // 分词文本也要跟着转
        assert_eq!(e.input("zhongguo")[0].words[0].text, "中國");
    }

    #[test]
    fn auto_learn_promotes_word() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let e = Engine::new(lexicon, lm);

        // 词库里没有「我特」，初始只能拿到原始串
        assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

        // 选不够次数不学
        e.record_selection_with_pinyin("我特", Some("wo te"));
        e.record_selection_with_pinyin("我特", Some("wo te"));
        assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

        // 第三次达到阈值
        e.record_selection_with_pinyin("我特", Some("wo te"));
        assert_eq!(e.user_words().len(), 1);
        assert!(
            e.input("wote").iter().any(|c| c.text == "我特"),
            "自动学习后应当能打出 我特"
        );
    }

    #[test]
    fn auto_learn_can_be_disabled() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let config = EngineConfig {
            auto_learn: false,
            ..EngineConfig::default()
        };
        let e = Engine::new(lexicon, lm).with_config(config);
        for _ in 0..5 {
            e.record_selection_with_pinyin("我特", Some("wo te"));
        }
        assert!(e.user_words().is_empty());
    }

    #[test]
    fn context_disambiguates_homophones() {
        // 同一拼音，两个候选：先（高频）、西安（低频）
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
        // TSV 加载器会把二元组计数也记进一元，所以这里额外给「先」补一条
        // 高频搭配，让它在**没有上下文**时仍然靠词频胜出。
        let lm: Arc<dyn LanguageModel> = Arc::new(
            BigramLm::from_bigram_tsv_str("我\t西安\t9990\n我\t先\t10\n先\t的\t100000\n").unwrap(),
        );
        let e = Engine::new(lexicon, lm);

        // 没有上下文时，词频决定：先
        assert_eq!(e.input("xian")[0].text, "先");

        // 有上下文「我」之后，语言模型应当把 西安 顶上来
        e.set_context("我");
        assert_eq!(e.input("xian")[0].text, "西安", "上下文应当消除同音词歧义");
    }

    #[test]
    fn arpa_context_disambiguates() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
        let arpa = "\\data\\\nngram 1=3\nngram 2=2\n\n\\1-grams:\n-1.0\t我\n-1.0\t先\n-1.0\t西安\n\n\\2-grams:\n-0.01\t我 西安\n-4.0\t我 先\n\n\\end\\\n";
        let lm: Arc<dyn LanguageModel> =
            Arc::new(ArpaLm::from_arpa_str(arpa).expect("ARPA 解析失败"));
        let e = Engine::new(lexicon, lm);
        assert_eq!(e.input("xian")[0].text, "先");
        e.set_context("我");
        assert_eq!(e.input("xian")[0].text, "西安");
    }

    #[test]
    fn context_uses_last_character() {
        // 中文上下文通常没有空格，必须能退到「最后一个字」去查 bigram
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("shi\t是\t50000\nshi\t事\t30000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(
            BigramLm::from_bigram_tsv_str(
                "做\t事\t9990\n做\t是\t10\n是\t的\t100000\n事\t的\t100000\n",
            )
            .unwrap(),
        );
        let e = Engine::new(lexicon, lm);
        assert_eq!(e.input("shi")[0].text, "是");

        e.set_context("我今天做");
        assert_eq!(
            e.input("shi")[0].text,
            "事",
            "多字上下文应当用最后一个字查二元组"
        );
    }

    #[test]
    fn completion_does_not_extend_unknown_head() {
        // shesh：只能是 she + sh*，不能把 shesh 整体当成能解析的头
        let e = engine("she shi\t设施\t500\nshe\t设\t100\n");
        assert!(e.input("shesh").iter().any(|c| c.text == "设施"));
    }

    #[test]
    fn completion_extends_the_last_syllable() {
        // 「shesh」尾巴是 sh，应当能补成 设施(she shi)
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str(
                "she shi\t设施\t9000\nshe sha\t射杀\t500\nshe shou\t射手\t400\n",
            )
            .unwrap(),
        );
        let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
        let list = e.input("shesh");
        assert!(
            list.iter().take(3).any(|c| c.text == "设施"),
            "应当补出 设施: {:?}",
            list.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn input_xian() {
        let e = default_engine();
        let cands = e.input("xian");
        let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
        assert!(texts.contains(&"先"), "{:?}", texts);
        assert!(texts.contains(&"西安"), "{:?}", texts);
    }

    #[test]
    fn apostrophe_does_not_yield_xian_word() {
        let e = default_engine();
        let cands = e.input("xi'an");
        let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
        assert!(texts.contains(&"西安"), "{:?}", texts);
        // 强制切分后不应再出现单音节 xian 对应的 先。
        assert!(!texts.contains(&"先"), "{:?}", texts);
    }

    #[test]
    fn jianpin_fallback() {
        let e = default_engine();
        let cands = e.input("zg");
        assert!(cands.iter().any(|c| c.text == "中国"), "{:?}", cands);
    }

    #[test]
    fn erhua() {
        let e = default_engine();
        let cands = e.input("huar");
        assert!(cands.iter().any(|c| c.text == "花儿"), "{:?}", cands);
    }

    #[test]
    fn empty_input() {
        let e = default_engine();
        assert!(e.input("").is_empty());
        assert!(e.input("   ").is_empty());
    }

    #[test]
    fn unknown_input_falls_back_to_pinyin() {
        let e = engine("");
        let cands = e.input("xian");
        assert!(!cands.is_empty());
        assert_eq!(cands[0].text, "xian");
    }

    #[test]
    fn ltr_valid_reflects_ranker() {
        struct NullLtr;
        impl crate::rank::LtrModel for NullLtr {
            fn score(&self, _feature: &Feature) -> f32 {
                0.0
            }
        }
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t1000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let ranker = Arc::new(LinearRanker::default().with_ltr(Arc::new(NullLtr), 1.0));
        let e = Engine::new(lexicon, lm).with_ranker(ranker);
        let cands = e.input("xian");
        assert!(!cands.is_empty());
        assert_eq!(cands[0].features.ltr_valid, 1.0);
    }
}
