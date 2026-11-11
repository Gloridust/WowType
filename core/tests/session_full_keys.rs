//! 会话的选词、翻页、标点、中英文模式（[`keys::ALL`]）的按键测试：把
//! fcitx5-addon/test/key_harness.cpp 里的按键测试逐条搬过来，在测试自己写的小词库上跑
//! （不读 dist/data，不碰真的 fcitx5）。fcitx5 外壳还没打开这几块（`keys` 是 0）的行为
//! 在 tests/session_keys.rs 里测。
//!
//! 下面的 [`shell`] 是一个最小的外壳，做 fcitx5 外壳（和 macOS 外壳的 SessionShell）在会话
//! 外面做的事：记最近上屏的字当上文、攒着学习次数要求存盘、中英文模式在输入框之间共用、
//! 记光标前一个字符。用例只通过它按键，所以读起来和 key_harness 一样。
//!
//! 每条注明在 key_harness.cpp 里的行号。没搬的：
//!
//! - 137-158：起私有 fcitx5、等后台载入词库。会话直接拿到引擎，不用等。
//! - 283-287：WOWTYPE_HARNESS_SHOW 调试打印。
//! - 289-292 里「１〔词〕」这种拼好的行文字：那是 fcitx5 画网格的办法，会话只给这一屏的候选、
//!   光标和面板种类，由外壳画；这里改为检查每行 6 个、光标和选择键。
//! - 425-473：表情面板（Super+.），这一版不做（macOS 有系统表情面板）。
//! - 590-611：fcitx5 全局翻页热键（Hotkey/PrevPage 设成逗号等）。那是 fcitx5 的全局设置，
//!   不在会话的设置里；会话只照 fcitx5 的默认热键（Tab / Shift+Tab 移动候选）。
//! - 743-977：互译，这一版不做。
//! - 979-1036：语音，这一版不做。374-378、537-538 的右 Alt 照常搬（右 Alt 就是普通修饰键，
//!   交给应用）。
//! - 1038-1063：main 里起实例的代码。
//!
//! 插件的两种事件在外壳里对应：失去焦点 = `reset()`，切换输入法 = `commit_composition()`。

use std::sync::Arc;

use wowtype_core::config;
use wowtype_core::lm::BigramLm;
use wowtype_core::session::keys;
use wowtype_core::{Engine, Lexicon, MemoryLexicon};

use shell::{mods, Key, KeyEvent, Mode, Session};

/// 最小的外壳：平台按键 → [`wowtype_core::session::Key`]，按返回的 Frame 上屏、记上文和学习次数。
/// macOS 的 WowTypeEngine/Session.swift + WowTypeKit/SessionShell.swift 做的是同一件事。
mod shell {
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;

    use wowtype_core::config;
    use wowtype_core::datetime::LocalTime;
    use wowtype_core::session::{self as core, keys, keysym, modifier, Frame, Panel};
    use wowtype_core::Engine;

    /// 测试里按键带的修饰键（平台的写法，外壳翻成 [`modifier`]）。
    pub mod mods {
        pub const SHIFT: u32 = 1;
        pub const CONTROL: u32 = 2;
        pub const ALT: u32 = 4;
        pub const SUPER: u32 = 8;
        /// 小键盘上的键。
        pub const KEYPAD: u32 = 16;
        pub const CAPS_LOCK: u32 = 32;
    }

    /// 具名键；打出字符的键用 `Key::None`，字符放在 `KeyEvent::unicode`。
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Key {
        None,
        Backspace,
        Return,
        Escape,
        Tab,
        Delete,
        Left,
        Right,
        Up,
        Down,
        Home,
        End,
        PageUp,
        PageDown,
        ShiftL,
        ShiftR,
        ControlL,
        ControlR,
        AltL,
        AltR,
        SuperL,
        SuperR,
        CapsLock,
        /// 别的功能键（F1……）。
        Other,
    }

    #[derive(Clone, Copy, Debug)]
    pub struct KeyEvent {
        pub key: Key,
        pub unicode: Option<char>,
        pub modifiers: u32,
        pub is_release: bool,
        /// 本地时区和 UTC 的差（秒），日期时间候选用。
        pub utc_offset_seconds: i32,
        /// Unix 毫秒：日期时间候选用，也当单按 Shift 的计时。
        pub time_ms: i64,
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Mode {
        Chinese,
        Ascii,
    }

    const CONTEXT_BYTES: usize = 24;
    const SAVE_EVERY: u32 = 20;
    const LABELS: [&str; 9] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"];

    thread_local! {
        /// 这次按键的时刻和时区（会话的时钟是函数指针，从这里读）。
        static NOW: Cell<(i64, i32)> = const { Cell::new((0, 0)) };
    }

    fn clock() -> Option<LocalTime> {
        let (ms, offset) = NOW.with(Cell::get);
        Some(local_time(ms, offset))
    }

    /// Unix 毫秒 + 时区 → 本地时间（公历，1970 年以后）。
    fn local_time(ms: i64, offset: i32) -> LocalTime {
        let secs = ms.div_euclid(1000) + i64::from(offset);
        let days = secs.div_euclid(86_400);
        let rem = secs.rem_euclid(86_400);
        // Howard Hinnant 的 civil_from_days
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z - era * 146_097;
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = doy - (153 * mp + 2) / 5 + 1;
        let month = if mp < 10 { mp + 3 } else { mp - 9 };
        let year = yoe + era * 400 + i64::from(month <= 2);
        LocalTime {
            year: year as i32,
            month: month as u32,
            day: day as u32,
            hour: (rem / 3600) as u32,
            minute: (rem % 3600 / 60) as u32,
            second: (rem % 60) as u32,
            weekday: (days + 4).rem_euclid(7) as u32,
        }
    }

    /// 所有输入框共用的状态（fcitx5 外壳里是插件对象的成员）。
    #[derive(Debug, Default)]
    struct Shared {
        mode: core::Mode,
        recent: String,
        unsaved: u32,
        save_requested: bool,
    }

    #[derive(Clone, Debug, Default)]
    pub struct SessionGroup(Rc<RefCell<Shared>>);

    /// 一个输入框：会话 + 外壳记的东西。
    pub struct Session {
        inner: core::Session<'static>,
        group: SessionGroup,
        commit: String,
        /// 光标前一个字符（上一次上屏的最后一个字，或者交给应用的字符）。
        prev: Option<char>,
    }

    fn keysym_of(ev: &KeyEvent) -> u32 {
        let keypad = ev.modifiers & mods::KEYPAD != 0;
        match (ev.key, ev.unicode) {
            (Key::None, Some(c)) if keypad => match c {
                '0'..='9' => keysym::KP_0 + (c as u32 - '0' as u32),
                '+' => keysym::KP_ADD,
                '-' => keysym::KP_SUBTRACT,
                '*' => keysym::KP_MULTIPLY,
                '/' => keysym::KP_DIVIDE,
                '.' => keysym::KP_DECIMAL,
                '=' => 0xffbd,
                other => other as u32,
            },
            (Key::None, Some(c)) => c as u32,
            (Key::None, None) => 0,
            (Key::Return, _) if keypad => keysym::KP_ENTER,
            (Key::Backspace, _) => keysym::BACKSPACE,
            (Key::Return, _) => keysym::RETURN,
            (Key::Escape, _) => keysym::ESCAPE,
            // X11 和 fcitx5 把 Shift+Tab 报成 ISO_Left_Tab
            (Key::Tab, _) if ev.modifiers & mods::SHIFT != 0 => keysym::ISO_LEFT_TAB,
            (Key::Tab, _) => keysym::TAB,
            (Key::Delete, _) => keysym::DELETE,
            (Key::Left, _) => keysym::LEFT,
            (Key::Right, _) => keysym::RIGHT,
            (Key::Up, _) => keysym::UP,
            (Key::Down, _) => keysym::DOWN,
            (Key::Home, _) => keysym::HOME,
            (Key::End, _) => keysym::END,
            (Key::PageUp, _) => keysym::PAGE_UP,
            (Key::PageDown, _) => keysym::PAGE_DOWN,
            (Key::ShiftL, _) => keysym::SHIFT_L,
            (Key::ShiftR, _) => keysym::SHIFT_R,
            (Key::ControlL, _) => 0xffe3,
            (Key::ControlR, _) => 0xffe4,
            (Key::CapsLock, _) => 0xffe5,
            (Key::AltL, _) => 0xffe9,
            (Key::AltR, _) => 0xffea,
            (Key::SuperL, _) => 0xffeb,
            (Key::SuperR, _) => 0xffec,
            (Key::Other, _) => 0xffbe, // F1
        }
    }

    fn modifiers_of(m: u32) -> u32 {
        [
            (mods::SHIFT, modifier::SHIFT),
            (mods::CAPS_LOCK, modifier::CAPS),
            (mods::CONTROL, modifier::CTRL),
            (mods::ALT, modifier::ALT),
            (mods::SUPER, modifier::SUPER),
        ]
        .into_iter()
        .filter(|(from, _)| m & from != 0)
        .fold(0, |acc, (_, to)| acc | to)
    }

