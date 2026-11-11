//! 输入会话的 C 接口（`wowtype_session_*`），见 core/include/wowtype_core.h 和 docs/ABI.md。
//!
//! 会话返回的指针（`WowtypeFrame` 和里面的字符串、过渡函数返回的字符串）归会话所有，
//! 在同一个会话的下一次调用前有效。

#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::mem::size_of;
use std::os::raw::{c_char, c_int};
use std::panic;
use std::ptr;

use crate::config::{SelectKeys, ShiftToggle};
use crate::ffi::{set_last_error, WowtypeEngineHandle};
use crate::session::{Candidate, CandidateKind, Config, Frame, Key, Mode, Panel, Session};

/// 一次按键（C 布局）。`size` 是外壳编译时的 `sizeof(WowtypeKey)`：
/// 以后在末尾加字段，旧外壳传的 size 小，没传的字段当 0。
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WowtypeKey {
    pub size: u32,
    pub keysym: u32,
    pub modifiers: u32,
    pub release: u32,
    pub prev_char: u32,
    /// 对齐（头文件里的 pad_），不用。
    pub pad_: u32,
    /// 按键时刻（单调时钟，毫秒），0 表示不知道（ABI 1.6）。
    pub time_ms: u64,
}

/// 会话的设置（C 布局）。外壳没填的字段（size 比我们认识的短）用默认值。
#[repr(C)]
#[derive(Clone, Copy)]
pub struct WowtypeSessionConfig {
    pub size: u32,
    /// 一页几个候选；0 用默认（9）。
    pub page_size: u32,
    pub calculator: c_int,
    pub date_time: c_int,
    pub emoji_suggest: c_int,
    // ---- ABI 1.6 ----
    /// 会话处理哪几块按键（WOWTYPE_SESSION_KEYS_*），默认 0。
    pub keys: u32,
    pub vertical: c_int,
    /// WOWTYPE_SELECT_KEYS_*。
    pub select_keys: c_int,
    /// WOWTYPE_SHIFT_TOGGLE_*。
    pub shift_toggle: c_int,
    pub page_minus: c_int,
    pub page_bracket: c_int,
    pub page_comma: c_int,
    pub page_tab: c_int,
    pub punct_halfwidth: c_int,
}

/// C 里的取值就是在表里的下标（WOWTYPE_SELECT_KEYS_*、WOWTYPE_SHIFT_TOGGLE_*）。
const SELECT_KEYS: [SelectKeys; 3] = [
    SelectKeys::Off,
    SelectKeys::Semicolon,
    SelectKeys::SemicolonQuote,
];
const SHIFT_TOGGLES: [ShiftToggle; 4] = [
    ShiftToggle::Both,
    ShiftToggle::Left,
    ShiftToggle::Right,
    ShiftToggle::Off,
];

fn index_of<T: PartialEq>(table: &[T], value: &T) -> c_int {
    table.iter().position(|v| v == value).unwrap_or(0) as c_int
}

impl WowtypeSessionConfig {
    fn from_config(config: &Config) -> Self {
        Self {
            size: size_of::<WowtypeSessionConfig>() as u32,
            page_size: config.page_size as u32,
            calculator: c_int::from(config.calculator),
            date_time: c_int::from(config.date_time),
            emoji_suggest: c_int::from(config.emoji_suggest),
            keys: config.keys,
            vertical: c_int::from(config.vertical),
            select_keys: index_of(&SELECT_KEYS, &config.select_keys),
            shift_toggle: index_of(&SHIFT_TOGGLES, &config.shift_toggle),
            page_minus: c_int::from(config.page_minus),
            page_bracket: c_int::from(config.page_bracket),
            page_comma: c_int::from(config.page_comma),
            page_tab: c_int::from(config.page_tab),
            punct_halfwidth: c_int::from(config.punct_halfwidth),
        }
    }

