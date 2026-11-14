//! 打字统计的 C ABI：输入法进程持有记录器，设置界面读写同一个文件。
//!
//! 约定见 core/include/wowtype_core.h：句柄由调用方保证生命周期，失败用 wowtype_last_error 取原因。

use std::os::raw::{c_char, c_int};

use crate::ffi::set_last_error;
use crate::stats::{self, Recorder};

pub struct WowtypeStats {
    recorder: Recorder,
}

unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { std::ffi::CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// 创建一个记录器；`path` 是统计文件的绝对路径。失败返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_new(path: *const c_char) -> *mut WowtypeStats {
    let Some(path) = (unsafe { cstr(path) }) else {
        set_last_error("stats path is null or not utf8");
        return std::ptr::null_mut();
    };
    if path.is_empty() {
        set_last_error("stats path is empty");
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(WowtypeStats {
        recorder: Recorder::new(path),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_free(stats: *mut WowtypeStats) {
    if stats.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(stats) });
}

/// 一次物理按键。`platform`：0 = X11/fcitx5（`code` 是 XKB 键码），1 = macOS（`NSEvent.keyCode`）。
/// `down` 非 0 表示按下。返回 0 成功，-1 参数错误。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_key(
    stats: *mut WowtypeStats,
    platform: c_int,
    code: u32,
    down: c_int,
    now_ms: i64,
) -> c_int {
    let Some(stats) = (unsafe { stats.as_mut() }) else {
        set_last_error("stats is null");
        return -1;
    };
    stats.recorder.key(platform, code, down != 0, now_ms);
    0
}

/// 一次上屏（文本只用来分类，不落盘）。`cand_index` 是候选位置（1 起），不是选候选时为 0。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_commit(
    stats: *mut WowtypeStats,
    text: *const c_char,
    source: *const c_char,
    scheme: *const c_char,
    cand_index: c_int,
    now_ms: i64,
) -> c_int {
    let Some(stats) = (unsafe { stats.as_mut() }) else {
        set_last_error("stats is null");
        return -1;
    };
    let Some(text) = (unsafe { cstr(text) }) else {
        set_last_error("stats text is null or not utf8");
        return -1;
    };
    let source = unsafe { cstr(source) }.unwrap_or_default();
    let scheme = unsafe { cstr(scheme) }.unwrap_or_default();
    stats
        .recorder
        .commit(&text, &source, &scheme, cand_index.max(0) as u32, now_ms);
    0
}

/// 把攒着的计数写进文件。返回 0 成功，-1 失败（原因见 wowtype_last_error）。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_flush(stats: *mut WowtypeStats, now_ms: i64) -> c_int {
    let Some(stats) = (unsafe { stats.as_mut() }) else {
        set_last_error("stats is null");
        return -1;
    };
    match stats.recorder.flush(now_ms) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

/// 当前开关（输入法缓存的值，最多 30 秒重读一次文件）。1 开，0 关。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_enabled(stats: *mut WowtypeStats) -> c_int {
    let Some(stats) = (unsafe { stats.as_ref() }) else {
        return 0;
    };
    c_int::from(stats.recorder.enabled())
}

/// 设置界面用：清空统计（只留开关，换一个新代号）。`generation` 由调用方给一个随机数。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_clear_file(path: *const c_char, generation: u64) -> c_int {
    let Some(path) = (unsafe { cstr(path) }) else {
        set_last_error("stats path is null or not utf8");
        return -1;
    };
    match stats::clear_file(std::path::Path::new(&path), generation) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

/// 设置界面用：改开关。
#[no_mangle]
pub unsafe extern "C" fn wowtype_stats_set_enabled(path: *const c_char, enabled: c_int) -> c_int {
    let Some(path) = (unsafe { cstr(path) }) else {
        set_last_error("stats path is null or not utf8");
        return -1;
    };
    match stats::set_enabled(std::path::Path::new(&path), enabled != 0) {
        Ok(()) => 0,
        Err(error) => {
            set_last_error(error);
            -1
        }
    }
}

/// 当前 Unix 毫秒，外壳不必自己算。
#[no_mangle]
pub extern "C" fn wowtype_stats_now_ms() -> i64 {
    stats::now_ms()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn ffi_round_trip() {
        let path = std::env::temp_dir().join(format!("wowtype-stats-ffi-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let stats = unsafe { wowtype_stats_new(path.as_ptr()) };
        assert!(!stats.is_null());
        let text = CString::new("你好").unwrap();
        let source = CString::new("quanpin").unwrap();
        let scheme = CString::new("").unwrap();
        let now = wowtype_stats_now_ms();
        assert_eq!(
            unsafe {
                wowtype_stats_commit(
                    stats,
                    text.as_ptr(),
                    source.as_ptr(),
                    scheme.as_ptr(),
                    1,
                    now,
                )
            },
            0
        );
        assert_eq!(unsafe { wowtype_stats_flush(stats, now) }, 0);
        assert_eq!(unsafe { wowtype_stats_enabled(stats) }, 1);
        // 清空一次，记录器下次写会丢掉旧计数。
        assert_eq!(unsafe { wowtype_stats_clear_file(path.as_ptr(), 7) }, 0);
        unsafe { wowtype_stats_free(stats) };
    }
}
