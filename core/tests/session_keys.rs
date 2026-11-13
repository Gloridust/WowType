//! 输入会话的按键测试：从 fcitx5-addon/test/key_harness.cpp 搬过来的用例，
//! 用纯 Rust 驱动 [`wowtype_core::session::Session`]，macOS 的 CI 也跑。
//!
//! 只搬已经挪进会话的行为：编辑区、已选词栈、退格、Esc，候选列表（引擎候选、计算器、
//! emoji 推荐、数字按键 emoji、日期时间）、编辑区分音节，选词、整句上屏和学习，
//! 空格、回车、数字、分号引号选词、翻页、移动候选和展开面板。
//! 标点（先上屏再出标点）、工具栏、emoji 面板、互译还在 fcitx5 外壳里。
//! 不带引擎的用例没有候选，用 `push_selection` 造已选词。
//! 以后每挪一块，就把 key_harness 里对应的用例搬过来。
//!
//! 前面的用例不带引擎（词库在后台载入好之前就是这样），编辑区是原始输入；
//! 后面的用例用一个小词库建引擎，看候选和分音节。

use std::sync::Arc;

use wowtype_core::datetime::LocalTime;
use wowtype_core::lm::BigramLm;
use wowtype_core::session::{
    keysym, modifier, CandidateKind, Config, Frame, Key, Panel, PunctStyle, Selection, Session,
};
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
                "home" => keysym::HOME,
                "end" => keysym::END,
                "del" => keysym::DELETE,
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
    // 开头的 ' 不是隔音符：没在打字，它是单引号，换成中文引号上屏
    let mut session = fresh();
    assert_eq!(type_keys(&mut session, "'").commit.as_deref(), Some("‘"));
    assert!(!session.composing());
}

#[test]
fn keys_without_candidates() {
    // 不带引擎（词库还没载入）：没有候选。空格、回车上屏原始输入，数字吃掉；
    // 标点上屏原始输入再上屏标点；翻页键、方向键还交给外壳（外壳吃掉）
    let mut session = fresh();
    type_keys(&mut session, "shi");
    assert_eq!(type_keys(&mut session, ",").commit.as_deref(), Some("shi，"));
    let mut session = fresh();
    type_keys(&mut session, "shi");
    for keys in ["<down>", "<pgdn>", "<tab>"] {
        let frame = type_keys(&mut session, keys);
        assert!(!frame.handled, "{keys} 没有候选时归外壳");
        assert_eq!(frame.preedit, "shi");
    }
    let frame = type_keys(&mut session, "1");
    assert!(frame.handled, "数字吃掉");
    assert_eq!(frame.preedit, "shi");
    let frame = type_keys(&mut session, "<sp>");
    assert!(frame.handled);
    assert_eq!(frame.commit.as_deref(), Some("shi"));
    assert!(!session.composing());

    type_keys(&mut session, "shi");
    assert_eq!(
        type_keys(&mut session, "<cr>").commit.as_deref(),
        Some("shi")
    );
    // 编辑区空了，空格、回车、数字交给应用
    for keys in ["<sp>", "<cr>", "1"] {
        assert!(!type_keys(&mut session, keys).handled, "{keys}");
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
fn date_time_follows_trigger_word_even_when_it_is_not_first() {
    // 接着前文打（刚上屏一个日期）时，「事件」可能排在「时间」前面；时间的写法是给「时间」的，
    // 「时间」挪到第一，写法跟在它后面
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str("shi jian\t事件\t900000\nshi jian\t时间\t500000\n").unwrap(),
    );
    let engine: &'static Engine =
        Box::leak(Box::new(Engine::new(lexicon, Arc::new(BigramLm::default()))));
    let mut session = with(engine);
    type_keys(&mut session, "shijian");
    assert_eq!(texts(&mut session)[..3], ["时间", "10:20", "10:20:30"]);
    assert!(texts(&mut session).contains(&"事件".to_string()));
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

    // #122：设置了显示双拼键时编辑区是打的键，候选照旧
    let mut session = with(engine);
    session.configure(Config {
        shuangpin_keys: true,
        ..Config::default()
    });
    let frame = type_keys(&mut session, "vsgo");
    assert_eq!(frame.preedit, "vsgo");
    assert_eq!(texts(&mut session)[0], "中国");

    let mut session = with(engine);
    type_keys(&mut session, "riqi");
    let all = texts(&mut session);
    assert_eq!(all[0], "日期");
    assert_eq!(all[1], "2026年11月11日");

    // 双拼时小写 v 是声母键：v1+2 不算
    let mut session = with(engine);
    type_keys(&mut session, "v");
    session.append("1+2");
    assert_ne!(texts(&mut session).first().map(String::as_str), Some("3"));

    // 双拼用大写 V 进计算器（#160）：按键进编辑区、算式原样显示、= 上屏结果
    let mut session = with(engine);
    let frame = type_keys(&mut session, "V1+2*3");
    assert_eq!(frame.preedit, "V1+2*3", "算式不当双拼键换成全拼");
    assert_eq!(texts(&mut session)[..2], ["7", "1+2*3=7"]);
    let frame = type_keys(&mut session, "=");
    assert_eq!(frame.commit.as_deref(), Some("7"));
    assert!(!session.composing());
    // 大写金额也一样
    let mut session = with(engine);
    type_keys(&mut session, "V12345.67");
    assert_eq!(texts(&mut session)[0], "壹万贰仟叁佰肆拾伍元陆角柒分");
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

    // 只打一个数：大写金额、中文数字、数字本身（#92）
    let mut session = with(engine());
    type_keys(&mut session, "v");
    session.append("12345.67");
    assert_eq!(
        texts(&mut session),
        ["壹万贰仟叁佰肆拾伍元陆角柒分", "一万二千三百四十五点六七", "12345.67"]
    );

    // 全拼时只认小写 v
    let mut session = with(engine());
    type_keys(&mut session, "V");
    session.append("1+2");
    assert_ne!(texts(&mut session).first().map(String::as_str), Some("3"));

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

// ---- 空格、回车、数字、选词键、翻页、展开面板 ----

/// 一个音有很多候选，翻页和展开面板用。
const MANY: &str = "\
shi\t是\t9000
shi\t十\t8900
shi\t事\t8800
shi\t时\t8700
shi\t市\t8600
shi\t使\t8500
shi\t世\t8400
shi\t师\t8300
shi\t式\t8200
shi\t试\t8100
shi\t实\t8000
shi\t室\t7900
shi\t视\t7800
shi\t石\t7700
shi\t湿\t7600
shi\t诗\t7500
shi\t史\t7400
shi\t示\t7300
shi\t士\t7200
shi\t失\t7100
ni hao\t你好\t9000
ni\t你\t8000
hao\t好\t8000
";

fn many_engine() -> &'static Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(MANY).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_max_candidates(300);
    Box::leak(Box::new(engine))
}

/// 一页 5 个、不推荐 emoji（候选顺序固定）的会话，打好 shi。
fn paged(config: Config) -> (Session<'static>, Vec<String>) {
    let mut session = with(many_engine());
    session.configure(Config {
        page_size: 5,
        emoji_suggest: false,
        ..config
    });
    type_keys(&mut session, "shi");
    let all = texts(&mut session);
    assert!(all.len() >= 20, "{all:?}");
    (session, all)
}

fn default_paged() -> (Session<'static>, Vec<String>) {
    paged(Config::default())
}

fn shown_texts(session: &mut Session) -> Vec<String> {
    session.shown().iter().map(|c| c.text.clone()).collect()
}

#[test]
fn space_commits_cursor_candidate() {
    // key_harness：「空格上屏首选」「右键移光标后空格上屏光标处」
    let (mut session, all) = default_paged();
    let frame = session.frame(false);
    assert_eq!((frame.cand_start, frame.cand_count), (0, 5));
    assert_eq!(frame.cand_cursor, Some(0));
    assert!(!frame.has_prev && frame.has_next);
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all[0].as_str())
    );
    assert!(!session.composing());

    let (mut session, all) = default_paged();
    assert_eq!(type_keys(&mut session, "<right>").cand_cursor, Some(1));
    let frame = session.key(&Key::press(keysym::SPACE));
    assert_eq!(frame.commit.as_deref(), Some(all[1].as_str()));
    assert_eq!(
        session.last_choice().map(|c| c.text.as_str()),
        Some(all[1].as_str()),
        "外壳靠 last_choice 知道上屏的是哪个候选"
    );
    // 下一次调用（包括松开键）清掉 last_choice
    session.key(&Key {
        release: true,
        ..Key::press(keysym::SPACE)
    });
    assert!(session.last_choice().is_none());
}