    fn is_modifier_key(key: Key) -> bool {
        matches!(
            key,
            Key::ShiftL
                | Key::ShiftR
                | Key::ControlL
                | Key::ControlR
                | Key::AltL
                | Key::AltR
                | Key::SuperL
                | Key::SuperR
                | Key::CapsLock
        )
    }

    fn utf8_tail(text: &str, max: usize) -> String {
        let mut start = text.len().saturating_sub(max);
        while !text.is_char_boundary(start) {
            start += 1;
        }
        text[start..].to_string()
    }

    impl Session {
        pub fn new() -> Self {
            Self::in_group(&SessionGroup::default())
        }

        pub fn in_group(group: &SessionGroup) -> Self {
            let mut inner = core::Session::new();
            inner.set_clock(clock);
            inner.configure(core::Config {
                keys: keys::ALL,
                ..core::Config::default()
            });
            Self {
                inner,
                group: group.clone(),
                commit: String::new(),
                prev: None,
            }
        }

        pub fn group(&self) -> SessionGroup {
            self.group.clone()
        }

        /// 读设置文本里和会话有关的键，返回认不出的行数。
        pub fn configure(&mut self, ini: &str) -> usize {
            let (settings, bad) = config::parse(ini);
            self.inner
                .configure(core::Config::from_settings(&settings, keys::ALL));
            if settings.shift_toggle == config::ShiftToggle::Off {
                self.group.0.borrow_mut().mode = core::Mode::Chinese;
            }
            bad
        }

        /// 每次调会话前：引擎、上文、共用的中英文模式。
        fn sync(&mut self, engine: Option<&'static Engine>) {
            self.inner.set_engine(engine);
            let shared = self.group.0.borrow();
            self.inner.set_context(&shared.recent);
            self.inner.set_mode(shared.mode);
        }

        /// 每次调会话后：上屏、记上文、攒学习次数、记下中英文模式。
        fn after(&mut self, engine: Option<&'static Engine>, frame: &Frame) {
            let mut shared = self.group.0.borrow_mut();
            shared.mode = frame.mode;
            let Some(text) = frame.commit.as_deref() else {
                return;
            };
            assert!(!text.is_empty(), "frame.commit 不该是空串");
            self.commit += text;
            self.prev = text.chars().last();
            shared.recent = utf8_tail(&(shared.recent.clone() + text), CONTEXT_BYTES);
            if let Some(engine) = engine {
                engine.set_context(&shared.recent);
                if frame.learned {
                    shared.unsaved += 1;
                    if shared.unsaved >= SAVE_EVERY {
                        shared.unsaved = 0;
                        shared.save_requested = true;
                    }
                }
            }
        }

        fn request_save_if_unsaved(&mut self) {
            let mut shared = self.group.0.borrow_mut();
            if shared.unsaved > 0 {
                shared.unsaved = 0;
                shared.save_requested = true;
            }
        }

        pub fn process_key(&mut self, engine: Option<&'static Engine>, ev: &KeyEvent) -> bool {
            NOW.with(|now| now.set((ev.time_ms, ev.utc_offset_seconds)));
            self.sync(engine);
            let key = core::Key {
                keysym: keysym_of(ev),
                modifiers: modifiers_of(ev.modifiers),
                release: ev.is_release,
                prev_char: self.prev,
                time_ms: ev.time_ms as u64,
            };
            let composing = self.inner.composing();
            let frame = self.inner.key(&key);
            self.after(engine, &frame);
            // 光标前一个字符，照 fcitx5 外壳的 DigitTracker：这次上屏了就是上屏的最后一个字；
            // 没上屏时，原样交给应用的字符算数，别的键（退格、方向键……）就不知道了
            if frame.commit.is_none() && !ev.is_release && !is_modifier_key(ev.key) {
                let command = ev.modifiers & (mods::CONTROL | mods::ALT | mods::SUPER) != 0;
                self.prev = ev
                    .unicode
                    .filter(|_| !frame.handled && !composing && !command);
            }
            frame.handled
        }

        /// 词库载入好了、自定义词改了：候选重算。
        pub fn refresh(&mut self, engine: Option<&'static Engine>) {
            self.inner.set_engine(None);
            self.sync(engine);
        }

        /// 鼠标点选这一屏的第 index 个。
        pub fn select(&mut self, engine: Option<&'static Engine>, index: usize) -> bool {
            self.sync(engine);
            let frame = self.inner.select(index);
            self.after(engine, &frame);
            frame.handled
        }

        /// 鼠标滚轮/翻页按钮：翻页键交给会话；这一屏没变时返回 false。
        pub fn page(&mut self, delta: i32) -> bool {
            if delta == 0 || !self.inner.composing() {
                return false;
            }
            let before = self.screen();
            let key = core::Key::press(if delta < 0 {
                keysym::PAGE_UP
            } else {
                keysym::PAGE_DOWN
            });
            let frame = self.inner.key(&key);
            let after = (frame.cand_offset, frame.cand_count, frame.cand_cursor);
            before != after
        }

        pub fn reset(&mut self) {
            self.inner.reset(false);
            self.request_save_if_unsaved();
        }

        pub fn commit_composition(&mut self, engine: Option<&'static Engine>) {
            self.sync(engine);
            let frame = self.inner.reset(true);
            self.after(engine, &frame);
            self.request_save_if_unsaved();
        }

        pub fn take_commit(&mut self) -> Option<String> {
            (!self.commit.is_empty()).then(|| std::mem::take(&mut self.commit))
        }

        pub fn take_save_request(&mut self) -> bool {
            std::mem::take(&mut self.group.0.borrow_mut().save_requested)
        }

        fn frame(&mut self) -> Frame {
            self.inner.frame(false)
        }

        fn screen(&mut self) -> (usize, usize, usize) {
            let f = self.frame();
            (f.cand_offset, f.cand_count, f.cand_cursor)
        }

        pub fn is_composing(&self) -> bool {
            self.inner.composing()
        }

        pub fn preedit(&mut self) -> String {
            self.frame().preedit
        }

        pub fn preedit_plain_len(&self) -> usize {
            self.inner.selected_text().len()
        }

        pub fn preedit_cursor(&mut self) -> usize {
            self.frame().preedit_cursor
        }

        pub fn aux(&self) -> &str {
            ""
        }

        pub fn candidate_count(&mut self) -> usize {
            self.frame().cand_count
        }

        /// 候选窗里显示的字：换行、制表符画成 ⏎、⇥（外壳画的时候换）。
        pub fn candidate_text(&mut self, index: usize) -> Option<String> {
            let f = self.frame();
            (index < f.cand_count).then(|| {
                self.inner.candidates()[f.cand_offset + index]
                    .text
                    .replace('\n', "⏎")
                    .replace('\t', "⇥")
            })
        }

        /// 选择键：列表是 1–9；展开面板里只有光标所在行有 1–6，其余是空串。
        pub fn candidate_label(&mut self, index: usize) -> Option<&'static str> {
            let f = self.frame();
            if index >= f.cand_count {
                return None;
            }
            if f.panel == Panel::List {
                return Some(LABELS[index % LABELS.len()]);
            }
            let at = f.cand_offset + index;
            let cursor = f.cand_offset + f.cand_cursor;
            Some(if at / core::GRID_COLS == cursor / core::GRID_COLS {
                LABELS[at % core::GRID_COLS]
            } else {
                ""
            })
        }

        pub fn candidate_cursor(&mut self) -> usize {
            self.frame().cand_cursor
        }

        /// 0 是列表，大于 0 是展开面板每行几个。
        pub fn columns(&mut self) -> usize {
            let f = self.frame();
            if f.panel == Panel::Grid && f.cand_count > 0 {
                core::GRID_COLS
            } else {
                0
            }
        }

        pub fn vertical(&self) -> bool {
            self.inner.config().vertical
        }

        pub fn has_prev_page(&mut self) -> bool {
            self.frame().has_prev
        }

        pub fn has_next_page(&mut self) -> bool {
            self.frame().has_next
        }

        pub fn mode(&self) -> Mode {
            match self.group.0.borrow().mode {
                core::Mode::Chinese => Mode::Chinese,
                core::Mode::English => Mode::Ascii,
            }
        }
    }
}

