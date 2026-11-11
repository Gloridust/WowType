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
//! - 选词（句首词进已选栈，整句上屏）和学习（选词记录、分几次选出来的整句也记一次）。
//!
//! 还没挪的键 [`Session::key`] 返回 `handled = false`，外壳接着用自己的旧逻辑处理。
//! 空格、数字这些选词键还在外壳里，外壳按全局序号调 [`Session::choose`]；
//! 计算器、双拼分号、表情面板往编辑区加字用 [`Session::append`]。这些过渡用法挪完以后会删掉。
//!
//! 下面三块也已经挪进来了，但要外壳在 [`Config::keys`] 里打开才生效（见 [`keys`]）：fcitx5 外壳
//! 还在用自己的旧逻辑，没打开，行为不变；macOS 外壳全部打开。照 PORTING.md 的顺序：
//!
//! - [`keys::SELECT`]：空格、回车、数字（含小键盘）、分号/引号选词、翻页键、候选光标、
//!   横排下键展开的面板（6 列 × 6 行一屏），V 模式计算器的数字和运算符、双拼的分号；
//! - [`keys::PUNCT`]：标点（没在打字时转中文标点，数字后的 `.` 是小数点；打字途中先上屏当前候选）；
//! - [`keys::MODE`]：单按 Shift 切中英文，英文模式没在打字时按键交给应用。
//!
//! 行为照 fcitx5 外壳的 keyEvent / handleGridKey / commitCurrent / punctFor / handleShiftToggle，
//! 翻页和光标照 fcitx5 的 CommonCandidateList（翻页后光标回到这页第一个）。
//! fcitx5 全局的翻页热键 macOS 上没有，照 fcitx5 的默认值：Tab / Shift+Tab 移动候选光标
//! （设置里打开 PageKeysTab 时改成翻页）。

use crate::config::{SelectKeys, ShiftToggle};
use crate::datetime::LocalTime;
use crate::Engine;

/// [`Config::keys`] 的位：会话处理哪几块按键。没打开的块照旧（`handled = false`，外壳自己处理）。
pub mod keys {
    /// 选词和翻页：空格、回车、数字（含小键盘）、分号/引号选词、翻页键、候选光标、展开面板，
    /// V 模式计算器的数字和运算符、双拼的分号；打字途中吞掉方向键、Tab、Delete。
    pub const SELECT: u32 = 1 << 0;
    /// 标点：没在打字时按样式转中文标点；打字途中先上屏当前候选，再上屏标点或其他可见字符。
    pub const PUNCT: u32 = 1 << 1;
    /// 中英文模式：单按 Shift 切换（[`super::Key::time_ms`] 用来判断按得够不够短）。
    pub const MODE: u32 = 1 << 2;
    pub const ALL: u32 = SELECT | PUNCT | MODE;
}

/// 展开面板每行几个、一屏几行。
pub const GRID_COLS: usize = 6;
pub const GRID_ROWS: usize = 6;
/// 按住 Shift 超过这么久就不算单按（毫秒）。
const SHIFT_TAP_MS: u64 = 500;
/// 打字途中按标点时，最多连着上屏几次当前候选（光标停在句首词上时要选好几次才整句上屏）。
const PUNCT_COMMIT_GUARD: usize = 16;

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
    pub const HOME: u32 = 0xff50;
    pub const END: u32 = 0xff57;
    pub const DELETE: u32 = 0xffff;
    /// Shift+Tab（X11 上 Shift+Tab 报的是这个）。
    pub const ISO_LEFT_TAB: u32 = 0xfe20;
    pub const SHIFT_L: u32 = 0xffe1;
    pub const SHIFT_R: u32 = 0xffe2;
    pub const KP_MULTIPLY: u32 = 0xffaa;
    pub const KP_ADD: u32 = 0xffab;
    pub const KP_SUBTRACT: u32 = 0xffad;
    pub const KP_DECIMAL: u32 = 0xffae;
    pub const KP_DIVIDE: u32 = 0xffaf;
    pub const KP_0: u32 = 0xffb0;
    pub const KP_9: u32 = 0xffb9;
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
    /// 光标前一个字符，不知道是 None（数字后的 `.` 是小数点，不转句号）。
    pub prev_char: Option<char>,
    /// 按键时刻（单调时钟，毫秒），单按 Shift 计时用；不知道给 0（不计时，按多久都算单按）。
    pub time_ms: u64,
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
    /// 下面是这一屏的候选（打开 [`keys::SELECT`] 时才填，否则都是 0）：
    /// 候选列表还是展开面板。
    pub panel: Panel,
    /// 这一屏第一个候选在全部候选（[`Session::candidates`]）里的序号。
    pub cand_offset: usize,
    /// 这一屏几个候选（列表是一页，面板最多 [`GRID_COLS`] × [`GRID_ROWS`] 个）。
    pub cand_count: usize,
    /// 高亮的候选在这一屏的位置（光标不在这一页时是 0，和空格选的一致）。
    pub cand_cursor: usize,
    pub has_prev: bool,
    pub has_next: bool,
    /// 中英文模式（打开 [`keys::MODE`] 时才填）。
    pub mode: Mode,
    /// 这次上屏记了选词（外壳按它攒着存用户词库，和 fcitx5 外壳的 finishCommit 一样）。
    pub learned: bool,
}