#[test]
fn return_commits_raw_input() {
    let (mut session, _) = default_paged();
    type_keys(&mut session, "<right>");
    assert_eq!(
        type_keys(&mut session, "<cr>").commit.as_deref(),
        Some("shi")
    );
    assert!(session.last_choice().is_none(), "回车不是选候选");
}

#[test]
fn digits_choose_on_the_page() {
    let (mut session, all) = default_paged();
    assert_eq!(
        type_keys(&mut session, "3").commit.as_deref(),
        Some(all[2].as_str())
    );

    // 超出这一页、0：吃掉，什么也不做
    let (mut session, _) = default_paged();
    for keys in ["6", "0"] {
        let frame = type_keys(&mut session, keys);
        assert!(frame.handled, "{keys}");
        assert_eq!(frame.commit, None);
        assert!(session.composing());
    }

    // 小键盘数字一样；带 Shift 的数字不是选词键
    let (mut session, all) = default_paged();
    let frame = session.key(&Key::press(keysym::KP_0 + 2));
    assert_eq!(frame.commit.as_deref(), Some(all[1].as_str()));
    // 带 Shift 的数字（法语键盘打数字要按 Shift）不选词：先上屏光标处的候选，再上屏这个数字
    let (mut session, all) = default_paged();
    let frame = session.key(&Key {
        modifiers: wowtype_core::session::modifier::SHIFT,
        ..Key::char('2')
    });
    assert_eq!(frame.commit, Some(format!("{}2", all[0])));

    // 翻到第二页，数字按第二页选
    let (mut session, all) = default_paged();
    type_keys(&mut session, "<pgdn>");
    assert_eq!(
        type_keys(&mut session, "2").commit.as_deref(),
        Some(all[6].as_str())
    );
}

#[test]
fn paging_keys() {
    // key_harness：「PgDn 翻页」「- = 翻页」「翻到头吃掉翻页键」
    let (mut session, all) = default_paged();
    let frame = type_keys(&mut session, "<pgdn>");
    assert!(frame.handled);
    assert_eq!((frame.cand_start, frame.cand_count), (5, 5));
    assert!(frame.has_prev && frame.has_next);
    assert_eq!(frame.cand_cursor, Some(0), "翻页时光标跟到新的一页开头");
    assert_eq!(shown_texts(&mut session), all[5..10]);
    assert_eq!(type_keys(&mut session, "=").cand_start, 10);
    assert_eq!(type_keys(&mut session, "-").cand_start, 5);
    assert_eq!(
        type_keys(&mut session, "<up>").cand_start,
        0,
        "横排上键翻页"
    );
    // 第一页再按 -：吃掉，不当标点
    let frame = type_keys(&mut session, "-");
    assert!(frame.handled);
    assert_eq!(frame.cand_start, 0);
    // PgUp 翻不动：交给外壳
    assert!(!session.key(&Key::press(keysym::PAGE_UP)).handled);
    // 翻到最后一页
    let last = (all.len() - 1) / 5 * 5;
    for _ in 0..10 {
        type_keys(&mut session, "<pgdn>");
    }
    let frame = session.frame(false);
    assert_eq!(frame.cand_start, last);
    assert!(!frame.has_next);
    assert!(
        type_keys(&mut session, "=").handled,
        "最后一页再按 = 也吃掉"
    );

    // 没打开的翻页键（, . [ ] Tab 默认不翻页）：标点先上屏候选再上屏标点，Tab 交给外壳
    let (mut session, all) = default_paged();
    assert!(!type_keys(&mut session, "<tab>").handled);
    assert_eq!(type_keys(&mut session, ",").commit, Some(format!("{}，", all[0])));

    // 只有一页：- 没页可翻，当符号：先上屏候选再上屏 -
    let mut session = with(many_engine());
    type_keys(&mut session, "nihao");
    assert!(session.frame(false).cand_count < 9 && !session.frame(false).has_next);
    let frame = type_keys(&mut session, "-");
    assert!(frame.commit.is_some_and(|c| c.ends_with('-')));
}

#[test]
fn configured_page_keys() {
    use wowtype_core::session::page_keys;
    let (mut session, _) = paged(Config {
        page_keys: page_keys::BRACKET | page_keys::COMMA | page_keys::TAB,
        ..Config::default()
    });
    assert_eq!(type_keys(&mut session, "]").cand_start, 5);
    assert_eq!(type_keys(&mut session, ".").cand_start, 10);
    assert_eq!(type_keys(&mut session, "<tab>").cand_start, 15);
    let shift_tab = Key {
        modifiers: wowtype_core::session::modifier::SHIFT,
        ..Key::press(keysym::TAB)
    };
    assert_eq!(session.key(&shift_tab).cand_start, 10);
    assert_eq!(session.key(&Key::press(keysym::ISO_LEFT_TAB)).cand_start, 5);
    assert_eq!(type_keys(&mut session, ",").cand_start, 0);
    assert_eq!(type_keys(&mut session, "[").cand_start, 0);
    // - = 没打开：当符号，先上屏候选
    let frame = type_keys(&mut session, "-");
    assert!(frame.handled);
    assert!(frame.commit.is_some_and(|c| c.ends_with('-')));
}

#[test]
fn cursor_moves_across_pages_and_wraps() {
    let (mut session, _) = default_paged();
    for _ in 0..5 {
        type_keys(&mut session, "<right>");
    }
    let frame = session.frame(false);
    assert_eq!(frame.cand_start, 5, "光标移出这一页，跟着翻页");
    assert_eq!(frame.cand_cursor, Some(0));

    // 第一个往左：绕到最后一个
    let (mut session, all2) = default_paged();
    let frame = type_keys(&mut session, "<left>");
    assert_eq!(frame.cand_start, (all2.len() - 1) / 5 * 5);
    assert_eq!(frame.cand_cursor, Some((all2.len() - 1) % 5));
    assert!(!frame.has_next);
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all2[all2.len() - 1].as_str())
    );
}

#[test]
fn actions_from_the_shell() {
    // 外壳把 fcitx5 全局的翻页、移动候选热键（或鼠标点的翻页按钮）翻成动作传进来
    use wowtype_core::session::KeyAction;
    let (mut session, all) = default_paged();
    let frame = session.key(&Key::action(KeyAction::NextPage));
    assert!(frame.handled);
    assert_eq!(frame.cand_start, 5);
    assert_eq!(
        session
            .key(&Key::action(KeyAction::NextCandidate))
            .cand_cursor,
        Some(1)
    );
    assert_eq!(
        session
            .key(&Key::action(KeyAction::PrevCandidate))
            .cand_cursor,
        Some(0)
    );
    assert_eq!(session.key(&Key::action(KeyAction::PrevPage)).cand_start, 0);
    // 第一页再往前：还是吃掉
    assert!(session.key(&Key::action(KeyAction::PrevPage)).handled);
    // 动作带着键码：动作优先（比如 fcitx5 设成 , . 翻页）
    let comma_next = Key {
        action: KeyAction::NextPage,
        ..Key::char('.')
    };
    assert_eq!(session.key(&comma_next).cand_start, 5);
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all[5].as_str())
    );

    // 方向键带了动作：照横排竖排的规则走，不按动作
    let (mut session, _) = default_paged();
    let down = Key {
        action: KeyAction::NextPage,
        ..Key::press(keysym::DOWN)
    };
    assert_eq!(session.key(&down).panel, Panel::Expanded);
}

