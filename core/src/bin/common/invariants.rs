//! `wowtype-eval --invariants`：把评测集里的每个输入逐键打一遍，检查「无论排序怎么调都不许出现」的结果。
//!
//! 排序评测（top1 命中率）只能说明「大多数时候第一个对」，说明不了「这种离谱的结果从来不会有」：
//! `cehaohou` 只剩「的好后」「得好后」两个候选（72bf8e2 修的）时，top1 统计里只少了一条。
//! 这里的每条规则都是硬的——一条都不许违反（`tools/eval/invariants-allow.tsv` 里写明了理由的除外）。
//! 规则的来历和成熟输入法（librime、libime、libpinyin）的做法见 `docs/ENGINE-INVARIANTS.md`。
//!
//! 每个前缀（`c`、`ce`、`ceh`……）在几种条件下各查一次：没有上文、用例自带的上文、`--inv-context`
//! 给的上文；给了 `--nnlm` 时每种再带上神经语言模型查一次。规则：
//!
//! - **typed-first**：输入能整个切成完整音节（不靠纠错、补全）时，第一个候选不是纠错出来的。
//!   例外和 `typed_reading_first` 一样：纠错以后音节更少（`shijain` 照字母读是 shi jia in，纠一处是「时间」）。
//! - **typed-first-partial**：不靠纠错、只靠末音节补全能读通时（`ceh` = ce + h…），第一个候选也不是纠错出来的
//!   （同样的音节数例外）。
//! - **first-syllable-chars**：照着打的读法（不纠错，末音节可以补全）有两个以上音节时，第一个音节的单字在候选里
//!   （`cehao` 里要有「测」：整句不对时用户要一个字一个字选）。切法不止一种时（`kenengs` = ke neng s / ken eng s）
//!   只要第一个候选用的那种；第一个候选是纠错出来的，每种都要。
//! - **min-candidates**：第一个音节是完整音节时，候选（不算原始串）至少有 min(9, 这个音节的常用单字数) 个。
//! - **typed-kept**：没有上文、不带神经语言模型时照着打的那个读法（第一个不纠错、用完整个输入的候选），
//!   加了上文或者带上模型以后还在：它是词库里的一个词时这个词还在候选里；是几个词拼的整句时，
//!   至少还有一个照着打的整句（拼法可以换：晚 | 事儿 → 碗 | 事儿）。
//! - **no-duplicates**：候选里没有字和用掉的键都一样的两条。
//! - **completion-outranks-word**：打全了、整个输入正好是一个常用词（词频 1000 以上、读音一点不差）时，补全出来的
//!   候选不排在它前面。
//! - **typo / fuzzy / jianpin-only-adds**、**-outranks-typed**：按错键纠错、模糊音兜底、简拼只能**加**候选，不能替换：
//!   把它关掉再查一次，关掉时第一页的候选开着时都还在，关掉时排第一的不排在它加进来的候选后面
//!   （纠错以后音节更少的例外，同 typed-first）。见 [`only_adds`]。

use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::sync::Arc;

use wowtype_core::nnlm::Nnlm;
use wowtype_core::syllable::parse;
use wowtype_core::{
    Candidate, EdgeKind, Engine, GraphMode, GraphOptions, Lexicon, Syllable, SyllableGraph,
    SyllableQuery,
};

/// 一页候选的个数（min-candidates 的上限）。
const PAGE: usize = 9;
/// typo-flood：照着打读得通时，排在正常候选前面的纠错候选最多这么多个（和引擎的 `TYPO_QUOTA` 一样）。
const TYPO_QUOTA: usize = 3;
/// completion-outranks-word、fuzzy-outranks-word 只管这么常用以上的词（和引擎的 `EXACT_PROTECT_MIN_FREQ` 一样）。
const EXACT_WORD_FREQ: f64 = 1000.0;

pub struct Options {
    /// 每个前缀都额外带上这些上文各查一次。
    pub contexts: Vec<String>,
    /// 每条规则最多打印几条违反（0 = 全打）。
    pub limit: usize,
    /// 已知违反的清单（规则、输入、上文、理由）。
    pub allow: Option<String>,
    /// 违反写进这个文件（全部，TSV）。
    pub out: Option<String>,
}

