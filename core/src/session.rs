//! 输入会话：一个输入框里的编辑状态和按键规则（见 docs/PORTING.md）。
//!
//! 目标是让 fcitx5 和 macOS 两个外壳只做「平台按键 → 会话 → 按结果画界面、上屏」，
//! 输入行为都在这里。现在是一块一块从 fcitx5 外壳（`fcitx5-addon/src/wowtype_engine.cpp`）
//! 挪过来的，已经挪进来的：
//!
//! - 编辑区里的原始输入、已选词栈（长句先选开头的词）；
//! - 字母和隔音符进编辑区，退格（先撤销最后一次选词，没有选词了才删字母），Esc 清空；
//! - 候选列表（引擎的候选 + 计算器、emoji 推荐、数字按键 emoji、日期时间），
//!   编辑区的分音节显示（`nihao` 显示成 `ni hao`，双拼显示成全拼）。
//!
//! 还没挪的键 [`Session::key`] 返回 `handled = false`，外壳接着用自己的旧逻辑处理。
//! 选词、上屏和学习这一轮还在外壳里，外壳用 [`Session::push_selection`]、
//! [`Session::append`] 这些过渡函数改编辑区，挪完以后会删掉。

use crate::datetime::LocalTime;
use crate::Engine;

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
    /// 编辑区：已选的词 + 还没选的输入（分好音节，双拼显示成全拼）。
    pub preedit: String,
    /// 编辑区光标，UTF-8 字节偏移。
    pub preedit_cursor: usize,
}

/// 会话的设置（外壳从自己的配置里抄过来）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Config {
    /// 一页几个候选（数字按键 emoji 只在第一页里找数字字）。
    pub page_size: usize,
    /// V 模式计算器（v 后面打算式）。双拼时不开（v 是韵母键）。
    pub calculator: bool,
    /// 打 riqi、shijian 这类时给日期时间候选。
    pub date_time: bool,
    /// 打字时推荐 emoji（开心 → 😊，八 → 8️⃣）。
    pub emoji_suggest: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            page_size: 9,
            calculator: true,
            date_time: true,
            emoji_suggest: true,
        }
    }
}

/// 候选的种类：选中以后怎么上屏、学不学。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CandidateKind {
    /// 引擎的候选：选中要学习。
    #[default]
    Word,
    /// 计算结果、日期时间、带换行的自定义词：原样上屏，不学习。
    Plain,
    /// emoji：上屏 [`Candidate::commit`]，记进最近用过的 emoji，不学习。
    Emoji,
}

/// 会话给出的一个候选。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Candidate {
    /// 候选框里显示的字。
    pub text: String,
    /// 拼音（空格分音节）；计算结果、emoji 这类为空。
    pub pinyin: String,
    /// 用掉了还没选词那部分输入的多少字节；比它短是句首词（选了以后剩下的接着选）。
    pub consumed: usize,
    pub kind: CandidateKind,
    /// 选中时上屏的字：emoji 推荐在句尾对上时是「整句 + emoji」，其余和 text 一样。
    pub commit: String,
    /// emoji 本身（推荐候选显示的是「开心😊」，这里是「😊」）；不是 emoji 为空。
    pub emoji: String,
}

impl Candidate {
    fn plain(text: String, consumed: usize) -> Self {
        Self {
            commit: text.clone(),
            text,
            consumed,
            kind: CandidateKind::Plain,
            ..Self::default()
        }
    }
}

/// 读本地时间的函数（测试里换成固定时间）。
pub type Clock = fn() -> Option<LocalTime>;

/// 选了开头的词以后，拿已上屏的字 + 已选的词当上文，最多这么多字节。
const CONTEXT_BYTES: usize = 24;
/// emoji 推荐插在第几个（首选和次选后面）。
const EMOJI_SLOT: usize = 2;

/// 一个输入框的会话。只能在一个线程里用。
///
/// 引擎是后台载入的，载入好之前 `engine` 是 None（照样能打字，只是没有候选）。
#[derive(Clone)]
pub struct Session<'e> {
    /// 全部原始输入（包括已经选过词的部分）。
    input: String,
    selections: Vec<Selection>,
    engine: Option<&'e Engine>,
    config: Config,
    /// 光标前已经上屏的字（外壳记的）。
    context: String,
    clock: Clock,
    /// 候选缓存：输入、已选词、引擎、上文、设置变了就作废，用的时候再算。
    candidates: Vec<Candidate>,
    fresh: bool,
    /// 每重算一次候选加一（C 接口按它判断要不要重建字符串）。
    generation: u64,
}