#[test]
fn vertical_list() {
    // 竖排：上下移光标，左右翻页，下键不展开
    let (mut session, all) = paged(Config {
        horizontal: false,
        ..Config::default()
    });
    let frame = type_keys(&mut session, "<down>");
    assert_eq!(frame.panel, Panel::Normal);
    assert_eq!(frame.cand_cursor, Some(1));
    assert_eq!(type_keys(&mut session, "<right>").cand_start, 5);
    assert_eq!(type_keys(&mut session, "<left>").cand_start, 0);
    let frame = type_keys(&mut session, "<up>");
    assert_eq!(frame.cand_cursor, Some((all.len() - 1) % 5), "绕到最后一个");
    assert_eq!(type_keys(&mut session, "<down>").cand_start, 0);
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all[0].as_str())
    );
}

#[test]
fn expanded_panel() {
    // key_harness：「横排下键展开候选面板」「面板里方向键、数字选当前行、Esc 收起」
    let (mut session, all) = default_paged();
    type_keys(&mut session, "<right>");
    let frame = type_keys(&mut session, "<down>");
    assert_eq!(frame.panel, Panel::Expanded);
    assert_eq!(frame.cand_start, 0);
    assert_eq!(frame.cand_count, all.len().min(36));
    assert_eq!(frame.cand_cursor, Some(1), "光标停在展开前选中的词上");
    assert!(session.view().expanded);

    assert_eq!(type_keys(&mut session, "<down>").cand_cursor, Some(7));
    assert_eq!(type_keys(&mut session, "<left>").cand_cursor, Some(6));
    // 数字选光标所在行
    assert_eq!(
        type_keys(&mut session, "3").commit.as_deref(),
        Some(all[8].as_str())
    );
    assert!(!session.composing());

    // 第一行再往上：收起，回到第一页
    let (mut session, _) = default_paged();
    type_keys(&mut session, "<down>");
    let frame = type_keys(&mut session, "<up>");
    assert_eq!(frame.panel, Panel::Normal);
    assert_eq!(frame.cand_start, 0);
    assert_eq!(frame.cand_cursor, Some(0));

    // Esc 收起，不清空
    let (mut session, all) = default_paged();
    type_keys(&mut session, "<down><right><right>");
    let frame = type_keys(&mut session, "<esc>");
    assert_eq!(frame.panel, Panel::Normal);
    assert!(session.composing());
    assert_eq!(frame.cand_cursor, Some(2));
    // 空格上屏面板光标处
    type_keys(&mut session, "<down>");
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all[2].as_str())
    );

    // 面板里按别的键：先收起，键照普通规则走（Tab 交给外壳吃掉）
    let (mut session, _) = default_paged();
    type_keys(&mut session, "<down><right>");
    let frame = type_keys(&mut session, "<tab>");
    assert!(!frame.handled);
    assert!(!session.view().expanded);
    assert_eq!(session.view().cursor, 1);

    // 退格：收起再删字母
    let (mut session, _) = default_paged();
    type_keys(&mut session, "<down>");
    let frame = type_keys(&mut session, "<bs>");
    assert_eq!(frame.panel, Panel::Normal);
    assert_eq!(frame.preedit, "sh");

    // 只有一个候选不展开（下键交给外壳吃掉）
    let lexicon: Arc<dyn Lexicon> =
        Arc::new(MemoryLexicon::from_tsv_str("heng xiang\t横向\t5000\n").unwrap());
    let engine: &'static Engine = Box::leak(Box::new(Engine::new(
        lexicon,
        Arc::new(BigramLm::default()),
    )));
    let mut session = with(engine);
    session.configure(Config {
        emoji_suggest: false,
        date_time: false,
        ..Config::default()
    });
    type_keys(&mut session, "hengxiang");
    assert_eq!(texts(&mut session), ["横向"]);
    let frame = type_keys(&mut session, "<down>");
    assert!(!frame.handled);
    assert_eq!(frame.panel, Panel::Normal);
}

#[test]
fn expanded_panel_second_screen() {
    // key_harness：「展开后下移 7 行：面板翻到第二屏」「第二屏收起后，横排候选框停在光标那一页」
    let tsv: String = (0..60u32)
        .map(|i| {
            format!(
                "shi\t{}\t{}\n",
                char::from_u32(0x4e00 + i).unwrap(),
                9000 - i
            )
        })
        .collect();
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(&tsv).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_max_candidates(300);
    let engine: &'static Engine = Box::leak(Box::new(engine));
    let mut session = with(engine);
    session.configure(Config {
        page_size: 5,
        emoji_suggest: false,
        date_time: false,
        ..Config::default()
    });
    type_keys(&mut session, "shi");
    let all = texts(&mut session);
    assert!(all.len() > 8 * 6, "要超过 8 行：{}", all.len());

    // 一直按下键走到第二屏：面板显示光标那一屏
    let frame = type_keys(
        &mut session,
        "<down><down><down><down><down><down><down><down>",
    );
    assert_eq!(frame.panel, Panel::Expanded);
    assert_eq!(frame.cand_start, 36);
    assert_eq!(frame.cand_cursor, Some(6));
    assert_eq!(session.view().grid_cursor, 42);

    // 收起：停在光标那一页，光标看得见
    let frame = type_keys(&mut session, "<esc>");
    assert_eq!(frame.panel, Panel::Normal);
    assert_eq!(session.view().page, 42 / 5);
    assert_eq!(frame.cand_start, 40);
    assert_eq!(frame.cand_cursor, Some(2));
    assert!(frame.has_prev);
    assert_eq!(
        type_keys(&mut session, "<sp>").commit.as_deref(),
        Some(all[42].as_str())
    );
}

#[test]
fn select_by_shown_index() {
    // 点候选：序号是在显示的那些（这一页，或展开面板的这一屏）里的
    let (mut session, all) = default_paged();
    type_keys(&mut session, "<pgdn>");
    assert_eq!(session.select(1).commit.as_deref(), Some(all[6].as_str()));

    let (mut session, _) = default_paged();
    assert!(!session.select(5).handled, "超出这一页");
    assert!(session.composing());

    let (mut session, all) = default_paged();
    type_keys(&mut session, "<down>");
    assert_eq!(session.select(13).commit.as_deref(), Some(all[13].as_str()));
}

#[test]
fn semicolon_and_quote_select() {
    // key_harness：「分号选第 2 个、引号选第 3 个」
    use wowtype_core::session::SelectKeys;
    let (mut session, all) = paged(Config {
        select_keys: SelectKeys::SemicolonQuote,
        ..Config::default()
    });
    assert_eq!(
        type_keys(&mut session, ";").commit.as_deref(),
        Some(all[1].as_str())
    );
    let (mut session, all) = paged(Config {
        select_keys: SelectKeys::SemicolonQuote,
        ..Config::default()
    });
    assert_eq!(
        type_keys(&mut session, "'").commit.as_deref(),
        Some(all[2].as_str())
    );

    // 只开分号：引号还是隔音符
    let (mut session, _) = paged(Config {
        select_keys: SelectKeys::Semicolon,
        ..Config::default()
    });
    assert_eq!(type_keys(&mut session, "'").preedit, "shi'");

    // 不开：分号是标点，先上屏候选
    let (mut session, all) = default_paged();
    assert_eq!(type_keys(&mut session, ";").commit, Some(format!("{}；", all[0])));

    // 第 2 个以后是第二页的：按这一页数
    let (mut session, all) = paged(Config {
        select_keys: SelectKeys::Semicolon,
        ..Config::default()
    });
    type_keys(&mut session, "<pgdn>");
    assert_eq!(
        type_keys(&mut session, ";").commit.as_deref(),
        Some(all[6].as_str())
    );
}