    fn to_config(self) -> Config {
        let default = Config::default();
        let pick = |value: c_int, n: usize| usize::try_from(value).ok().filter(|&i| i < n);
        Config {
            page_size: if self.page_size == 0 {
                default.page_size
            } else {
                self.page_size as usize
            },
            calculator: self.calculator != 0,
            date_time: self.date_time != 0,
            emoji_suggest: self.emoji_suggest != 0,
            keys: self.keys,
            vertical: self.vertical != 0,
            select_keys: pick(self.select_keys, SELECT_KEYS.len())
                .map_or(default.select_keys, |i| SELECT_KEYS[i]),
            shift_toggle: pick(self.shift_toggle, SHIFT_TOGGLES.len())
                .map_or(default.shift_toggle, |i| SHIFT_TOGGLES[i]),
            page_minus: self.page_minus != 0,
            page_bracket: self.page_bracket != 0,
            page_comma: self.page_comma != 0,
            page_tab: self.page_tab != 0,
            punct_halfwidth: self.punct_halfwidth != 0,
        }
    }
}

impl Default for WowtypeSessionConfig {
    fn default() -> Self {
        Self::from_config(&Config::default())
    }
}

/// 过渡：一个候选的全部信息（C 布局），字段含义见头文件。
#[repr(C)]
#[derive(Clone, Copy)]
pub struct WowtypeCandidateInfo {
    pub size: u32,
    pub text: *const c_char,
    pub pinyin: *const c_char,
    pub consumed: usize,
    pub kind: c_int,
    pub commit: *const c_char,
    pub emoji: *const c_char,
}

pub const WOWTYPE_CAND_WORD: c_int = 0;
pub const WOWTYPE_CAND_PLAIN: c_int = 1;
pub const WOWTYPE_CAND_EMOJI: c_int = 2;

/// 一个候选的 C 字符串（随候选重算重建）。
struct CCandidate {
    text: CString,
    pinyin: CString,
    commit: CString,
    emoji: CString,
    consumed: usize,
    kind: c_int,
}

impl CCandidate {
    fn new(c: &Candidate) -> Self {
        Self {
            text: to_c(&c.text),
            pinyin: to_c(&c.pinyin),
            commit: to_c(&c.commit),
            emoji: to_c(&c.emoji),
            consumed: c.consumed,
            kind: match c.kind {
                CandidateKind::Word => WOWTYPE_CAND_WORD,
                CandidateKind::Plain => WOWTYPE_CAND_PLAIN,
                CandidateKind::Emoji => WOWTYPE_CAND_EMOJI,
            },
        }
    }
}

/// 一次调用之后外壳要做的事（C 布局），字段含义见头文件。
#[repr(C)]
pub struct WowtypeFrame {
    pub size: u32,
    pub handled: c_int,
    pub commit: *const c_char,
    pub preedit: *const c_char,
    pub preedit_cursor: c_int,
    pub aux: *const c_char,
    pub panel: c_int,
    pub cand_count: usize,
    pub cand_cursor: c_int,
    pub has_prev: c_int,
    pub has_next: c_int,
    pub wake_after_ms: u32,
    // ---- ABI 1.6 ----
    /// 这一屏第一个候选在全部候选里的序号（candidate_info 用它加上屏内位置）。
    pub cand_offset: usize,
    /// WOWTYPE_MODE_*。
    pub mode: c_int,
    /// 这次上屏记了选词（外壳攒着存用户词库）。
    pub learned: c_int,
}

impl Default for WowtypeFrame {
    fn default() -> Self {
        Self {
            size: size_of::<WowtypeFrame>() as u32,
            handled: 0,
            commit: ptr::null(),
            preedit: ptr::null(),
            preedit_cursor: 0,
            aux: ptr::null(),
            panel: 0,
            cand_count: 0,
            cand_cursor: 0,
            has_prev: 0,
            has_next: 0,
            wake_after_ms: 0,
            cand_offset: 0,
            mode: 0,
            learned: 0,
        }
    }
}

/// 会话句柄。引擎借用的是外壳的 `WowtypeEngineHandle`，外壳保证它比会话活得久
/// （或者先 set_engine(NULL)）。
pub struct WowtypeSession {
    session: Session<'static>,
    /// 候选的 C 字符串，和 `c_generation` 那次重算的候选对应。
    c_candidates: Vec<CCandidate>,
    c_generation: u64,
    frame: WowtypeFrame,
    commit: Option<CString>,
    preedit: CString,
    /// 过渡函数返回的字符串。
    text: CString,
}