/// 测试词库：只放这些用例要用到的词。
const LEXICON: &str = "\
ni hao\t你好\t100000
ni\t你\t60000
ni\t泥\t8000
ni\t尼\t6000
hao\t好\t70000
zhong guo\t中国\t90000
zhong\t中\t60000
zhong\t重\t30000
zhong\t种\t20000
guo\t国\t40000
zhong dian\t重点\t60000
zhong di\t种地\t2000
di\t地\t50000
ka\t卡\t20000
kan\t看\t90000
dan\t但\t40000
dan\t蛋\t9000
da\t大\t90000
heng\t横\t9000
heng xiang\t横向\t5000
xiang\t向\t40000
hou xuan\t候选\t5000
hou xuan ci\t候选词\t2000
ci\t词\t30000
ke yi\t可以\t90000
ke\t可\t40000
yi\t一\t90000
yong\t用\t50000
zhong wen\t中文\t40000
wen\t文\t30000
ji xu\t继续\t30000
ren min\t人民\t40000
kai xin\t开心\t30000
kai\t开\t40000
xin\t心\t30000
jin tian\t今天\t60000
ba\t吧\t50000
ba\t八\t40000
ba\t把\t30000
ba\t爸\t10000
ge\t个\t80000
shi\t是\t90000
shi\t事\t60000
shi\t时\t55000
shi\t十\t50000
shi\t市\t40000
shi\t使\t35000
shi\t世\t30000
shi\t式\t25000
shi\t试\t20000
shi\t实\t18000
shi\t师\t15000
shi\t诗\t12000
shi\t石\t10000
shi\t识\t9000
shi\t史\t8000
zhi\t之\t90000
zhi\t只\t80000
zhi\t知\t70000
zhi\t指\t60000
zhi\t直\t50000
zhi\t至\t40000
zhi\t制\t30000
zhi\t值\t20000
zhi\t支\t10000
zhi\t纸\t9000
ri qi\t日期\t30000
shi jian\t时间\t60000
xing qi\t星期\t30000
xing\t行\t50000
xing\t星\t30000
niu nai\t牛奶\t20000
liu\t流\t30000
nai\t耐\t20000
xi an\t西安\t20000
xi\t西\t30000
an\t安\t30000
wo\t我\t90000
de\t的\t90000
";

const ENGLISH: &str = "GitHub\nhello\nvery\n";

/// 一个会话 + 引擎，像插件那样把上屏和交给应用的字记下来。
/// 引擎是泄漏出来的 `&'static`，会话可以一直拿着（测试进程结束就回收）。
struct Rig {
    engine: Option<&'static Engine>,
    session: Session,
    committed: String,
    passed: String,
    now_ms: i64,
    utc_offset: i32,
    custom_tsv: String,
}

fn build_engine(settings: &config::Config) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(LEXICON).unwrap());
    let mut e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    e.load_english_str(ENGLISH);
    config::apply_to_engine(&mut e, settings);
    e
}

fn engine() -> Engine {
    build_engine(&config::Config::default())
}

fn leak(engine: Engine) -> &'static Engine {
    Box::leak(Box::new(engine))
}

impl Rig {
    fn new() -> Self {
        Self::with(Some(engine()))
    }

    fn with(engine: Option<Engine>) -> Self {
        Self {
            engine: engine.map(leak),
            session: Session::new(),
            committed: String::new(),
            passed: String::new(),
            // 2026-11-10 09:05:01（东八区），星期二
            now_ms: 1_794_272_701_000,
            utc_offset: 8 * 3600,
            custom_tsv: String::new(),
        }
    }

    /// 像插件的 reloadConfig：设置文本同时给会话和引擎。引擎的设置要 `&mut`，这里换一个按新设置
    /// 建的引擎（上文、学习记录和自定义词搬过去），再让会话重算候选。
    fn configure(&mut self, ini: &str) {
        assert_eq!(self.session.configure(ini), 0, "{ini}");
        if let Some(old) = self.engine {
            let fresh = build_engine(&config::parse(ini).0);
            fresh.set_context(&old.context());
            fresh.lexicon().set_custom_tsv(&self.custom_tsv);
            self.engine = Some(leak(fresh));
            self.session.refresh(self.engine);
        }
    }

    fn custom(&mut self, tsv: &str) {
        self.custom_tsv = tsv.to_string();
        self.engine.unwrap().lexicon().set_custom_tsv(tsv);
        self.session.refresh(self.engine);
    }

    fn event(&mut self, key: Key, unicode: Option<char>, modifiers: u32, release: bool) -> bool {
        self.now_ms += 10;
        let ev = KeyEvent {
            key,
            unicode,
            modifiers,
            is_release: release,
            utc_offset_seconds: self.utc_offset,
            time_ms: self.now_ms,
        };
        let handled = self.session.process_key(self.engine, &ev);
        self.collect();
        handled
    }

    fn collect(&mut self) {
        if let Some(text) = self.session.take_commit() {
            assert!(!text.is_empty(), "take_commit 不该给空串");
            self.committed += &text;
        }
    }

    /// 按下再松开（和 harness 的 send 一样）。没被接住的字符记进 passed。
    fn send(&mut self, key: Key, unicode: Option<char>, modifiers: u32) -> bool {
        let handled = self.event(key, unicode, modifiers, false);
        self.event(key, unicode, modifiers, true);
        if !handled {
            if let Some(c) = unicode {
                self.passed.push(c);
            }
        }
        handled
    }

    fn ch(&mut self, c: char) -> bool {
        let modifiers = if c.is_ascii_uppercase() {
            mods::SHIFT
        } else {
            0
        };
        self.send(Key::None, Some(c), modifiers)
    }

    fn key(&mut self, key: Key) -> bool {
        self.send(key, None, 0)
    }

    /// 按一串键。<sp> <bs> <cr> <esc> <down> <up> <left> <right> <pgdn> <pgup> <tab> 是特殊键。
    fn ty(&mut self, keys: &str) {
        let mut rest = keys;
        while let Some(c) = rest.chars().next() {
            if c == '<' {
                let end = rest.find('>').unwrap();
                let name = &rest[1..end];
                rest = &rest[end + 1..];
                match name {
                    "sp" => self.ch(' '),
                    "bs" => self.key(Key::Backspace),
                    "cr" => self.key(Key::Return),
                    "esc" => self.key(Key::Escape),
                    "down" => self.key(Key::Down),
                    "up" => self.key(Key::Up),
                    "left" => self.key(Key::Left),
                    "right" => self.key(Key::Right),
                    "pgdn" => self.key(Key::PageDown),
                    "pgup" => self.key(Key::PageUp),
                    "tab" => self.key(Key::Tab),
                    other => panic!("不认识的键 <{other}>"),
                };
                continue;
            }
            rest = &rest[c.len_utf8()..];
            self.ch(c);
        }
    }

    fn preedit(&mut self) -> String {
        self.session.preedit()
    }

    fn page(&mut self) -> Vec<String> {
        (0..self.session.candidate_count())
            .map(|i| self.session.candidate_text(i).unwrap())
            .collect()
    }

    fn labels(&mut self) -> Vec<String> {
        (0..self.session.candidate_count())
            .map(|i| self.session.candidate_label(i).unwrap().to_string())
            .collect()
    }

    /// 每个用例前清空上屏记录和编辑区（harness 的 fresh）。
    fn fresh(&mut self) {
        self.ty("<esc>");
        self.committed.clear();
        self.passed.clear();
    }

    fn tap_shift(&mut self, key: Key, hold_ms: i64) -> bool {
        self.event(key, None, 0, false);
        self.now_ms += hold_ms;
        self.event(key, None, mods::SHIFT, true)
    }

    /// 换成另一个会话（像切到另一个应用的输入框），引擎和上屏记录不变。
    fn swap(&mut self, other: &mut Session) {
        std::mem::swap(&mut self.session, other);
    }

    fn history(&self, word: &str) -> u32 {
        self.engine.unwrap().history_count(word)
    }
}

/// 只看上屏结果的用例：(harness 行号, 设置, 按键, 上屏, 交给应用)。
const COMMIT_VECTORS: &[(u32, &str, &str, &str, &str)] = &[
    (160, "", "nihao<sp>", "你好", ""),
    (163, "", "nihao,", "你好，", ""),
    (167, "", "zhognguo<sp>", "中国", ""),
    (171, "", "nihao<cr>", "nihao", ""),
    (175, "", "github<sp>", "GitHub", ""),
    (179, "", "Hello<sp>", "Hello", ""),
    (185, "", "zhongdi<sp>", "种地", ""),
    (187, "", "ka<sp>", "卡", ""),
    (334, "", "ni<bs><bs>,", "，", ""),
    (339, "", "1", "", "1"),
    (368, "", "hengxiang<cr>", "hengxiang", ""),
    (382, "", "/jixu<sp>", "继续", "/"),
    (386, "", "nihao/", "你好/", ""),
    (390, "", "nihao+", "你好+", ""),
    (
        620,
        "Shuangpin=True\nShuangpinScheme=Microsoft\n",
        "vsgo<sp>",
        "中国",
        "",
    ),
    (
        627,
        "Shuangpin=True\nShuangpinScheme=Microsoft\n",
        "ni;",
        "你；",
        "",
    ),
    (661, "", "v1+2*3<sp>", "7", ""),
    (667, "", "v(1.5-0.5)/4=", "0.25", ""),
    (710, "", "ni;", "你；", ""),
];

#[test]
fn commit_vectors() {
    for &(line, ini, keys, committed, passed) in COMMIT_VECTORS {
        let mut rig = Rig::new();
        rig.configure(ini);
        rig.ty(keys);
        assert_eq!(
            (rig.committed.as_str(), rig.passed.as_str()),
            (committed, passed),
            "key_harness.cpp:{line} {keys}"
        );
    }
}

/// 只看编辑区的用例：(行号, 设置, 按键, 编辑区)。
const PREEDIT_VECTORS: &[(u32, &str, &str, &str)] = &[
    (366, "", "hengxiang", "heng'xiang"),
    (371, "", "zhongg", "zhong'g"),
    (
        619,
        "Shuangpin=True\nShuangpinScheme=Microsoft\n",
        "vsgo",
        "zhong'guo",
    ),
    (
        624,
        "Shuangpin=True\nShuangpinScheme=Microsoft\n",
        "x;",
        "xing",
    ),
    (659, "", "v1+2*3", "v1+2*3"),
    (665, "", "v(1.5-0.5)/4", "v(1.5-0.5)/4"),
    (
        724,
        "SelectKeys=Semicolon\nEmojiSuggest=False\n",
        "xi'an",
        "xi'an",
    ),
];

