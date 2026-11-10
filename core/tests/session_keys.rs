//! 输入会话的按键测试：从 fcitx5-addon/test/key_harness.cpp 搬过来的用例，
//! 用纯 Rust 驱动 [`wowtype_core::session::Session`]，macOS 的 CI 也跑。
//!
//! 只搬已经挪进会话的行为：编辑区、已选词栈、退格、Esc，候选列表（引擎候选、计算器、
//! emoji 推荐、数字按键 emoji、日期时间）、编辑区分音节，选词、整句上屏和学习。
//! 空格、回车、数字键这些选词键还在 fcitx5 外壳里，这里直接调 `choose` / `commit_input`
//! （外壳按了这些键就是这么调的）；不带引擎的用例没有候选，用 `push_selection` 造已选词。
//! 以后每挪一块，就把 key_harness 里对应的用例搬过来。
//!
//! 前面的用例不带引擎（词库在后台载入好之前就是这样），编辑区是原始输入；
//! 后面的用例用一个小词库建引擎，看候选和分音节。

use std::sync::Arc;

use wowtype_core::datetime::LocalTime;
use wowtype_core::lm::BigramLm;
use wowtype_core::session::{keysym, CandidateKind, Config, Frame, Key, Selection, Session};
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

/// 按一串键，和 key_harness 的 type() 一样：<sp> <bs> <cr> <esc> 等是特殊键，其余按字符。
fn type_keys(session: &mut Session, keys: &str) -> Frame {
    let mut frame = session.frame(false);
    let mut rest = keys;
    while let Some(c) = rest.chars().next() {
        let key = if c == '<' {
            let end = rest.find('>').expect("特殊键没有 >");
            let name = &rest[1..end];
            rest = &rest[end + 1..];
            Key::press(match name {
                "sp" => keysym::SPACE,
                "bs" => keysym::BACKSPACE,
                "cr" => keysym::RETURN,
                "esc" => keysym::ESCAPE,
                "down" => keysym::DOWN,
                "up" => keysym::UP,
                "left" => keysym::LEFT,
                "right" => keysym::RIGHT,
                "pgdn" => keysym::PAGE_DOWN,
                "tab" => keysym::TAB,
                other => panic!("不认识的特殊键 <{other}>"),
            })
        } else {
            rest = &rest[c.len_utf8()..];
            Key::char(c)
        };
        frame = session.key(&key);
        // 外壳每个键都送按下和松开，松开不该改变编辑区
        let release = Key {
            release: true,
            ..key
        };
        let after = session.key(&release);
        assert!(!after.handled, "松开不该被会话处理");
        assert_eq!(after.preedit, frame.preedit, "松开改了编辑区");
    }
    frame
}

/// 每个用例前清空（key_harness 的 fresh）。
fn fresh() -> Session<'static> {
    let mut session = Session::new();
    type_keys(&mut session, "<esc>");
    session
}

/// 选句首词（候选还在外壳：这里直接按外壳会传的参数压栈）。
fn select_prefix(session: &mut Session, text: &str, pinyin: &str, bytes: usize) {
    session.push_selection(Selection {
        text: text.into(),
        pinyin: pinyin.into(),
        bytes,
    });
}

#[test]
fn backspace_undoes_selection_first() {
    // key_harness：「长句先选开头的词」「退格先撤销选词（#49），剩余拼音不动；没有选词了才删字母」
    let mut session = fresh();
    type_keys(&mut session, "nihaozhongguo");
    select_prefix(&mut session, "你好", "ni hao", 5);
    assert_eq!(
        session.frame(true).preedit,
        "你好zhongguo",
        "编辑区 = 已选 + 剩余拼音"
    );
    assert_eq!(session.remaining(), "zhongguo");

    let frame = type_keys(&mut session, "<bs>");
    assert!(frame.handled);
    assert_eq!(frame.preedit, "nihaozhongguo", "退格先撤销选词");
    assert!(session.selections().is_empty());

    let frame = type_keys(&mut session, "<bs>");
    assert_eq!(frame.preedit, "nihaozhonggu", "没有选词了退格删字母");

    // 打回 o，再选一次开头的词：剩下的拼音接着选
    type_keys(&mut session, "o");
    select_prefix(&mut session, "你好", "ni hao", 5);
    assert_eq!(session.selected_text(), "你好");
    assert_eq!(session.remaining(), "zhongguo");
    let frame = session.reset(true);
    assert_eq!(frame.commit.as_deref(), Some("你好zhongguo"));
}