fn to_c(text: &str) -> CString {
    CString::new(text.replace('\0', " ")).unwrap_or_default()
}

unsafe fn arg(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

/// 按 size 读一个带 size 字段的结构体：外壳给的比我们认识的短，缺的字段当 0。
unsafe fn read_sized<T: Copy + Default>(ptr: *const T, size: u32) -> T {
    let mut value = T::default();
    let len = (size as usize).min(size_of::<T>());
    unsafe {
        ptr::copy_nonoverlapping(ptr as *const u8, &mut value as *mut T as *mut u8, len);
    }
    value
}

impl WowtypeSession {
    fn publish(&mut self, frame: Frame) -> *const WowtypeFrame {
        self.commit = frame.commit.as_deref().map(to_c);
        self.preedit = to_c(&frame.preedit);
        self.frame = WowtypeFrame {
            handled: c_int::from(frame.handled),
            commit: self.commit.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
            preedit: self.preedit.as_ptr(),
            preedit_cursor: frame.preedit_cursor.try_into().unwrap_or(c_int::MAX),
            panel: match frame.panel {
                Panel::List => 0,
                Panel::Grid => 1,
            },
            cand_count: frame.cand_count,
            cand_cursor: frame.cand_cursor.try_into().unwrap_or(0),
            has_prev: c_int::from(frame.has_prev),
            has_next: c_int::from(frame.has_next),
            cand_offset: frame.cand_offset,
            mode: frame.mode as c_int,
            learned: c_int::from(frame.learned),
            ..WowtypeFrame::default()
        };
        &self.frame
    }

    fn text(&mut self, text: &str) -> *const c_char {
        self.text = to_c(text);
        self.text.as_ptr()
    }

    /// 现在的编辑区；算候选时出了 panic 就当没有候选。
    fn current(&mut self, handled: bool) -> *const WowtypeFrame {
        let inner = &mut self.session;
        let frame = match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.frame(handled))) {
            Ok(frame) => frame,
            Err(_) => {
                set_last_error("session panicked");
                let preedit = self.session.selected_text() + self.session.remaining();
                Frame {
                    handled,
                    commit: None,
                    preedit_cursor: preedit.len(),
                    preedit,
                    ..Frame::default()
                }
            }
        };
        self.publish(frame)
    }

    fn c_candidates(&mut self) -> &[CCandidate] {
        let inner = &mut self.session;
        let computed = panic::catch_unwind(panic::AssertUnwindSafe(|| {
            inner.candidates();
        }));
        if computed.is_err() {
            set_last_error("session panicked");
            self.c_candidates.clear();
            return &self.c_candidates;
        }
        if self.session.generation() != self.c_generation {
            self.c_candidates = self
                .session
                .candidates()
                .iter()
                .map(CCandidate::new)
                .collect();
            self.c_generation = self.session.generation();
        }
        &self.c_candidates
    }
}

unsafe fn engine_ref(engine: *mut WowtypeEngineHandle) -> Option<&'static crate::Engine> {
    unsafe { engine.as_ref() }.map(|handle| &handle.engine)
}

/// 建会话。engine 可以传 NULL（外壳的词库在后台载入，载入好之前也要能打字，载入好了
/// 用 set_engine 补上）；传了的话要比会话活得久。config 可以传 NULL（全用默认）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_new(
    engine: *mut WowtypeEngineHandle,
    config: *const WowtypeSessionConfig,
) -> *mut WowtypeSession {
    let mut session = Session::new();
    session.set_engine(unsafe { engine_ref(engine) });
    if !config.is_null() {
        session.configure(unsafe { read_sized(config, (*config).size) }.to_config());
    }
    let mut handle = Box::new(WowtypeSession {
        session,
        c_candidates: Vec::new(),
        c_generation: 0,
        frame: WowtypeFrame::default(),
        commit: None,
        preedit: CString::default(),
        text: CString::default(),
    });
    handle.current(false);
    Box::into_raw(handle)
}

/// 换引擎（词库在后台载入好了），可以传 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_set_engine(
    session: *mut WowtypeSession,
    engine: *mut WowtypeEngineHandle,
) {
    if let Some(handle) = unsafe { session.as_mut() } {
        handle.session.set_engine(unsafe { engine_ref(engine) });
    }
}