/// 一个输入（一次按键后的整串）在音节图上的形状，和排序无关。
struct Shape {
    /// 只用完整音节（不纠错、不补全）切完的最少音节数。
    exact: Option<usize>,
    /// 不纠错、末音节可以补全时切完的最少音节数。
    no_typo: Option<usize>,
    /// 不纠错（末音节可以补全）、音节最少的切法里第一个音节的拼音；最少音节数小于 2 时为空。
    first: Vec<String>,
    /// 第一个音节本身是个完整音节、打全了（单音节输入就是整个输入）：min-candidates 看它的单字数。
    head: Vec<String>,
}

fn shape(input: &str, lexicon: &dyn Lexicon, chars: &mut HashMap<String, usize>) -> Option<Shape> {
    let parsed = parse(&input.to_ascii_lowercase()).ok()?;
    if parsed.is_empty() {
        return None;
    }
    let graph = SyllableGraph::build(
        &parsed,
        GraphOptions {
            mode: GraphMode::Full,
            allow_erhua: true,
            typo: false,
            completion: true,
        },
    );
    let n = graph.len();
    // 词库里一个字都没有的音节（nia、hm……）不算「照着打能读」：zuinia 照着打是 zui ni a，不是 zui nia。
    // 补全边的音节是补出来的，不查
    let mut has_chars = HashMap::new();
    for pos in 0..n {
        for e in graph.edges_from(pos) {
            if e.completion == 0 && matches!(e.kind, EdgeKind::Full { .. }) {
                let text = e.display();
                has_chars
                    .entry(text.clone())
                    .or_insert_with(|| char_count(lexicon, chars, &text) > 0);
            }
        }
    }
    let usable = |e: &wowtype_core::Edge| {
        e.completion > 0 || has_chars.get(&e.display()).copied().unwrap_or(false)
    };
    // 从每个位置走到底最少几个音节
    let min_from = |allow_completion: bool| -> Vec<Option<usize>> {
        let mut best = vec![None; n + 1];
        best[n] = Some(0);
        for pos in (0..n).rev() {
            best[pos] = graph
                .edges_from(pos)
                .iter()
                .filter(|e| !e.typo && (allow_completion || e.completion == 0) && usable(e))
                .filter_map(|e| best[e.end].map(|b| b + e.syllable_count()))
                .min();
        }
        best
    };
    let exact = min_from(false);
    let no_typo = min_from(true);
    let plain_syllable = |e: &&wowtype_core::Edge| {
        !e.typo && e.completion == 0 && matches!(e.kind, EdgeKind::Full { erhua: false, .. })
    };
    let mut first = Vec::new();
    if let Some(total) = no_typo[0].filter(|&t| t >= 2) {
        for e in graph.edges_from(0).iter().filter(plain_syllable) {
            if no_typo[e.end].is_some_and(|rest| rest + 1 == total) {
                first.push(e.display());
            }
        }
    }
    let mut head = first.clone();
    if head.is_empty() && exact[0] == Some(1) {
        head.extend(
            graph
                .edges_from(0)
                .iter()
                .filter(plain_syllable)
                .filter(|e| e.end == n)
                .map(|e| e.display()),
        );
    }
    first.sort();
    first.dedup();
    head.sort();
    head.dedup();
    Some(Shape {
        exact: exact[0],
        no_typo: no_typo[0],
        first,
        head,
    })
}

fn is_raw(c: &Candidate) -> bool {
    c.words.len() == 1 && c.words[0].pinyin.is_empty()
}

fn syllables(c: &Candidate) -> usize {
    c.pinyin.split_whitespace().count()
}

fn typo(c: &Candidate) -> bool {
    c.features.typo_count > 0.0
}

/// 每个词在词库里真有这个读音（模糊音兜底的「朋友」penyou、「最近」zuijing 不算照着打的）。
fn lexicon_reading(lexicon: &dyn Lexicon, c: &Candidate) -> bool {
    !c.words.is_empty()
        && c.words.iter().all(|w| {
            let query: Option<Vec<SyllableQuery>> = w
                .pinyin
                .split_whitespace()
                .map(|s| Syllable::from_text(s).map(|s| s.query(false)))
                .collect();
            query.is_some_and(|q| {
                !q.is_empty() && lexicon.lookup(&q).iter().any(|e| e.word == w.text)
            })
        })
}