impl Default for Session<'_> {
    fn default() -> Self {
        Self {
            input: String::new(),
            selections: Vec::new(),
            engine: None,
            config: Config::default(),
            context: String::new(),
            clock: system_time,
            candidates: Vec::new(),
            fresh: false,
            generation: 0,
        }
    }
}

impl std::fmt::Debug for Session<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Session")
            .field("input", &self.input)
            .field("selections", &self.selections)
            .field("has_engine", &self.engine.is_some())
            .field("config", &self.config)
            .finish_non_exhaustive()
    }
}

impl<'e> Session<'e> {
    pub fn new() -> Self {
        Self::default()
    }

    /// 带引擎建会话。
    pub fn with_engine(engine: &'e Engine) -> Self {
        Self {
            engine: Some(engine),
            ..Self::default()
        }
    }

    /// 换引擎（外壳的词库在后台载入好了）。
    pub fn set_engine(&mut self, engine: Option<&'e Engine>) {
        let same = match (self.engine, engine) {
            (Some(a), Some(b)) => std::ptr::eq(a, b),
            (None, None) => true,
            _ => false,
        };
        if !same {
            self.engine = engine;
            self.fresh = false;
        }
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn configure(&mut self, config: Config) {
        if self.config != config {
            self.config = config;
            self.fresh = false;
        }
    }

    /// 光标前已经上屏的字（选了开头的词以后，剩下的部分拿它和已选的词当上文排序）。
    pub fn set_context(&mut self, text: &str) {
        if self.context != text {
            self.context.clear();
            self.context.push_str(text);
            self.fresh = false;
        }
    }

    /// 换掉读本地时间的函数（测试用）。
    pub fn set_clock(&mut self, clock: Clock) {
        self.clock = clock;
        self.fresh = false;
    }

    /// 处理一次按键。
    pub fn key(&mut self, key: &Key) -> Frame {
        let handled = self.handle_key(key);
        if handled {
            self.fresh = false;
        }
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
    pub fn frame(&mut self, handled: bool) -> Frame {
        let preedit = self.selected_text() + &self.segmented_remaining();
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
        self.fresh = false;
    }

    /// 还没选词那部分输入的候选（全部，不分页）。没有引擎、没在打字时为空。
    pub fn candidates(&mut self) -> &[Candidate] {
        if !self.fresh {
            self.candidates = self.compute_candidates();
            self.fresh = true;
            self.generation += 1;
        }
        &self.candidates
    }

    /// 候选重算过几次（C 接口用）。
    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }

    fn compute_candidates(&self) -> Vec<Candidate> {
        let input = self.remaining();
        let Some(engine) = self.engine else {
            return Vec::new();
        };
        if input.is_empty() {
            return Vec::new();
        }
        if self.calc_active() && input.len() > 1 {
            // V 模式：v 后面是算式，候选是结果和「算式=结果」
            return crate::calc::candidates(&input[1..])
                .into_iter()
                .map(|text| Candidate::plain(text, input.len()))
                .collect();
        }

        // 已经选了开头的词时，把它当上文，剩下的部分排序更准
        let context = self.context.clone() + &self.selected_text();
        engine.set_context(utf8_tail(&context, CONTEXT_BYTES));
        let Ok(found) = engine.try_input(input) else {
            return Vec::new();
        };
        let mut all: Vec<Candidate> = found
            .into_iter()
            .map(|c| {
                let consumed = if c.consumed == 0 || c.consumed > input.len() {
                    input.len()
                } else {
                    c.consumed
                };
                // 自定义词里带换行的，不往用户词库里记（词库是一行一条）
                let kind = if c.text.contains(['\n', '\t']) {
                    CandidateKind::Plain
                } else {
                    CandidateKind::Word
                };
                Candidate {
                    commit: c.text.clone(),
                    text: c.text,
                    pinyin: c.pinyin,
                    consumed,
                    kind,
                    emoji: String::new(),
                }
            })
            .collect();
        if self.config.emoji_suggest {
            add_emoji_suggestion(&mut all, input.len());
            add_keycap(&mut all, input.len(), self.config.page_size);
        }
        if self.config.date_time && self.selections.is_empty() {
            self.add_date_time(&mut all, input, engine.config().shuangpin);
        }
        all
    }

    /// 日期时间：首选还是那个词（日期、时间），各种写法从第二个开始。
    fn add_date_time(&self, all: &mut Vec<Candidate>, input: &str, shuangpin: bool) {
        let Some(first) = all.first() else {
            return;
        };
        // 全拼看打的字母（riqi、rq、date 等）；双拼看首选的拼音
        let key = if shuangpin {
            if first.consumed < input.len() {
                return;
            }
            first.pinyin.clone()
        } else {
            input.to_owned()
        };
        let Some(now) = (self.clock)() else {
            return;
        };
        let extra = crate::datetime::candidates(&key, &now)
            .into_iter()
            .map(|text| Candidate::plain(text, input.len()));
        all.splice(1..1, extra);
    }

    /// V 模式（计算器）：没选过词、v 开头、后面只有数字和运算符。双拼时 v 是韵母键，不开。
    fn calc_active(&self) -> bool {
        let shuangpin = self.engine.is_some_and(|e| e.config().shuangpin);
        if !self.config.calculator || shuangpin || !self.selections.is_empty() {
            return false;
        }
        let Some(rest) = self.input.strip_prefix('v') else {
            return false;
        };
        rest.bytes()
            .all(|c| c.is_ascii_digit() || b"+-*/%^.()".contains(&c))
    }

    /// 还没选词那部分输入的显示：全拼分音节（nihao → ni hao），双拼显示成全拼
    /// （vsgo → zhong'guo），和微信输入法一样。分不出来就原样。
    fn segmented_remaining(&mut self) -> String {
        let input = self.remaining().to_owned();
        if let Some(engine) = self.engine {
            if engine.config().shuangpin {
                return engine
                    .shuangpin_display(&input)
                    .filter(|shown| !shown.is_empty())
                    .unwrap_or(input);
            }
        }
        let full = self
            .candidates()
            .iter()
            .find(|c| c.consumed >= input.len())
            .map(|c| c.pinyin.clone());
        full.and_then(|pinyin| crate::preedit::segment_input(&input, &pinyin))
            .unwrap_or(input)
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

    /// 过渡：外壳选了句首词，压进已选栈（选词还在外壳里）。
    pub fn push_selection(&mut self, selection: Selection) {
        self.selections.push(selection);
        self.fresh = false;
    }

    /// 过渡：外壳往原始输入后面加字（计算器的算式、双拼的分号、表情面板的搜索词）。
    pub fn append(&mut self, text: &str) {
        self.input.push_str(text);
        self.fresh = false;
    }
}

/// 首选是整句时按它推荐一个 emoji，插在第 [`EMOJI_SLOT`] 个。
fn add_emoji_suggestion(all: &mut Vec<Candidate>, input_len: usize) {
    let Some(first) = all.first() else {
        return;
    };
    if first.consumed < input_len {
        return;
    }
    let top = first.text.clone();
    let emoji: Vec<Candidate> = crate::emoji::recommend(&top, 1)
        .into_iter()
        .map(|s| Candidate {
            // 句尾对上时 commit 是「整句 + emoji」
            emoji: s
                .commit
                .strip_prefix(top.as_str())
                .unwrap_or(&s.commit)
                .to_owned(),
            text: s.display,
            pinyin: String::new(),
            consumed: input_len,
            kind: CandidateKind::Emoji,
            commit: s.commit,
        })
        .collect();
    let at = EMOJI_SLOT.min(all.len());
    all.splice(at..at, emoji);
}

/// 第一页里有数字字就在它后面跟按键 emoji：打 ba 是「吧 八 8️⃣ 把」，和手机输入法一样。
fn add_keycap(all: &mut Vec<Candidate>, input_len: usize, page_size: usize) {
    let window = all.len().min(page_size);
    for i in 0..window {
        let c = &all[i];
        if c.kind == CandidateKind::Emoji || c.consumed < input_len {
            continue;
        }
        let Some(keycap) = crate::emoji::keycap(&c.text) else {
            continue;
        };
        all.insert(
            i + 1,
            Candidate {
                text: keycap.to_owned(),
                pinyin: String::new(),
                consumed: input_len,
                kind: CandidateKind::Emoji,
                commit: keycap.to_owned(),
                emoji: keycap.to_owned(),
            },
        );
        return;
    }
}

/// 只留尾部 max_bytes 字节，起点对齐到字符边界。
fn utf8_tail(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let mut start = text.len() - max_bytes;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// 本地时间（日期时间候选用）。
#[cfg(unix)]
pub fn system_time() -> Option<LocalTime> {
    let mut now: libc::time_t = 0;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: time 和 localtime_r 只写我们给的两个变量
    unsafe {
        libc::time(&mut now);
        if libc::localtime_r(&now, &mut tm).is_null() {
            return None;
        }
    }
    Some(LocalTime {
        year: tm.tm_year + 1900,
        month: (tm.tm_mon + 1).max(0) as u32,
        day: tm.tm_mday.max(0) as u32,
        hour: tm.tm_hour.max(0) as u32,
        minute: tm.tm_min.max(0) as u32,
        second: tm.tm_sec.max(0) as u32,
        weekday: tm.tm_wday.max(0) as u32,
    })
}

#[cfg(not(unix))]
pub fn system_time() -> Option<LocalTime> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed(keys: &str) -> Session<'static> {
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