/// 候选怎么摆。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Panel {
    /// 一页一行（或一列）的候选列表。
    #[default]
    List = 0,
    /// 横排时按下键展开的面板：每行 [`GRID_COLS`] 个，光标所在行标 1–6。
    Grid = 1,
}

/// 中文还是英文（英文时没在打字的按键交给应用）。
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    #[default]
    Chinese = 0,
    English = 1,
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
    /// 会话处理哪几块按键（[`keys`] 的位），默认 0：还在 fcitx5 外壳里。
    pub keys: u32,
    /// 候选竖排（上下键移动候选、左右键翻页；横排反过来，下键展开面板）。
    pub vertical: bool,
    /// 分号、引号选第 2、3 个候选。
    pub select_keys: SelectKeys,
    /// 单按哪个 Shift 切中英文。
    pub shift_toggle: ShiftToggle,
    /// 打字途中这些键翻页：- =、[ ]、, .、Shift+Tab Tab。
    pub page_minus: bool,
    pub page_bracket: bool,
    pub page_comma: bool,
    pub page_tab: bool,
    /// 半角标点（ASCII 原样上屏）。
    pub punct_halfwidth: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            page_size: 9,
            calculator: true,
            date_time: true,
            emoji_suggest: true,
            keys: 0,
            vertical: false,
            select_keys: SelectKeys::Off,
            shift_toggle: ShiftToggle::Both,
            page_minus: true,
            page_bracket: false,
            page_comma: false,
            page_tab: false,
            punct_halfwidth: false,
        }
    }
}

impl Config {
    /// 由设置文件的内容得到会话设置（[`crate::config::Config`] 里和会话有关的键），
    /// `keys` 填 `keys`（外壳打开哪几块）。
    pub fn from_settings(settings: &crate::config::Config, keys: u32) -> Self {
        Self {
            page_size: settings.page_size,
            calculator: settings.calculator,
            date_time: settings.date_time,
            emoji_suggest: settings.emoji_suggest,
            keys,
            vertical: settings.candidate_layout == crate::config::Layout::Vertical,
            select_keys: settings.select_keys,
            shift_toggle: settings.shift_toggle,
            page_minus: settings.page_keys_minus,
            page_bracket: settings.page_keys_bracket,
            page_comma: settings.page_keys_comma,
            page_tab: settings.page_keys_tab,
            punct_halfwidth: settings.punctuation_style == crate::symbols::PunctStyle::Halfwidth,
        }
    }

    fn on(&self, block: u32) -> bool {
        self.keys & block != 0
    }
}

/// 候选列表的翻页和光标，照 fcitx5 的 CommonCandidateList（插件的设置：光标可以不在本页、
/// 翻页后光标回到这页第一个）。
#[derive(Clone, Copy, Debug, Default)]
struct List {
    len: usize,
    page_size: usize,
    page: usize,
    /// 全局光标位置；可以不在当前页（展开面板收起后）。
    cursor: usize,
}

impl List {
    fn new(len: usize, page_size: usize, cursor: usize) -> Self {
        Self {
            len,
            page_size: page_size.max(1),
            page: 0,
            cursor: cursor.min(len.saturating_sub(1)),
        }
    }

    fn total_pages(&self) -> usize {
        ceil_div(self.len, self.page_size)
    }

    fn page_start(&self) -> usize {
        self.page * self.page_size
    }