/// 照着打的那个读法：第一个不纠错、用完整个输入、每个词词库里真有这个读音的中文候选。
fn typed_reading<'a>(
    lexicon: &dyn Lexicon,
    cands: &'a [Candidate],
    len: usize,
) -> Option<&'a Candidate> {
    cands
        .iter()
        .find(|c| !is_raw(c) && !typo(c) && c.consumed >= len && lexicon_reading(lexicon, c))
}

/// 候选的拼音正好是打的字母（不是补全、纠错出来的）。翻页长尾里补全出来的词没有补全的标记，
/// 只能这样认：shenghu 的「圣皇」是 sheng huang。
fn same_letters(c: &Candidate, input: &str) -> bool {
    let typed = input.bytes().filter(u8::is_ascii_alphabetic).map(|b| b.to_ascii_lowercase());
    c.pinyin
        .bytes()
        .filter(u8::is_ascii_alphabetic)
        .eq(typed)
}

/// 「照着打的」：不是纠错、模糊音兜底、简拼加进来的，每个词词库里真有这个读音。
fn plain_typed(lexicon: &dyn Lexicon, c: &Candidate) -> bool {
    !is_raw(c)
        && !typo(c)
        && !c.features.fuzzy
        && c.features.full_jianpin == 0.0
        && lexicon_reading(lexicon, c)
}

/// 照着打的读法是不是词库里的一个词（不是几个词拼出来的整句）。
fn is_word(c: &Candidate) -> bool {
    c.words.len() == 1 && c.words[0].known
}

/// 候选前几个的简写：纠错的后面标 `*`，句首词标 `…`。
fn brief(cands: &[Candidate], len: usize, n: usize) -> String {
    let mut out: Vec<String> = cands
        .iter()
        .take(n)
        .map(|c| {
            let mut s = c.text.clone();
            if typo(c) {
                s.push('*');
            }
            if c.consumed < len {
                s.push('…');
            }
            s
        })
        .collect();
    if cands.len() > n {
        out.push(format!("……共 {} 个", cands.len()));
    }
    out.join(" ")
}

struct Violation {
    rule: &'static str,
    input: String,
    context: String,
    nnlm: bool,
    detail: String,
}

impl Violation {
    fn key(&self) -> (String, String, String) {
        (
            self.rule.to_string(),
            self.input.clone(),
            self.context.clone(),
        )
    }
}

/// 单字数：这个音节的常用单字有几个（min-candidates 的门槛）。
fn char_count(lexicon: &dyn Lexicon, cache: &mut HashMap<String, usize>, syllable: &str) -> usize {
    if let Some(&n) = cache.get(syllable) {
        return n;
    }
    let n = parse(syllable)
        .ok()
        .map(|p| {
            let g = SyllableGraph::build(&p, GraphOptions::default());
            g.edges_from(0)
                .iter()
                .filter(|e| {
                    e.end == g.len() && matches!(e.kind, EdgeKind::Full { erhua: false, .. })
                })
                .map(|e| {
                    let q: Vec<SyllableQuery> = vec![e.query()];
                    lexicon
                        .lookup_common(&q)
                        .iter()
                        .filter(|w| w.word.chars().count() == 1)
                        .count()
                })
                .max()
                .unwrap_or(0)
        })
        .unwrap_or(0);
    cache.insert(syllable.to_string(), n);
    n
}

