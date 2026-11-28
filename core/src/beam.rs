//! 束搜索：在音节图 + 词典上搜索 TopN 条路径。
//!
//! 词格上的束搜索：
//! 1. 每个字母位置一个桶，只在同一位置的状态之间比较（Viterbi 风格）；
//! 2. 从一个位置出发，DFS 枚举最长 max_word_syllables 个音节查词典，
//!    词典没有更长的词时立即剪枝（Lexicon::has_longer）；
//! 3. 每条精确边也提供一个未知词兜底，保证任何合法输入都能走到底；
//! 4. 纠错边按 typo_cost 扣分，路径纠错次数有上限；
//! 5. 按词典代价 + 二元 LM 分数累计，每个位置保留 beam_size 条状态。

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use crate::graph::{Edge, GraphMode, SyllableGraph};
use crate::lexicon::{freq_cost, is_ext_char, Lexicon};
use crate::lm::LanguageModel;
use crate::syllable::SyllableQuery;

/// 束搜索配置。
#[derive(Clone, Debug)]
pub struct BeamConfig {
    /// 每层保留的状态数。WeType 会按输入长度在 10~40 间调度，这里先用固定值。
    pub beam_size: usize,
    /// 一个词最多覆盖几个音节。
    pub max_word_syllables: usize,
    /// 从同一位置出发、结束于同一位置的已知词最多保留几个（按代价截断）。
    pub max_expansions_per_state: usize,
    /// 未登录音节的惩罚。越大越倾向词典里的词。
    pub unknown_cost: f64,
    /// 语言模型权重（词典代价的权重固定是 1）。
    pub lm_weight: f64,
    /// 每处纠错的惩罚（自然对数）。
    pub typo_cost: f64,
    /// 补全每多出一个字母的惩罚（自然对数）。
    pub completion_cost: f64,
    /// 一条路径最多纠几处。
    pub max_typos: usize,
    /// 一个词最多纠几处。
    pub max_typos_per_word: usize,
    /// 两键按反（meiyuo -> meiyou）比按错一个键（meiguo）少罚多少：手快时打反是最常见的错，
    /// 也很少碰巧打出别的常用词。
    pub swap_discount: f64,
    /// 全拼混简拼（k yi -> 可以，yong z wen -> 用中文）时，每个只打了声母的音节的惩罚。
    ///
    /// 错键的全拼常常也能读成混简拼（jifu 打成 jifk -> 积分卡），罚得太轻会把纠错挤下去，
    /// 太重又打不出混简拼。2.0 时纠错的前三命中不变，混简拼前三从 27% 升到 84%。
    pub abbrev_cost: f64,
    /// 全拼混简拼时，输入的最后一个字母当省略的声母（yuluj -> 与路径）再加的惩罚。
    ///
    /// 末尾没打完的音节由补全处理（woxiangch -> 我想吃），补全按缺了几个字母扣分，
    /// 比这里更准；这里只在补全也凑不出来时兜底。
    pub tail_abbrev_cost: f64,
    /// 也出 CJK 扩展 B 区及以后的单字（[`crate::lexicon::LexEntry::is_ext_char`]）。
    ///
    /// 默认关：常见的中文字体（Noto CJK、思源、苹方）都没有这些字，列出来只是一排方块。
    pub rare_ext_chars: bool,
    /// 剪枝时同一个末词最多留几条历史（前面的字不一样的），见 [`prune`]。
    ///
    /// 1 就是二元模型下的维特比：末词相同的只留最好的一条，句子中间的另一种选法（海边的「完风 / 晚风」吹着……）
    /// 走到下一个词就被并掉，最后出来的几条整句只在句尾不一样，神经语言模型重排时根本看不到句中的另一种写法。
    /// 留 3 条时，别人写的整句（chime 的 1010 条盲测，带 nnlm）top1 59.5% -> 63.5%、前 9 里有正确整句的 64.8% -> 72.4%；
    /// 不带神经语言模型时各组评测逐条不变（二元模型下的最优路径没变）。
    pub histories_per_word: usize,
}

