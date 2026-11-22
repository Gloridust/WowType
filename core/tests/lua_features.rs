//! 雾凇 Lua 功能移植的端到端测试：走真实的 Session（不是 engine.input），
//! 因为化学式候选、错音注释、Unicode、农历都接在会话层。
//!
//! 词库用小表即可——这些功能的表是编译期静态的，不依赖词库内容，
//! 这也验证了它们「雾凇/万象词库都生效」的设计。

use std::sync::Arc;

use wowtype_core::datetime::LocalTime;
use wowtype_core::lm::BigramLm;
use wowtype_core::session::{CandidateKind, Key, Session};
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

const LEXICON: &str = "\
liu suan\t硫酸\t900000\n\
na\t那\t900000\n\
na\t钠\t500\n\
gei yu\t给与\t900000\n\
gei yu\t给予\t100\n\
zhu jiao\t主角\t900000\n\
ri qi\t日期\t900000\n\
";

fn engine() -> &'static Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    Box::leak(Box::new(Engine::new(
        lexicon,
        Arc::new(BigramLm::default()),
    )))
}

fn session() -> Session<'static> {
    let mut s = Session::new();
    s.set_engine(Some(engine()));
    s.set_clock(|| {
        Some(LocalTime {
            year: 2026,
            month: 11,
            day: 21,
            hour: 12,
            minute: 0,
            second: 0,
            weekday: 6,
        })
    });
    s
}

fn type_keys(s: &mut Session, keys: &str) {
    for c in keys.chars() {
        s.key(&Key::char(c));
    }
}

fn texts(s: &mut Session) -> Vec<String> {
    s.candidates().iter().map(|c| c.text.clone()).collect()
}

#[test]
fn chemical_formula_is_a_direct_candidate() {
    let mut s = session();
    type_keys(&mut s, "liusuan");
    let t = texts(&mut s);
    assert!(t.iter().any(|x| x == "H₂SO₄"), "打 liusuan 要出 H₂SO₄ 候选: {t:?}");
    // 化学式是 Plain 候选，数字键直接上屏、不学习
    let c = s.candidates().iter().find(|c| c.text == "H₂SO₄").unwrap();
    assert_eq!(c.kind, CandidateKind::Plain);
    assert_eq!(c.commit, "H₂SO₄");
}

#[test]
fn element_symbol_and_ion() {
    let mut s = session();
    type_keys(&mut s, "na");
    assert!(texts(&mut s).iter().any(|x| x == "Na"), "打 na 要出元素符号 Na");

    let mut s = session();
    type_keys(&mut s, "tielizi");
    assert!(texts(&mut s).iter().any(|x| x == "Fe³⁺"), "打 tielizi 要出 Fe³⁺");
}

#[test]
fn chemical_formula_comment_on_chinese_word() {
    let mut s = session();
    type_keys(&mut s, "liusuan");
    let c = s.candidates().iter().find(|c| c.text == "硫酸").unwrap();
    assert_eq!(c.comment, "H₂SO₄", "「硫酸」候选后要注释化学式");
}

#[test]
fn corrector_comment() {
    let mut s = session();
    type_keys(&mut s, "geiyu");
    // 词库里「给与」词频高是首选，错音表按 (拼音,词) 命中「给予」，给它加注释
    let c = s.candidates().iter().find(|c| c.text == "给予");
    assert!(c.is_some(), "词库里要有「给予」候选");
    assert_eq!(c.unwrap().comment, "jǐ yǔ", "「给予」候选要注释正确读音");
}

#[test]
fn unicode_input() {
    let mut s = session();
    type_keys(&mut s, "U62fc");
    let t = texts(&mut s);
    assert_eq!(t.first().map(String::as_str), Some("拼"), "U62fc 要出「拼」");
}

#[test]
fn lunar_nl_and_date() {
    let mut s = session();
    type_keys(&mut s, "nl");
    let t = texts(&mut s);
    assert!(t.iter().any(|x| x.contains('年') && x.contains('月')), "nl 要出农历: {t:?}");

    let mut s = session();
    type_keys(&mut s, "N20261121");
    let t = texts(&mut s);
    assert!(t.first().map(|x| x.contains('年')).unwrap_or(false), "N20261121 要出农历: {t:?}");
}

#[test]
fn keysym_shift_for_uppercase() {
    // 大写 U/N 要能用 Shift 打出来（外壳把 shift+字母交给会话）
    let mut s = session();
    s.key(&Key {
        keysym: u32::from(b'U'),
        modifiers: wowtype_core::session::modifier::SHIFT,
        ..Key::default()
    });
    for c in "62fc".chars() {
        s.key(&Key::char(c));
    }
    assert_eq!(texts(&mut s).first().map(String::as_str), Some("拼"));
}

/// 带英文词表的会话，用来测 jetb -> JetBrains（英文词表运行时从字符串载入）。
fn english_session() -> Session<'static> {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    let eng = Box::leak(Box::new(Engine::new(
        lexicon,
        Arc::new(BigramLm::default()),
    )));
    eng.load_english_str(concat!(
        "JetBrains\tJetBrains\njet\tjet\njets\tjets\n",
        "python\tpython\npythonic\tpythonic\nPyTorch\tPyTorch\npyjamas\tpyjamas\n",
        "January\tJanuary\nJanuary\tJanuary\nJane\tJane\nJanet\tJanet\njanitor\tjanitor\n",
    ));
    let mut s = Session::new();
    s.set_engine(Some(eng));
    s
}