    fn page_len(&self) -> usize {
        self.len
            .saturating_sub(self.page_start())
            .min(self.page_size)
    }

    /// 光标在这页的第几个；不在这页时 None。
    fn cursor_on_page(&self) -> Option<usize> {
        (self.len > 0 && self.cursor / self.page_size == self.page)
            .then(|| self.cursor % self.page_size)
    }

    fn has_prev(&self) -> bool {
        self.page > 0
    }

    fn has_next(&self) -> bool {
        self.page + 1 < self.total_pages()
    }

    /// 翻页：光标原来在这页时回到新页的第一个，不在时不动。
    fn set_page(&mut self, page: usize) {
        if page != self.page && page < self.total_pages() {
            let was_here = self.cursor_on_page().is_some();
            self.page = page;
            if was_here {
                self.cursor = self.page_start();
            }
        }
    }

    fn prev(&mut self) {
        if self.has_prev() {
            self.set_page(self.page - 1);
        }
    }

    fn next(&mut self) {
        if self.has_next() {
            self.set_page(self.page + 1);
        }
    }

    /// 上一个/下一个候选：到头绕到另一头，并翻到光标所在的页。
    fn move_cursor(&mut self, prev: bool) {
        if self.len == 0 {
            return;
        }
        if self.cursor_on_page().is_none() {
            self.cursor = self.page_start() + if prev { self.page_len() - 1 } else { 0 };
            return;
        }
        self.cursor = match (prev, self.cursor) {
            (true, 0) => self.len - 1,
            (true, c) => c - 1,
            (false, c) if c + 1 >= self.len => 0,
            (false, c) => c + 1,
        };
        self.set_page(self.cursor / self.page_size);
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
    /// 候选列表的翻页和光标（[`keys::SELECT`]），候选重算时回到第一页。
    list: List,
    /// 横排时按下键展开了面板。
    expanded: bool,
    grid_cursor: usize,
    /// 中英文模式（[`keys::MODE`]）。fcitx5 里所有输入框共用一个，外壳用 `set_mode` 同步。
    mode: Mode,
    /// 按下还没松开的那个 Shift 和按下的时刻（单按 Shift 切中英文）。
    shift_down: Option<u32>,
    shift_down_at: u64,
    /// 这次调用要上屏的字（打字途中按标点会先上屏候选再上屏标点，攒在一起给外壳）。
    out: String,
    /// 这次调用的上屏记了选词。
    out_learned: bool,
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
            list: List::default(),
            expanded: false,
            grid_cursor: 0,
            mode: Mode::Chinese,
            shift_down: None,
            shift_down_at: 0,
            out: String::new(),
            out_learned: false,
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
        if config.on(keys::MODE) && config.shift_toggle == ShiftToggle::Off {
            // 关了单按 Shift 就没法切回中文，照 fcitx5 外壳回到中文
            self.mode = Mode::Chinese;
        }
    }

    /// 中英文模式（[`keys::MODE`]）。
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// 换中英文模式（外壳在输入框之间同步用，不上屏编辑区）。
    pub fn set_mode(&mut self, mode: Mode) {
        self.mode = mode;
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
        self.begin();
        let handled = self.handle_key(key);
        self.end(handled)
    }

    /// 一次调用开始：清掉上一次攒的上屏。
    fn begin(&mut self) {
        self.out.clear();
        self.out_learned = false;
    }

    /// 一次调用结束：编辑区 + 这次攒的上屏。
    fn end(&mut self, handled: bool) -> Frame {
        let mut frame = self.frame(handled);
        frame.commit = (!self.out.is_empty()).then(|| std::mem::take(&mut self.out));
        frame.learned = std::mem::take(&mut self.out_learned);
        frame
    }