#[test]
fn backspace_pops_selections_in_order() {
    let mut session = fresh();
    type_keys(&mut session, "nihaozhongguoren");
    select_prefix(&mut session, "你好", "ni hao", 5);
    select_prefix(&mut session, "中国", "zhong guo", 8);
    assert_eq!(session.frame(true).preedit, "你好中国ren");
    assert_eq!(type_keys(&mut session, "<bs>").preedit, "你好zhongguoren");
    assert_eq!(type_keys(&mut session, "<bs>").preedit, "nihaozhongguoren");
    assert_eq!(type_keys(&mut session, "<bs>").preedit, "nihaozhongguore");
}

#[test]
fn backspace_to_empty_closes_composition() {
    // key_harness：「退格删光后编辑区关闭」
    let mut session = fresh();
    let frame = type_keys(&mut session, "ni<bs><bs>");
    assert!(frame.handled);
    assert!(frame.preedit.is_empty());
    assert!(!session.composing());
    // 编辑区空了，退格交给应用
    assert!(!type_keys(&mut session, "<bs>").handled);
}

#[test]
fn backspace_after_selecting_everything_but_one_letter() {
    // 选了句首词后把剩下的字母删光：撤销选词，回到原始输入
    let mut session = fresh();
    type_keys(&mut session, "nihaom");
    select_prefix(&mut session, "你好", "ni hao", 5);
    assert_eq!(type_keys(&mut session, "<bs>").preedit, "nihaom");
    assert_eq!(type_keys(&mut session, "<bs>").preedit, "nihao");
}

#[test]
fn escape_clears() {
    let mut session = fresh();
    type_keys(&mut session, "nihaozhongguo");
    select_prefix(&mut session, "你好", "ni hao", 5);
    let frame = type_keys(&mut session, "<esc>");
    assert!(frame.handled);
    assert!(frame.preedit.is_empty());
    assert!(!session.composing());
    assert!(session.selections().is_empty());
    // 空编辑区的 Esc 交给应用
    assert!(!type_keys(&mut session, "<esc>").handled);
}

#[test]
fn uppercase_kept_and_apostrophe() {
    // key_harness：「大写保留 Hello」、隔音符（xi'an）、开头的隔音符没有意义
    let mut session = fresh();
    assert_eq!(type_keys(&mut session, "Hello").preedit, "Hello");
    let mut session = fresh();
    assert_eq!(type_keys(&mut session, "xi'an").preedit, "xi'an");
    let mut session = fresh();
    assert!(!type_keys(&mut session, "'").handled);
    assert!(!session.composing());
}

#[test]
fn keys_not_moved_yet_are_left_to_the_shell() {
    // 还没挪进会话的键：会话不处理，编辑区不动（外壳接着处理）
    let mut session = fresh();
    type_keys(&mut session, "shi");
    for keys in ["<sp>", "<cr>", "1", ",", "<down>", "<pgdn>", "<tab>", "-"] {
        let frame = type_keys(&mut session, keys);
        assert!(!frame.handled, "{keys} 现在还归外壳");
        assert_eq!(frame.preedit, "shi");
    }
}

#[test]
fn switching_input_method_commits_raw() {
    // key_harness：「切换输入法时打了一半的字母上屏」；失去焦点（不上屏）是 reset(false)
    let mut session = fresh();
    type_keys(&mut session, "nihao");
    assert_eq!(session.reset(true).commit.as_deref(), Some("nihao"));
    let mut session = fresh();
    type_keys(&mut session, "nihao");
    let frame = session.reset(false);
    assert_eq!(frame.commit, None);
    assert!(frame.preedit.is_empty());
}

// ---- 带引擎：候选和分音节 ----

const LEXICON: &str = "\
ni hao\t你好\t9000
zhong guo\t中国\t9000
heng xiang\t横向\t5000
kai xin\t开心\t9000
kai xin\t凯欣\t300
kai xin\t开新\t200
ba\t吧\t9000
ba\t八\t8000
ba\t把\t7000
ri qi\t日期\t9000
shi jian\t时间\t9000
xing qi\t星期\t9000
shi\t是\t9000
shi\t十\t8000
";

fn engine() -> &'static Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    Box::leak(Box::new(Engine::new(
        lexicon,
        Arc::new(BigramLm::default()),
    )))
}