#[test]
fn shuangpin_semicolon_is_a_key_on_odd_count() {
    // key_harness：「微软双拼分号是韵母键」：等第二个键时分号进编辑区；
    // 打满一对以后分号不进编辑区（开了选词键时选第 2 个也不行：分号是 ing 键）
    use wowtype_core::session::SelectKeys;
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(MANY).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_shuangpin(true);
    engine.set_shuangpin_scheme(wowtype_core::shuangpin::Scheme::Microsoft);
    let engine: &'static Engine = Box::leak(Box::new(engine));
    let mut session = with(engine);
    session.configure(Config {
        select_keys: SelectKeys::Semicolon,
        ..Config::default()
    });
    type_keys(&mut session, "x");
    let frame = type_keys(&mut session, ";");
    assert!(frame.handled);
    assert_eq!(session.input(), "x;");
    let frame = type_keys(&mut session, ";");
    assert!(frame.handled);
    assert!(
        frame.commit.as_deref().is_some_and(|c| c.ends_with('；')),
        "成对了：分号是标点，先上屏候选：{:?}",
        frame.commit
    );
    assert!(!session.composing());
}

/// 分几次选出来的词，用一次就记住（https://x.com/so1v3/status/2120415675969896729）。
#[test]
fn composed_word_is_learned_after_one_use() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(concat!(
            "shuang\t双\t9000\n",
            "shuang\t霜\t500\n",
            "pin\t拼\t9000\n",
            "pin\t频\t500\n",
            "ge\t个\t9000\n",
            "ge\t阁\t500\n",
            "wo\t我\t9000\n",
            "wo\t窝\t500\n",
            "men\t们\t9000\n",
            "men\t门\t500\n",
            "qu\t去\t9000\n",
            "qu\t区\t500\n",
        ))
        .unwrap(),
    );
    let engine: &'static Engine =
        Box::leak(Box::new(Engine::new(lexicon, Arc::new(BigramLm::default()))));

    let mut session = with(engine);
    type_keys(&mut session, "shuangpinge");
    assert_ne!(texts(&mut session).first().map(String::as_str), Some("霜频阁"));
    choose_text(&mut session, "霜");
    choose_text(&mut session, "频");
    let frame = choose_text(&mut session, "阁");
    assert_eq!(frame.commit.as_deref(), Some("霜频阁"));
    assert!(
        engine.user_words().iter().any(|(_, w, _)| w == "霜频阁"),
        "选一次就进用户词库：{:?}",
        engine.user_words()
    );

    let mut again = with(engine);
    type_keys(&mut again, "shuangpinge");
    assert_eq!(texts(&mut again).first().map(String::as_str), Some("霜频阁"));

    // 超过四个字的是整句，不会一次就进词库
    let mut long = with(engine);
    type_keys(&mut long, "womenquwomen");
    choose_text(&mut long, "窝");
    choose_text(&mut long, "门");
    choose_text(&mut long, "区");
    choose_text(&mut long, "窝");
    let frame = choose_text(&mut long, "门");
    assert_eq!(frame.commit.as_deref(), Some("窝门区窝门"));
    assert!(
        !engine.user_words().iter().any(|(_, w, _)| w == "窝门区窝门"),
        "整句不该一次就进词库：{:?}",
        engine.user_words()
    );
}

fn forget_engine() -> &'static Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(concat!(
            "shuang\t双\t9000\n",
            "shuang\t霜\t500\n",
            "pin\t拼\t9000\n",
            "pin\t频\t500\n",
            "ge\t个\t9000\n",
            "ge\t阁\t500\n",
        ))
        .unwrap(),
    );
    Box::leak(Box::new(Engine::new(
        lexicon,
        Arc::new(BigramLm::default()),
    )))
}

fn ctrl(keysym: u32) -> Key {
    Key {
        keysym,
        modifiers: modifier::CTRL,
        ..Key::default()
    }
}

/// 学错的词 Ctrl+Delete 忘掉（#102）：用户词库、选词热度都去掉，编辑区不动，候选原地重算。
#[test]
fn ctrl_delete_forgets_learned_word() {
    let engine = forget_engine();
    let mut session = with(engine);
    type_keys(&mut session, "shuangpinge");
    choose_text(&mut session, "霜");
    choose_text(&mut session, "频");
    choose_text(&mut session, "阁");
    assert!(engine.user_words().iter().any(|(_, w, _)| w == "霜频阁"));

    let mut again = with(engine);
    let before = type_keys(&mut again, "shuangpinge");
    assert_eq!(
        texts(&mut again).first().map(String::as_str),
        Some("霜频阁")
    );
    let frame = again.key(&ctrl(keysym::DELETE));
    assert!(frame.handled);
    assert!(frame.forgot, "忘掉了要告诉外壳存盘");
    assert_eq!(frame.commit, None);
    assert_eq!(frame.preedit, before.preedit, "编辑区不动");
    assert_eq!(again.input(), "shuangpinge");
    assert!(frame.cand_count > 0);
    assert!(
        !engine.user_words().iter().any(|(_, w, _)| w == "霜频阁"),
        "{:?}",
        engine.user_words()
    );
    assert_eq!(engine.history_count("霜频阁"), 0);
    assert_ne!(
        texts(&mut again).first().map(String::as_str),
        Some("霜频阁")
    );
    // 松开不算
    let release = Key {
        release: true,
        ..ctrl(keysym::DELETE)
    };
    assert!(!again.key(&release).handled);

    // 重新打一遍也不是第一个了，接着照常打字
    let mut retype = with(engine);
    type_keys(&mut retype, "shuangpinge");
    assert_ne!(
        texts(&mut retype).first().map(String::as_str),
        Some("霜频阁")
    );
    let frame = type_keys(&mut retype, "<sp>");
    assert!(frame.commit.is_some());
}

/// 词库里本来就有的词：删不掉，学到的加分去掉，回到原来的位置。光标停在原处。
#[test]
fn ctrl_delete_resets_system_word_and_keeps_cursor() {
    let engine = forget_engine();
    for _ in 0..3 {
        let mut session = with(engine);
        type_keys(&mut session, "shuang");
        choose_text(&mut session, "霜");
    }
    assert!(engine.history_count("霜") >= 3);
    let mut session = with(engine);
    type_keys(&mut session, "shuang");
    assert_eq!(texts(&mut session)[0], "霜", "选多了排到前面");
    // 光标挪到第二个（双），它没学过：什么也不做，但键吃掉
    let frame = type_keys(&mut session, "<right>");
    assert_eq!(frame.cand_cursor, Some(1));
    let frame = session.key(&ctrl(keysym::DELETE));
    assert!(frame.handled);
    assert!(!frame.forgot);
    assert_eq!(frame.cand_cursor, Some(1));
    assert_eq!(texts(&mut session)[0], "霜");
    // Ctrl+退格（Mac 笔记本没有向前删除键）忘掉首选
    type_keys(&mut session, "<left>");
    let frame = session.key(&ctrl(keysym::BACKSPACE));
    assert!(frame.handled && frame.forgot);
    assert_eq!(session.input(), "shuang", "Ctrl+退格不删字母");
    assert_eq!(texts(&mut session)[0], "双", "回到原来的位置");
    assert!(
        texts(&mut session).contains(&"霜".to_string()),
        "词库里的词还在"
    );
    assert_eq!(engine.history_count("霜"), 0);
    assert!(!engine.user_words().iter().any(|(_, w, _)| w == "霜"));
}