/// 一种条件下查出来的候选要满足的规则（typed-kept 另算）。
fn check_one(
    input: &str,
    shape: &Shape,
    cands: &[Candidate],
    lexicon: &dyn Lexicon,
    chars: &mut HashMap<String, usize>,
    mut report: impl FnMut(&'static str, String),
) {
    let len = input.len();
    let top = cands.iter().find(|c| !is_raw(c));
    // typed-first / typed-first-partial
    if let Some(top) = top.filter(|c| typo(c)) {
        let (rule, need) = match (shape.exact, shape.no_typo) {
            (Some(n), _) => ("typed-first", Some(n)),
            (None, Some(n)) => ("typed-first-partial", Some(n)),
            _ => ("", None),
        };
        // 照着打的音节词库里一个字都没有（ng、hm）：没有可排的，纠错出来的排第一不算
        let typed_has_chars = shape
            .head
            .iter()
            .chain(&shape.first)
            .any(|s| char_count(lexicon, chars, s) > 0);
        if let Some(need) = need.filter(|_| typed_has_chars) {
            // 纠错以后整个输入用更少的音节读完，是在把输入解释得更省（shijain -> 时间），不算
            let fewer = top.consumed >= len && syllables(top) < need;
            if !fewer {
                report(
                    rule,
                    format!(
                        "第一个是纠错出来的「{}」（{}），照着打能读成 {need} 个音节",
                        top.text, top.pinyin
                    ),
                );
            }
        }
    }
    // first-syllable-chars：照着打的切法不止一种时（kenengs = ke neng s / ken eng s），候选里第一个照着打的读法
    // 用的是其中一种，就只要这一种的单字（hung 的「混个」hun g…，不要求 hu ng 的「虎」）；一个照着打的读法都没有时，每种都要
    let top_first = typed_reading(lexicon, cands, len)
        .and_then(|c| c.pinyin.split_whitespace().next())
        .filter(|f| shape.first.iter().any(|s| s == f));
    let wanted: Vec<&String> = match top_first {
        Some(f) => shape.first.iter().filter(|s| *s == f).collect(),
        None => shape.first.iter().collect(),
    };
    for s in wanted {
        if char_count(lexicon, chars, s) == 0 {
            continue;
        }
        let found = cands
            .iter()
            .any(|c| c.text.chars().count() == 1 && c.pinyin == *s);
        if !found {
            report(
                "first-syllable-chars",
                format!("候选里没有第一个音节 {s} 的单字"),
            );
        }
    }
    // completion-outranks-word：输入打全了、整个输入正好是一个够常用的词（读音一点不差）时，
    // 补全出来的候选不排在它前面（zhongdi 出「种地」不出「重点」，见 protect_exact_input）
    if shape.exact.is_some() {
        let word_at = cands.iter().position(|c| {
            c.consumed >= len
                && is_word(c)
                && c.words[0].freq >= EXACT_WORD_FREQ
                && !typo(c)
                && c.features.prefix_completion == 0.0
                && c.features.full_jianpin == 0.0
                && !c.features.fuzzy
                && same_letters(c, input)
                && lexicon_reading(lexicon, c)
        });
        if let Some(at) = word_at {
            let ahead: Vec<&str> = cands[..at]
                .iter()
                .filter(|c| c.features.prefix_completion > 0.0)
                .map(|c| c.text.as_str())
                .collect();
            if !ahead.is_empty() {
                report(
                    "completion-outranks-word",
                    format!(
                        "打全了的词「{}」排在补全出来的「{}」后面",
                        cands[at].text,
                        ahead.join("」「")
                    ),
                );
            }
            // fuzzy-outranks-word：同样的词也不排在模糊音兜底的词后面（penyou 出「喷油」「朋友」）。照着打
            // 只能几个字硬凑时（shengme）模糊音的词可以排第一，那是用户定的，不查
            let ahead: Vec<&str> = cands[..at]
                .iter()
                .filter(|c| c.features.fuzzy)
                .map(|c| c.text.as_str())
                .collect();
            if !ahead.is_empty() {
                report(
                    "fuzzy-outranks-word",
                    format!(
                        "照着打的词「{}」排在模糊音兜底的「{}」后面",
                        cands[at].text,
                        ahead.join("」「")
                    ),
                );
            }
        }
    }
    // min-candidates
    let need = shape
        .head
        .iter()
        .map(|s| char_count(lexicon, chars, s))
        .max()
        .unwrap_or(0)
        .min(PAGE);
    let shown = cands.iter().filter(|c| !is_raw(c)).count();
    if shown < need {
        report(
            "min-candidates",
            format!(
                "只有 {shown} 个中文候选，第一个音节（{}）就有 {need} 个以上常用单字",
                shape.head.join("/")
            ),
        );
    }
    // typo-flood：排第一的不是纠错出来的时（照着打读得通），纠错候选有名额：排在正常候选前面的最多 TYPO_QUOTA 个，
    // 其余只能在整个列表的最后面。nishi 以前第 12 到 36 个全是纠错的「即使、笔试、迷失……」，ni 的单字被压到第五页
    if top.is_some_and(|c| !typo(c)) {
        let last_normal = cands.iter().rposition(|c| !is_raw(c) && !typo(c));
        let ahead: Vec<&Candidate> = last_normal
            .map(|n| cands[..n].iter().filter(|c| !is_raw(c) && typo(c)).collect())
            .unwrap_or_default();
        if ahead.len() > TYPO_QUOTA {
            let sample: Vec<&str> = ahead.iter().take(6).map(|c| c.text.as_str()).collect();
            report(
                "typo-flood",
                format!(
                    "{} 个纠错出来的候选排在正常候选前面（最多 {TYPO_QUOTA} 个）：{}……",
                    ahead.len(),
                    sample.join(" ")
                ),
            );
        }
    }
    // no-duplicates
    let mut seen = HashSet::new();
    for c in cands {
        if !seen.insert((c.text.as_str(), c.consumed)) {
            report(
                "no-duplicates",
                format!("「{}」（用掉 {} 个键）出现了两次", c.text, c.consumed),
            );
            break;
        }
    }
}

/// 只该往候选里「加」东西的机制：开着和关掉时的候选对比（[`only_adds`]）。
struct Mechanism {
    /// 规则名的前缀（`typo-only-adds`、`typo-outranks-typed`）。
    name: &'static str,
    /// 说明里的叫法。
    label: &'static str,
    /// 这个候选是这个机制加进来的。
    added: fn(&Candidate) -> bool,
    /// 开关。
    set: fn(&mut Engine, bool),
}

impl Mechanism {
    fn added(&self, c: &Candidate) -> bool {
        (self.added)(c)
    }

    fn set(&self, engine: &mut Engine, on: bool) {
        (self.set)(engine, on)
    }
}

const MECHANISMS: [Mechanism; 3] = [
    Mechanism {
        name: "typo",
        label: "按错键纠错",
        added: |c| c.features.typo_count > 0.0,
        set: |e, on| e.set_typo_correction(on),
    },
    Mechanism {
        name: "fuzzy",
        label: "模糊音兜底",
        added: |c| c.features.fuzzy,
        set: |e, on| e.set_fuzzy_fallback(on),
    },
    Mechanism {
        name: "jianpin",
        label: "简拼",
        added: |c| c.features.full_jianpin > 0.0,
        set: |e, on| e.set_jianpin_fallback(on),
    },
];

/// 用户的原话：按键纠错应该是「添加可疑的候选词，而不是替代原候选词」。纠错、模糊音兜底、简拼都一样：
///
/// - `<机制>-only-adds`：关掉它时第一页有的词（词库里的整词、句首词、单字）和排第一的照着打的读法，开着时还在候选里；
/// - `<机制>-outranks-typed`：关掉它时排第一的，开着时不排在它加进来的候选后面。例外和 typed-first 一样：
///   纠错以后整个输入的音节更少（`jintiam` -> 今天）。
fn only_adds(
    mechanism: &Mechanism,
    lexicon: &dyn Lexicon,
    input: &str,
    on: &[Candidate],
    off: &[Candidate],
    mut report: impl FnMut(&'static str, String),
) {
    let len = input.len();
    let rule = |suffix: &str| -> &'static str {
        match (mechanism.name, suffix) {
            ("typo", "adds") => "typo-only-adds",
            ("typo", _) => "typo-outranks-typed",
            ("fuzzy", "adds") => "fuzzy-only-adds",
            // 模糊音的「排到前面」不在这里查：照着打是现成的词时归 fuzzy-outranks-word，硬凑时允许
            ("fuzzy", _) => "fuzzy-outranks-word",
            (_, "adds") => "jianpin-only-adds",
            _ => "jianpin-outranks-typed",
        }
    };
    // 词库里的词（整词、句首词、单字）一个都不能少；几个词拼的整句有上限、会换拼法，只要还有一个照着打的整句
    let mut missing: Vec<&str> = off
        .iter()
        .filter(|c| !is_raw(c))
        .take(PAGE)
        .filter(|c| is_word(c) && plain_typed(lexicon, c))
        .filter(|c| !on.iter().any(|o| o.text == c.text))
        .map(|c| c.text.as_str())
        .collect();
    // 关掉时排第一的照着打的读法（关掉一种机制时另外几种照样会加候选，那些不算）：整句也要还在
    let top = off
        .iter()
        .find(|c| c.consumed >= len && plain_typed(lexicon, c));
    // 是几个词拼的整句时（我 | 知己）拼法可以换，至少还要有一个照着打的读法
    let typed_on = on.iter().any(|c| c.consumed >= len && plain_typed(lexicon, c));
    if let Some(t) = top.filter(|t| !is_word(t) && !typed_on) {
        missing.push(t.text.as_str());
    }
    if !missing.is_empty() {
        report(
            rule("adds"),
            format!(
                "关掉{}时第一页有的「{}」，开着时没了；关掉时 {}",
                mechanism.label,
                missing.join("」「"),
                brief(off, len, 9)
            ),
        );
    }
    let Some(top) = top else {
        return;
    };
    if mechanism.name == "fuzzy" {
        return;
    }
    // 开着时它前面的、加进来的候选：比到它和开着时第一个照着打的读法里靠前的那个
    let Some(at) = on
        .iter()
        .position(|c| c.text == top.text || (c.consumed >= len && plain_typed(lexicon, c)))
    else {
        return;
    };
    let ahead: Vec<&Candidate> = on[..at]
        .iter()
        .filter(|c| mechanism.added(c))
        .filter(|c| {
            // 纠错以后整个输入用更少的音节读完（jintiam -> 今天）：和 typed-first 的例外一样
            !(mechanism.name == "typo" && c.consumed >= len && syllables(c) < syllables(top))
        })
        .collect();
    if !ahead.is_empty() {
        report(
            rule("outranks"),
            format!(
                "关掉{}时排第一的「{}」，开着时排到了它加进来的「{}」后面",
                mechanism.label,
                top.text,
                ahead
                    .iter()
                    .map(|c| c.text.as_str())
                    .collect::<Vec<_>>()
                    .join("」「")
            ),
        );
    }
}

fn read_allow(path: &str) -> HashMap<(String, String, String), String> {
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|e| super::fail(&format!("读不了 {path}: {e}")));
    let mut out = HashMap::new();
    for (i, line) in text.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() < 4 || cols[3].trim().is_empty() {
            super::fail(&format!(
                "{path}:{}: 要四列：规则、输入、上文（可以空）、理由",
                i + 1
            ));
        }
        out.insert(
            (
                cols[0].to_string(),
                cols[1].to_string(),
                cols[2].to_string(),
            ),
            cols[3].to_string(),
        );
    }
    out
}

