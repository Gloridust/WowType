//! 输入会话：一个输入框里的编辑状态和按键规则（见 docs/PORTING.md）。
//!
//! 目标是让 fcitx5 和 macOS 两个外壳只做「平台按键 → 会话 → 按结果画界面、上屏」，
//! 输入行为都在这里。现在是一块一块从 fcitx5 外壳（`fcitx5-addon/src/wowtype_engine.cpp`）
//! 挪过来的，已经挪进来的：
//!
//! - 编辑区里的原始输入、已选词栈（长句先选开头的词）；
//! - 字母和隔音符进编辑区，退格（先撤销最后一次选词，没有选词了才删字母），Esc 清空。
//!
//! 还没挪的键 [`Session::key`] 返回 `handled = false`，外壳接着用自己的旧逻辑处理。
//! 候选、分音节显示、上屏和学习这一轮还在外壳里，外壳用 [`Session::push_selection`]、
//! [`Session::append`] 这些过渡函数改编辑区，挪完以后会删掉。

/// 平台无关的键码：XKB keysym 的子集（fcitx5 直接用，macOS 外壳把 kVK_* 翻成这个）。
pub mod keysym {
    pub const BACKSPACE: u32 = 0xff08;
    pub const TAB: u32 = 0xff09;
    pub const RETURN: u32 = 0xff0d;
    pub const ESCAPE: u32 = 0xff1b;
    pub const LEFT: u32 = 0xff51;
    pub const UP: u32 = 0xff52;
    pub const RIGHT: u32 = 0xff53;
    pub const DOWN: u32 = 0xff54;
    pub const PAGE_UP: u32 = 0xff55;
    pub const PAGE_DOWN: u32 = 0xff56;
    pub const KP_ENTER: u32 = 0xff8d;
    pub const SPACE: u32 = 0x20;
    pub const APOSTROPHE: u32 = 0x27;
}

/// 修饰键位掩码，和 X11/fcitx5 的 KeyState 取值一样（fcitx5 外壳可以直接传）。
pub mod modifier {
    pub const SHIFT: u32 = 1 << 0;
    pub const CAPS: u32 = 1 << 1;
    pub const CTRL: u32 = 1 << 2;
    pub const ALT: u32 = 1 << 3;
    pub const SUPER: u32 = 1 << 6;
}

/// 一次按键。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Key {
    pub keysym: u32,
    pub modifiers: u32,
    /// 松开（按下是 false）。
    pub release: bool,
    /// 光标前一个字符，不知道是 None（以后挪标点、小数点时用）。
    pub prev_char: Option<char>,
}

impl Key {
    /// 按下一个键，不带修饰键。
    pub fn press(keysym: u32) -> Self {
        Self {
            keysym,
            ..Self::default()
        }
    }

    /// 按下一个可见 ASCII 字符（大写字母带上 Shift，和 fcitx5 收到的一样）。
    pub fn char(c: char) -> Self {
        let modifiers = if c.is_ascii_uppercase() {
            modifier::SHIFT
        } else {
            0
        };
        Self {
            keysym: c as u32,
            modifiers,
            ..Self::default()
        }
    }

    fn has_command_modifier(&self) -> bool {
        self.modifiers & (modifier::CTRL | modifier::ALT | modifier::SUPER) != 0
    }
}

/// 已经选好、还没上屏的一个词（长句先选开头的词）。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    pub text: String,
    pub pinyin: String,
    /// 用掉的原始输入字节数。
    pub bytes: usize,
}

/// 一次调用之后外壳要做的事。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Frame {
    /// 会话处理了这个键。false：会话还不管这个键（外壳接着处理，挪完以后就是交给应用）。
    pub handled: bool,
    /// 要上屏的字。
    pub commit: Option<String>,
    /// 编辑区：已选的词 + 还没选的原始输入（分音节显示还在外壳里）。
    pub preedit: String,
    /// 编辑区光标，UTF-8 字节偏移。
    pub preedit_cursor: usize,
}

/// 一个输入框的会话。只能在一个线程里用。
#[derive(Clone, Debug, Default)]
pub struct Session {
    /// 全部原始输入（包括已经选过词的部分）。
    input: String,
    selections: Vec<Selection>,
}

impl Session {
    pub fn new() -> Self {
        Self::default()
    }

    /// 处理一次按键。
    pub fn key(&mut self, key: &Key) -> Frame {
        let handled = self.handle_key(key);
        self.frame(handled)
    }