/// 2026-11-11 10:20:30，星期三。
fn fixed_time() -> Option<LocalTime> {
    Some(LocalTime {
        year: 2026,
        month: 11,
        day: 11,
        hour: 10,
        minute: 20,
        second: 30,
        weekday: 3,
    })
}

fn with(engine: &'static Engine) -> Session<'static> {
    let mut session = Session::with_engine(engine);
    session.set_clock(fixed_time);
    session
}

/// 选文字是 text 的那个候选（外壳按数字键、点鼠标都是这样）。
fn choose_text(session: &mut Session, text: &str) -> Frame {
    let index = session
        .candidates()
        .iter()
        .position(|c| c.text == text)
        .unwrap_or_else(|| panic!("没有候选 {text}"));
    session.choose(index)
}

fn texts(session: &mut Session) -> Vec<String> {
    session
        .candidates()
        .iter()
        .map(|c| c.text.clone())
        .collect()
}

#[test]
fn preedit_is_segmented() {
    // key_harness：「编辑区给拼音分音节」「编辑区 = 已选 + 剩余拼音（分好音节）」「退格先撤销选词」
    let mut session = with(engine());
    assert_eq!(type_keys(&mut session, "hengxiang").preedit, "heng'xiang");

    let mut session = with(engine());
    assert_eq!(
        type_keys(&mut session, "nihaozhongguo").preedit,
        "ni'hao'zhong'guo"
    );
    assert_eq!(choose_text(&mut session, "你好").preedit, "你好zhong'guo");
    assert_eq!(
        type_keys(&mut session, "<bs>").preedit,
        "ni'hao'zhong'guo",
        "退格撤销选词，分音节跟着回来"
    );
}

#[test]
fn candidates_come_from_the_engine() {
    let mut session = with(engine());
    type_keys(&mut session, "nihao");
    let all = session.candidates();
    assert_eq!(all[0].text, "你好");
    assert_eq!(all[0].pinyin, "ni hao");
    assert_eq!(all[0].consumed, 5);
    assert_eq!(all[0].kind, CandidateKind::Word);
    assert_eq!(all[0].commit, "你好");
}

#[test]
fn no_engine_yet_means_no_candidates() {
    // 词库在后台载入：载入好之前照样打字，编辑区是原始输入；载入好了候选马上出来
    let mut session = Session::new();
    type_keys(&mut session, "hengxiang");
    assert!(session.candidates().is_empty());
    assert_eq!(session.frame(false).preedit, "hengxiang");
    session.set_engine(Some(engine()));
    assert_eq!(texts(&mut session)[0], "横向");
    assert_eq!(session.frame(false).preedit, "heng'xiang");
}

#[test]
fn emoji_suggestion_is_third() {
    // key_harness：「打字时推荐 emoji：插在第三个候选」
    let mut session = with(engine());
    type_keys(&mut session, "kaixin");
    let all = session.candidates().to_vec();
    assert_eq!(all[0].text, "开心");
    assert_eq!(all[2].text, "😊");
    assert_eq!(all[2].kind, CandidateKind::Emoji);
    assert_eq!(all[2].commit, "😊");
    assert_eq!(all[2].emoji, "😊");

    // 关掉 emoji 推荐后没有 😊
    session.configure(Config {
        emoji_suggest: false,
        ..Config::default()
    });
    assert!(!texts(&mut session).contains(&"😊".to_string()));
}

#[test]
fn keycap_follows_number_word() {
    // key_harness：「ba：八 后面是 8️⃣」「拼音没打完的『八』不跟 8️⃣」
    let mut session = with(engine());
    type_keys(&mut session, "ba");
    let all = session.candidates().to_vec();
    let at = all.iter().position(|c| c.text == "8️⃣").expect("没有 8️⃣");
    assert_eq!(all[at - 1].text, "八");
    assert_eq!(all[at].kind, CandidateKind::Emoji);
    assert_eq!(all[at].commit, "8️⃣");
    assert_eq!(
        all.iter()
            .filter(|c| c.kind == CandidateKind::Emoji)
            .count(),
        1,
        "只跟一个"
    );

    // 第一页（page_size）之外的数字字不跟
    session.configure(Config {
        page_size: 1,
        ..Config::default()
    });
    assert!(!texts(&mut session).contains(&"8️⃣".to_string()));
}

#[test]
fn date_time_after_first() {
    // key_harness：「日期时间候选：格式从第二个开始」
    let mut session = with(engine());
    type_keys(&mut session, "riqi");
    let all = session.candidates().to_vec();
    assert_eq!(all[0].text, "日期");
    assert_eq!(all[1].text, "2026年11月11日");
    assert_eq!(all[1].kind, CandidateKind::Plain);
    assert_eq!(all[2].text, "2026-11-11");

    let mut session = with(engine());
    type_keys(&mut session, "shijian");
    assert_eq!(texts(&mut session)[..3], ["时间", "10:20", "10:20:30"]);

    let mut session = with(engine());
    type_keys(&mut session, "xingqi");
    assert_eq!(texts(&mut session)[1], "星期三");

    // 选过词以后不出
    let mut session = with(engine());
    type_keys(&mut session, "nihaoriqi");
    choose_text(&mut session, "你好");
    assert!(!texts(&mut session).iter().any(|t| t.contains('年')));

    // 关掉不出
    let mut session = with(engine());
    session.configure(Config {
        date_time: false,
        ..Config::default()
    });
    type_keys(&mut session, "riqi");
    assert!(!texts(&mut session).iter().any(|t| t.contains('年')));
}

#[test]
fn insertion_order_emoji_keycap_date_time() {
    // 外壳的顺序：emoji 推荐插第 3 个，然后在第一页里找数字字跟按键 emoji，
    // 最后日期时间插在首选后面（把前面插的往后挤）
    let mut session = with(engine());
    type_keys(&mut session, "riqi");
    let all = session.candidates().to_vec();
    let formats = all
        .iter()
        .skip(1)
        .take_while(|c| c.kind == CandidateKind::Plain)
        .count();
    assert!(formats >= 5, "日期格式紧跟首选：{:?}", texts(&mut session));
    assert!(
        all[1 + formats..]
            .iter()
            .all(|c| c.kind != CandidateKind::Plain),
        "日期格式是连着的"
    );
}

#[test]
fn shuangpin_display_and_date_key() {
    // key_harness：「双拼编辑区显示全拼」；双拼时日期时间看首选的拼音
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_shuangpin(true);
    let engine: &'static Engine = Box::leak(Box::new(engine));
    let mut session = with(engine);
    let frame = type_keys(&mut session, "vsgo");
    assert!(frame.preedit.contains("zhong"), "{}", frame.preedit);
    assert_eq!(texts(&mut session)[0], "中国");

    let mut session = with(engine);
    type_keys(&mut session, "riqi");
    let all = texts(&mut session);
    assert_eq!(all[0], "日期");
    assert_eq!(all[1], "2026年11月11日");

    // 双拼不开计算器（v 是韵母键）
    let mut session = with(engine);
    type_keys(&mut session, "v");
    session.append("1+2");
    assert_ne!(texts(&mut session).first().map(String::as_str), Some("3"));
}

#[test]
fn calculator() {
    // key_harness：「V 模式计算器」（v 后面的数字和运算符是外壳 append 进来的）
    let mut session = with(engine());
    type_keys(&mut session, "v");
    session.append("1+2*3");
    let all = session.candidates().to_vec();
    assert_eq!(all[0].text, "7");
    assert_eq!(all[0].kind, CandidateKind::Plain);
    assert_eq!(all[1].text, "1+2*3=7");
    assert_eq!(session.frame(false).preedit, "v1+2*3", "算式不分音节");

    let mut session = with(engine());
    type_keys(&mut session, "v");
    session.append("(1.5-0.5)/4");
    assert_eq!(texts(&mut session)[0], "0.25");

    // 关掉计算器：v1+2 不算
    let mut session = with(engine());
    session.configure(Config {
        calculator: false,
        ..Config::default()
    });
    type_keys(&mut session, "v");
    session.append("1+2");
    assert_ne!(texts(&mut session).first().map(String::as_str), Some("3"));
}

#[test]
fn cache_follows_edits() {
    // 改了编辑区、上文、设置，候选跟着变；没改就不重算
    let mut session = with(engine());
    type_keys(&mut session, "ba");
    let first = texts(&mut session);
    assert_eq!(texts(&mut session), first);
    type_keys(&mut session, "<bs>");
    type_keys(&mut session, "<esc>shi");
    assert_eq!(texts(&mut session)[0], "是");
    session.set_context("我");
    assert_eq!(texts(&mut session)[0], "是");
    type_keys(&mut session, "<esc>");
    assert!(session.candidates().is_empty());
}

// ---- 选词、整句上屏、学习 ----

#[test]
fn choose_sentence_start_then_the_rest() {
    // key_harness：「句首词选完接着选剩下的」「整句上屏」
    let mut session = with(engine());
    type_keys(&mut session, "nihaozhongguo");
    let frame = choose_text(&mut session, "你好");
    assert!(frame.handled);
    assert_eq!(frame.commit, None, "句首词先进已选栈");
    assert_eq!(session.remaining(), "zhongguo");
    assert_eq!(texts(&mut session)[0], "中国");
    let frame = session.choose(0);
    assert!(frame.handled);
    assert_eq!(frame.commit.as_deref(), Some("你好中国"));
    assert!(frame.preedit.is_empty());
    assert!(!session.composing());
}

#[test]
fn bad_index_is_not_handled() {
    let mut session = with(engine());
    type_keys(&mut session, "nihao");
    let total = session.candidates().len();
    let frame = session.choose(total);
    assert!(!frame.handled);
    assert_eq!(frame.commit, None);
    assert_eq!(frame.preedit, "ni'hao", "选错序号什么也不改");

    // 没有引擎就没有候选
    let mut session = fresh();
    type_keys(&mut session, "nihao");
    assert!(!session.choose(0).handled);
}

#[test]
fn whole_sentence_is_learned() {
    // 分几次选出来的整句也记一次选词；选够 3 次（auto_learn_threshold）就收进用户词库
    let engine = engine();
    for round in 0..3 {
        let mut session = with(engine);
        type_keys(&mut session, "nihaozhongguo");
        choose_text(&mut session, "你好");
        assert_eq!(
            choose_text(&mut session, "中国").commit.as_deref(),
            Some("你好中国"),
            "第 {round} 次"
        );
    }
    let learned = engine.user_words();
    assert!(
        learned
            .iter()
            .any(|(pinyin, word, _)| word == "你好中国" && pinyin == "ni hao zhong guo"),
        "整句带拼音收进用户词库：{learned:?}"
    );
}

#[test]
fn single_word_is_learned_with_pinyin() {
    let engine = engine();
    for _ in 0..3 {
        let mut session = with(engine);
        type_keys(&mut session, "kaixin");
        assert_eq!(
            choose_text(&mut session, "开新").commit.as_deref(),
            Some("开新")
        );
    }
    assert!(engine
        .user_words()
        .iter()
        .any(|(pinyin, word, _)| word == "开新" && pinyin == "kai xin"));
}

#[test]
fn emoji_and_plain_commit_without_learning() {
    // emoji 推荐、日期时间：带上已选的词一起上屏，不进用户词库
    let engine = engine();
    for _ in 0..3 {
        let mut session = with(engine);
        type_keys(&mut session, "nihaokaixin");
        choose_text(&mut session, "你好");
        assert_eq!(
            choose_text(&mut session, "😊").commit.as_deref(),
            Some("你好😊")
        );

        let mut session = with(engine);
        type_keys(&mut session, "riqi");
        assert_eq!(
            choose_text(&mut session, "2026-11-11").commit.as_deref(),
            Some("2026-11-11")
        );
        assert!(!session.composing());
    }
    assert!(engine
        .user_words()
        .iter()
        .all(|(_, word, _)| !word.contains('😊') && !word.contains("2026")));
}

#[test]
fn keycap_and_calculator_commit() {
    let mut session = with(engine());
    type_keys(&mut session, "ba");
    assert_eq!(
        choose_text(&mut session, "8️⃣").commit.as_deref(),
        Some("8️⃣")
    );

    let mut session = with(engine());
    type_keys(&mut session, "v");
    session.append("1+2*3");
    assert_eq!(session.choose(1).commit.as_deref(), Some("1+2*3=7"));
    assert!(!session.composing());
}

#[test]
fn commit_input_commits_selected_and_raw() {
    // key_harness：「回车：已选的词 + 原始字母上屏」
    let mut session = with(engine());
    type_keys(&mut session, "nihaokaixin");
    choose_text(&mut session, "你好");
    let frame = session.commit_input();
    assert!(frame.handled);
    assert_eq!(frame.commit.as_deref(), Some("你好kaixin"));
    assert!(!session.composing());

    // 什么也没打：没有上屏
    let mut session = with(engine());
    assert_eq!(session.commit_input().commit, None);

    // 不带引擎也能上屏原始输入
    let mut session = fresh();
    type_keys(&mut session, "abc");
    assert_eq!(session.commit_input().commit.as_deref(), Some("abc"));
}