/// 自定义词不让 Ctrl+Delete 删；没在打字时这些键交给应用。
#[test]
fn ctrl_delete_keeps_custom_words_and_idle_is_not_ours() {
    let engine = forget_engine();
    engine.lexicon().set_custom_tsv("shuang\t爽\n");
    let mut session = with(engine);
    type_keys(&mut session, "shuang");
    assert_eq!(texts(&mut session)[0], "爽");
    let frame = session.key(&ctrl(keysym::DELETE));
    assert!(frame.handled && !frame.forgot);
    assert_eq!(texts(&mut session)[0], "爽");
    // Shift+Delete 也认，同样不动自定义词
    let shift_delete = Key {
        keysym: keysym::DELETE,
        modifiers: modifier::SHIFT,
        ..Key::default()
    };
    assert!(session.key(&shift_delete).handled);
    assert_eq!(texts(&mut session)[0], "爽");
    // 带 Alt 的不是
    let ctrl_alt = Key {
        keysym: keysym::DELETE,
        modifiers: modifier::CTRL | modifier::ALT,
        ..Key::default()
    };
    assert!(!session.key(&ctrl_alt).handled);

    let mut idle = with(engine);
    assert!(!idle.key(&ctrl(keysym::DELETE)).handled);
    assert!(!idle.key(&ctrl(keysym::BACKSPACE)).handled);
}

#[test]
fn brackets_pick_first_or_last_char() {
    // 以词定字（#83）：[ 取光标处候选的第一个字，] 取最后一个字
    let mut session = with(engine());
    type_keys(&mut session, "nihao");
    assert_eq!(texts(&mut session)[0], "你好");
    let frame = type_keys(&mut session, "[");
    assert!(frame.handled);
    assert_eq!(frame.commit.as_deref(), Some("你"));
    assert!(frame.preedit.is_empty());

    let mut session = with(engine());
    assert_eq!(type_keys(&mut session, "kaixin]").commit.as_deref(), Some("心"));

    // 光标挪到第二个候选：取它的字
    let mut session = with(engine());
    type_keys(&mut session, "kaixin<right>");
    assert_eq!(type_keys(&mut session, "]").commit.as_deref(), Some("欣"));

    // 句首词：取的字进已选栈，剩下的拼音接着选
    let mut session = with(engine());
    type_keys(&mut session, "nihaozhongguo");
    let prefix = session
        .candidates()
        .iter()
        .position(|c| c.text == "你好")
        .expect("有句首词你好");
    for _ in 0..prefix {
        type_keys(&mut session, "<right>");
    }
    let frame = type_keys(&mut session, "]");
    assert_eq!(frame.commit, None);
    assert_eq!(session.selected_text(), "好");
    assert_eq!(type_keys(&mut session, "<sp>").commit.as_deref(), Some("好中国"));

    // 取出来的字不记选词：你好没学过，不会因为按了 [ 变成用户词
    let engine = engine();
    let mut session = with(engine);
    type_keys(&mut session, "nihao[");
    assert!(engine.user_words().is_empty(), "以词定字不学词：{:?}", engine.user_words());
}

#[test]
fn brackets_fall_through_when_nothing_to_pick() {
    // 单字候选：没有字可取，[ 是标点：先上屏候选再上屏【
    let mut session = with(engine());
    type_keys(&mut session, "ba");
    assert_eq!(texts(&mut session)[0], "吧");
    assert_eq!(type_keys(&mut session, "[").commit.as_deref(), Some("吧【"));

    // 关掉以词定字，或者 [ ] 是翻页键：不取字
    let mut session = with(engine());
    session.configure(Config {
        pick_char: false,
        ..Config::default()
    });
    type_keys(&mut session, "nihao");
    assert_eq!(type_keys(&mut session, "[").commit.as_deref(), Some("你好【"));

    let mut session = with(engine());
    session.configure(Config {
        page_keys: wowtype_core::session::page_keys::BRACKET,
        ..Config::default()
    });
    // [ ] 是翻页键时不取字；第一页上按 [ 没页可翻，当标点（和只有一页时按 - 一样）
    type_keys(&mut session, "nihao");
    assert_eq!(type_keys(&mut session, "[").commit.as_deref(), Some("你好【"));
}

fn key_after(c: char, prev: Option<char>, hints: u32) -> Key {
    Key {
        prev_char: prev,
        hints,
        ..Key::char(c)
    }
}

#[test]
fn punctuation_when_not_composing() {
    // 没在打字：有中文标点的换成中文标点上屏；没有的（/ + @）交给应用
    let mut session = with(engine());
    let frame = type_keys(&mut session, ",");
    assert_eq!(frame.commit.as_deref(), Some("，"));
    assert!(!frame.learned, "只上屏标点不算学到了词");
    for keys in ["/", "+", "@"] {
        assert!(!type_keys(&mut session, keys).handled, "{keys}");
    }
    // 半角样式：都交给应用
    let mut session = with(engine());
    session.configure(Config {
        punct_style: PunctStyle::Halfwidth,
        ..Config::default()
    });
    assert!(!type_keys(&mut session, ",").handled);
}

#[test]
fn punctuation_after_digit_stays_ascii() {
    // 应用给了光标前的字：数字后面的 . : , 保持英文（3.14、20:22、3,000）
    let mut session = with(engine());
    assert!(!session.key(&key_after('.', Some('3'), 0)).handled);
    assert_eq!(session.key(&key_after('.', Some('好'), 0)).commit.as_deref(), Some("。"));
    // 读不到周围文字：看会话自己记的上一个字（交给应用的数字也记）
    let mut session = with(engine());
    assert!(!type_keys(&mut session, "3").handled);
    assert!(!type_keys(&mut session, ".").handled, "3 后面的点保持英文");
    assert!(!type_keys(&mut session, "1").handled);
    assert!(!type_keys(&mut session, "4").handled);
    assert_eq!(type_keys(&mut session, "nihao<sp>").commit.as_deref(), Some("你好"));
    assert_eq!(type_keys(&mut session, ".").commit.as_deref(), Some("。"));
    // 数字交给应用以后又按了退格（也交给应用）：光标前是什么不知道了，点是句号
    let mut session = with(engine());
    assert!(!type_keys(&mut session, "3").handled);
    assert!(!type_keys(&mut session, "<bs>").handled);
    assert_eq!(type_keys(&mut session, ".").commit.as_deref(), Some("。"));
}

#[test]
fn quotes_alternate_per_session() {
    let mut a = with(engine());
    let mut b = with(engine());
    assert_eq!(type_keys(&mut a, "\"").commit.as_deref(), Some("“"));
    // 另一个输入框里不受 a 的影响
    assert_eq!(type_keys(&mut b, "\"").commit.as_deref(), Some("“"));
    assert_eq!(type_keys(&mut a, "\"").commit.as_deref(), Some("”"));
    assert_eq!(type_keys(&mut a, "'").commit.as_deref(), Some("‘"));
    assert_eq!(type_keys(&mut a, "'").commit.as_deref(), Some("’"));
}

#[test]
fn punctuation_while_composing_commits_candidate_first() {
    let mut session = with(engine());
    type_keys(&mut session, "nihao");
    let frame = type_keys(&mut session, ",");
    assert_eq!(frame.commit.as_deref(), Some("你好，"));
    assert!(frame.learned, "上屏的有引擎的候选");
    assert!(!session.composing());
    // 没有中文标点的符号原样跟在后面
    type_keys(&mut session, "nihao");
    assert_eq!(type_keys(&mut session, "/").commit.as_deref(), Some("你好/"));
    // 数字后面的标点：候选上屏以后光标前是汉字，照样换成中文标点
    type_keys(&mut session, "nihao");
    assert_eq!(type_keys(&mut session, ".").commit.as_deref(), Some("你好。"));
}