#[test]
fn preedit_vectors() {
    for &(line, ini, keys, preedit) in PREEDIT_VECTORS {
        let mut rig = Rig::new();
        rig.configure(ini);
        rig.ty(keys);
        assert_eq!(rig.preedit(), preedit, "key_harness.cpp:{line} {keys}");
        assert_eq!(rig.committed, "", "key_harness.cpp:{line} {keys} 不该上屏");
        assert!(rig.session.is_composing());
        // 编辑区全是还在打的拼音，光标在末尾
        assert_eq!(rig.session.preedit_plain_len(), 0);
        assert_eq!(rig.session.preedit_cursor(), preedit.len());
    }
}

/// 只看第一个候选的用例：(行号, 设置, 自定义词, 按键, 第一个候选)。
const FIRST_VECTORS: &[(u32, &str, &str, &str, &str)] = &[
    (223, "", "", "kyi", "可以"),
    (223, "", "", "yongzwen", "用中文"),
    (530, "", "ni hao\t妮好\n", "nihao", "妮好"),
    (553, "", "", "nihao", "你好"),
    (659, "", "", "v1+2*3", "7"),
    (666, "", "", "v(1.5-0.5)/4", "0.25"),
    (
        697,
        "EmojiSuggest=False\n",
        "mail\tme@example.com\n",
        "mail",
        "me@example.com",
    ),
    (
        702,
        "EmojiSuggest=False\n",
        "di zhi\t四川省\\n宜宾市\n",
        "dizhi",
        "四川省⏎宜宾市",
    ),
];

#[test]
fn first_candidate_vectors() {
    for &(line, ini, custom, keys, first) in FIRST_VECTORS {
        let mut rig = Rig::new();
        rig.configure(ini);
        rig.custom(custom);
        rig.ty(keys);
        assert_eq!(
            rig.page().first().map(String::as_str),
            Some(first),
            "key_harness.cpp:{line} {keys}：{:?}",
            rig.page()
        );
    }
}

#[test]
fn exact_word_and_head_words() {
    // 190-198：单音节不出拆开音节的句首词（dan -> 大）
    let mut rig = Rig::new();
    rig.ty("dan");
    let dan = rig.page();
    assert!(
        !dan.is_empty() && !dan.contains(&"大".to_string()),
        "{dan:?}"
    );
    // 200-215：长句第一页：整句 + 词 + 单字，只差最后一个字的整句只有一个
    rig.fresh();
    rig.ty("hengxianghouxuanci");
    let heng = rig.page();
    let tail_variants = heng
        .iter()
        .filter(|t| t.starts_with("横向候选") && t.chars().count() == 5)
        .count();
    assert!(
        heng.first().map(String::as_str) == Some("横向候选词")
            && tail_variants == 1
            && heng.contains(&"横".to_string()),
        "{heng:?}"
    );
}

#[test]
fn head_word_select_and_undo() {
    // 227-257
    let mut rig = Rig::new();
    rig.ty("nihaozhongguo");
    let at = rig
        .page()
        .iter()
        .position(|t| t == "你好")
        .expect("第一页有句首词 你好");
    rig.ty(&(at + 1).to_string());
    assert_eq!(rig.committed, "", "选句首词不上屏");
    assert_eq!(rig.preedit(), "你好zhong'guo");
    assert_eq!(
        rig.session.preedit_plain_len(),
        "你好".len(),
        "已选的词不加下划线"
    );
    assert_eq!(rig.session.preedit_cursor(), rig.preedit().len());
    // 选句首词时马上记一次选词
    assert_eq!(rig.history("你好"), 1);
    // 退格先撤销最后一次选词，拼音回到编辑区（和 fcitx5 外壳、微信输入法一样），再退格才删字母
    rig.ty("<bs>");
    assert_eq!(rig.preedit(), "ni'hao'zhong'guo", "退格撤销选词");
    rig.ty("<bs><bs><bs><bs><bs><bs><bs><bs>");
    assert_eq!(rig.preedit(), "ni'hao");
    assert!(rig.session.is_composing());
    assert_eq!(rig.session.preedit_plain_len(), 0);
    // 撤销选词不撤销已经记下的那次学习（插件就是这样）
    assert_eq!(rig.history("你好"), 1);
    rig.ty("zhongguo");
    let at = rig.page().iter().position(|t| t == "你好").unwrap();
    rig.ty(&(at + 1).to_string());
    rig.ty("<sp>");
    assert_eq!(rig.committed, "你好中国");
    // 整句也记一次（带每段的拼音），下次能一次打出来
    assert_eq!(rig.history("你好中国"), 1);
    assert_eq!(rig.history("中国"), 1);
}

#[test]
fn paging_and_digits() {
    // 259-269：翻页后数字按当前页选
    let mut rig = Rig::new();
    rig.ty("shi");
    let first = rig.page();
    assert_eq!(first.len(), 9, "默认每页 9 个：{first:?}");
    assert_eq!(rig.labels(), ["1", "2", "3", "4", "5", "6", "7", "8", "9"]);
    assert!(!rig.session.has_prev_page() && rig.session.has_next_page());
    rig.ty("<pgdn>");
    let second = rig.page();
    assert!(!second.is_empty() && second != first, "{second:?}");
    assert!(rig.session.has_prev_page());
    assert_eq!(rig.session.candidate_cursor(), 0, "翻页后光标在这页第一个");
    rig.ty("1");
    assert_eq!(rig.committed, second[0]);

    // = - 也翻页（换个没学过的引擎，免得刚才的选词改了排序）
    let mut rig = Rig::new();
    rig.ty("shi=");
    assert_eq!(rig.page(), second);
    rig.ty("-");
    assert_eq!(rig.page(), first);
    assert_eq!(rig.committed, "");
}

#[test]
fn page_api_like_mouse_wheel() {
    let mut rig = Rig::new();
    rig.ty("shi");
    let first = rig.page();
    assert!(!rig.session.page(-1), "第一页往前翻不动");
    assert!(rig.session.page(1));
    assert_ne!(rig.page(), first);
    while rig.session.page(1) {}
    assert!(!rig.session.has_next_page());
    assert!(rig.session.page(-1));
    assert!(rig.session.has_next_page());
    // 没在编辑时什么也不做
    rig.fresh();
    assert!(!rig.session.page(1));
}

#[test]
fn edge_page_minus_equal_commit_then_symbol() {
    // 插件的行为：第一页按 -、最后一页按 =，翻不动，就当成符号：先上屏当前候选
    let mut rig = Rig::new();
    rig.ty("nihao");
    assert!(!rig.session.has_prev_page() && !rig.session.has_next_page());
    rig.ty("-");
    assert_eq!(rig.committed, "你好-");
    rig.fresh();
    rig.ty("nihao=");
    assert_eq!(rig.committed, "你好=");
}

#[test]
fn grid_expand_move_select() {
    // 277-292：下键展开成每行 6 个的网格
    let mut rig = Rig::new();
    rig.ty("shi");
    assert_eq!(rig.session.columns(), 0);
    assert!(!rig.session.vertical(), "默认横排");
    let first_page = rig.page();
    rig.ty("<down>");
    assert_eq!(rig.session.columns(), 6);
    let grid = rig.page();
    assert!(first_page.len() >= 8 && grid.len() > 6, "{grid:?}");
    assert_eq!(grid[..6], first_page[..6], "第一行 6 个就是第一页的前 6 个");
    assert_eq!(rig.session.candidate_cursor(), 0, "光标框住第一个");
    let labels = rig.labels();
    assert_eq!(labels[..6], ["1", "2", "3", "4", "5", "6"]);
    assert!(
        labels[6..].iter().all(String::is_empty),
        "只有光标所在行有选择键"
    );
    // 293-295：右移两格空格选第三个
    rig.ty("<right><right><sp>");
    assert_eq!(rig.committed, first_page[2]);
    assert_eq!(rig.session.columns(), 0, "上屏后收起");

    // 298-303：下移一行空格选第七个
    rig.fresh();
    rig.ty("zhi");
    let now = rig.page();
    let grid_now = {
        rig.ty("<down>");
        rig.page()
    };
    rig.ty("<down>");
    assert_eq!(rig.session.candidate_cursor(), 6);
    assert_eq!(rig.labels()[6..12], ["1", "2", "3", "4", "5", "6"]);
    assert!(rig.labels()[..6].iter().all(String::is_empty));
    rig.ty("<sp>");
    assert!(now.len() > 6);
    assert_eq!(rig.committed, grid_now[6]);

    // 304-309：数字选光标所在行
    rig.fresh();
    rig.ty("zhi<down><down>2");
    assert_eq!(rig.committed, grid_now[7]);
}