    fn handle_key(&mut self, key: &Key) -> bool {
        if key.release || key.has_command_modifier() {
            return false;
        }
        let sym = key.keysym;
        if (u32::from(b'a')..=u32::from(b'z')).contains(&sym)
            || (u32::from(b'A')..=u32::from(b'Z')).contains(&sym)
        {
            // 大写字母原样保留：Hello、iPhone 这类英文候选要用到
            self.input.push(char::from(sym as u8));
            return true;
        }
        if !self.composing() {
            return false;
        }
        match sym {
            keysym::APOSTROPHE => {
                // 隔音符（xi'an）；开头的隔音符没有意义（上面已经排除了）
                self.input.push('\'');
                true
            }
            keysym::BACKSPACE => {
                // 选过词先撤销最后一次选词，拼音回到编辑区（后面还没选的拼音不动），
                // 和微信输入法一样；没有选词了才删字母
                if self.selections.pop().is_none() {
                    self.input.pop();
                }
                if self.input.is_empty() {
                    self.clear();
                }
                true
            }
            keysym::ESCAPE => {
                self.clear();
                true
            }
            _ => false,
        }
    }

    /// 清空编辑区。commit_pending：把已选的词和还没选的原始输入上屏（切换输入法时）。
    pub fn reset(&mut self, commit_pending: bool) -> Frame {
        let commit = if commit_pending && self.composing() {
            Some(self.selected_text() + self.remaining())
        } else {
            None
        };
        self.clear();
        Frame {
            handled: true,
            commit,
            ..self.frame(true)
        }
    }

    /// 现在的编辑区（不处理按键）。
    pub fn frame(&self, handled: bool) -> Frame {
        let preedit = self.selected_text() + self.remaining();
        Frame {
            handled,
            commit: None,
            preedit_cursor: preedit.len(),
            preedit,
        }
    }

    fn clear(&mut self) {
        self.input.clear();
        self.selections.clear();
    }

    /// 正在输入（编辑区不空）。
    pub fn composing(&self) -> bool {
        !self.input.is_empty()
    }

    /// 全部原始输入。
    pub fn input(&self) -> &str {
        &self.input
    }

    /// 已选的词用掉的字节数。
    pub fn selected_bytes(&self) -> usize {
        self.selections.iter().map(|s| s.bytes).sum()
    }

    /// 还没选词的那部分输入。
    pub fn remaining(&self) -> &str {
        self.input.get(self.selected_bytes()..).unwrap_or("")
    }

    /// 已选的词连起来。
    pub fn selected_text(&self) -> String {
        self.selections.iter().map(|s| s.text.as_str()).collect()
    }

    pub fn selections(&self) -> &[Selection] {
        &self.selections
    }

    /// 过渡：外壳选了句首词，压进已选栈（候选还在外壳里）。
    pub fn push_selection(&mut self, selection: Selection) {
        self.selections.push(selection);
    }

    /// 过渡：外壳往原始输入后面加字（计算器的算式、双拼的分号、表情面板的搜索词）。
    pub fn append(&mut self, text: &str) {
        self.input.push_str(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(keys: &str) -> Session {
        let mut session = Session::new();
        for c in keys.chars() {
            session.key(&Key::char(c));
        }
        session
    }

    #[test]
    fn letters_and_apostrophe() {
        let session = typed("xi'an");
        assert_eq!(session.input(), "xi'an");
        // 开头的隔音符不进编辑区
        let mut session = Session::new();
        assert!(!session.key(&Key::char('\'')).handled);
        assert!(!session.composing());
    }

    #[test]
    fn command_modifiers_and_release_are_not_ours() {
        let mut session = typed("ni");
        let ctrl_a = Key {
            keysym: u32::from(b'a'),
            modifiers: modifier::CTRL,
            ..Key::default()
        };
        assert!(!session.key(&ctrl_a).handled);
        let release = Key {
            release: true,
            ..Key::press(keysym::BACKSPACE)
        };
        assert!(!session.key(&release).handled);
        assert_eq!(session.input(), "ni");
    }

    #[test]
    fn keys_outside_composition_are_not_ours() {
        let mut session = Session::new();
        assert!(!session.key(&Key::press(keysym::BACKSPACE)).handled);
        assert!(!session.key(&Key::press(keysym::ESCAPE)).handled);
    }

    #[test]
    fn reset_commits_selected_and_raw() {
        let mut session = typed("nihaozhongguo");
        session.push_selection(Selection {
            text: "你好".into(),
            pinyin: "ni hao".into(),
            bytes: 5,
        });
        let frame = session.reset(true);
        assert_eq!(frame.commit.as_deref(), Some("你好zhongguo"));
        assert!(frame.preedit.is_empty());
        assert!(!session.composing());
        assert_eq!(session.reset(true).commit, None);
    }

    #[test]
    fn preedit_cursor_is_byte_offset() {
        let mut session = typed("nihaoma");
        session.push_selection(Selection {
            text: "你好".into(),
            pinyin: "ni hao".into(),
            bytes: 5,
        });
        let frame = session.frame(true);
        assert_eq!(frame.preedit, "你好ma");
        assert_eq!(frame.preedit_cursor, "你好ma".len());
    }
}