    fn handle_key(&mut self, key: &Key) -> bool {
        let modes = self.config.on(keys::MODE);
        if modes && self.shift_toggle(key) {
            return true;
        }
        if key.release {
            return false;
        }
        if modes && self.mode == Mode::English && !self.composing() {
            // 英文模式：按键原样交给应用（字母、半角标点都直接上屏）
            return false;
        }
        if key.has_command_modifier() {
            return false;
        }
        let sym = key.keysym;
        if self.composing() && self.config.on(keys::SELECT) {
            if let Some(handled) = self.select_key(key) {
                return handled;
            }
        }
        if (u32::from(b'a')..=u32::from(b'z')).contains(&sym)
            || (u32::from(b'A')..=u32::from(b'Z')).contains(&sym)
        {
            // 大写字母原样保留：Hello、iPhone 这类英文候选要用到
            self.input.push(char::from(sym as u8));
            self.fresh = false;
            return true;
        }
        if !self.composing() {
            return self.config.on(keys::PUNCT) && self.idle_punct(key);
        }
        match sym {
            keysym::APOSTROPHE => {
                // 隔音符（xi'an）；开头的隔音符没有意义（上面已经排除了）
                self.input.push('\'');
                self.fresh = false;
                return true;
            }
            keysym::BACKSPACE => {
                // 选过词先撤销最后一次选词，拼音回到编辑区（后面还没选的拼音不动），
                // 和微信输入法一样；没有选词了才删字母
                if self.selections.pop().is_none() {
                    self.input.pop();
                }
                self.fresh = false;
                if self.input.is_empty() {
                    self.clear();
                }
                return true;
            }
            keysym::ESCAPE => {
                self.clear();
                return true;
            }
            _ => {}
        }
        if self.config.on(keys::PUNCT) && self.composing_punct(key) {
            return true;
        }
        // 编辑区里光标没法移动，这些键吃掉，免得应用里的光标乱跑
        self.config.on(keys::SELECT)
            && ((keysym::HOME..=keysym::END).contains(&sym)
                || matches!(sym, keysym::TAB | keysym::ISO_LEFT_TAB | keysym::DELETE))
    }

    /// 打字时的选词、翻页、计算器（[`keys::SELECT`]）。None：不是这些键，接着照常处理。
    fn select_key(&mut self, key: &Key) -> Option<bool> {
        let sym = key.keysym;
        if self.expanded && self.grid_key(sym) {
            return Some(true);
        }
        match sym {
            keysym::SPACE => {
                self.commit_current();
                return Some(true);
            }
            keysym::RETURN | keysym::KP_ENTER => {
                // 回车：已选的词 + 原始字母上屏
                self.do_commit_input();
                return Some(true);
            }
            _ => {}
        }
        if self.calc_active() {
            // V 模式：v 后面的数字、运算符进编辑区（不选词、不翻页、不当标点）
            if sym == u32::from(b'=') && self.input.len() > 1 {
                // = 上屏计算结果（第一个候选）
                self.commit_current();
                return Some(true);
            }
            if let Some(c) = calc_char(sym) {
                self.input.push(c);
                self.fresh = false;
                return Some(true);
            }
        }
        if let Some(nth) = self.select_key_index(sym) {
            // 分号选第 2 个、引号选第 3 个；没这么多候选就什么都不做
            self.choose_on_page(nth);
            return Some(true);
        }
        if let Some(digit) = digit(sym) {
            // 数字（含小键盘）按当前页选词
            if digit >= 1 {
                self.choose_on_page(digit);
            }
            return Some(true);
        }
        if sym == u32::from(b';') && self.semicolon_is_key() {
            // 微软、搜狗、紫光双拼用分号当 ing：等第二个键时分号进编辑区，不当标点
            self.input.push(';');
            self.fresh = false;
            return Some(true);
        }
        if self.candidates().is_empty() {
            return None;
        }
        self.list_key(key).then_some(true)
    }

    /// 选这一页的第 nth 个（从 1 数）；没有就什么都不做。
    fn choose_on_page(&mut self, nth: usize) {
        self.candidates();
        if nth >= 1 && nth <= self.list.page_len() {
            self.do_choose(self.list.page_start() + nth - 1);
        }
    }