#[test]
fn auto_space_between_han_and_ascii() {
    use wowtype_core::autospace::{DIGITS, LETTERS};
    use wowtype_core::session::key_hints::NO_AUTO_SPACE;
    let config = Config {
        auto_space: LETTERS | DIGITS,
        ..Config::default()
    };
    // 汉字后面打数字：会话自己上屏，补一个空格
    let mut session = with(engine());
    session.configure(config);
    assert_eq!(session.key(&key_after('5', Some('第'), 0)).commit.as_deref(), Some(" 5"));
    // 光标前是字母、读不到光标前的字、密码框：不补，数字交给应用
    assert!(!session.key(&key_after('5', Some('a'), 0)).handled);
    assert!(!session.key(&key_after('5', None, 0)).handled);
    assert!(!session.key(&key_after('5', Some('第'), NO_AUTO_SPACE)).handled);
    // 英文后面上屏汉字：前面补空格
    let mut session = with(engine());
    session.configure(config);
    type_keys(&mut session, "niha");
    session.key(&key_after('o', Some('x'), 0));
    let frame = session.key(&key_after(' ', Some('x'), 0));
    assert_eq!(frame.commit.as_deref(), Some(" 你好"));
    // 关着（默认）不补
    let mut session = with(engine());
    type_keys(&mut session, "niha");
    session.key(&key_after('o', Some('x'), 0));
    assert_eq!(session.key(&key_after(' ', Some('x'), 0)).commit.as_deref(), Some("你好"));
}

fn shift(sym: u32, release: bool, time_ms: u64) -> Key {
    Key {
        keysym: sym,
        release,
        time_ms,
        code: if sym == keysym::SHIFT_L { 50 } else { 62 },
        ..Key::default()
    }
}

#[test]
fn shift_tap_toggles_mode() {
    use wowtype_core::session::Mode;
    let mut session = with(engine());
    assert!(!session.key(&shift(keysym::SHIFT_L, false, 1000)).handled);
    let frame = session.key(&shift(keysym::SHIFT_L, true, 1100));
    assert!(frame.handled && frame.mode_changed);
    assert_eq!(frame.mode, Mode::English);
    // 英文模式：字母交给应用
    assert!(!type_keys(&mut session, "a").handled);
    assert!(!type_keys(&mut session, ",").handled);
    // 再按一下回到中文（没有「译」）
    session.key(&shift(keysym::SHIFT_L, false, 2000));
    assert_eq!(session.key(&shift(keysym::SHIFT_L, true, 2100)).mode, Mode::Chinese);
    assert!(type_keys(&mut session, "a").handled);
}

#[test]
fn shift_tap_rules() {
    use wowtype_core::session::{Mode, ShiftToggle};
    // 按住太久不算
    let mut session = with(engine());
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1600)).mode_changed);
    // 按住时按了别的键（Shift+A 打大写）不算
    let mut session = with(engine());
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    type_keys(&mut session, "A");
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1100)).mode_changed);
    // 外壳自己处理掉的键也报给会话（OBSERVE）：按住 Shift 时按了它就不算
    let mut session = with(engine());
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    let observed = Key {
        keysym: u32::from(b'1'),
        action: wowtype_core::session::KeyAction::Observe,
        ..Key::default()
    };
    assert!(!session.key(&observed).handled, "OBSERVE 不处理");
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1100)).mode_changed);
    // 自动重复不重新计时：按住 0.6 秒，中间来了几次重复
    let mut session = with(engine());
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    session.key(&Key { repeat: true, ..shift(keysym::SHIFT_L, false, 1400) });
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1600)).mode_changed);
    // 松开时按键码认：同一个键松开时翻成了别的符号也算
    let mut session = with(engine());
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    let other = Key { keysym: 0xfe08, code: 50, release: true, time_ms: 1100, ..Key::default() };
    assert!(session.key(&other).mode_changed, "ISO_Next_Group 松开");
    // 只用右 Shift：左边的不算
    let mut session = with(engine());
    session.configure(Config { shift_toggle: ShiftToggle::Right, ..Config::default() });
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1100)).mode_changed);
    session.key(&shift(keysym::SHIFT_R, false, 2000));
    assert!(session.key(&shift(keysym::SHIFT_R, true, 2100)).mode_changed);
    // 带 Ctrl 按下（Ctrl+Shift 切输入法）、开着面板不算
    let mut session = with(engine());
    session.key(&Key { modifiers: modifier::CTRL, ..shift(keysym::SHIFT_L, false, 1000) });
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1100)).mode_changed);
    use wowtype_core::session::key_hints::PANEL_OPEN;
    session.key(&Key { hints: PANEL_OPEN, ..shift(keysym::SHIFT_L, false, 2000) });
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 2100)).mode_changed);
    // 有「译」：中 → 英 → 译 → 中
    let mut session = with(engine());
    session.configure(Config { translate_mode: true, ..Config::default() });
    let mut modes = Vec::new();
    for i in 0..3u64 {
        session.key(&shift(keysym::SHIFT_L, false, 1000 * (i + 1)));
        modes.push(session.key(&shift(keysym::SHIFT_L, true, 1000 * (i + 1) + 50)).mode);
    }
    assert_eq!(modes, [Mode::English, Mode::Translate, Mode::Chinese]);
}

#[test]
fn switching_to_english_commits_composition() {
    use wowtype_core::session::Mode;
    let mut session = with(engine());
    type_keys(&mut session, "nihao");
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    let frame = session.key(&shift(keysym::SHIFT_L, true, 1100));
    assert_eq!(frame.commit.as_deref(), Some("nihao"));
    assert!(!session.composing());
    // set_mode 一样；切回中文不上屏
    let mut session = with(engine());
    type_keys(&mut session, "ni");
    assert_eq!(session.set_mode(Mode::English).commit.as_deref(), Some("ni"));
    let frame = session.set_mode(Mode::Chinese);
    assert!(frame.mode_changed && frame.commit.is_none());
    assert!(!session.set_mode(Mode::Chinese).mode_changed, "已经是中文");
}

#[test]
fn english_mode_auto_space() {
    use wowtype_core::autospace::{DIGITS, LETTERS};
    use wowtype_core::session::Mode;
    let mut session = with(engine());
    session.configure(Config { auto_space: LETTERS | DIGITS, ..Config::default() });
    session.set_mode(Mode::English);
    assert_eq!(session.key(&key_after('L', Some('用'), 0)).commit.as_deref(), Some(" L"));
    assert!(!session.key(&key_after('i', Some('L'), 0)).handled);
}

/// 假翻译器：记下发了哪些请求、取消了几次，结果由测试写。
#[derive(Default)]
struct FakeTranslator {
    started: std::cell::RefCell<Vec<String>>,
    cancels: std::cell::Cell<usize>,
    snap: std::cell::RefCell<wowtype_core::translate::Snapshot>,
}

impl FakeTranslator {
    fn set(&self, state: wowtype_core::translate::JobState, text: &str) {
        let mut snap = self.snap.borrow_mut();
        snap.state = state;
        snap.text = text.to_owned();
    }
}

impl wowtype_core::session::TranslateBackend for FakeTranslator {
    fn start(&self, text: &str) {
        use wowtype_core::translate::JobState;
        let snap = self.snap.borrow().clone();
        if snap.source == text && matches!(snap.state, JobState::Running | JobState::Done) {
            return;
        }
        self.started.borrow_mut().push(text.to_owned());
        *self.snap.borrow_mut() = wowtype_core::translate::Snapshot {
            state: JobState::Running,
            source: text.to_owned(),
            text: String::new(),
            error: String::new(),
        };
    }
    fn cancel(&self) {
        self.cancels.set(self.cancels.get() + 1);
        *self.snap.borrow_mut() = Default::default();
    }
    fn poll(&self) -> wowtype_core::translate::Snapshot {
        self.snap.borrow().clone()
    }
    fn tag(&self, _text: &str) -> String {
        "中→英".to_owned()
    }
}