#[test]
fn grid_collapse() {
    // 310-314：在第一行按上键收起
    let mut rig = Rig::new();
    rig.ty("shi");
    let first_page = rig.page();
    rig.ty("<down><down><up><up>");
    assert_eq!(rig.session.columns(), 0);
    assert_eq!(rig.page().len(), first_page.len());
    // 315-318：Esc 只收起，不清空输入
    rig.fresh();
    rig.ty("shi<down><esc>");
    assert_eq!(rig.session.columns(), 0);
    assert_eq!(rig.preedit(), "shi");
    // 319-321：展开后接着打字：收起并照常输入
    rig.ty("<down>j");
    assert_eq!(rig.session.columns(), 0);
    assert_eq!(rig.preedit(), "shi'j");
}

#[test]
fn grid_paging_and_bounds() {
    let mut rig = Rig::new();
    rig.ty("shi<down>");
    let n = rig.page().len();
    assert!(n <= 36);
    // 左键在第一个不动，PageDown 跳到最后一个（一屏装得下）
    rig.ty("<left>");
    assert_eq!(rig.session.candidate_cursor(), 0);
    rig.ty("<pgdn>");
    assert_eq!(rig.session.candidate_cursor(), n - 1);
    rig.ty("<right>");
    assert_eq!(rig.session.candidate_cursor(), n - 1, "最后一个右移不动");
    // PageUp 回到第一屏同一列
    rig.ty("<pgup>");
    assert_eq!(rig.session.candidate_cursor(), (n - 1) % 6);
    // 不在这一行的数字吃掉、不上屏
    rig.ty("9");
    assert_eq!(rig.committed, "");
    assert_eq!(rig.session.columns(), 6);
    // 鼠标点选这一屏的任意一格
    let grid = rig.page();
    assert!(rig.session.select(rig.engine, 8));
    rig.collect();
    assert_eq!(rig.committed, grid[8]);
}

#[test]
fn grid_collapse_keeps_cursor_off_page() {
    // 插件的行为：网格里移到第一页以外再收起，列表回到第一页、光标留在原处（不在这页），
    // 这时空格选这页第一个
    let mut rig = Rig::new();
    rig.configure("EmojiSuggest=False\n");
    rig.ty("shi");
    let first_page = rig.page();
    rig.ty("<down><down><down><esc>");
    assert_eq!(rig.session.columns(), 0);
    assert_eq!(rig.page(), first_page);
    assert_eq!(rig.session.candidate_cursor(), 0);
    rig.ty("<sp>");
    assert_eq!(rig.committed, first_page[0]);
}

#[test]
fn cursor_then_space() {
    // 323-328
    let mut rig = Rig::new();
    rig.ty("shi<right>");
    let list = rig.page();
    assert_eq!(rig.session.candidate_cursor(), 1);
    rig.ty("<sp>");
    assert_eq!(rig.committed, list[1]);
}

#[test]
fn cursor_wraps_across_pages() {
    // fcitx5 的候选列表：光标在第一个时左移，绕到最后一个并翻到那一页
    let mut rig = Rig::new();
    rig.configure("EmojiSuggest=False\n");
    rig.ty("shi<left>");
    assert!(!rig.session.has_next_page() && rig.session.has_prev_page());
    let last = rig.page();
    assert_eq!(rig.session.candidate_cursor(), last.len() - 1);
    rig.ty("<right>");
    assert!(!rig.session.has_prev_page(), "右移绕回第一页第一个");
    assert_eq!(rig.session.candidate_cursor(), 0);
    // 一页的最后一个右移进下一页
    rig.ty("<right><right><right><right><right><right><right><right><right>");
    assert!(rig.session.has_prev_page());
    assert_eq!(rig.session.candidate_cursor(), 0);
}

#[test]
fn tab_moves_candidate_like_fcitx_defaults() {
    // fcitx5 默认热键：Tab 下一个候选、Shift+Tab 上一个
    let mut rig = Rig::new();
    rig.ty("shi");
    let list = rig.page();
    assert!(rig.key(Key::Tab));
    assert_eq!(rig.session.candidate_cursor(), 1);
    assert!(rig.send(Key::Tab, None, mods::SHIFT));
    assert_eq!(rig.session.candidate_cursor(), 0);
    rig.ty("<tab><sp>");
    assert_eq!(rig.committed, list[1]);
    // 没候选（词库还在加载）时吃掉，不交给应用
    let mut bare = Rig::with(None);
    bare.ty("ni");
    assert!(bare.key(Key::Tab));
    assert_eq!(bare.preedit(), "ni");
    // 没在编辑时交给应用
    rig.fresh();
    assert!(!rig.key(Key::Tab));
}

#[test]
fn backspace_and_idle_keys() {
    // 330-335：退格删光后编辑区关闭
    let mut rig = Rig::new();
    rig.ty("ni<bs><bs>");
    assert_eq!(rig.preedit(), "");
    assert!(rig.page().is_empty());
    assert!(!rig.session.is_composing());
    // 没在编辑时退格、回车、Esc、方向键交给应用
    for key in [
        Key::Backspace,
        Key::Return,
        Key::Escape,
        Key::Left,
        Key::Down,
    ] {
        assert!(!rig.key(key), "{key:?}");
    }
    // 没在编辑时：没收录的符号交给应用，开头的隔音符也是
    for c in ['/', '+', '"', '\'', '-', '=', '_'] {
        assert!(!rig.ch(c), "{c}");
    }
    assert_eq!(rig.passed, "/+\"'-=_");
    assert_eq!(rig.committed, "");
    // 收录的标点出中文标点
    for c in ",.?!;:()[]<>\\~@#$%&*".chars() {
        assert!(rig.ch(c), "{c}");
    }
    assert_eq!(rig.committed, "，。？！；：（）【】《》、～＠＃＄％＆＊");
}

#[test]
fn composing_swallows_cursor_keys() {
    let mut rig = Rig::new();
    rig.ty("ni");
    for key in [Key::Delete, Key::Home, Key::End, Key::Tab] {
        assert!(rig.key(key), "{key:?} 编辑中吃掉");
        assert_eq!(rig.preedit(), "ni");
    }
    // 别的功能键（F1……）照 fcitx5 交给应用，编辑区不动
    assert!(!rig.key(Key::Other));
    assert_eq!(rig.preedit(), "ni");
    assert_eq!(rig.committed, "");
    rig.fresh();
    for key in [Key::Delete, Key::Home, Key::End, Key::Other] {
        assert!(!rig.key(key), "{key:?} 没在编辑时交给应用");
    }
}

#[test]
fn modifiers_pass_through() {
    // 374-378、537-538：右 Alt 交给应用，编辑区不动
    let mut rig = Rig::new();
    rig.ty("ni");
    assert!(!rig.key(Key::AltR));
    assert_eq!(rig.preedit(), "ni");
    // Ctrl/Alt/Super 组合键交给应用，编辑区保留
    for m in [mods::CONTROL, mods::ALT, mods::SUPER] {
        assert!(!rig.send(Key::None, Some('a'), m));
        assert!(!rig.send(Key::None, Some(' '), m));
        assert_eq!(rig.preedit(), "ni");
    }
    // 单独的修饰键交给应用
    for key in [
        Key::ControlL,
        Key::ControlR,
        Key::AltL,
        Key::SuperL,
        Key::SuperR,
        Key::CapsLock,
        Key::ShiftL,
    ] {
        assert!(!rig.event(key, None, 0, false));
    }
    assert_eq!(rig.preedit(), "ni");
    assert_eq!(rig.committed, "");
}

#[test]
fn keypad() {
    // 插件的行为：小键盘数字和主键盘数字一样按当前页选词（fcitx 的 Key::isDigit 含 KP_0..KP_9，
    // KeyEvent 的 normalize 去掉了 NumLock），网格里选光标所在行；计算器里算数字。
    // 小键盘 + 不是标点也不选词，交给应用（cpp:1583-1590、1396、1684-1710）
    let mut rig = Rig::new();
    rig.ty("shi");
    let page = rig.page();
    assert!(!rig.send(Key::None, Some('+'), mods::KEYPAD));
    assert_eq!(rig.preedit(), "shi");
    assert!(rig.send(Key::None, Some('2'), mods::KEYPAD));
    let preedit = rig.preedit();
    assert_eq!(
        (
            rig.committed.as_str(),
            preedit.as_str(),
            rig.passed.as_str()
        ),
        (page[1].as_str(), "", "+")
    );
    rig.fresh();
    rig.ty("zhi<down>");
    let grid = rig.page();
    rig.ty("<down>");
    assert!(rig.send(Key::None, Some('2'), mods::KEYPAD));
    assert_eq!(rig.committed, grid[7], "网格里选光标所在行的第 2 个");
    rig.fresh();
    rig.ty("shi");
    assert!(rig.send(Key::None, Some('0'), mods::KEYPAD), "0 吃掉");
    let preedit = rig.preedit();
    assert_eq!((rig.committed.as_str(), preedit.as_str()), ("", "shi"));
    rig.fresh();
    rig.ty("v");
    for c in ['1', '+', '2', '.', '5'] {
        assert!(rig.send(Key::None, Some(c), mods::KEYPAD), "{c}");
    }
    assert_eq!(rig.preedit(), "v1+2.5");
    assert_eq!(rig.page()[0], "3.5");
    // 小键盘回车 = 回车
    assert!(rig.send(Key::Return, None, mods::KEYPAD));
    assert_eq!(rig.committed, "v1+2.5");
    // 没在编辑时都交给应用
    rig.fresh();
    assert!(!rig.send(Key::None, Some('1'), mods::KEYPAD));
    assert!(!rig.send(Key::None, Some('.'), mods::KEYPAD));
    assert!(!rig.send(Key::Return, None, mods::KEYPAD));
}

