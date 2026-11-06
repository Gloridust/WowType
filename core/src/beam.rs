//! 束搜索：在音节图 + 词典上搜索 TopN 条路径。
//!
//! 骨架实现是“词级”束搜索：
//! 1. 从当前节点出发，DFS 枚举最长 max_word_syllables 个音节；
//! 2. 每到一个节点就用整段音节序列查词典，命中即成为一个“词”扩展；
//! 3. 每条边也提供一个未知词兜底，保证任何合法输入都能走到底；
//! 4. 按词典代价 + 二元 LM 分数累计，保留 beam_size 条状态。
//!
//! 真实实现应把词典查询换成前缀 trie / LOUDS 的 PredictiveSearch，避免这里
//! 对每个前缀都做一次 HashMap 查询。

use std::collections::hash_map::Entry;
use std::collections::HashMap;

use crate::graph::{Edge, SyllableGraph};
use crate::lexicon::{LexEntry, Lexicon};
use crate::lm::LanguageModel;
use crate::syllable::SyllableQuery;

/// 束搜索配置。
#[derive(Clone, Debug)]
pub struct BeamConfig {
    /// 每层保留的状态数。WeType 会按输入长度在 10~40 间调度，这里先用固定值。
    pub beam_size: usize,
    /// 一个词最多覆盖几个音节。
    pub max_word_syllables: usize,
    /// 每个状态最多保留多少个已知词扩展（按词频降序截断）。
    pub max_expansions_per_state: usize,
    /// 未登录音节的惩罚。越大越倾向词典里的词。
    pub unknown_cost: f64,
    /// 语言模型权重。
    pub lm_weight: f64,
    /// 词典代价权重。
    pub lexicon_weight: f64,
}

impl Default for BeamConfig {
    fn default() -> Self {
        Self {
            beam_size: 20,
            max_word_syllables: 6,
            max_expansions_per_state: 256,
            unknown_cost: 18.0,
            lm_weight: 1.0,
            lexicon_weight: 1.0,
        }
    }
}

/// 路径上的一个词（已知词或兜底的音节串）。
#[derive(Clone, Debug)]
pub struct BeamWord {
    pub text: String,
    pub pinyin: String,
    pub freq: f64,
    pub known: bool,
    pub syllable_count: usize,
    pub jianpin: bool,
}

/// 一条完整路径。
#[derive(Clone, Debug)]
pub struct BeamPath {
    pub text: String,
    pub pinyin: String,
    pub words: Vec<BeamWord>,
    /// 累计分（越高越好），已减去词典代价。
    pub score: f64,
    /// LM 对数概率累计（<= 0）。
    pub lm_score: f64,
    /// 词典代价累计（>= 0）。
    pub lexical_cost: f64,
    /// 词典覆盖的音节比例。
    pub coverage: f32,
    pub jianpin: bool,
}

#[derive(Clone, Debug)]
struct State {
    pos: usize,
    words: Vec<BeamWord>,
    score: f64,
    lm_score: f64,
    lexical_cost: f64,
    covered_syllables: usize,
    total_syllables: usize,
    last: Option<String>,
    jianpin: bool,
}