/// 跑全部检查，返回是不是有没列进清单的违反。
pub fn run(
    engine: &mut Engine,
    lexicon: &dyn Lexicon,
    nnlm: Option<Arc<Nnlm>>,
    cases: &[(String, String)],
    opts: &Options,
) -> bool {
    // 逐键：每个用例的每个前缀；上文：没有、用例自带的、--inv-context 的
    let mut prefixes: Vec<String> = Vec::new();
    let mut seen_prefix = HashSet::new();
    let mut with_context: Vec<(String, String)> = Vec::new();
    let mut seen_ctx = HashSet::new();
    for (input, context) in cases {
        let letters: Vec<usize> = input
            .char_indices()
            .map(|(i, ch)| i + ch.len_utf8())
            .collect();
        for &end in &letters {
            let prefix = &input[..end];
            if prefix.ends_with('\'') {
                continue;
            }
            if seen_prefix.insert(prefix.to_string()) {
                prefixes.push(prefix.to_string());
            }
            let mut ctxs: Vec<&str> = opts.contexts.iter().map(String::as_str).collect();
            if !context.is_empty() {
                ctxs.push(context);
            }
            for c in ctxs {
                if seen_ctx.insert((prefix.to_string(), c.to_string())) {
                    with_context.push((prefix.to_string(), c.to_string()));
                }
            }
        }
    }
    eprintln!(
        "不变量：{} 个用例，逐键 {} 个前缀，带上文的 {} 组{}",
        cases.len(),
        prefixes.len(),
        with_context.len(),
        if nnlm.is_some() {
            "，每组再带神经语言模型查一次"
        } else {
            ""
        }
    );

    let mut violations: Vec<Violation> = Vec::new();
    let mut chars: HashMap<String, usize> = HashMap::new();
    let mut shapes: HashMap<String, Option<Shape>> = HashMap::new();
    // 没有上文、不带模型时照着打的读法
    let mut typed: HashMap<String, (String, bool)> = HashMap::new();
    let mut queries = 0usize;

    let mut run_condition =
        |engine: &mut Engine,
         input: &str,
         context: &str,
         with_nnlm: bool,
         violations: &mut Vec<Violation>,
         typed: &mut HashMap<String, (String, bool)>| {
            engine.set_context(context);
            engine.set_nnlm(if with_nnlm { nnlm.clone() } else { None });
            let cands = engine.input(input);
            queries += 1;
            let shape = shapes
                .entry(input.to_string())
                .or_insert_with(|| shape(input, lexicon, &mut chars));
            let Some(shape) = shape.as_ref() else {
                return;
            };
            let mut found: Vec<(&'static str, String)> = Vec::new();
            check_one(input, shape, &cands, lexicon, &mut chars, |rule, detail| {
                found.push((rule, detail))
            });
            // 纠错、模糊音兜底、简拼只能「加」候选：关掉它再查一次，对比
            for mechanism in &MECHANISMS {
                if !cands.iter().take(2 * PAGE).any(|c| mechanism.added(c)) {
                    continue;
                }
                // 简拼只在全拼走不通时才用（zg、wm 本来就没有照着打的全拼读法），只查打全了的输入：
                // 那时它一个候选都不该加
                if mechanism.name == "jianpin" && shape.exact.is_none() {
                    continue;
                }
                mechanism.set(engine, false);
                let off = engine.input(input);
                mechanism.set(engine, true);
                queries += 1;
                only_adds(mechanism, lexicon, input, &cands, &off, |rule, detail| {
                    found.push((rule, detail))
                });
            }
            let base = context.is_empty() && !with_nnlm;
            // typed-kept：照着打的读法是个词时这个词还在；是几个词拼的整句时（晚 | 事儿），换一种拼法
            // （碗 | 事儿）也算，但至少要有一个照着打的整句
            if base {
                if shape.exact.is_some() {
                    if let Some(t) = typed_reading(lexicon, &cands, input.len())
                        .filter(|c| c.features.prefix_completion == 0.0)
                    {
                        typed.insert(input.to_string(), (t.text.clone(), is_word(t)));
                    }
                }
            } else if let Some((t, word)) = typed.get(input) {
                let kept = if *word {
                    cands.iter().any(|c| &c.text == t)
                } else {
                    typed_reading(lexicon, &cands, input.len()).is_some()
                };
                if !kept {
                    found.push((
                        "typed-kept",
                        if *word {
                            format!("没有上文、不带模型时照着打的词「{t}」不见了")
                        } else {
                            format!(
                                "没有上文、不带模型时有照着打的整句（「{t}」），这里一个都没有了"
                            )
                        },
                    ));
                }
            }
            for (rule, detail) in found {
                violations.push(Violation {
                    rule,
                    input: input.to_string(),
                    context: context.to_string(),
                    nnlm: with_nnlm,
                    detail: format!("{detail}；候选 {}", brief(&cands, input.len(), 9)),
                });
            }
        };

    let modes: &[bool] = if nnlm.is_some() {
        &[false, true]
    } else {
        &[false]
    };
    for &m in modes {
        for p in &prefixes {
            run_condition(&mut *engine, p, "", m, &mut violations, &mut typed);
        }
    }
    for &m in modes {
        for (p, c) in &with_context {
            run_condition(&mut *engine, p, c, m, &mut violations, &mut typed);
        }
    }
    engine.set_context("");
    engine.set_nnlm(nnlm.clone());
    eprintln!("共查询 {queries} 次");

    // 同一条规则、同一个输入和上文，带不带模型都违反时只算一条（标「两种都」）
    let mut merged: Vec<Violation> = Vec::new();
    let mut index: HashMap<(String, String, String), usize> = HashMap::new();
    for v in violations {
        match index.get(&v.key()) {
            Some(&i) => {
                if merged[i].nnlm != v.nnlm {
                    merged[i].detail.push_str("（带不带模型都这样）");
                }
            }
            None => {
                index.insert(v.key(), merged.len());
                merged.push(v);
            }
        }
    }

    let allow = opts.allow.as_deref().map(read_allow).unwrap_or_default();
    let mut used_allow = HashSet::new();
    let mut by_rule: Vec<(&'static str, Vec<&Violation>)> = Vec::new();
    let mut new_count = 0usize;
    for v in &merged {
        if allow.contains_key(&v.key()) {
            used_allow.insert(v.key());
            continue;
        }
        new_count += 1;
        match by_rule.iter_mut().find(|(r, _)| *r == v.rule) {
            Some((_, list)) => list.push(v),
            None => by_rule.push((v.rule, vec![v])),
        }
    }

    let rules = [
        "typed-first",
        "typed-first-partial",
        "first-syllable-chars",
        "min-candidates",
        "typed-kept",
        "no-duplicates",
        "completion-outranks-word",
        "typo-only-adds",
        "typo-outranks-typed",
        "typo-flood",
        "fuzzy-only-adds",
        "fuzzy-outranks-word",
        "jianpin-only-adds",
        "jianpin-outranks-typed",
    ];
    println!("== 不变量");
    for rule in rules {
        let list = by_rule
            .iter()
            .find(|(r, _)| *r == rule)
            .map(|(_, l)| l.as_slice())
            .unwrap_or(&[]);
        let allowed = merged
            .iter()
            .filter(|v| v.rule == rule && allow.contains_key(&v.key()))
            .count();
        println!(
            "{rule:<24} 违反 {}{}",
            list.len(),
            if allowed > 0 {
                format!("（另有 {allowed} 条在已知清单里）")
            } else {
                String::new()
            }
        );
        let shown = if opts.limit == 0 {
            list.len()
        } else {
            opts.limit.min(list.len())
        };
        for v in &list[..shown] {
            println!("  {}", line(v));
        }
        if shown < list.len() {
            println!("  ……还有 {} 条（--inv-limit 0 全打）", list.len() - shown);
        }
    }
    let stale: Vec<_> = allow.keys().filter(|k| !used_allow.contains(*k)).collect();
    if !stale.is_empty() {
        println!(
            "已知清单里这些已经不违反了，从 {} 删掉：",
            opts.allow.as_deref().unwrap_or("")
        );
        for (r, i, c) in &stale {
            println!("  {r}\t{i}\t{c}");
        }
    }
    if let Some(path) = &opts.out {
        let mut out = String::from("# 规则\t输入\t上文\t神经语言模型\t说明\n");
        for v in &merged {
            let _ = writeln!(
                out,
                "{}\t{}\t{}\t{}\t{}",
                v.rule,
                v.input,
                v.context,
                if v.nnlm { "带" } else { "不带" },
                v.detail
            );
        }
        if let Err(e) = std::fs::write(path, out) {
            super::fail(&format!("写不了 {path}: {e}"));
        }
    }
    new_count > 0 || !stale.is_empty()
}

fn line(v: &Violation) -> String {
    let mut s = v.input.clone();
    if !v.context.is_empty() {
        let _ = write!(s, "（上文「{}」）", v.context);
    }
    if v.nnlm {
        s.push_str("（带模型）");
    }
    let _ = write!(s, "：{}", v.detail);
    s
}