#[test]
fn im_switch_and_focus_loss() {
    // 342-347：切换输入法时打了一半的字母上屏
    let mut rig = Rig::new();
    rig.ty("nihao");
    rig.session.commit_composition(rig.engine);
    rig.collect();
    assert_eq!(rig.committed, "nihao");
    assert!(!rig.session.is_composing());
    // 已选的词 + 剩下的字母
    rig.fresh();
    rig.ty("nihaozhongguo");
    let at = rig.page().iter().position(|t| t == "你好").unwrap();
    rig.ty(&(at + 1).to_string());
    rig.session.commit_composition(rig.engine);
    rig.collect();
    assert_eq!(rig.committed, "你好zhongguo");
    // 没在编辑时什么也不做
    rig.fresh();
    rig.session.commit_composition(rig.engine);
    assert_eq!(rig.session.take_commit(), None);

    // 349-354：失去焦点不上屏、编辑区清空
    rig.fresh();
    rig.ty("nihao");
    rig.session.reset();
    rig.collect();
    assert_eq!(rig.committed, "");
    assert_eq!(rig.preedit(), "");
    assert!(rig.page().is_empty());
    assert!(!rig.session.is_composing());
}

#[test]
fn many_commits_and_context() {
    // 356-362：连续上屏很多字，上下文按 UTF-8 截断不出错
    let mut rig = Rig::new();
    for _ in 0..30 {
        rig.ty("zhongguo<sp>");
    }
    rig.ty("renmin<sp>");
    assert_eq!(rig.committed, "中国".repeat(30) + "人民");
    // 上下文是最近上屏的 24 字节以内，对齐到字
    let context = rig.engine.unwrap().context();
    assert!(
        context.len() <= 24 && context.ends_with("人民"),
        "{context}"
    );
    assert_eq!(context, "中国中国中国人民");
}

#[test]
fn head_word_context() {
    // 已经选了开头的词时，把它接在上文后面给引擎
    let mut rig = Rig::new();
    rig.ty("wo<sp>");
    rig.ty("nihaozhongguo");
    let at = rig.page().iter().position(|t| t == "你好").unwrap();
    rig.ty(&(at + 1).to_string());
    assert_eq!(rig.engine.unwrap().context(), "我你好");
    rig.ty("<esc>");
    rig.ty("ni");
    assert_eq!(rig.engine.unwrap().context(), "我");
}

#[test]
fn enter_records_raw_letters() {
    // 插件的行为：回车上屏原始字母，并把原始字母记一次选词
    let mut rig = Rig::new();
    rig.ty("nihao<cr>");
    assert_eq!(rig.committed, "nihao");
    assert_eq!(rig.history("nihao"), 1);
    assert_eq!(rig.history("你好"), 0);
    assert!(rig.engine.unwrap().user_words().is_empty());
}

#[test]
fn save_request_every_20_learning_commits() {
    let mut rig = Rig::new();
    for _ in 0..19 {
        rig.ty("nihao<sp>");
    }
    assert!(!rig.session.take_save_request());
    // 标点、Esc 不算学习
    rig.ty(",nihao<esc>");
    assert!(!rig.session.take_save_request());
    rig.ty("nihao<sp>");
    assert!(rig.session.take_save_request());
    assert!(!rig.session.take_save_request(), "取一次就清零");
    for _ in 0..19 {
        rig.ty("ni<cr>");
    }
    assert!(!rig.session.take_save_request());
    rig.ty("ni<cr>");
    assert!(rig.session.take_save_request());
    // 没有引擎时不学习，也不要求存盘
    let mut bare = Rig::with(None);
    for _ in 0..25 {
        bare.ty("ni<sp>");
    }
    assert_eq!(bare.committed, "ni".repeat(25));
    assert!(!bare.session.take_save_request());
}

#[test]
fn shared_state_across_sessions() {
    // 插件里中英文模式、上文、学习计数是插件对象的成员，所有输入框共用
    // （wowtype_engine.h:314-335），只有编辑区、候选是每个输入框自己的
    let mut rig = Rig::new();
    let mut other = Session::in_group(&rig.session.group());
    // 在一个输入框里单按 Shift 切英文，别的输入框也是英文
    assert!(rig.tap_shift(Key::ShiftR, 50));
    assert_eq!(other.mode(), Mode::Ascii);
    rig.swap(&mut other);
    assert!(!rig.ch('a'), "另一个输入框里字母也交给应用");
    assert!(rig.tap_shift(Key::ShiftR, 50));
    rig.swap(&mut other);
    assert_eq!(rig.session.mode(), Mode::Chinese, "切回中文也一起");

    // 上文是全局的：在一个输入框上屏，另一个输入框算候选时接着用
    rig.ty("wo<sp>");
    rig.swap(&mut other);
    rig.ty("ni");
    assert_eq!(rig.engine.unwrap().context(), "我");
    assert_eq!(rig.preedit(), "ni", "编辑区各管各的");
    rig.swap(&mut other);
    assert_eq!(rig.preedit(), "");
    rig.swap(&mut other);
    rig.ty("<esc>");
    rig.swap(&mut other);

    // 学习计数是全局的：两个输入框各 10 次（加上面的 1 次）也凑够 20 次
    for _ in 0..9 {
        rig.ty("nihao<sp>");
    }
    rig.swap(&mut other);
    for _ in 0..9 {
        rig.ty("nihao<sp>");
    }
    assert!(!rig.session.take_save_request());
    rig.swap(&mut other);
    rig.ty("nihao<sp>");
    rig.swap(&mut other);
    assert!(rig.session.take_save_request(), "哪个会话都能取到");
    rig.swap(&mut other);
    assert!(!rig.session.take_save_request(), "取一次就清零");

    // 不在一组的会话互不影响
    let mut alone = Session::new();
    assert!(rig.tap_shift(Key::ShiftR, 50));
    assert_eq!(alone.mode(), Mode::Chinese);
    assert!(!alone.take_save_request());
}

#[test]
fn save_request_on_focus_loss_and_im_switch() {
    // 插件 deactivate（失去焦点、切换输入法）时有没存的学习就存盘（cpp:1805 maybeSaveUserDict(true)）
    let mut rig = Rig::new();
    rig.ty("nihao<sp>");
    assert!(!rig.session.take_save_request());
    rig.session.reset();
    assert!(
        rig.session.take_save_request(),
        "失去焦点：有 1 次没存的学习"
    );
    rig.session.reset();
    assert!(!rig.session.take_save_request(), "没有没存的学习就不要求");
    rig.ty("nihao");
    rig.session.commit_composition(rig.engine);
    rig.collect();
    assert_eq!(rig.committed, "你好nihao");
    assert!(
        rig.session.take_save_request(),
        "切换输入法：原始字母上屏也算一次学习，存盘"
    );
    rig.session.commit_composition(rig.engine);
    assert!(!rig.session.take_save_request());
    // 标点不算学习
    rig.ty(",");
    rig.session.reset();
    assert!(!rig.session.take_save_request());
    // 另一个会话学的、这个会话失去焦点时也存（计数是全局的）
    let mut other = Session::in_group(&rig.session.group());
    rig.ty("nihao<sp>");
    other.reset();
    assert!(rig.session.take_save_request());
}

#[test]
fn emoji_suggestions() {
    // 393-402：kaixin 第三个是 😊，选了只上屏 😊
    let mut rig = Rig::new();
    rig.ty("kaixin");
    let kaixin = rig.page();
    assert!(
        kaixin.len() > 2 && kaixin[0] == "开心" && kaixin[2] == "😊",
        "{kaixin:?}"
    );
    rig.ty("3");
    assert_eq!(rig.committed, "😊");
    // 选 emoji 不学习
    assert_eq!(rig.history("😊"), 0);
    assert_eq!(rig.history("开心"), 0);
    // 403-416：句尾是开心时推荐「开心😊」，上屏整句 + emoji
    rig.fresh();
    rig.ty("jintianhaokaixin");
    let sentence = rig.page();
    let at = sentence
        .iter()
        .position(|t| t == "开心😊")
        .unwrap_or_else(|| panic!("{sentence:?}"));
    rig.ty(&(at + 1).to_string());
    assert_eq!(rig.committed, sentence[0].clone() + "😊");
    // 417-423：单字不推荐 emoji
    rig.fresh();
    rig.ty("shi");
    assert!(!rig.page().contains(&"✅".to_string()), "{:?}", rig.page());
}