impl Default for BeamConfig {
    fn default() -> Self {
        Self {
            beam_size: 20,
            max_word_syllables: 6,
            max_expansions_per_state: 32,
            unknown_cost: 18.0,
            // 下面三个（tools/tune_weights.py 在评测集上自动调的，2026-11-17，见 docs/ENGINE.md「排序参数」）：原来是 1.0 / 6.0 / 1.2
            lm_weight: 0.85,
            typo_cost: 8.0,
            completion_cost: 1.5,
            max_typos: 2,
            max_typos_per_word: 1,
            swap_discount: 1.5,
            abbrev_cost: 2.0,
            tail_abbrev_cost: 4.0,
            rare_ext_chars: false,
            histories_per_word: 3,
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
    /// 只打了声母的音节数。
    pub abbrev: usize,
    /// 最后一个音节只打了声母。
    pub ends_abbrev: bool,
    /// 这个词用了几处纠错。
    pub typos: usize,
    /// 其中几处是两键按反。
    pub swaps: usize,
    /// 补全多出的字母数（用户还没打的部分）。
    pub completion: usize,
    /// 在输入里的字母区间 [start, end)。
    pub start: usize,
    pub end: usize,
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
    /// 整条路径的纠错次数。
    pub typos: usize,
    /// 补全多出的字母数。
    pub completion: usize,
}

/// 词格里的一个状态：停在某个字母位置、以某个词结尾。
///
/// 用回溯指针代替整条词序列，扩展时不必复制路径。
#[derive(Clone, Copy, Debug)]
struct Node {
    /// 父状态在 arena 里的下标（起点为 None）。
    parent: Option<usize>,
    /// 末词：words[from][idx]。
    word: Option<(usize, usize)>,
    score: f64,
    lm_score: f64,
    lexical_cost: f64,
    covered_syllables: usize,
    total_syllables: usize,
    typos: usize,
    completion: usize,
    jianpin: bool,
    /// 到这里为止整串文字的哈希（FNV-1a，逐词接着算）：[`prune`] 用它认出「同一串字、切法不同」的状态。
    text_hash: u64,
}

/// [`Node::text_hash`] 的起点和递推（FNV-1a）。
const TEXT_HASH_SEED: u64 = 0xcbf2_9ce4_8422_2325;

fn extend_text_hash(mut hash: u64, text: &str) -> u64 {
    for b in text.bytes() {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// 从某个位置出发的一个可选词（已知词或兜底音节）。
struct Span {
    word: BeamWord,
    lexical: f64,
}

/// [`collect_spans`] 去重时，留下的词不超过这么多就逐个比字，多了改用哈希表。
const UNIQUE_SCAN: usize = 32;

/// [`collect_spans`] 每组先排好的这一段是名额的几倍（不够再排剩下的，结果一样，见那里）。
const HEAD_PER_SPAN: usize = 3;

/// [`collect_spans`] 里一组（同一个结束位置）的去重和名额。
struct Keep<'a> {
    per_span: usize,
    typo_quota: bool,
    /// 留下的词（[`Found::hits`] 的下标），按排好的先后。
    unique: Vec<u32>,
    /// 留下的字 -> 在 unique 里的下标。留得少时（束搜索每组 32 个）逐个比更快；
    /// 翻页长尾每组要留上千个，逐个比就成了平方（#227），超过 [`UNIQUE_SCAN`] 个以后改查这张表。
    index: HashMap<&'a str, usize>,
    /// (照着打的, 纠错的) 各留了几个；不另算名额时两种合在第一个里数。
    kept: (usize, usize),
}

impl<'a> Keep<'a> {
    /// 按排好的先后递进来一个词（纠错处数、字）；`of` 查已经留下的词的纠错处数和字。返回 true：名额都满了，这组不用再往下看。
    fn offer(&mut self, span: u32, span_typos: usize, span_text: &'a str, of: &dyn Fn(u32) -> (usize, &'a str)) -> bool {
        let (per_span, typo_quota) = (self.per_span, self.typo_quota);
        let kept = &mut self.kept;
        let corrected = typo_quota && span_typos > 0;
        let count = if corrected { kept.1 } else { kept.0 };
        if count >= per_span {
            return kept.0 >= per_span && (!typo_quota || kept.1 >= per_span);
        }
        // 同一个词可能经由不同切分到达，留代价最低的那个（已经按代价排好，留先来的）
        let found = if self.unique.len() <= UNIQUE_SCAN {
            self.unique.iter().position(|&k| of(k).1 == span_text)
        } else {
            if self.index.is_empty() {
                for (at, &k) in self.unique.iter().enumerate() {
                    self.index.insert(of(k).1, at);
                }
            }
            self.index.get(span_text).copied()
        };
        match found {
            None => {
                if !self.index.is_empty() {
                    self.index.insert(span_text, self.unique.len());
                }
                self.unique.push(span);
                if corrected {
                    kept.1 += 1;
                } else {
                    kept.0 += 1;
                }
            }
            // 同一个字既能照着打读出来、也能纠错读出来（蹲：dun 常用，cun 冷门）：留照着打的那个。
            // 按代价留的话纠错的 dun 便宜，照着打的 cun 被去重去掉，后面再筛掉纠错的，cunzai 里就没有「蹲」了
            Some(at) if of(self.unique[at]).0 > 0 && span_typos == 0 => {
                if typo_quota {
                    kept.1 -= 1;
                    kept.0 += 1;
                }
                self.unique[at] = span;
            }
            Some(_) => {}
        }
        false
    }
}

/// [`collect_spans`] 查词时攒下的：每次查词一条 [`Lookup`]，查到的每个词一条 [`Hit`]，字都放在 `text` 里。
#[derive(Default)]
struct Found {
    hits: Vec<Hit>,
    lookups: Vec<Lookup>,
    text: String,
    /// 词典的总频次，算代价用（[`crate::lexicon::freq_cost`]），整次只取一次。
    total_freq: f64,
}

/// 查到的一个词。
struct Hit {
    /// 哪一次查词（[`Found::lookups`] 的下标）。
    lookup: u32,
    /// 字在 [`Found::text`] 里的字节区间。
    text: (u32, u32),
    freq: f64,
    /// 词典代价。
    lexical: f64,
    /// 组内排序用的代价：词典代价 + 纠错、补全的代价。
    key: f64,
}

/// 一次查词：这次查到的词共用的读音和位置。
struct Lookup {
    pinyin: String,
    syllable_count: usize,
    jianpin: bool,
    abbrev: usize,
    ends_abbrev: bool,
    typos: usize,
    swaps: usize,
    completion: usize,
    start: usize,
    end: usize,
}

/// 在音节图上做「按位置同步」的束搜索（词格 Viterbi）。
///
/// 每个字母位置一个桶，只在同一个位置的状态之间比较、剪枝。
/// 如果把不同位置的状态放在一起比，走得远的路径扣分次数多，
/// 会被系统性地剪掉（「今天」输给「进 + 天」），长句因此几乎打不对。
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
    let per_span = config.max_expansions_per_state.max(1);
    let final_cap = beam_size.saturating_mul(8).max(32);

    // 每个位置出发的候选词，只算一次（与到达该位置的路径无关）
    let mut spans: Vec<Vec<Span>> = (0..n).map(|_| Vec::new()).collect();

    let mut arena: Vec<Node> = Vec::new();
    let mut buckets: Vec<Vec<Node>> = (0..=n).map(|_| Vec::new()).collect();
    buckets[0].push(Node {
        parent: None,
        word: None,
        score: 0.0,
        lm_score: 0.0,
        lexical_cost: 0.0,
        covered_syllables: 0,
        total_syllables: 0,
        typos: 0,
        completion: 0,
        jianpin: false,
        text_hash: TEXT_HASH_SEED,
    });

    let per_word = config.histories_per_word.max(1);
    for pos in 0..n {
        if buckets[pos].is_empty() {
            continue;
        }
        let states = prune(std::mem::take(&mut buckets[pos]), beam_size, per_word, |node| {
            node.word.map(|(f, i)| spans[f][i].word.text.as_str())
        });
        spans[pos] = collect_spans(
            graph,
            lexicon,
            pos,
            max_word_syllables,
            per_span,
            config,
            false,
            false,
        );

        for state in states {
            let parent = arena.len();
            arena.push(state);
            let prev_text = state.word.map(|(f, i)| spans[f][i].word.text.clone());
            for (idx, span) in spans[pos].iter().enumerate() {
                let word = &span.word;
                if state.typos + word.typos > config.max_typos {
                    continue;
                }
                let (lm_raw, covered) = if word.known {
                    (
                        lm.score(prev_text.as_deref(), &word.text),
                        word.syllable_count,
                    )
                } else {
                    (0.0, 0)
                };
                let typo_cost = (config.typo_cost * word.typos as f64 - config.swap_discount * word.swaps as f64)
                    + config.completion_cost * word.completion as f64
                    + abbrev_penalty(graph, word, config);
                let next = Node {
                    parent: Some(parent),
                    word: Some((pos, idx)),
                    score: state.score - span.lexical + config.lm_weight * lm_raw - typo_cost,
                    lm_score: state.lm_score + lm_raw,
                    lexical_cost: state.lexical_cost + span.lexical,
                    covered_syllables: state.covered_syllables + covered,
                    total_syllables: state.total_syllables + word.syllable_count,
                    typos: state.typos + word.typos,
                    completion: state.completion + word.completion,
                    jianpin: state.jianpin || word.jianpin,
                    text_hash: extend_text_hash(state.text_hash, &word.text),
                };
                buckets[word.end].push(next);
            }
        }
    }

    // 终点不按末词去重：保留多样性，最后按整句文本去重
    let mut finals = std::mem::take(&mut buckets[n]);
    finals.sort_by(|a, b| b.score.total_cmp(&a.score));
    // 截断时纠错最少的整句也至少留几条（同 prune）
    let fewest = finals.iter().map(|s| s.typos).min().unwrap_or(0);
    let mut typed = 0usize;
    let mut kept = 0usize;
    finals.retain(|node| {
        let is_typed = node.typos == fewest;
        let keep = kept < final_cap || (is_typed && typed < TYPED_RESERVE);
        if keep {
            kept += 1;
            typed += usize::from(is_typed);
        }
        keep
    });

    let mut best_by_text: HashMap<String, BeamPath> = HashMap::new();
    for node in finals {
        let mut words: Vec<BeamWord> = Vec::new();
        let mut cursor = Some(node);
        while let Some(current) = cursor {
            if let Some((f, i)) = current.word {
                words.push(spans[f][i].word.clone());
            }
            cursor = current.parent.map(|p| arena[p]);
        }
        words.reverse();
        let text: String = words.iter().map(|w| w.text.as_str()).collect();
        let pinyin = words
            .iter()
            .map(|w| w.pinyin.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let coverage = if node.total_syllables == 0 {
            0.0
        } else {
            node.covered_syllables as f32 / node.total_syllables as f32
        };
        let path = BeamPath {
            text: text.clone(),
            pinyin,
            words,
            score: node.score,
            lm_score: node.lm_score,
            lexical_cost: node.lexical_cost,
            coverage,
            jianpin: node.jianpin,
            typos: node.typos,
            completion: node.completion,
        };
        match best_by_text.entry(text) {
            Entry::Vacant(slot) => {
                slot.insert(path);
            }
            Entry::Occupied(mut slot) => {
                if path.score > slot.get().score {
                    slot.insert(path);
                }
            }
        }
    }

    let mut paths: Vec<BeamPath> = best_by_text.into_values().collect();
    paths.sort_by(|a, b| {
        b.score
            .total_cmp(&a.score)
            .then_with(|| a.text.cmp(&b.text))
    });
    paths
}

/// 句首词：从输入开头起、没有用完整个输入的已知词，按「更长优先、代价更低优先」排序。
///
/// 返回 (词, 代价)。代价含纠错惩罚。
pub fn first_words(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    config: &BeamConfig,
    limit: usize,
) -> Vec<(BeamWord, f64)> {
    let n = graph.len();
    if n == 0 || limit == 0 {
        return Vec::new();
    }
    let per_span = config.max_expansions_per_state.max(1);
    const RARE: bool = false;
    let mut words: Vec<(BeamWord, f64)> = collect_spans(
        graph,
        lexicon,
        0,
        config.max_word_syllables.max(1),
        per_span,
        config,
        RARE,
        true,
    )
    .into_iter()
    .filter(|s| s.word.known && s.word.end < n)
    .map(|s| {
        let cost = s.lexical
            + (config.typo_cost * s.word.typos as f64 - config.swap_discount * s.word.swaps as f64)
            + abbrev_penalty(graph, &s.word, config);
        (s.word, cost)
    })
    .collect();
    words.sort_by(|a, b| {
        b.0.end
            .cmp(&a.0.end)
            .then_with(|| a.1.total_cmp(&b.1))
            .then_with(|| a.0.text.cmp(&b.0.text))
    });
    // 每个长度最多取几个，避免两字词把单字全部挤掉；单字多留几个，
    // 整句和词都不对时用户靠它一个字一个字地选
    // 纠错出来的另算名额，不占照着打的词的位置（纠错只能「加」候选）
    let mut per_end: HashMap<(usize, bool), usize> = HashMap::new();
    words.retain(|(w, _)| {
        let count = per_end.entry((w.end, w.typos > 0)).or_insert(0);
        *count += 1;
        let single = w.pinyin.split_whitespace().count() <= 1;
        *count <= if single { 6 } else { 3 }
    });
    // 超过 limit 时先去掉排在后面的纠错词，照着打的词留着
    let typed = words.iter().filter(|(w, _)| w.typos == 0).count();
    let mut typo_room = limit.saturating_sub(typed);
    words.retain(|(w, _)| {
        if w.typos == 0 {
            return true;
        }
        let keep = typo_room > 0;
        typo_room = typo_room.saturating_sub(1);
        keep
    });
    words.truncate(limit);
    words
}

/// 从输入开头起的全部词典词（翻页时补在后面）：包括正好用完整个输入的同音词。
///
/// 和 [`first_words`] 不同，这里每个结束位置最多留 `per_span` 个，不再按长度限量。
/// 排序：用掉的字母多的在前，同样长的按代价从低到高。
pub fn all_first_words(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    config: &BeamConfig,
    per_span: usize,
) -> Vec<(BeamWord, f64)> {
    if graph.len() == 0 || per_span == 0 {
        return Vec::new();
    }
    // 生僻字只在这里（翻页的长尾）出现，见 [`crate::lexicon::LexEntry::is_rare`]
    const RARE: bool = true;
    let mut words: Vec<(BeamWord, f64)> = collect_spans(
        graph,
        lexicon,
        0,
        config.max_word_syllables.max(1),
        per_span,
        config,
        RARE,
        true,
    )
    .into_iter()
    .filter(|s| s.word.known)
    .map(|s| {
        let cost = s.lexical
            + (config.typo_cost * s.word.typos as f64 - config.swap_discount * s.word.swaps as f64)
            + config.completion_cost * s.word.completion as f64
            + abbrev_penalty(graph, &s.word, config);
        (s.word, cost)
    })
    .collect();
    words.sort_by(|a, b| {
        b.0.end
            .cmp(&a.0.end)
            .then_with(|| a.1.total_cmp(&b.1))
            .then_with(|| a.0.text.cmp(&b.0.text))
    });
    words
}

/// 从 pos 出发的所有候选词：词典命中（按结束位置分组，各取代价最低的若干个）
/// 加上每条精确边的未登录兜底。
/// `typo_quota`：纠错出来的词另算名额（句首词、翻页长尾用）。纠错只能「加」候选：和照着打的词抢同一份
/// 名额的话，纠错出来的常用词（词频高、只扣一个固定罚分）会把照着打的冷门字挤掉（`cunzai` 的「蹲」cun）。
#[allow(clippy::too_many_arguments)]
fn collect_spans(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    pos: usize,
    max_syllables: usize,
    per_span: usize,
    config: &BeamConfig,
    rare: bool,
    typo_quota: bool,
) -> Vec<Span> {
    let mut found = Found {
        total_freq: lexicon.total_freq(),
        ..Found::default()
    };
    let mut keys: Vec<SyllableQuery> = Vec::new();
    collect_dfs(
        graph,
        lexicon,
        pos,
        pos,
        max_syllables,
        0,
        0,
        &mut keys,
        &mut found,
        config,
        rare,
    );

    // 同一个结束位置内按「词典代价 + 纠错代价」排序截断。
    // 不能跨结束位置按词频截断：单字的频次天然比多字词高，会把长词全挤掉。
    //
    // 查到的词先只记成 [`Hit`]（字放在一个共用的缓冲里），排序、去重都在下标上做，
    // 只给留下来的造 [`BeamWord`]：万象词库里乱按的 `sdsj` 一个位置就能查出上万个词，
    // 以前每个都复制一遍词条、造一个带两个 String 的 Span 再整体排序（#227）。
    // 先后和以前完全一样：以前是按结束位置分组（组内保持查到的先后）、组内按（代价, 字）稳定排序，
    // 这里按（结束位置, 代价, 字, 查到的先后）排，是同一个顺序。
    let Found {
        hits, lookups, text, ..
    } = found;
    let word_of = |h: &Hit| &text[h.text.0 as usize..h.text.1 as usize];
    let mut order: Vec<u32> = (0..hits.len() as u32).collect();
    // 按结束位置先粗分组，组内再排：组和组之间只比一个整数
    order.sort_unstable_by_key(|&i| lookups[hits[i as usize].lookup as usize].end);
    let mut out = Vec::new();
    let mut group_start = 0;
    while group_start < order.len() {
        let end = lookups[hits[order[group_start] as usize].lookup as usize].end;
        let group_len = order[group_start..]
            .iter()
            .position(|&i| lookups[hits[i as usize].lookup as usize].end != end)
            .unwrap_or(order.len() - group_start);
        let group = &mut order[group_start..group_start + group_len];
        group_start += group_len;
        let cmp = |a: &u32, b: &u32| {
            let (ha, hb) = (&hits[*a as usize], &hits[*b as usize]);
            ha.key
                .total_cmp(&hb.key)
                .then_with(|| word_of(ha).cmp(word_of(hb)))
                .then(a.cmp(b))
        };
        let typos_of = |i: u32| lookups[hits[i as usize].lookup as usize].typos;
        let mut keep = Keep {
            per_span,
            typo_quota,
            unique: Vec::with_capacity(per_span.min(group.len())),
            index: HashMap::new(),
            kept: (0, 0),
        };
        // 一组常有上千个词，按顺序往下取，取够名额就停（束搜索每组 32 个）：先只挑出排在最前面的一段排好，
        // 这段不够再排剩下的。上面的比较是全序（最后比查到的先后），挑出来的这段和整组排好以后的开头一模一样
        let head = HEAD_PER_SPAN.saturating_mul(per_span).min(group.len());
        if head < group.len() {
            group.select_nth_unstable_by(head, cmp);
        }
        group[..head].sort_unstable_by(cmp);
        let mut done = false;
        for &span in group[..head].iter() {
            if keep.offer(span, typos_of(span), word_of(&hits[span as usize]), &|k| {
                (typos_of(k), word_of(&hits[k as usize]))
            }) {
                done = true;
                break;
            }
        }
        if !done && head < group.len() {
            // 照着打的名额满了以后，剩下照着打的词都只是跳过（kept.0 只增不减），不用排它们
            let mut tail: Vec<u32> = if typo_quota && keep.kept.0 >= per_span {
                group[head..].iter().copied().filter(|&i| typos_of(i) > 0).collect()
            } else {
                group[head..].to_vec()
            };
            tail.sort_unstable_by(cmp);
            for span in tail {
                if keep.offer(span, typos_of(span), word_of(&hits[span as usize]), &|k| {
                    (typos_of(k), word_of(&hits[k as usize]))
                }) {
                    break;
                }
            }
        }
        let unique = keep.unique;
        out.extend(unique.into_iter().map(|i| {
            let hit = &hits[i as usize];
            let lookup = &lookups[hit.lookup as usize];
            Span {
                lexical: hit.lexical,
                word: BeamWord {
                    text: word_of(hit).to_string(),
                    pinyin: lookup.pinyin.clone(),
                    freq: hit.freq,
                    known: true,
                    syllable_count: lookup.syllable_count,
                    jianpin: lookup.jianpin,
                    abbrev: lookup.abbrev,
                    ends_abbrev: lookup.ends_abbrev,
                    typos: lookup.typos,
                    swaps: lookup.swaps,
                    completion: lookup.completion,
                    start: lookup.start,
                    end: lookup.end,
                },
            }
        }));
    }

    // 未知音节兜底：每条精确边都允许直接当作一个未登录词，保证任何合法输入都能走到底。
    for edge in graph.edges_from(pos) {
        if edge.typo || edge.completion > 0 {
            continue;
        }
        out.push(Span {
            word: unknown_word(edge),
            lexical: config.unknown_cost,
        });
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn collect_dfs(
    graph: &SyllableGraph,
    lexicon: &dyn Lexicon,
    start: usize,
    pos: usize,
    max_syllables: usize,
    typos: usize,
    swaps: usize,
    keys: &mut Vec<SyllableQuery>,
    out: &mut Found,
    config: &BeamConfig,
    rare: bool,
) {
    for edge in graph.edges_from(pos) {
        let edge_typos = typos + usize::from(edge.typo);
        let edge_swaps = swaps + usize::from(edge.typo && edge.swap);
        if edge_typos > config.max_typos_per_word {
            continue;
        }
        let before = keys.len();
        edge.push_queries(keys);
        if keys.len() > max_syllables {
            keys.truncate(before);
            continue;
        }
        let abbrev = keys.iter().filter(|q| q.is_jianpin()).count();
        let jianpin = abbrev > 0;
        // 生僻字只给打全了、没纠错的全拼（shi 列全 shi 的字）；sh、s 这种简拼和补全不带它们，
        // 不然每打一个声母都要排几千个字
        let common = !(rare && !jianpin && edge.completion == 0 && edge_typos == 0);
        let skip_ext = !config.rare_ext_chars && keys.len() == 1;
        let lookup = out.lookups.len() as u32;
        // 排序用的代价：和以前组内排序时现算的一样（词典代价 + 纠错、补全的代价）
        let extra = (config.typo_cost * edge_typos as f64 - config.swap_discount * edge_swaps as f64)
            + config.completion_cost * usize::from(edge.completion) as f64;
        let total_freq = out.total_freq;
        let before_hits = out.hits.len();
        let (hits, text) = (&mut out.hits, &mut out.text);
        lexicon.visit(keys, common, &mut |word, freq| {
            if skip_ext && is_ext_char(word) {
                return;
            }
            let lexical = freq_cost(freq, total_freq);
            let at = text.len() as u32;
            text.push_str(word);
            hits.push(Hit {
                lookup,
                text: (at, text.len() as u32),
                freq,
                lexical,
                key: lexical + extra,
            });
        });
        if out.hits.len() > before_hits {
            out.lookups.push(Lookup {
                pinyin: pinyin_of(keys),
                syllable_count: keys.len(),
                jianpin,
                abbrev,
                ends_abbrev: keys.last().is_some_and(|q| q.is_jianpin()),
                typos: edge_typos,
                swaps: edge_swaps,
                completion: usize::from(edge.completion),
                start,
                end: edge.end,
            });
        }
        if keys.len() < max_syllables && lexicon.has_longer(keys) {
            collect_dfs(
                graph,
                lexicon,
                start,
                edge.end,
                max_syllables,
                edge_typos,
                edge_swaps,
                keys,
                out,
                config,
                rare,
            );
        }
        keys.truncate(before);
    }
}

/// 全拼混简拼时省略韵母的惩罚（纯全拼、纯简拼的图不罚）。
fn abbrev_penalty(graph: &SyllableGraph, word: &BeamWord, config: &BeamConfig) -> f64 {
    if graph.mode() != GraphMode::Mixed || word.abbrev == 0 {
        return 0.0;
    }
    let tail = if word.ends_abbrev && word.end == graph.len() {
        config.tail_abbrev_cost
    } else {
        0.0
    };
    config.abbrev_cost * word.abbrev as f64 + tail
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
        abbrev: usize::from(query.is_jianpin()),
        ends_abbrev: query.is_jianpin(),
        typos: 0,
        swaps: 0,
        completion: 0,
        start: edge.start,
        end: edge.end,
    }
}

fn pinyin_of(keys: &[SyllableQuery]) -> String {
    keys.iter()
        .map(|q| q.display())
        .collect::<Vec<_>>()
        .join(" ")
}

/// 纠错最少的状态在每个位置至少留这么多个，不管分数排第几（见 [`prune`]）。
const TYPED_RESERVE: usize = 4;

/// 同一位置内剪枝：末词相同、纠错处数也相同的状态最多留 `per_word` 条（[`BeamConfig::histories_per_word`]），
/// 而且文字得不一样；再取前 beam_size。
///
/// 二元模型下末词相同的状态后续完全等价，只留最好的一条（`per_word` = 1）就够选出分数最高的整句。
/// 但那样最后剩下的整句只在句尾不同，句子中间的另一种选法早被并掉了；多留几条，神经语言模型重排时才有的挑。
/// 末词相同、前面的字也一样只是切法不同的（不 | 知道 | 的、不知道 | 的）只算一条，不占名额。
///
/// 纠错处数不同的不能并成一条：`cehaohou` 走到 hao 后面时，「的 | 好」（c 当成按错的 d，「的」词频高）
/// 和「测 | 好」末词都是「好」，以前只留分数高的「的 | 好」，没纠错的读法到这里就断了，
/// 最后只剩「的好后」「得好后」两个候选，连 `ce` 的单字都选不到。
///
/// 另外，这个位置上纠错最少的那些状态至少留 [`TYPED_RESERVE`] 个，哪怕分数排在 beam_size 以外：
/// 「照着打的字母读」的路径必须能走到底，排不排第一由后面的排序决定。
fn prune<'a, F>(states: Vec<Node>, beam_size: usize, per_word: usize, last_word: F) -> Vec<Node>
where
    F: Fn(&Node) -> Option<&'a str>,
{
    // 按分数从高到低、同分的按原来的先后（和对 states 本身稳定排序一样），只排（分数, 下标）：
    // 一个位置能堆上千个状态，整个 Node 搬来搬去比比较本身慢（#227）
    let mut order: Vec<(f64, u32)> = states
        .iter()
        .enumerate()
        .map(|(i, s)| (s.score, i as u32))
        .collect();
    order.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    let fewest = states.iter().map(|s| s.typos).min().unwrap_or(0);
    let mut seen: HashMap<(&'a str, usize), usize> = HashMap::new();
    let mut texts: HashSet<(u64, &'a str, usize)> = HashSet::new();
    let mut out = Vec::with_capacity(beam_size + TYPED_RESERVE);
    let mut typed = 0usize;
    for state in order.iter().map(|&(_, i)| states[i as usize]) {
        let full = out.len() >= beam_size;
        if full && (state.typos != fewest || typed >= TYPED_RESERVE) {
            if typed >= TYPED_RESERVE {
                break;
            }
            continue;
        }
        let last = last_word(&state).unwrap_or("");
        let kept = seen.entry((last, state.typos)).or_insert(0);
        if *kept >= per_word {
            continue;
        }
        // 末词相同、前面的字也一样（只是切法不同）的只留分数最高的那条，不占这个末词的名额。
        // 末词不同的不管字一不一样都留：二元模型下它们后面接的词分数不同
        if per_word > 1 && !texts.insert((state.text_hash, last, state.typos)) {
            continue;
        }
        *kept += 1;
        typed += usize::from(state.typos == fewest);
        out.push(state);
    }
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
                typo: false,
                completion: false,
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
    fn histories_per_word_keeps_mid_sentence_alternatives() {
        // 晚风 | 吹 | 着 和 完 | 风 | 吹 | 着：走到「吹」时末词相同。只留一条历史的话句中的另一种写法到这里就没了，
        // 最后出来的整句只在句尾不一样，重排时没得挑
        let g = graph("wanfengchuizhe", GraphMode::Full);
        let lex = MemoryLexicon::from_tsv_str(
            "wan feng\t晚风\t300\nwan\t完\t900\nfeng\t风\t900\nchui\t吹\t900\nzhe\t着\t900\n",
        )
        .unwrap();
        let lm = BigramLm::default();
        let texts = |histories: usize| -> Vec<String> {
            let config = BeamConfig {
                histories_per_word: histories,
                ..BeamConfig::default()
            };
            beam_search(&g, &lex, &lm, &config)
                .into_iter()
                .map(|p| p.text)
                .collect()
        };
        let one = texts(1);
        assert_eq!(
            one.iter().filter(|t| *t == "晚风吹着" || *t == "完风吹着").count(),
            1,
            "只留一条历史：{one:?}"
        );
        let three = texts(3);
        assert!(
            three.iter().any(|t| t == "晚风吹着") && three.iter().any(|t| t == "完风吹着"),
            "留三条历史时两种写法都在：{three:?}"
        );
        assert_eq!(one[0], three[0], "第一名（二元模型下的最优）不变");
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