/// 改设置。config 为 NULL 时全用默认。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_configure(
    session: *mut WowtypeSession,
    config: *const WowtypeSessionConfig,
) {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return;
    };
    let config = if config.is_null() {
        Config::default()
    } else {
        unsafe { read_sized(config, (*config).size) }.to_config()
    };
    handle.session.configure(config);
}

/// 现在的编辑区（不处理按键，handled 为 0）。session 为 NULL 时返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_frame(
    session: *mut WowtypeSession,
) -> *const WowtypeFrame {
    match unsafe { session.as_mut() } {
        Some(handle) => handle.current(false),
        None => ptr::null(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_session_free(session: *mut WowtypeSession) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// 处理一次按键。session 或 key 为 NULL 时返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_key(
    session: *mut WowtypeSession,
    key: *const WowtypeKey,
) -> *const WowtypeFrame {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    if key.is_null() {
        set_last_error("key is null");
        return ptr::null();
    }
    let raw = unsafe { read_sized(key, (*key).size) };
    let key = Key {
        keysym: raw.keysym,
        modifiers: raw.modifiers,
        release: raw.release != 0,
        prev_char: char::from_u32(raw.prev_char).filter(|&c| c != '\0'),
        time_ms: raw.time_ms,
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.key(&key))) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session key panicked");
            handle.current(false)
        }
    }
}

/// 清空编辑区；commit_pending 非 0 时把已选的词和原始输入放进 frame->commit。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_reset(
    session: *mut WowtypeSession,
    commit_pending: c_int,
) -> *const WowtypeFrame {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.reset(commit_pending != 0))) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session reset panicked");
            handle.current(false)
        }
    }
}

/// 鼠标点选这一屏的第 index 个候选（frame->cand_offset 起，ABI 1.6）。没有这个候选时 handled 为 0。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_select(
    session: *mut WowtypeSession,
    index: usize,
) -> *const WowtypeFrame {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.select(index))) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session select panicked");
            handle.current(false)
        }
    }
}

/// 换中英文模式（WOWTYPE_MODE_*，外壳在输入框之间同步用，ABI 1.6）。不认识的取值不改。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_set_mode(session: *mut WowtypeSession, mode: c_int) {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return;
    };
    match mode {
        0 => handle.session.set_mode(Mode::Chinese),
        1 => handle.session.set_mode(Mode::English),
        _ => set_last_error("unknown session mode"),
    }
}

/// 由设置文本（格式同 wowtype_engine_configure）填会话设置，keys 填进 out->keys（ABI 1.6）。
/// 按 out->size 写；没写的键用默认值。返回认不出的行数，参数为 NULL 时返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_config_parse(
    ini_text: *const c_char,
    keys: u32,
    out: *mut WowtypeSessionConfig,
) -> c_int {
    if ini_text.is_null() || out.is_null() {
        set_last_error("null argument");
        return -1;
    }
    let text = unsafe { arg(ini_text) };
    let (settings, bad) = crate::config::parse(&text);
    let len = (unsafe { (*out).size } as usize).min(size_of::<WowtypeSessionConfig>());
    let config = WowtypeSessionConfig {
        size: len as u32,
        ..WowtypeSessionConfig::from_config(&Config::from_settings(&settings, keys))
    };
    unsafe {
        ptr::copy_nonoverlapping(&config as *const _ as *const u8, out as *mut u8, len);
    }
    bad.try_into().unwrap_or(c_int::MAX)
}

// ---- 过渡函数：外壳还没挪完时用，挪完以后删掉（见 docs/ABI.md）----

/// 全部原始输入（含已选词用掉的部分）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_input(session: *mut WowtypeSession) -> *const c_char {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let text = handle.session.input().to_owned();
    handle.text(&text)
}

/// 还没选词的那部分原始输入。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_remaining(session: *mut WowtypeSession) -> *const c_char {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let text = handle.session.remaining().to_owned();
    handle.text(&text)
}

/// 已选的词连起来。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_selected_text(
    session: *mut WowtypeSession,
) -> *const c_char {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let text = handle.session.selected_text();
    handle.text(&text)
}