#[test]
fn keycap_suggestions() {
    // 475-490：ba -> 吧 八 8️⃣ 把，选了只上屏 8️⃣
    let mut rig = Rig::new();
    rig.ty("ba");
    let ba = rig.page();
    let at = ba
        .iter()
        .position(|t| t == "8️⃣")
        .unwrap_or_else(|| panic!("{ba:?}"));
    assert!(at > 0 && ba[at - 1] == "八", "{ba:?}");
    rig.ty(&(at + 1).to_string());
    assert_eq!(rig.committed, "8️⃣");
    // 491-503：十 后面是 🔟
    rig.fresh();
    rig.ty("shi");
    let shi = rig.page();
    let ten = shi
        .iter()
        .position(|t| t == "十")
        .unwrap_or_else(|| panic!("{shi:?}"));
    assert_eq!(shi[ten + 1], "🔟");
    assert_eq!(shi.iter().filter(|t| *t == "🔟").count(), 1);
    // 504-510：拼音没打完的「八」不跟 8️⃣
    rig.fresh();
    rig.ty("bage");
    assert!(!rig.page().contains(&"8️⃣".to_string()), "{:?}", rig.page());
}

#[test]
fn config_reload() {
    // 512-543：竖排、每页 5 个、关掉 emoji 推荐、自定义词
    let mut rig = Rig::new();
    rig.configure("CandidateLayout=Vertical\nPageSize=5\nVoice=False\nEmojiSuggest=False\n");
    rig.custom("# 测试\nni hao\t妮好\nwo de you xiang\t我的邮箱\n");
    rig.ty("nihao");
    assert!(rig.session.vertical(), "设置竖排后候选竖排");
    let vertical = rig.page();
    assert_eq!(vertical.len(), 5, "{vertical:?}");
    assert_eq!(vertical[0], "妮好");
    assert_eq!(rig.labels(), ["1", "2", "3", "4", "5"]);
    // 竖排时下键移动光标（不翻页、不展开）
    rig.ty("<down>");
    assert_eq!(rig.session.columns(), 0);
    assert_eq!(rig.session.candidate_cursor(), 1);
    rig.ty("<sp>");
    assert_eq!(rig.committed, vertical[1]);
    rig.fresh();
    assert!(!rig.key(Key::AltR), "右 Alt 交给应用");
    rig.ty("wdyx<sp>");
    assert_eq!(rig.committed, "我的邮箱");
    rig.fresh();
    rig.ty("kaixin");
    assert!(
        !rig.page().iter().any(|t| t.contains("😊")),
        "{:?}",
        rig.page()
    );

    // 竖排时左右键翻页
    rig.fresh();
    rig.ty("shi");
    let first = rig.page();
    rig.ty("<right>");
    assert_ne!(rig.page(), first);
    rig.ty("<left>");
    assert_eq!(rig.page(), first);

    // 545-555：设置文本清空后回到默认
    rig.configure("");
    rig.custom("");
    rig.fresh();
    rig.ty("nihao");
    assert!(!rig.session.vertical());
    assert_eq!(rig.page()[0], "你好");
    rig.fresh();
    rig.ty("shi");
    assert_eq!(rig.page().len(), 9);
}

#[test]
fn configure_keeps_composition() {
    let mut rig = Rig::new();
    rig.ty("shi");
    assert_eq!(rig.session.configure("PageSize=5\n"), 0);
    assert_eq!(rig.preedit(), "shi", "改设置不清空编辑区");
    rig.session.refresh(rig.engine);
    assert_eq!(rig.page().len(), 5);
    // 认不出的行计数，其他键照用
    assert_eq!(
        rig.session
            .configure("PageSize=7\nNoSuchKey=1\nCandidateLayout=Diagonal\n"),
        2
    );
    rig.session.refresh(rig.engine);
    assert_eq!(rig.page().len(), 7);
    // 同一个键写两次只看最后一行：最后一行不合法就用默认值（和 fcitx 一样），不留前面的 7
    assert_eq!(rig.session.configure("PageSize=7\nPageSize=99\n"), 1);
    rig.session.refresh(rig.engine);
    assert_eq!(rig.page().len(), 9);
}

#[test]
fn shift_toggle() {
    // 557-576：单按右 Shift 切英文
    let mut rig = Rig::new();
    assert!(rig.tap_shift(Key::ShiftR, 50), "单按右 Shift 被接住");
    assert_eq!(rig.session.mode(), Mode::Ascii);
    rig.ty("nihao,");
    assert_eq!(rig.committed, "");
    assert_eq!(rig.passed, "nihao,");
    assert_eq!(rig.preedit(), "");
    rig.tap_shift(Key::ShiftR, 50);
    assert_eq!(rig.session.mode(), Mode::Chinese);
    rig.fresh();
    rig.ty("nihao<sp>");
    assert_eq!(rig.committed, "你好");
    rig.fresh();
    rig.ty("nih");
    rig.tap_shift(Key::ShiftR, 50);
    assert_eq!(rig.committed, "nih", "打到一半切英文，字母原样上屏");
    assert_eq!(rig.preedit(), "");
    rig.tap_shift(Key::ShiftR, 50);
    assert_eq!(rig.session.mode(), Mode::Chinese);

    // 578-587：Shift 按着打了别的键就不算单按
    rig.fresh();
    rig.event(Key::ShiftR, None, 0, false);
    rig.send(Key::None, Some('A'), mods::SHIFT);
    assert!(!rig.event(Key::ShiftR, None, mods::SHIFT, true));
    rig.ty("<esc>nihao<sp>");
    assert_eq!(rig.committed, "你好");
    assert_eq!(rig.session.mode(), Mode::Chinese);
}

#[test]
fn shift_toggle_rules() {
    let mut rig = Rig::new();
    // 按太久（超过 0.5 秒）不切
    assert!(!rig.tap_shift(Key::ShiftL, 600));
    assert_eq!(rig.session.mode(), Mode::Chinese);
    // 按着 Ctrl 时按 Shift 不算
    rig.event(Key::ShiftL, None, mods::CONTROL, false);
    assert!(!rig.event(Key::ShiftL, None, mods::CONTROL | mods::SHIFT, true));
    // 左按右放不算；之后再松开左 Shift 还算（插件也这样）
    rig.event(Key::ShiftL, None, 0, false);
    assert!(!rig.event(Key::ShiftR, None, mods::SHIFT, true));
    assert_eq!(rig.session.mode(), Mode::Chinese);
    assert!(rig.event(Key::ShiftL, None, mods::SHIFT, true));
    assert_eq!(rig.session.mode(), Mode::Ascii);
    assert!(rig.tap_shift(Key::ShiftL, 50));
    assert_eq!(rig.session.mode(), Mode::Chinese);
    // 只认右 Shift
    rig.configure("ShiftToggle=Right\n");
    assert!(!rig.tap_shift(Key::ShiftL, 50));
    assert!(rig.tap_shift(Key::ShiftR, 50));
    assert_eq!(rig.session.mode(), Mode::Ascii);
    // 关掉时回到中文、不再切换
    rig.configure("ShiftToggle=Off\n");
    assert_eq!(rig.session.mode(), Mode::Chinese);
    assert!(!rig.tap_shift(Key::ShiftR, 50));
    rig.configure("ShiftToggle=Left\n");
    assert!(rig.tap_shift(Key::ShiftL, 50));
    assert_eq!(rig.session.mode(), Mode::Ascii);
    // 英文模式下命名键也交给应用
    assert!(!rig.key(Key::Backspace));
    assert!(!rig.ch('1'));
}

#[test]
fn shuangpin_semicolon() {
    // 613-631：微软双拼分号当 ing；成对之后的分号还是标点
    let mut rig = Rig::new();
    rig.configure("Shuangpin=True\nShuangpinScheme=Microsoft\n");
    rig.ty("x;");
    assert!(
        rig.preedit().contains("xing") && rig.committed.is_empty(),
        "{}",
        rig.preedit()
    );
    rig.ty("<sp>");
    assert_eq!(rig.committed, "行");
    // 双拼时计算器不开：v 后面的数字按选词处理
    rig.fresh();
    rig.ty("vsgo1");
    assert_eq!(rig.committed, "中国");
    // 自然码不用分号：分号是标点
    rig.configure("Shuangpin=True\nShuangpinScheme=Ziranma\n");
    rig.fresh();
    rig.ty("x;");
    assert!(rig.committed.ends_with('；'), "{}", rig.committed);
}

#[test]
fn datetime_candidates() {
    // 633-655：日期时间候选认全拼和简拼（rq、sj），格式从第二个开始（时间来自按键事件）
    let mut rig = Rig::new();
    rig.ty("riqi");
    let items = rig.page();
    assert_eq!(
        items[..3],
        ["日期", "2026年11月10日", "2026-11-10"],
        "{items:?}"
    );
    rig.ty("2");
    assert_eq!(rig.committed, "2026年11月10日");
    rig.fresh();
    rig.ty("shijian");
    assert_eq!(rig.page()[..3], ["时间", "09:05", "09:05:01"]);
    rig.fresh();
    rig.ty("xingqi");
    assert_eq!(rig.page()[..3], ["星期", "星期二", "周二"]);
    rig.fresh();
    rig.ty("sj");
    assert!(rig.page().iter().any(|t| t == "09:05"), "{:?}", rig.page());
    rig.fresh();
    rig.ty("shij");
    assert!(
        !rig.page().iter().any(|t| t.contains(':')),
        "半截拼音不出：{:?}",
        rig.page()
    );
    // 时区来自事件：西五区还是 11 月 9 日 20 点
    rig.fresh();
    rig.utc_offset = -5 * 3600;
    rig.ty("riqi");
    assert_eq!(rig.page()[1], "2026年11月9日");
    // 关掉后不出
    rig.fresh();
    rig.configure("DateTime=False\n");
    rig.ty("riqi");
    assert!(
        !rig.page().iter().any(|t| t.contains('年')),
        "{:?}",
        rig.page()
    );
}