    /// 候选列表的移动和翻页。横排时左右键移动、上下键翻页（下键展开面板）；竖排反过来。
    fn list_key(&mut self, key: &Key) -> bool {
        let sym = key.keysym;
        let shift = key.modifiers & modifier::SHIFT != 0;
        let tab_prev = sym == keysym::ISO_LEFT_TAB || (sym == keysym::TAB && shift);
        let tab_next = sym == keysym::TAB && !shift;
        if (tab_prev || tab_next) && !self.config.page_tab {
            // fcitx5 全局热键的默认值：Tab 下一个候选，Shift+Tab 上一个
            self.list.move_cursor(tab_prev);
            return true;
        }
        let horizontal = !self.config.vertical;
        let (prev_key, next_key, prev_page_key, next_page_key) = if horizontal {
            (keysym::LEFT, keysym::RIGHT, keysym::UP, keysym::DOWN)
        } else {
            (keysym::UP, keysym::DOWN, keysym::LEFT, keysym::RIGHT)
        };
        if horizontal && sym == keysym::DOWN && self.candidates.len() > 1 {
            // 横排时下键展开面板（照微信输入法），光标停在当前选中的词上
            self.expanded = true;
            self.grid_cursor = self.list.cursor;
            return true;
        }
        if sym == prev_key {
            self.list.move_cursor(true);
            return true;
        }
        if sym == next_key {
            self.list.move_cursor(false);
            return true;
        }
        let config = &self.config;
        let char_prev = (config.page_minus && sym == u32::from(b'-'))
            || (config.page_bracket && sym == u32::from(b'['))
            || (config.page_comma && sym == u32::from(b','))
            || (config.page_tab && tab_prev);
        let char_next = (config.page_minus && sym == u32::from(b'='))
            || (config.page_bracket && sym == u32::from(b']'))
            || (config.page_comma && sym == u32::from(b'.'))
            || (config.page_tab && tab_next);
        if (sym == keysym::PAGE_UP || sym == prev_page_key || char_prev) && self.list.has_prev() {
            self.list.prev();
            true
        } else if (sym == keysym::PAGE_DOWN || sym == next_page_key || char_next)
            && self.list.has_next()
        {
            self.list.next();
            true
        } else {
            // 已经在第一页/最后一页：吃掉，不当标点上屏（只有一页时照常当标点）
            (char_prev || char_next) && (self.list.has_prev() || self.list.has_next())
        }
    }

    /// 展开面板里的按键。返回 false 表示已收起，按键接着照常处理。
    fn grid_key(&mut self, sym: u32) -> bool {
        let n = self.candidates().len();
        if n == 0 {
            self.expanded = false;
            return false;
        }
        let screen = GRID_COLS * GRID_ROWS;
        let cursor = self.grid_cursor.min(n - 1);
        match sym {
            keysym::LEFT => self.grid_cursor = cursor.saturating_sub(1),
            keysym::RIGHT => self.grid_cursor = (cursor + 1).min(n - 1),
            // 第一行再往上：收起
            keysym::UP if cursor < GRID_COLS => self.collapse(),
            keysym::UP => self.grid_cursor = cursor - GRID_COLS,
            keysym::DOWN => {
                if cursor + GRID_COLS < n {
                    self.grid_cursor = cursor + GRID_COLS;
                } else if cursor / GRID_COLS + 1 < ceil_div(n, GRID_COLS) {
                    self.grid_cursor = n - 1; // 最后一行不满时落到最后一个
                }
            }
            keysym::PAGE_DOWN => self.grid_cursor = (cursor + screen).min(n - 1),
            s if s == u32::from(b'=') => self.grid_cursor = (cursor + screen).min(n - 1),
            keysym::PAGE_UP => self.grid_cursor = grid_page_up(cursor, screen),
            s if s == u32::from(b'-') => self.grid_cursor = grid_page_up(cursor, screen),
            keysym::ESCAPE => self.collapse(),
            keysym::SPACE => {
                self.do_choose(cursor);
            }
            _ => {
                if let Some(digit) = digit(sym) {
                    // 数字选光标所在行的第几个；别的数字吃掉
                    let index = cursor / GRID_COLS * GRID_COLS + digit;
                    if (1..=GRID_COLS).contains(&digit) && index <= n {
                        self.do_choose(index - 1);
                    }
                    return true;
                }
                // 打字、退格、回车、标点：先收起，再照常处理
                self.collapse();
                return false;
            }
        }
        true
    }

    /// 收起展开面板：回到候选列表第一页，光标停在面板里选中的词上。
    fn collapse(&mut self) {
        self.expanded = false;
        self.list = List::new(
            self.candidates.len(),
            self.config.page_size,
            self.grid_cursor,
        );
    }

    /// 空格：上屏光标处的候选；光标不在这页时上屏这页第一个；没有候选时上屏原始字母。
    fn commit_current(&mut self) {
        let n = self.candidates().len();
        if self.expanded && n > 0 {
            self.do_choose(self.grid_cursor.min(n - 1));
        } else if self.list.page_len() > 0 {
            let at = self.list.page_start() + self.list.cursor_on_page().unwrap_or(0);
            self.do_choose(at);
        } else {
            self.do_commit_input();
        }
    }

