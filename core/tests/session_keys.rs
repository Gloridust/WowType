//! 输入会话的按键测试：从 fcitx5-addon/test/key_harness.cpp 搬过来的用例，
//! 用纯 Rust 驱动 [`wowtype_core::session::Session`]，macOS 的 CI 也跑。
//!
//! 只搬已经挪进会话的行为（编辑区、已选词栈、退格、Esc）。候选还在 fcitx5 外壳里，
//! 这里选句首词用 `push_selection` 代替（外壳选词时就是这么调的）；
//! 编辑区分音节（`你好zhong'guo`）也还在外壳，这里看的是原始输入，分音节由 key_harness 断言。
//! 以后每挪一块，就把 key_harness 里对应的用例搬过来。

use wowtype_core::session::{keysym, Frame, Key, Selection, Session};

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
fn fresh() -> Session {
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