/// 选第 index 个候选（全部候选里的序号，不分页）：句首词进已选栈，其余上屏并记选词，
/// 见 `Session::choose`。序号不对时 handled 为 0。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_choose(
    session: *mut WowtypeSession,
    index: usize,
) -> *const WowtypeFrame {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.choose(index))) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session choose panicked");
            handle.current(false)
        }
    }
}

/// 上屏已选的词 + 还没选的原始输入，原始输入也记一次选词（回车、打字途中按标点）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_commit_input(
    session: *mut WowtypeSession,
) -> *const WowtypeFrame {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.commit_input())) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session commit panicked");
            handle.current(false)
        }
    }
}

/// 往原始输入后面加字（计算器、双拼分号、表情面板搜索词）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_append(session: *mut WowtypeSession, text: *const c_char) {
    if let Some(handle) = unsafe { session.as_mut() } {
        let text = unsafe { arg(text) };
        handle.session.append(&text);
    }
}

/// 光标前已经上屏的字（外壳记的上文）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_set_context(
    session: *mut WowtypeSession,
    text: *const c_char,
) {
    if let Some(handle) = unsafe { session.as_mut() } {
        let text = unsafe { arg(text) };
        handle.session.set_context(&text);
    }
}

/// 全部候选的个数（不分页）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_candidate_total(session: *mut WowtypeSession) -> usize {
    unsafe { session.as_mut() }.map_or(0, |handle| handle.c_candidates().len())
}