    /// 没在打字时的标点（[`keys::PUNCT`]）：按样式和光标前一个字符转中文标点。
    /// 没收录的（/ " + 等）、半角样式、数字后的小数点不处理，交给应用。
    fn idle_punct(&mut self, key: &Key) -> bool {
        let Some(c) = visible_ascii(key.keysym) else {
            return false;
        };
        match crate::symbols::punct(c, self.punct_style(), key.prev_char) {
            Some(punct) => {
                self.emit(punct);
                true
            }
            None => false,
        }
    }

    /// 打字途中按标点或其他可见字符（[`keys::PUNCT`]）：先上屏当前候选，再上屏它。
    fn composing_punct(&mut self, key: &Key) -> bool {
        let Some(c) = visible_ascii(key.keysym) else {
            return false;
        };
        if c == '\'' || c.is_ascii_alphabetic() {
            return false;
        }
        // 光标停在句首词上时，选完它还剩半句：接着选第一个候选，直到整句上屏
        for _ in 0..PUNCT_COMMIT_GUARD {
            if !self.composing() {
                break;
            }
            self.commit_current();
        }
        let mut text = c.to_string();
        if crate::symbols::fullwidth_punct(c).is_some() {
            // 光标前是刚上屏的字（没有就看外壳给的）
            let prev = self.out.chars().last().or(key.prev_char);
            if let Some(punct) = crate::symbols::punct(c, self.punct_style(), prev) {
                text = punct.to_owned();
            }
        }
        self.emit(&text);
        true
    }

    fn punct_style(&self) -> crate::symbols::PunctStyle {
        if self.config.punct_halfwidth {
            crate::symbols::PunctStyle::Halfwidth
        } else {
            crate::symbols::PunctStyle::Fullwidth
        }
    }

    /// 单按 Shift 切中英文：按下记下来，松开时中间没按别的键、也没按太久就切。
    /// 切了返回 true（这个松开事件算用掉）。
    fn shift_toggle(&mut self, key: &Key) -> bool {
        let sym = key.keysym;
        let is_shift = sym == keysym::SHIFT_L || sym == keysym::SHIFT_R;
        let wanted = is_shift
            && match self.config.shift_toggle {
                ShiftToggle::Both => true,
                ShiftToggle::Left => sym == keysym::SHIFT_L,
                ShiftToggle::Right => sym == keysym::SHIFT_R,
                ShiftToggle::Off => false,
            };
        if !key.release {
            self.shift_down = (wanted && !key.has_command_modifier()).then_some(sym);
            self.shift_down_at = key.time_ms;
            return false;
        }
        if !wanted || self.shift_down != Some(sym) {
            if !is_shift {
                self.shift_down = None;
            }
            return false;
        }
        self.shift_down = None;
        // 按住 Shift 超过 0.5 秒多半是想打大写或者犹豫了，不切（不知道时刻时不计时）
        let timed = key.time_ms != 0 && self.shift_down_at != 0;
        if timed && key.time_ms.saturating_sub(self.shift_down_at) > SHIFT_TAP_MS {
            return false;
        }
        if self.mode == Mode::English {
            self.mode = Mode::Chinese;
        } else {
            self.mode = Mode::English;
            if self.composing() {
                // 打到一半切英文：已选的词 + 打的字母原样上屏（和微信输入法一样）
                self.do_commit_input();
            }
        }
        true
    }

    fn select_key_index(&self, sym: u32) -> Option<usize> {
        match self.config.select_keys {
            SelectKeys::Off => None,
            // 微软、搜狗、紫光双拼里分号是 ing 键，不能拿来选词
            _ if sym == u32::from(b';') => (!self.shuangpin_semicolon()).then_some(2),
            SelectKeys::SemicolonQuote if sym == keysym::APOSTROPHE => Some(3),
            _ => None,
        }
    }

    fn shuangpin_semicolon(&self) -> bool {
        self.engine.is_some_and(|e| {
            let config = e.config();
            config.shuangpin && config.shuangpin_scheme.uses_semicolon()
        })
    }

    /// 双拼的分号是不是按键：还没选词的部分（不算隔音符）是单数个键，在等韵母。
    fn semicolon_is_key(&self) -> bool {
        self.shuangpin_semicolon()
            && self.composing()
            && self.remaining().chars().filter(|&c| c != '\'').count() % 2 == 1
    }