impl State {
    fn start() -> Self {
        Self {
            pos: 0,
            words: Vec::new(),
            score: 0.0,
            lm_score: 0.0,
            lexical_cost: 0.0,
            covered_syllables: 0,
            total_syllables: 0,
            last: None,
            jianpin: false,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn advance(
        &self,
        end: usize,
        word: BeamWord,
        score_inc: f64,
        lm_inc: f64,
        lexical_inc: f64,
        covered_inc: usize,
    ) -> Self {
        let jianpin = self.jianpin || word.jianpin;
        let total_inc = word.syllable_count;
        let last = Some(word.text.clone());
        let mut words = self.words.clone();
        words.push(word);
        Self {
            pos: end,
            words,
            score: self.score + score_inc,
            lm_score: self.lm_score + lm_inc,
            lexical_cost: self.lexical_cost + lexical_inc,
            covered_syllables: self.covered_syllables + covered_inc,
            total_syllables: self.total_syllables + total_inc,
            last,
            jianpin,
        }
    }
}

struct WordMatch {
    end: usize,
    keys: Vec<SyllableQuery>,
    entry: LexEntry,
}

/// 在音节图上跑束搜索。
pub fn beam_search(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    lm: &dyn LanguageModel,
    config: &BeamConfig,
) -> Vec<BeamPath> {
    let n = graph.len();
    if n == 0 || !graph.has_complete_path() {
        return Vec::new();
    }

    let beam_size = config.beam_size.max(1);
    let max_word_syllables = config.max_word_syllables.max(1);
    let max_expansions = config.max_expansions_per_state.max(1);

    let mut beam = vec![State::start()];
    let mut finals: Vec<State> = Vec::new();

    for _ in 0..=n {
        let mut next: Vec<State> = Vec::new();

        for state in &beam {
            if state.pos >= n {
                continue;
            }

            // 已知词扩展。
            let mut matches = collect_matches(graph, lexicon, state.pos, max_word_syllables);
            matches.sort_by(|a, b| b.entry.freq.total_cmp(&a.entry.freq));
            matches.truncate(max_expansions);

            for m in matches {
                let known = m.keys.len();
                let jianpin = m.keys.iter().any(|q| q.is_jianpin());
                let word = BeamWord {
                    text: m.entry.word.clone(),
                    pinyin: pinyin_of(&m.keys),
                    freq: m.entry.freq,
                    known: true,
                    syllable_count: known,
                    jianpin,
                };
                let lexical = config.lexicon_weight * lexicon.cost(&m.entry);
                let lm_raw = lm.score(state.last.as_deref(), &m.entry.word);
                let lm_inc = config.lm_weight * lm_raw;
                let next_state =
                    state.advance(m.end, word, -lexical + lm_inc, lm_raw, lexical, known);
                if next_state.pos >= n {
                    finals.push(next_state);
                } else {
                    next.push(next_state);
                }
            }

            // 未知音节兜底：每条边都允许直接当作一个未登录词。
            for edge in graph.edges_from(state.pos) {
                let word = unknown_word(edge);
                let next_state = state.advance(
                    edge.end,
                    word,
                    -config.unknown_cost,
                    0.0,
                    config.unknown_cost,
                    0,
                );
                if next_state.pos >= n {
                    finals.push(next_state);
                } else {
                    next.push(next_state);
                }
            }
        }

        if next.is_empty() {
            break;
        }
        beam = prune(next, beam_size);

        // 防止歧义输入把 finals 撑爆；最终还会按文本去重。
        finals.sort_by(|a, b| b.score.total_cmp(&a.score));
        finals.truncate(beam_size.saturating_mul(8).max(32));
    }

    let mut best_by_text: HashMap<String, State> = HashMap::new();
    for state in finals {
        let text: String = state.words.iter().map(|w| w.text.as_str()).collect();
        match best_by_text.entry(text) {
            Entry::Vacant(slot) => {
                slot.insert(state);
            }
            Entry::Occupied(mut slot) => {
                if state.score > slot.get().score {
                    slot.insert(state);
                }
            }
        }
    }

    let mut paths: Vec<BeamPath> = best_by_text
        .into_values()
        .map(|state| {
            let text: String = state.words.iter().map(|w| w.text.as_str()).collect();
            let pinyin = state
                .words
                .iter()
                .map(|w| w.pinyin.as_str())
                .collect::<Vec<_>>()
                .join(" ");
            let coverage = if state.total_syllables == 0 {
                0.0
            } else {
                state.covered_syllables as f32 / state.total_syllables as f32
            };
            BeamPath {
                text,
                pinyin,
                words: state.words,
                score: state.score,
                lm_score: state.lm_score,
                lexical_cost: state.lexical_cost,
                coverage,
                jianpin: state.jianpin,
            }
        })
        .collect();

    paths.sort_by(|a, b| b.score.total_cmp(&a.score));
    paths
}

fn unknown_word(edge: &Edge) -> BeamWord {
    let query = edge.query();
    BeamWord {
        text: edge.display(),
        pinyin: query.display(),
        freq: 0.0,
        known: false,
        syllable_count: edge.syllable_count(),
        jianpin: query.is_jianpin(),
    }
}

fn pinyin_of(keys: &[SyllableQuery]) -> String {
    keys.iter()
        .map(|q| q.display())
        .collect::<Vec<_>>()
        .join(" ")
}

fn collect_matches(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    start: usize,
    max_syllables: usize,
) -> Vec<WordMatch> {
    let mut out = Vec::new();
    let mut keys = Vec::new();
    collect_matches_dfs(graph, lexicon, start, max_syllables, &mut keys, &mut out);
    out
}

fn collect_matches_dfs<'a>(
    graph: &SyllableGraph,
    lexicon: &'a dyn Lexicon,
    pos: usize,
    max_syllables: usize,
    keys: &mut Vec<SyllableQuery>,
    out: &mut Vec<WordMatch>,
) {
    if keys.len() >= max_syllables {
        return;
    }
    for edge in graph.edges_from(pos) {
        keys.push(edge.query());
        for entry in lexicon.lookup(keys) {
            out.push(WordMatch {
                end: edge.end,
                keys: keys.clone(),
                entry,
            });
        }
        collect_matches_dfs(graph, lexicon, edge.end, max_syllables, keys, out);
        keys.pop();
    }
}

fn prune(mut states: Vec<State>, beam_size: usize) -> Vec<State> {
    states.sort_by(|a, b| b.score.total_cmp(&a.score));

    let mut best: HashMap<(usize, String), State> = HashMap::new();
    for state in states {
        let key = (state.pos, state.last.clone().unwrap_or_default());
        match best.entry(key) {
            Entry::Vacant(slot) => {
                slot.insert(state);
            }
            Entry::Occupied(mut slot) => {
                if state.score > slot.get().score {
                    slot.insert(state);
                }
            }
        }
    }

    let mut out: Vec<State> = best.into_values().collect();
    out.sort_by(|a, b| b.score.total_cmp(&a.score));
    out.truncate(beam_size);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graph::{GraphMode, GraphOptions};
    use crate::lexicon::MemoryLexicon;
    use crate::lm::BigramLm;
    use crate::syllable::parse;

    fn graph(text: &str, mode: GraphMode) -> SyllableGraph {
        let parsed = parse(text).unwrap();
        SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode,
                allow_erhua: true,
            },
        )
    }

    fn lex() -> MemoryLexicon {
        MemoryLexicon::from_tsv_str("xian\t先\t1000\nxi an\t西安\t500\nzhong guo\t中国\t800\n")
            .unwrap()
    }

    #[test]
    fn beam_finds_xian_and_xian_apostrophe() {
        let g = graph("xian", GraphMode::Full);
        let lex = lex();
        let lm = BigramLm::default();
        let paths = beam_search(&g, &lex, &lm, &BeamConfig::default());
        let texts: Vec<&str> = paths.iter().map(|p| p.text.as_str()).collect();
        assert!(texts.contains(&"先"), "缺少 先: {:?}", texts);
        assert!(texts.contains(&"西安"), "缺少 西安: {:?}", texts);
    }

    #[test]
    fn max_word_syllables_prunes_multi_syllable_word() {
        let g = graph("xian", GraphMode::Full);
        let lex = lex();
        let lm = BigramLm::default();
        let cfg = BeamConfig {
            max_word_syllables: 1,
            ..Default::default()
        };
        let paths = beam_search(&g, &lex, &lm, &cfg);
        let texts: Vec<&str> = paths.iter().map(|p| p.text.as_str()).collect();
        assert!(texts.contains(&"先"));
        assert!(
            !texts.contains(&"西安"),
            "max_word_syllables=1 不应匹配两音节词"
        );
    }

    #[test]
    fn jianpin_path() {
        let g = graph("zg", GraphMode::Jianpin);
        let lex = lex();
        let lm = BigramLm::default();
        let paths = beam_search(&g, &lex, &lm, &BeamConfig::default());
        assert!(paths.iter().any(|p| p.text == "中国" && p.jianpin));
    }

    #[test]
    fn unknown_syllables_still_produce_path() {
        let g = graph("xian", GraphMode::Full);
        let lex = MemoryLexicon::new();
        let lm = BigramLm::default();
        let paths = beam_search(&g, &lex, &lm, &BeamConfig::default());
        assert!(!paths.is_empty());
        assert_eq!(paths[0].coverage, 0.0);
        assert!(paths.iter().any(|p| p.text == "xian"));
    }

    #[test]
    fn beam_size_is_respected() {
        let g = graph("xian", GraphMode::Full);
        let lex = lex();
        let lm = BigramLm::default();
        let cfg = BeamConfig {
            beam_size: 1,
            ..Default::default()
        };
        let paths = beam_search(&g, &lex, &lm, &cfg);
        assert!(!paths.is_empty());
    }
}