fn translating(t: &'static FakeTranslator) -> Session<'static> {
    use wowtype_core::session::Mode;
    let mut session = with(engine());
    session.set_translator(Some(t));
    session.set_mode(Mode::Translate);
    session
}

fn at(c: char, time_ms: u64) -> Key {
    Key { time_ms, ..Key::char(c) }
}

#[test]
fn translate_collects_source_and_requests_after_pause() {
    use wowtype_core::translate::JobState;
    let t: &'static FakeTranslator = Box::leak(Box::default());
    let mut session = translating(t);
    for (i, c) in "nihao".chars().enumerate() {
        session.key(&at(c, 1000 + i as u64));
    }
    let frame = session.key(&at(' ', 1010));
    assert_eq!(frame.commit, None, "互译时上屏的字攒成原文");
    let view = frame.translate.clone().expect("互译中");
    assert_eq!(view.source, "你好");
    assert_eq!(view.title, "中→英 互译：");
    assert!(frame.wake_after_ms > 0, "要叫会话发请求");
    // 0.5 秒以内不发，之后发
    session.tick(1300);
    assert!(t.started.borrow().is_empty());
    session.tick(1520);
    assert_eq!(*t.started.borrow(), ["你好"]);
    // 流式译文；译完了回车上屏
    t.set(JobState::Running, "Hel");
    assert_eq!(session.tick(1570).translate.unwrap().text, "Hel");
    t.set(JobState::Done, "Hello");
    let frame = session.key(&Key::press(keysym::RETURN));
    assert_eq!(frame.commit.as_deref(), Some("Hello"));
    assert_eq!(session.translate_source(), "");
}

#[test]
fn clearing_one_session_keeps_another_sessions_request() {
    // 两个输入框共用一个翻译器：A 发了请求，B 后来发的顶掉了它；A 清空时不能把 B 的请求取消掉
    use wowtype_core::translate::JobState;
    let t: &'static FakeTranslator = Box::leak(Box::default());
    let mut a = translating(t);
    let mut b = translating(t);
    for (i, c) in "nihao ".chars().enumerate() {
        a.key(&at(c, 1000 + i as u64));
    }
    a.tick(1600);
    assert_eq!(*t.started.borrow(), ["你好"]);
    for (i, c) in "shijie ".chars().enumerate() {
        b.key(&at(c, 2000 + i as u64));
    }
    b.tick(2600);
    let b_source = b.translate_source().to_owned();
    assert_eq!(*t.started.borrow(), ["你好".to_owned(), b_source.clone()]);
    a.key(&Key::press(keysym::ESCAPE));
    assert_eq!(a.translate_source(), "");
    assert_eq!(t.cancels.get(), 0, "翻译器上跑的是 B 的请求，A 清空不取消");
    assert_eq!(t.snap.borrow().source, b_source);
    assert_eq!(t.snap.borrow().state, JobState::Running);
    // B 自己清空时取消自己的请求
    b.key(&Key::press(keysym::ESCAPE));
    assert_eq!(t.cancels.get(), 1);
}

#[test]
fn translate_enter_before_done_commits_when_ready() {
    use wowtype_core::translate::JobState;
    let t: &'static FakeTranslator = Box::leak(Box::default());
    let mut session = translating(t);
    type_keys(&mut session, "nihao<sp>");
    let frame = session.key(&Key::press(keysym::RETURN));
    assert_eq!(frame.commit, None);
    assert_eq!(frame.translate.unwrap().status, "翻译中…好了就上屏");
    assert_eq!(*t.started.borrow(), ["你好"], "回车立刻发请求");
    t.set(JobState::Done, "Hello");
    assert_eq!(session.tick(5000).commit.as_deref(), Some("Hello"));
}

#[test]
fn translate_keys() {
    let t: &'static FakeTranslator = Box::leak(Box::default());
    // Shift+回车上屏原文
    let mut session = translating(t);
    type_keys(&mut session, "nihao<sp>");
    let shift_enter = Key { modifiers: modifier::SHIFT, ..Key::press(keysym::RETURN) };
    assert_eq!(session.key(&shift_enter).commit.as_deref(), Some("你好"));
    // 退格删原文，Esc 清空，方向键吃掉
    let mut session = translating(t);
    type_keys(&mut session, "nihao<sp>");
    type_keys(&mut session, "<bs>");
    assert_eq!(session.translate_source(), "你");
    assert!(type_keys(&mut session, "<left>").handled);
    type_keys(&mut session, "<esc>");
    assert_eq!(session.translate_source(), "");
    // 数字、点、斜杠进原文（3.14 的点原样）；句末标点立刻发请求
    let mut session = translating(t);
    type_keys(&mut session, "3.14/2");
    assert_eq!(session.translate_source(), "3.14/2");
    let mut session = translating(t);
    type_keys(&mut session, "nihao.");
    assert_eq!(session.translate_source(), "你好。");
    let before = t.started.borrow().len();
    session.tick(0);
    assert_eq!(t.started.borrow().len(), before + 1, "句末立刻发");
}

#[test]
fn leaving_translate_commits_source() {
    use wowtype_core::session::{key_hints::NO_TRANSLATE, Mode};
    let t: &'static FakeTranslator = Box::leak(Box::default());
    let mut session = translating(t);
    type_keys(&mut session, "nihao<sp>");
    type_keys(&mut session, "ma");
    let frame = session.set_mode(Mode::Chinese);
    assert_eq!(frame.commit.as_deref(), Some("你好"), "原文原样上屏");
    assert!(session.composing(), "正在打的拼音留着");
    // 密码框：「译」里也照常上屏
    let mut session = translating(t);
    type_keys(&mut session, "nihao");
    let frame = session.key(&Key { hints: NO_TRANSLATE, ..Key::press(keysym::SPACE) });
    assert_eq!(frame.commit.as_deref(), Some("你好"));
    assert!(frame.translate.is_none());
}

#[test]
fn clearing_one_session_keeps_others_request() {
    let t: &'static FakeTranslator = Box::leak(Box::default());
    let mut a = translating(t);
    let mut b = translating(t);
    type_keys(&mut a, "nihao.");
    a.tick(0);
    assert_eq!(t.cancels.get(), 0);
    b.clear_translation();
    assert_eq!(t.cancels.get(), 0, "b 没发过请求，不取消 a 的");
    a.clear_translation();
    assert_eq!(t.cancels.get(), 1);
}

#[test]
fn v_space_opens_toolbar() {
    use wowtype_core::session::{Panel, Tool};
    let mut session = with(engine());
    let frame = type_keys(&mut session, "v<sp>");
    assert_eq!(frame.panel, Panel::Tool);
    assert_eq!(frame.aux, "工具栏：数字键选择，Esc 关闭");
    assert_eq!(shown_texts(&mut session), ["剪贴板", "常用语", "符号", "表情"]);
    // 菜单第 3 项「符号」：符号面板（网格），不搜索时列全部符号
    let frame = type_keys(&mut session, "3");
    assert_eq!(frame.panel, Panel::Emoji);
    assert_eq!(session.open_panel(), Some(Tool::Emoji { symbols: true }));
    assert!(frame.cand_count > 0);
    // Esc 关上
    let frame = type_keys(&mut session, "<esc>");
    assert_eq!(frame.panel, Panel::Normal);
    assert_eq!(session.open_panel(), None);
    // vim 照常打字；v1+2 照常算
    let mut session = with(engine());
    type_keys(&mut session, "vim<sp>");
    assert_eq!(session.open_panel(), None);
    // 关掉工具栏：v 空格就是 v
    let mut session = with(engine());
    session.configure(Config { toolbar: false, ..Config::default() });
    type_keys(&mut session, "v<sp>");
    assert_eq!(session.open_panel(), None);
}

#[test]
fn toolbar_clipboard_and_back() {
    use wowtype_core::session::Tool;
    wowtype_core::clipboard::clear();
    // 没打开剪贴板历史：提示去设置里打开
    let mut session = with(engine());
    type_keys(&mut session, "v<sp>1");
    assert_eq!(session.open_panel(), Some(Tool::Clipboard));
    assert_eq!(session.frame(false).aux, "剪贴板：没打开，在设置里打开「记录剪贴板历史」");
    // 退格回菜单，菜单里退格关上
    type_keys(&mut session, "<bs>");
    assert_eq!(session.open_panel(), Some(Tool::Menu));
    type_keys(&mut session, "<bs>");
    assert_eq!(session.open_panel(), None);
    // 打开了：选一条上屏（多行的显示成 ⏎）
    wowtype_core::clipboard::remember("第一行\n第二行");
    let mut session = with(engine());
    session.configure(Config { clipboard_history: true, ..Config::default() });
    type_keys(&mut session, "v<sp>1");
    assert_eq!(shown_texts(&mut session), ["第一行⏎第二行"]);
    let frame = type_keys(&mut session, "1");
    assert_eq!(frame.commit.as_deref(), Some("第一行\n第二行"));
    assert!(!frame.learned);
    assert_eq!(session.open_panel(), None);
    wowtype_core::clipboard::clear();
}

#[test]
fn emoji_panel_search_and_pick() {
    use wowtype_core::session::{Panel, Tool};
    // 打了一半的拼音当搜索词；字母接着搜，退格删搜索词，删空了再按就关上
    let mut session = with(engine());
    type_keys(&mut session, "xiao");
    let frame = session.toggle_emoji_panel();
    assert_eq!(frame.panel, Panel::Emoji);
    assert_eq!(frame.preedit, "xiao");
    assert!(!session.composing());
    assert_eq!(session.open_panel(), Some(Tool::Emoji { symbols: false }));
    type_keys(&mut session, "<bs><bs><bs><bs>");
    assert_eq!(session.frame(false).preedit, "");
    type_keys(&mut session, "<bs>");
    assert_eq!(session.open_panel(), None);
    // 英文搜索；右移、数字选光标所在行的第几个
    let mut session = with(engine());
    session.toggle_emoji_panel();
    type_keys(&mut session, "smile");
    let all = shown_texts(&mut session);
    assert!(all.len() > 2, "{all:?}");
    let frame = type_keys(&mut session, "2");
    assert_eq!(frame.commit.as_deref(), Some(all[1].as_str()));
    assert_eq!(session.open_panel(), None);
    // 带 Ctrl 的组合键：收起面板，交给应用
    let mut session = with(engine());
    session.toggle_emoji_panel();
    let ctrl_c = Key { modifiers: modifier::CTRL, ..Key::char('c') };
    assert!(!session.key(&ctrl_c).handled);
    assert_eq!(session.open_panel(), None);
    // 面板开着时单按 Shift 不切中英文
    let mut session = with(engine());
    session.toggle_emoji_panel();
    session.key(&shift(keysym::SHIFT_L, false, 1000));
    assert!(!session.key(&shift(keysym::SHIFT_L, true, 1100)).mode_changed);
}

#[test]
fn arrow_caret_moves_inside_pinyin() {
    // #129：方向键移动拼音里的光标，字母插在光标处，退格删光标前一个
    let caret = Config {
        arrow_caret: true,
        ..Config::default()
    };
    let mut session = with(engine());
    session.configure(caret);
    let frame = type_keys(&mut session, "nihao");
    assert_eq!(frame.preedit_cursor, frame.preedit.len(), "一开始光标在末尾");
    let first = frame.cand_cursor;

    let frame = type_keys(&mut session, "<left><left><left>");
    assert_eq!(&frame.preedit[..frame.preedit_cursor], "ni", "光标在 ni 后面：{}", frame.preedit);
    assert_eq!(frame.cand_cursor, first, "光标不在两头时左键不动候选");
    type_keys(&mut session, "x");
    assert_eq!(session.input(), "nixhao", "字母插在光标处");
    let frame = type_keys(&mut session, "<bs>");
    assert_eq!(session.input(), "nihao", "退格删光标前一个");
    assert_eq!(&frame.preedit[..frame.preedit_cursor], "ni");

    // Home 到最前：退格没东西删；横排时再按左键才移动候选
    type_keys(&mut session, "<home>");
    assert!(session.key(&Key::press(keysym::BACKSPACE)).handled);
    assert_eq!(session.input(), "nihao", "光标在最前面时退格不删");
    let frame = type_keys(&mut session, "<right>");
    assert_eq!(&frame.preedit[..frame.preedit_cursor], "n");
    // Delete 删光标后一个
    type_keys(&mut session, "<del>");
    assert_eq!(session.input(), "nhao");
    type_keys(&mut session, "i");
    assert_eq!(session.input(), "nihao");

    // End 回到末尾；末尾再按右键移动候选
    let frame = type_keys(&mut session, "<end>");
    assert_eq!(frame.preedit_cursor, frame.preedit.len());
    let frame = type_keys(&mut session, "<right>");
    assert_ne!(frame.cand_cursor, first, "光标在最右边时右键移动候选");
    // 清空重打：空格照常上屏首选
    let frame = type_keys(&mut session, "<esc>nihao<sp>");
    assert_eq!(frame.commit.as_deref(), Some("你好"));
}

#[test]
fn arrow_caret_vertical_and_off() {
    // 竖排：左右键只管光标，到头了也吃掉，候选不动
    let mut session = with(engine());
    session.configure(Config {
        arrow_caret: true,
        horizontal: false,
        ..Config::default()
    });
    let frame = type_keys(&mut session, "nihao");
    let first = frame.cand_cursor;
    let frame = type_keys(&mut session, "<right>");
    assert!(frame.handled && frame.cand_cursor == first, "竖排时末尾的右键吃掉");
    let frame = type_keys(&mut session, "<left>");
    assert!(frame.preedit_cursor < frame.preedit.len(), "竖排左键移光标");
    assert_eq!(frame.cand_cursor, first, "竖排左键不动候选");

    // 关着（默认）：左右键照旧移动候选，光标总在末尾
    let mut session = with(engine());
    let frame = type_keys(&mut session, "nihao<right>");
    assert_eq!(frame.preedit_cursor, frame.preedit.len());
    assert_eq!(frame.cand_cursor, Some(1));
}

#[test]
fn arrow_caret_resets_after_choosing_a_word() {
    // 选了句首词：光标回到剩下的拼音末尾
    let mut session = with(engine());
    session.configure(Config {
        arrow_caret: true,
        ..Config::default()
    });
    type_keys(&mut session, "nihaoshijie<left><left>");
    choose_text(&mut session, "你好");
    let frame = session.frame(true);
    assert_eq!(frame.preedit_cursor, frame.preedit.len(), "{}", frame.preedit);
    type_keys(&mut session, "a");
    assert_eq!(session.remaining(), "shijiea");
}

#[test]
fn arrow_caret_shuangpin_shows_keys() {
    // 双拼显示成全拼（zhong'guo）时换不回光标位置：光标在中间时显示打的键
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_shuangpin(true);
    let engine: &'static Engine = Box::leak(Box::new(engine));
    let mut session = with(engine);
    session.configure(Config {
        arrow_caret: true,
        ..Config::default()
    });
    let frame = type_keys(&mut session, "vsgo");
    assert!(frame.preedit.contains("zhong"), "光标在末尾时照常显示全拼：{}", frame.preedit);
    let frame = type_keys(&mut session, "<left>");
    assert_eq!(frame.preedit, "vsgo");
    assert_eq!(frame.preedit_cursor, 3);
    assert_eq!(texts(&mut session)[0], "中国", "候选照旧按整个输入算");
}