    /// 清空编辑区。commit_pending：把已选的词和还没选的原始输入上屏（切换输入法时），
    /// 和 [`Session::commit_input`] 一样也记一次选词。
    pub fn reset(&mut self, commit_pending: bool) -> Frame {
        self.begin();
        if commit_pending && self.composing() {
            self.do_commit_input();
        } else {
            self.clear();
        }
        self.end(true)
    }

    /// 现在的编辑区（不处理按键）。
    pub fn frame(&mut self, handled: bool) -> Frame {
        let preedit = self.selected_text() + &self.segmented_remaining();
        let mut frame = Frame {
            handled,
            commit: None,
            preedit_cursor: preedit.len(),
            preedit,
            ..Frame::default()
        };
        if self.config.on(keys::SELECT) {
            self.fill_screen(&mut frame);
        }
        if self.config.on(keys::MODE) {
            frame.mode = self.mode;
        }
        frame
    }

    /// 这一屏的候选：列表是当前页，展开面板是光标所在的那一屏。
    fn fill_screen(&mut self, frame: &mut Frame) {
        let n = self.candidates().len();
        if !self.composing() || n == 0 {
            return;
        }
        if self.expanded {
            let screen = GRID_COLS * GRID_ROWS;
            self.grid_cursor = self.grid_cursor.min(n - 1);
            let start = self.grid_cursor / screen * screen;
            frame.panel = Panel::Grid;
            frame.cand_offset = start;
            frame.cand_count = (n - start).min(screen);
            frame.cand_cursor = self.grid_cursor - start;
            frame.has_prev = self.grid_cursor >= screen;
            frame.has_next = start + frame.cand_count < n;
        } else {
            frame.cand_offset = self.list.page_start();
            frame.cand_count = self.list.page_len();
            frame.cand_cursor = self.list.cursor_on_page().unwrap_or(0);
            frame.has_prev = self.list.has_prev();
            frame.has_next = self.list.has_next();
        }
    }

    /// 鼠标点选这一屏（[`Frame::cand_offset`] 起）的第 index 个候选。没有这个候选时 handled 为 0。
    pub fn select(&mut self, index: usize) -> Frame {
        let mut probe = Frame::default();
        self.fill_screen(&mut probe);
        if index >= probe.cand_count {
            return self.frame(false);
        }
        self.choose(probe.cand_offset + index)
    }

    fn clear(&mut self) {
        self.input.clear();
        self.selections.clear();
        self.fresh = false;
        self.expanded = false;
        self.grid_cursor = 0;
        self.list = List::default();
    }

