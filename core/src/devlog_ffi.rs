//! 开发者模式的打字记录的 C ABI（1.20 起），见 [`crate::devlog`] 和 docs/DEVLOG.md。
//!
//! 整个进程一份：外壳读到 wowtype.conf 的 `DeveloperMode` 就调 [`wowtype_devlog_configure`]，
//! 之后会话的每次调用（`wowtype_session_key`、`_select`、`_choose`、`_reset`……）自己把记录写进文件，
//! 外壳不用再做别的。

use std::os::raw::{c_char, c_int};
use std::path::Path;

use crate::devlog;
use crate::ffi::set_last_error;

unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// 打开（enabled 非 0）或关上记录。path 是记录文件的绝对路径（数据目录里的 `devlog.jsonl`）；
/// 关上时可以传 NULL。打开却没给路径返回 -1（照样是关着的）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_devlog_configure(path: *const c_char, enabled: c_int) -> c_int {
    let path = unsafe { cstr(path) }.filter(|p| !p.is_empty());
    if enabled != 0 && path.is_none() {
        devlog::configure(None, false);
        set_last_error("devlog path is null, empty or not utf8");
        return -1;
    }
    devlog::configure(path.as_deref().map(Path::new), enabled != 0);
    0
}

/// 开着没有（1 / 0）。
#[no_mangle]
pub extern "C" fn wowtype_devlog_enabled() -> c_int {
    c_int::from(devlog::enabled())
}

/// 现在有焦点的应用（程序名、bundle id、exe 名），记在每条记录的 `app` 里。NULL 或空串是不知道。
#[no_mangle]
pub unsafe extern "C" fn wowtype_devlog_set_app(name: *const c_char) {
    devlog::set_app(&unsafe { cstr(name) }.unwrap_or_default());
}

/// 设置界面用：清空记录（删掉 `devlog.jsonl` 和 `devlog.jsonl.1`）。输入法开着关着都行。
#[no_mangle]
pub unsafe extern "C" fn wowtype_devlog_clear(path: *const c_char) -> c_int {
    let Some(path) = (unsafe { cstr(path) }) else {
        set_last_error("devlog path is null or not utf8");
        return -1;
    };
    match devlog::clear(Path::new(&path)) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}