/// 第 index 个候选（不分页）写进 out（按 out->size 写）。返回 0 成功，-1 越界或参数为 NULL。
/// 字符串在同一会话下一次改了编辑区或设置的调用前有效。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_candidate_info(
    session: *mut WowtypeSession,
    index: usize,
    out: *mut WowtypeCandidateInfo,
) -> c_int {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return -1;
    };
    if out.is_null() {
        return -1;
    }
    let Some(c) = handle.c_candidates().get(index) else {
        return -1;
    };
    let len = (unsafe { (*out).size } as usize).min(size_of::<WowtypeCandidateInfo>());
    let info = WowtypeCandidateInfo {
        size: len as u32,
        text: c.text.as_ptr(),
        pinyin: c.pinyin.as_ptr(),
        consumed: c.consumed,
        kind: c.kind,
        commit: c.commit.as_ptr(),
        emoji: c.emoji.as_ptr(),
    };
    unsafe {
        ptr::copy_nonoverlapping(&info as *const _ as *const u8, out as *mut u8, len);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::keysym;

    fn press(session: *mut WowtypeSession, keysym: u32) -> &'static WowtypeFrame {
        let key = WowtypeKey {
            size: size_of::<WowtypeKey>() as u32,
            keysym,
            ..WowtypeKey::default()
        };
        unsafe { &*wowtype_session_key(session, &key) }
    }

    fn c(ptr: *const c_char) -> String {
        assert!(!ptr.is_null());
        unsafe { CStr::from_ptr(ptr) }.to_str().unwrap().to_owned()
    }

    #[test]
    fn roundtrip() {
        let session = unsafe { wowtype_session_new(ptr::null_mut(), ptr::null()) };
        assert!(!session.is_null());
        for ch in "nihaoma".bytes() {
            assert_eq!(press(session, u32::from(ch)).handled, 1);
        }
        assert_eq!(c(unsafe { wowtype_session_remaining(session) }), "nihaoma");
        // 没有引擎：没有候选，选不了
        assert_eq!(unsafe { wowtype_session_candidate_total(session) }, 0);
        assert_eq!(unsafe { &*wowtype_session_choose(session, 0) }.handled, 0);

        let frame = press(session, keysym::BACKSPACE);
        assert_eq!(frame.handled, 1);
        assert!(frame.commit.is_null());
        assert_eq!(c(frame.preedit), "nihaom");
        assert_eq!(frame.size as usize, size_of::<WowtypeFrame>());

        let frame = unsafe { &*wowtype_session_reset(session, 1) };
        assert_eq!(c(frame.commit), "nihaom");
        assert_eq!(c(frame.preedit), "");
        unsafe { wowtype_session_free(session) };
    }

    #[test]
    fn short_key_struct_is_zero_extended() {
        // 旧外壳的 WowtypeKey 只到 keysym：后面的字段当 0（没有修饰键、按下）
        let session = unsafe { wowtype_session_new(ptr::null_mut(), ptr::null()) };
        let key = WowtypeKey {
            size: 8,
            keysym: u32::from(b'a'),
            modifiers: 0xffff,
            release: 1,
            prev_char: 0,
            pad_: 0,
            time_ms: 0,
        };
        let frame = unsafe { &*wowtype_session_key(session, &key) };
        assert_eq!(frame.handled, 1);
        assert_eq!(c(frame.preedit), "a");
        unsafe { wowtype_session_free(session) };
    }

    fn engine() -> WowtypeEngineHandle {
        use crate::lm::BigramLm;
        use crate::{Engine, MemoryLexicon};
        use std::sync::Arc;
        let tsv: String = (0..20)
            .map(|i| format!("shi\t字{i:02}\t{}\n", 1000 - i))
            .collect();
        let lexicon = Arc::new(MemoryLexicon::from_tsv_str(&tsv).unwrap());
        WowtypeEngineHandle {
            engine: Engine::new(lexicon, Arc::new(BigramLm::default())),
        }
    }

    fn type_text(session: *mut WowtypeSession, text: &str) -> &'static WowtypeFrame {
        let mut frame = None;
        for ch in text.bytes() {
            frame = Some(press(session, u32::from(ch)));
        }
        frame.unwrap()
    }

    #[test]
    fn config_parse_fills_by_size() {
        let ini = c"SelectKeys=SemicolonQuote\nShiftToggle=Right\nPageSize=5\n\
                    CandidateLayout=Vertical\nPunctuationStyle=Halfwidth\nPageKeysTab=True\nNoSuch=1\n";
        let mut out = WowtypeSessionConfig::default();
        let bad = unsafe {
            wowtype_session_config_parse(ini.as_ptr(), crate::session::keys::ALL, &mut out)
        };
        assert_eq!(bad, 1);
        assert_eq!(out.size as usize, size_of::<WowtypeSessionConfig>());
        assert_eq!(out.keys, crate::session::keys::ALL);
        assert_eq!(
            (out.page_size, out.vertical, out.punct_halfwidth),
            (5, 1, 1)
        );
        assert_eq!((out.select_keys, out.shift_toggle), (2, 2));
        assert_eq!((out.page_minus, out.page_tab), (1, 1));
        // 旧外壳的结构体短：只写到 size 为止
        let mut short = WowtypeSessionConfig {
            size: 8,
            keys: 77,
            vertical: 77,
            ..WowtypeSessionConfig::default()
        };
        assert_eq!(
            unsafe { wowtype_session_config_parse(ini.as_ptr(), 1, &mut short) },
            1
        );
        assert_eq!((short.size, short.page_size), (8, 5));
        assert_eq!((short.keys, short.vertical), (77, 77), "size 之外不写");
        // 取值越界的回到默认
        let config = WowtypeSessionConfig {
            select_keys: 9,
            shift_toggle: -1,
            ..WowtypeSessionConfig::default()
        }
        .to_config();
        assert_eq!(config.select_keys, Config::default().select_keys);
        assert_eq!(config.shift_toggle, Config::default().shift_toggle);
        assert_eq!(
            unsafe { wowtype_session_config_parse(ptr::null(), 0, &mut out) },
            -1
        );
        assert_eq!(
            unsafe { wowtype_session_config_parse(ini.as_ptr(), 0, ptr::null_mut()) },
            -1
        );
    }

    #[test]
    fn keys_default_off_keeps_1_5_behavior() {
        let mut engine = engine();
        let session = unsafe { wowtype_session_new(&mut engine, ptr::null()) };
        let frame = type_text(session, "shi");
        assert_eq!((frame.cand_count, frame.mode, frame.learned), (0, 0, 0));
        assert_eq!(press(session, u32::from(b' ')).handled, 0, "空格还归外壳");
        assert_eq!(press(session, u32::from(b',')).handled, 0, "标点还归外壳");
        unsafe { wowtype_session_free(session) };
    }

    #[test]
    fn select_mode_and_screen_fields() {
        let mut engine = engine();
        let config = WowtypeSessionConfig {
            keys: crate::session::keys::ALL,
            page_size: 5,
            ..WowtypeSessionConfig::default()
        };
        let session = unsafe { wowtype_session_new(&mut engine, &config) };
        let frame = type_text(session, "shi");
        assert_eq!(
            (frame.panel, frame.cand_offset, frame.cand_count),
            (0, 0, 5)
        );
        assert_eq!((frame.has_prev, frame.has_next), (0, 1));
        let frame = press(session, keysym::PAGE_DOWN);
        assert_eq!(
            (frame.cand_offset, frame.cand_count, frame.has_prev),
            (5, 5, 1)
        );
        let mut info = WowtypeCandidateInfo {
            size: size_of::<WowtypeCandidateInfo>() as u32,
            ..unsafe { std::mem::zeroed() }
        };
        assert_eq!(
            unsafe { wowtype_session_candidate_info(session, frame.cand_offset + 1, &mut info) },
            0
        );
        let want = c(info.text);
        let frame = unsafe { &*wowtype_session_select(session, 1) };
        assert_eq!(frame.handled, 1);
        assert_eq!(c(frame.commit), want);
        assert_eq!(frame.learned, 1);
        assert_eq!(
            unsafe { &*wowtype_session_select(session, 0) }.handled,
            0,
            "没在打字"
        );
        // 展开面板
        type_text(session, "shi");
        let frame = press(session, keysym::DOWN);
        assert_eq!(frame.panel, 1);
        assert!(frame.cand_count > 5);
        assert_eq!(press(session, keysym::ESCAPE).panel, 0, "Esc 先收起面板");
        assert_eq!(c(press(session, keysym::ESCAPE).preedit), "", "再按清空");
        // 中英文模式
        assert_eq!(unsafe { &*wowtype_session_frame(session) }.mode, 0);
        unsafe { wowtype_session_set_mode(session, 1) };
        assert_eq!(unsafe { &*wowtype_session_frame(session) }.mode, 1);
        assert_eq!(
            press(session, u32::from(b'a')).handled,
            0,
            "英文模式交给应用"
        );
        unsafe { wowtype_session_set_mode(session, 7) };
        assert_eq!(
            unsafe { &*wowtype_session_frame(session) }.mode,
            1,
            "不认识的取值不改"
        );
        unsafe { wowtype_session_set_mode(session, 0) };
        assert_eq!(press(session, u32::from(b'a')).handled, 1);
        unsafe { wowtype_session_free(session) };
        unsafe { wowtype_session_set_mode(ptr::null_mut(), 1) };
        assert!(unsafe { wowtype_session_select(ptr::null_mut(), 0) }.is_null());
    }

    #[test]
    fn shift_tap_uses_time_ms() {
        let config = WowtypeSessionConfig {
            keys: crate::session::keys::ALL,
            ..WowtypeSessionConfig::default()
        };
        let session = unsafe { wowtype_session_new(ptr::null_mut(), &config) };
        let shift = |release: u32, modifiers: u32, time_ms: u64| {
            let key = WowtypeKey {
                size: size_of::<WowtypeKey>() as u32,
                keysym: keysym::SHIFT_L,
                modifiers,
                release,
                time_ms,
                ..WowtypeKey::default()
            };
            unsafe { &*wowtype_session_key(session, &key) }.mode
        };
        shift(0, 0, 1000);
        assert_eq!(shift(1, 1, 1100), 1, "快按快松切到英文");
        shift(0, 0, 2000);
        assert_eq!(shift(1, 1, 2900), 1, "按太久不切");
        unsafe { wowtype_session_free(session) };
    }

    #[test]
    fn null_handles() {
        assert!(unsafe { wowtype_session_key(ptr::null_mut(), ptr::null()) }.is_null());
        assert!(unsafe { wowtype_session_reset(ptr::null_mut(), 0) }.is_null());
        assert_eq!(
            unsafe { wowtype_session_candidate_total(ptr::null_mut()) },
            0
        );
        assert!(unsafe { wowtype_session_choose(ptr::null_mut(), 0) }.is_null());
        assert!(unsafe { wowtype_session_commit_input(ptr::null_mut()) }.is_null());
        unsafe { wowtype_session_free(ptr::null_mut()) };
    }
}