    /// 还没选词那部分输入的候选（全部，不分页）。没有引擎、没在打字时为空。
    /// 重算以后候选列表回到第一页、光标在第一个，展开面板收起。
    pub fn candidates(&mut self) -> &[Candidate] {
        if !self.fresh {
            self.candidates = self.compute_candidates();
            self.fresh = true;
            self.generation += 1;
            self.expanded = false;
            self.grid_cursor = 0;
            self.list = List::new(self.candidates.len(), self.config.page_size, 0);
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

    /// 选第 index 个候选（全部候选里的序号，不分页）。
    ///
    /// - emoji：上屏已选的词 + emoji（推荐在句尾对上时是整句 + emoji），不学习；
    /// - 计算结果、日期时间这类用完输入的：已选的词 + 它原样上屏，不学习；
    /// - 句首词（没用完输入）：进已选栈，记一次选词，剩下的接着选；
    /// - 其余：已选的词 + 它上屏，记选词（分几次选出来的整句也记一次，下次能一次打出来）。
    ///
    /// 序号不对时什么也不做（handled = false）。过渡：选词键挪进来以后外壳改用按页的 select。
    pub fn choose(&mut self, index: usize) -> Frame {
        self.begin();
        let handled = self.do_choose(index);
        self.end(handled)
    }

    /// [`Session::choose`] 的本体：上屏的字攒进这次调用。序号不对时返回 false。
    fn do_choose(&mut self, index: usize) -> bool {
        let Some(chosen) = self.candidates().get(index).cloned() else {
            return false;
        };
        let remaining = self.remaining().len();
        match chosen.kind {
            CandidateKind::Emoji => {
                let text = self.selected_text() + &chosen.commit;
                self.finish(text);
            }
            CandidateKind::Plain if chosen.consumed >= remaining => {
                let text = self.selected_text() + &chosen.text;
                self.finish(text);
            }
            _ if chosen.consumed < remaining => {
                // 句首词：先放进已选栈，剩下的拼音继续选
                self.learn(&chosen.text, &chosen.pinyin);
                self.push_selection(Selection {
                    text: chosen.text,
                    pinyin: chosen.pinyin,
                    bytes: chosen.consumed,
                });
            }
            _ => self.commit_with(&chosen.text, &chosen.pinyin),
        }
        true
    }

    /// 上屏已选的词 + 还没选的原始输入（回车、打字途中按标点），原始输入也记一次选词。
    /// 过渡：回车、标点挪进来以后由 key 处理。
    pub fn commit_input(&mut self) -> Frame {
        self.begin();
        self.do_commit_input();
        self.end(true)
    }

    fn do_commit_input(&mut self) {
        let tail = self.remaining().to_owned();
        self.commit_with(&tail, "");
    }

    /// 已选的词 + tail 上屏，记选词，清空。
    fn commit_with(&mut self, tail: &str, tail_pinyin: &str) {
        let text = self.selected_text() + tail;
        if self.engine.is_some() && !text.is_empty() {
            self.out_learned = true;
            if !tail.is_empty() {
                // 带上拼音：选够次数后引擎会自动把这个词收进用户词库
                self.learn(tail, tail_pinyin);
            }
            if !self.selections.is_empty() && !tail.is_empty() && !tail_pinyin.is_empty() {
                // 分几次选出来的整句也记一次，下次能一次打出来
                let mut pinyin = String::new();
                for selection in &self.selections {
                    pinyin.push_str(&selection.pinyin);
                    pinyin.push(' ');
                }
                pinyin.push_str(tail_pinyin);
                self.learn(&text, &pinyin);
            }
        }
        self.finish(text)
    }

    /// 记一次选词。上文和算候选时一样（已上屏的字 + 已选的词）。
    fn learn(&self, word: &str, pinyin: &str) {
        let Some(engine) = self.engine else {
            return;
        };
        let context = self.context.clone() + &self.selected_text();
        engine.set_context(utf8_tail(&context, CONTEXT_BYTES));
        engine.record_selection_with_pinyin(word, Some(pinyin).filter(|p| !p.is_empty()));
    }

    /// 上屏 text（空的不上屏），清空编辑区。
    fn finish(&mut self, text: String) {
        self.clear();
        self.emit(&text);
    }

    /// 攒进这次调用要上屏的字。
    fn emit(&mut self, text: &str) {
        self.out.push_str(text);
    }

    /// 选了句首词，压进已选栈（测试里不带引擎时用）。
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

/// V 模式计算器认的字符（数字、运算符、括号），小键盘也算。
fn calc_char(sym: u32) -> Option<char> {
    match sym {
        keysym::KP_0..=keysym::KP_9 => char::from_digit(sym - keysym::KP_0, 10),
        keysym::KP_ADD => Some('+'),
        keysym::KP_SUBTRACT => Some('-'),
        keysym::KP_MULTIPLY => Some('*'),
        keysym::KP_DIVIDE => Some('/'),
        keysym::KP_DECIMAL => Some('.'),
        _ => visible_ascii(sym).filter(|c| c.is_ascii_digit() || "+-*/.%^()".contains(*c)),
    }
}

/// 数字键（主键盘或小键盘，和 fcitx 的 Key::isDigit 一样）的数字。
fn digit(sym: u32) -> Option<usize> {
    match sym {
        0x30..=0x39 => Some((sym - 0x30) as usize),
        keysym::KP_0..=keysym::KP_9 => Some((sym - keysym::KP_0) as usize),
        _ => None,
    }
}

/// 可见 ASCII 字符（! 到 ~）的 keysym 就是它的码位。
fn visible_ascii(sym: u32) -> Option<char> {
    (0x21..=0x7e).contains(&sym).then(|| char::from(sym as u8))
}

/// 展开面板往上翻一屏：不到一屏时回到第一行同一列。
fn grid_page_up(cursor: usize, screen: usize) -> usize {
    if cursor >= screen {
        cursor - screen
    } else {
        cursor % GRID_COLS
    }
}

/// 向上取整的除法（MSRV 还没有 usize::div_ceil 时也能用）。
fn ceil_div(a: usize, b: usize) -> usize {
    let b = b.max(1);
    a / b + usize::from(a % b != 0)
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
