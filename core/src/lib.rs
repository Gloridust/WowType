//! Wowtype 拼音引擎骨架。
//!
//! 流水线：
//! 输入预处理 -> 音节图 -> 束搜索（词典 + 二元 LM） -> 特征/线性打分 -> 候选。
//! LTR / 神经重排 / MixRank 只在接口上预留，尚未接入真实模型。

pub mod beam;
pub mod ffi;
pub mod graph;
pub mod lexicon;
pub mod lm;
pub mod rank;
pub mod shuangpin;
pub mod syllable;

use std::collections::hash_map::Entry;
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

pub use crate::beam::{beam_search, BeamConfig, BeamPath, BeamWord};
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
    pub fn set_shuangpin(&mut self, on: bool) {
        self.config.shuangpin = on;
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
        Ok(result)
    }

    /// 英文/未登录输入：保证原始输入本身可以作为候选上屏。
    ///
    /// 条件：启用了英文候选、输入含字母、没有被完整词覆盖。分数压到最低一档。
    fn append_raw_candidate(&self, display: &str, candidates: &mut Vec<Candidate>) {
        if !self.config.english_candidate || display.is_empty() || display.len() > 32 {
            return;
        }
        if !display.bytes().any(|b| b.is_ascii_alphabetic()) {
            return;
        }
        if candidates
            .iter()
            .any(|c| c.text.eq_ignore_ascii_case(display))
        {
            return;
        }
        let covered = candidates
            .first()
            .map(|c| c.features.coverage_score >= 1.0 && !c.words.iter().any(|w| !w.known))
            .unwrap_or(false);
        if covered {
            return;
        }
        // 已有候选全是未登录兜底时，原始串更可信，排到最前；
        // 否则（有真实词但覆盖不全）压到最后一档。
        let has_known_word = candidates
            .first()
            .map(|c| c.words.iter().any(|w| w.known))
            .unwrap_or(false);
        let score = if candidates.is_empty() {
            -1.0
        } else if has_known_word {
            candidates
                .iter()
                .map(|c| c.score)
                .fold(f64::INFINITY, f64::min)
                - 1.0
        } else {
            candidates
                .iter()
                .map(|c| c.score)
                .fold(f64::NEG_INFINITY, f64::max)
                + 1.0
        };
        candidates.push(Candidate {
            text: display.to_string(),
            pinyin: display.to_ascii_lowercase(),
            score,
            features: Feature::default(),
            words: vec![CandidateWord {
                text: display.to_string(),
                pinyin: String::new(),
                freq: 0.0,
                known: false,
            }],
        });
        candidates.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        candidates.truncate(self.config.max_candidates.max(1));
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

    /// 跑一次查询：先精确，覆盖率不足时枚举尾部补全；fuzzy=true 时查不到会回退模糊音。
    fn run_query(&self, normalized: &str, at_ms: u64, fuzzy: bool) -> Result<Vec<Candidate>> {
        let exact = self.query_once(normalized, at_ms, fuzzy)?;
        // 精确路径质量够好（全覆盖）就直接返回；否则说明尾部是半成品音节
        // 或者走了未登录兜底，此时枚举补全再和精确结果合并排序。
        let covered = exact
            .first()
            .map(|c| c.features.coverage_score >= 1.0 && !c.words.iter().any(|w| !w.known))
            .unwrap_or(false);
        if covered {
            return Ok(exact);
        }
        let completions = partial_completions(normalized);
        if completions.is_empty() {
            return Ok(exact);
        }
        let mut merged: HashMap<String, Candidate> = HashMap::new();
        for candidate in exact {
            merged.insert(candidate.text.clone(), candidate);
        }
        for candidate_input in completions.iter().take(32) {
            if let Ok(list) = self.query_once(candidate_input, at_ms, fuzzy) {
                for candidate in list {
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
        }
        let mut result: Vec<Candidate> = merged.into_values().collect();
        // 分数并列时按文本排序，保证结果稳定（HashMap 迭代顺序不固定）
        result.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        result.truncate(self.config.max_candidates.max(1));
        Ok(result)
    }

    fn query_once(&self, normalized: &str, at_ms: u64, fuzzy: bool) -> Result<Vec<Candidate>> {
        let parsed = parse(normalized)?;
        if parsed.is_empty() {
            return Ok(Vec::new());
        }

        // 先全拼；走不通再简拼。混合模式留给显式配置。
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
            },
        );
        let graph = if full.has_complete_path() {
            full
        } else if self.config.jianpin_fallback {
            let jianpin = SyllableGraph::build(
                &parsed,
                GraphOptions {
                    mode: GraphMode::Jianpin,
                    allow_erhua: false,
                },
            );
            if !jianpin.has_complete_path() {
                return Ok(Vec::new());
            }
            jianpin
        } else {
            return Ok(Vec::new());
        };

        // fuzzy 时用包装视图：精确查不到再退到模糊音。
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref());
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let mut paths = beam_search(&graph, lexicon, self.lm.as_ref(), &self.config.beam);
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

        // 上下文：取光标前文本的最后一个词，与候选首词算二元分。
        let (with_context, context_bigram_score) = self
            .context
            .read()
            .map(|context| {
                let prev_word = context.split_whitespace().last().unwrap_or("");
                if prev_word.is_empty() {
                    return (0.0, 0.0);
                }
                let score = path
                    .words
                    .first()
                    .map(|w| self.lm.score(Some(prev_word), &w.text) as f32)
                    .unwrap_or(0.0);
                (1.0, score)
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
            // 用户词、NNLM、typo、补全等特征还没有数据源，保持 0。
            ..Feature::default()
        }
    }
}

/// 把「尾部还没成音节」的输入展开成若干条完整输入。
///
/// 例如 zhongg -> [zhongguo, zhonggu, zhongguai, ...]，nih -> [niha, nihai, ...]。
/// 从最长的可切分前缀往前试，命中就返回，避免组合爆炸。
fn partial_completions(input: &str) -> Vec<String> {
    if !(2..=16).contains(&input.len()) || !input.bytes().all(|b| b.is_ascii_lowercase()) {
        return Vec::new();
    }
    for cut in (0..input.len()).rev() {
        let (head, tail) = input.split_at(cut);
        if tail.len() > 6 {
            continue;
        }
        if !head.is_empty() && parse(head).is_err() {
            continue;
        }
        let mut out: Vec<String> = Vec::new();
        for syllable in SYLLABLES {
            if syllable.starts_with(tail) {
                out.push(format!("{head}{syllable}"));
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    Vec::new()
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
    fn full_pinyin_does_not_add_raw_candidate() {
        let e = default_engine();
        assert!(
            !e.input("nihao").iter().any(|c| c.text == "nihao"),
            "完整覆盖时不应插入原始拼音串"
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