#[test]
fn radical_reverse_lookup_via_session() {
    // 拆字反查（雾凇 search.lua）：uU + 部件拼音 → 汉字，走真实 Session。
    // 真机上 Shift+u 常被外壳报成小写，编辑区实际是 uu，所以两种大小写都要能查。
    let mut s = session();
    type_keys(&mut s, "uukoushu"); // 口 + 竖 = 中（小写引导，真机场景）
    assert!(
        texts(&mut s).iter().any(|x| x == "中"),
        "uukoushu 应反查出「中」: {:?}",
        texts(&mut s)
    );

    let mut s = session();
    type_keys(&mut s, "uUkoushu"); // 大写引导（兼容）
    assert!(
        texts(&mut s).iter().any(|x| x == "中"),
        "uUkoushu 应反查出「中」: {:?}",
        texts(&mut s)
    );

    let mut s = session();
    type_keys(&mut s, "uUlonglonglonglong"); // 四个龙 = 𪚥
    assert!(
        texts(&mut s).iter().any(|x| x == "𪚥"),
        "uUlonglonglonglong 应反查出「𪚥」: {:?}",
        texts(&mut s)
    );
}

#[test]
fn radical_reverse_lookup_lowercase_uu_with_separator() {
    // 真机截图场景：用户想打 uU'shi，但 Shift+u 被外壳报成小写，编辑区是 uu'shi。
    // 必须走拆字反查（出以 shi 开头的拆字），不能退化成普通 shi 拼音候选（于是/护士…）。
    let mut s = session();
    type_keys(&mut s, "uu'shi");
    let t = texts(&mut s);
    assert!(
        !t.is_empty() && !t.iter().any(|x| x == "于是"),
        "uu'shi 应出拆字候选、不能是普通 shi 拼音候选: {:?}",
        t
    );
}

#[test]
fn radical_reverse_lookup_ignores_separator() {
    // 用户按 uU'shi 这种带隔音符的打法也要能查（rime algebra xform/'//）。
    let mut s = session();
    type_keys(&mut s, "uU'koushu");
    assert!(
        texts(&mut s).iter().any(|x| x == "中"),
        "uU'koushu 应反查出「中」: {:?}",
        texts(&mut s)
    );
}

#[test]
fn english_abbrev_completion_via_session() {
    // 智能中英混输（雾凇 melt_eng）：jetb 唯一命中 jetbrains → JetBrains。
    let mut s = english_session();
    type_keys(&mut s, "jetb");
    assert_eq!(
        texts(&mut s).first().map(String::as_str),
        Some("JetBrains"),
        "jetb 应补全出 JetBrains: {:?}",
        texts(&mut s)
    );
}

#[test]
fn english_multi_prefix_via_session() {
    // 真机场景：py / jan 同时是合法拼音，前缀命中多个英文词时也要能列出（打出来）。
    let mut s = english_session();
    type_keys(&mut s, "py");
    let t = texts(&mut s);
    assert!(
        t.iter().any(|x| x == "python"),
        "py 应能打出 python: {:?}",
        t
    );
    assert!(t.iter().any(|x| x == "PyTorch"), "py 应列出 PyTorch: {:?}", t);

    let mut s = english_session();
    type_keys(&mut s, "jan");
    let t = texts(&mut s);
    assert!(
        t.iter().any(|x| x == "January"),
        "jan 应能打出 January: {:?}",
        t
    );
}

#[test]
fn math_symbol_is_a_direct_candidate() {
    // 万象数学符号（others.txt）：打拼音直接出符号候选，走真实 Session。
    for (pinyin, symbol) in [
        ("genhao", "√"),
        ("pi", "π"),
        ("yuedengyu", "≈"),
        ("budengyu", "≠"),
        ("wuqiongda", "∞"),
        ("alpha", "α"),
        ("xiaoyudengyu", "≤"),
        // 通用拼音直打符号清单（用户反馈补全）
        ("dengyu", "="),
        ("jiajian", "±"),
        ("chenghao", "×"),
        ("chuhao", "÷"),
        ("wuqiong", "∞"),
        ("jiaodu", "∠"),
        ("chuizhi", "⊥"),
        ("pingxing", "∥"),
        ("sanjiaoxing", "△"),
        ("jifen", "∫"),
        ("qiuhe", "∑"),
        ("piandao", "∂"),
        ("shuyu", "∈"),
        ("bushuyu", "∉"),
        ("kongji", "∅"),
        ("jiaoji", "∩"),
        ("bingji", "∪"),
        ("yinwei", "∵"),
        ("suoyi", "∴"),
        ("aerfa", "α"),
        ("beita", "β"),
        ("gama", "γ"),
        ("deerta", "Δ"),
        ("xigema", "Σ"),
        ("oumeiga", "Ω"),
        ("pai", "π"),
        ("xita", "θ"),
        ("namuda", "λ"),
    ] {
        let mut s = session();
        type_keys(&mut s, pinyin);
        let t = texts(&mut s);
        assert!(t.iter().any(|x| x == symbol), "{pinyin} 应出 {symbol}: {t:?}");
    }
}

#[test]
fn math_symbol_via_pinyin_with_separator() {
    // 带隔音符的全拼也能命中（normalize 去掉 '）。空格键在输入法里是选词，不进编辑区，
    // 真机隔音用单引号 '。
    let mut s = session();
    type_keys(&mut s, "gen'hao");
    let t = texts(&mut s);
    assert!(t.iter().any(|x| x == "√"), "gen'hao 应出 √: {t:?}");
}