#[test]
fn calculator() {
    // 657-672
    let mut rig = Rig::new();
    rig.ty("v(1.5-0.5)/4");
    assert_eq!(rig.committed, "", "算式里的 . - 不翻页也不上屏");
    rig.fresh();
    rig.ty("very");
    assert!(rig.page().contains(&"very".to_string()), "{:?}", rig.page());
    // 关掉计算器：v1 的 1 按选词处理，之后的 + 没在编辑，交给应用
    rig.fresh();
    rig.configure("Calculator=False\n");
    rig.ty("v");
    let v = rig.page();
    assert!(!v.is_empty(), "{v:?}");
    rig.ty("1+");
    assert!(!rig.session.is_composing());
    assert_eq!(
        (rig.committed.as_str(), rig.passed.as_str()),
        (v[0].as_str(), "+")
    );
}

#[test]
fn fuzzy_groups() {
    // 674-688：n=l 默认关，打开后 liunai 能出牛奶
    let mut rig = Rig::new();
    rig.configure("Fuzzy=True\nTypoCorrection=False\n");
    rig.ty("liunai");
    assert!(
        !rig.page().contains(&"牛奶".to_string()),
        "{:?}",
        rig.page()
    );
    rig.fresh();
    rig.configure("Fuzzy=True\nFuzzyNL=True\nTypoCorrection=False\n");
    rig.ty("liunai");
    assert!(rig.page().contains(&"牛奶".to_string()), "{:?}", rig.page());
}

#[test]
fn custom_codes_and_newline() {
    // 690-706：自定义编码、\n 换行
    let mut rig = Rig::new();
    rig.configure("EmojiSuggest=False\n");
    rig.custom("mail\tme@example.com\ndi zhi\t四川省\\n宜宾市\n");
    rig.ty("mail<sp>");
    assert_eq!(rig.committed, "me@example.com");
    rig.fresh();
    rig.ty("dizhi");
    assert_eq!(rig.page()[0], "四川省⏎宜宾市");
    rig.ty("<sp>");
    assert_eq!(rig.committed, "四川省\n宜宾市", "上屏真的换行");
    // 带换行的词不学习
    assert_eq!(rig.history("四川省\n宜宾市"), 0);
}

#[test]
fn select_keys() {
    // 708-738
    let mut rig = Rig::new();
    rig.configure("SelectKeys=Semicolon\nEmojiSuggest=False\n");
    rig.ty("shi");
    let items = rig.page();
    rig.ty(";");
    assert_eq!(rig.committed, items[1], "分号选第二个");
    rig.fresh();
    rig.configure("SelectKeys=SemicolonQuote\nEmojiSuggest=False\n");
    rig.ty("shi");
    let items = rig.page();
    rig.ty("'");
    assert_eq!(rig.committed, items[2], "引号选第三个");
    // 翻页后按当前页选
    rig.fresh();
    rig.ty("shi<pgdn>");
    let second = rig.page();
    rig.ty(";");
    assert_eq!(rig.committed, second[1]);
    // 微软双拼的分号是 ing，不拿来选词
    rig.fresh();
    rig.configure("SelectKeys=Semicolon\nShuangpin=True\nShuangpinScheme=Microsoft\n");
    rig.ty("x;");
    assert!(rig.preedit().contains("xing"), "{}", rig.preedit());
}

#[test]
fn digits_out_of_range_are_swallowed() {
    let mut rig = Rig::new();
    rig.ty("nihao");
    let n = rig.page().len();
    assert!(n < 9, "{:?}", rig.page());
    assert!(rig.ch(char::from_digit(n as u32 + 1, 10).unwrap()));
    assert!(rig.ch('0'));
    assert_eq!(rig.committed, "");
    assert_eq!(rig.preedit(), "ni'hao");
}

#[test]
fn select_api_like_mouse_click() {
    let mut rig = Rig::new();
    rig.ty("shi<pgdn>");
    let second = rig.page();
    assert!(!rig.session.select(rig.engine, second.len()));
    assert!(rig.session.select(rig.engine, 2));
    rig.collect();
    assert_eq!(rig.committed, second[2]);
    assert!(!rig.session.select(rig.engine, 0), "没在编辑时没有候选");
}

#[test]
fn without_engine() {
    // 词库还在加载：字母照样进编辑区，只是没有候选；空格、回车上屏原始字母
    let mut rig = Rig::with(None);
    rig.ty("nihao");
    assert_eq!(rig.preedit(), "nihao");
    assert_eq!(rig.session.candidate_count(), 0);
    assert_eq!(rig.session.candidate_text(0), None);
    assert_eq!(rig.session.candidate_label(0), None);
    assert_eq!(rig.session.candidate_cursor(), 0);
    assert!(!rig.session.has_next_page());
    rig.ty("<sp>");
    assert_eq!(rig.committed, "nihao");
    rig.fresh();
    rig.ty("nihao,");
    assert_eq!(rig.committed, "nihao，");
    // 词库好了：refresh 后有候选
    rig.fresh();
    rig.ty("nihao");
    rig.engine = Some(leak(engine()));
    rig.session.refresh(rig.engine);
    assert_eq!(rig.page()[0], "你好");
    assert_eq!(rig.preedit(), "ni'hao");
    // 没在编辑时 refresh 什么也不做
    rig.fresh();
    rig.session.refresh(rig.engine);
    assert!(rig.page().is_empty());
    assert_eq!(rig.session.take_commit(), None);
}

#[test]
fn outputs_when_idle() {
    let mut rig = Rig::new();
    let s = &mut rig.session;
    assert!(!s.is_composing());
    assert_eq!(s.preedit(), "");
    assert_eq!((s.preedit_plain_len(), s.preedit_cursor()), (0, 0));
    assert_eq!(s.aux(), "");
    assert_eq!(s.candidate_count(), 0);
    assert_eq!(s.columns(), 0);
    assert_eq!(s.mode(), Mode::Chinese);
}

#[test]
fn releases_are_ignored() {
    let mut rig = Rig::new();
    assert!(!rig.event(Key::None, Some('n'), 0, true));
    assert!(!rig.session.is_composing());
}

#[test]
fn session_constants_match_the_header() {
    // C ABI 的 #define 和 Rust 里的值一致
    let header = include_str!("../include/wowtype_core.h");
    let value = |name: &str| -> u32 {
        let at = header
            .find(&format!("#define {name} "))
            .unwrap_or_else(|| panic!("{name}"));
        let rest = header[at + name.len() + 9..].trim_start();
        let number = |text: &str| -> u32 {
            text[..text
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(text.len())]
                .parse()
                .unwrap_or_else(|_| panic!("{name}: {text:.20}"))
        };
        // 取值是数字或 (1u << n)
        match rest.strip_prefix("(1u << ") {
            Some(shift) => 1 << number(shift),
            None => number(rest),
        }
    };
    use wowtype_core::session::{self as core, modifier};
    for (name, v) in [
        ("WOWTYPE_SESSION_KEYS_SELECT", keys::SELECT),
        ("WOWTYPE_SESSION_KEYS_PUNCT", keys::PUNCT),
        ("WOWTYPE_SESSION_KEYS_MODE", keys::MODE),
        ("WOWTYPE_SESSION_KEYS_ALL", keys::ALL),
        ("WOWTYPE_MOD_SHIFT", modifier::SHIFT),
        ("WOWTYPE_MOD_CAPS", modifier::CAPS),
        ("WOWTYPE_MOD_CTRL", modifier::CTRL),
        ("WOWTYPE_MOD_ALT", modifier::ALT),
        ("WOWTYPE_MOD_SUPER", modifier::SUPER),
        ("WOWTYPE_MODE_CHINESE", core::Mode::Chinese as u32),
        ("WOWTYPE_MODE_ENGLISH", core::Mode::English as u32),
        ("WOWTYPE_PANEL_LIST", core::Panel::List as u32),
        ("WOWTYPE_PANEL_GRID", core::Panel::Grid as u32),
        ("WOWTYPE_GRID_COLS", core::GRID_COLS as u32),
        ("WOWTYPE_SELECT_KEYS_OFF", 0),
        ("WOWTYPE_SELECT_KEYS_SEMICOLON", 1),
        ("WOWTYPE_SELECT_KEYS_SEMICOLON_QUOTE", 2),
        ("WOWTYPE_SHIFT_TOGGLE_BOTH", 0),
        ("WOWTYPE_SHIFT_TOGGLE_LEFT", 1),
        ("WOWTYPE_SHIFT_TOGGLE_RIGHT", 2),
        ("WOWTYPE_SHIFT_TOGGLE_OFF", 3),
    ] {
        assert_eq!(value(name), v, "{name}");
    }
}
