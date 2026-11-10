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

use crate::ffi::{set_last_error, WowtypeEngineHandle};
use crate::session::{Frame, Key, Selection, Session};

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
}

/// 建会话时的设置（C 布局）。现在没有可设的项，只有 size；可以传 NULL。
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct WowtypeSessionConfig {
    pub size: u32,
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
        }
    }
}

/// 会话句柄。
pub struct WowtypeSession {
    session: Session,
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
            ..WowtypeFrame::default()
        };
        &self.frame
    }

    fn text(&mut self, text: &str) -> *const c_char {
        self.text = to_c(text);
        self.text.as_ptr()
    }
}

/// 建会话。engine 现在还不用，可以传 NULL（外壳的词库在后台载入，载入好之前也要能打字）；
/// 传了的话要比会话活得久。config 可以传 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_new(
    _engine: *mut WowtypeEngineHandle,
    _config: *const WowtypeSessionConfig,
) -> *mut WowtypeSession {
    let mut handle = Box::new(WowtypeSession {
        session: Session::new(),
        frame: WowtypeFrame::default(),
        commit: None,
        preedit: CString::default(),
        text: CString::default(),
    });
    let frame = handle.session.frame(false);
    handle.publish(frame);
    Box::into_raw(handle)
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
    };
    let inner = &mut handle.session;
    match panic::catch_unwind(panic::AssertUnwindSafe(|| inner.key(&key))) {
        Ok(frame) => handle.publish(frame),
        Err(_) => {
            set_last_error("session key panicked");
            let frame = handle.session.frame(false);
            handle.publish(frame)
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
    let frame = handle.session.reset(commit_pending != 0);
    handle.publish(frame)
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

/// 已选词的个数。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_selection_count(session: *const WowtypeSession) -> usize {
    unsafe { session.as_ref() }.map_or(0, |handle| handle.session.selections().len())
}

/// 第 index 个已选词的拼音（空格分音节）；越界返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_selection_pinyin(
    session: *mut WowtypeSession,
    index: usize,
) -> *const c_char {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return ptr::null();
    };
    match handle.session.selections().get(index) {
        Some(selection) => {
            let pinyin = selection.pinyin.clone();
            handle.text(&pinyin)
        }
        None => ptr::null(),
    }
}

/// 选了句首词：压进已选栈。bytes 是它用掉的原始输入字节数。
#[no_mangle]
pub unsafe extern "C" fn wowtype_session_push_selection(
    session: *mut WowtypeSession,
    text: *const c_char,
    pinyin: *const c_char,
    bytes: usize,
) {
    if let Some(handle) = unsafe { session.as_mut() } {
        handle.session.push_selection(Selection {
            text: unsafe { arg(text) },
            pinyin: unsafe { arg(pinyin) },
            bytes,
        });
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
        let text = CString::new("你好").unwrap();
        let pinyin = CString::new("ni hao").unwrap();
        unsafe { wowtype_session_push_selection(session, text.as_ptr(), pinyin.as_ptr(), 5) };
        assert_eq!(c(unsafe { wowtype_session_remaining(session) }), "ma");
        assert_eq!(unsafe { wowtype_session_selection_count(session) }, 1);
        assert_eq!(
            c(unsafe { wowtype_session_selection_pinyin(session, 0) }),
            "ni hao"
        );
        assert!(unsafe { wowtype_session_selection_pinyin(session, 1) }.is_null());

        let frame = press(session, keysym::BACKSPACE);
        assert_eq!(frame.handled, 1);
        assert!(frame.commit.is_null());
        assert_eq!(c(frame.preedit), "nihaoma");
        assert_eq!(frame.size as usize, size_of::<WowtypeFrame>());

        let frame = unsafe { &*wowtype_session_reset(session, 1) };
        assert_eq!(c(frame.commit), "nihaoma");
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
        };
        let frame = unsafe { &*wowtype_session_key(session, &key) };
        assert_eq!(frame.handled, 1);
        assert_eq!(c(frame.preedit), "a");
        unsafe { wowtype_session_free(session) };
    }

    #[test]
    fn null_handles() {
        assert!(unsafe { wowtype_session_key(ptr::null_mut(), ptr::null()) }.is_null());
        assert!(unsafe { wowtype_session_reset(ptr::null_mut(), 0) }.is_null());
        assert_eq!(unsafe { wowtype_session_selection_count(ptr::null()) }, 0);
        unsafe { wowtype_session_free(ptr::null_mut()) };
    }
}
