//! 开发者模式的打字记录：默认关，打开以后把每次选词、上屏、放弃**明文**记在本机，调排序用。
//!
//! 和打字统计（[`crate::stats`]，只有计数）、输入法日志（只有启动和出错）不是一回事：这里记的就是
//! 打了什么、当时有哪些候选、选了第几个。所以默认关，设置界面打开时要弹窗说清楚，「导出日志」也不带它。
//!
//! 记什么（一行一个 JSON，见 docs/DEVLOG.md）：
//! - `commit`：一次上屏。原始输入、光标前的上文、上屏的字、打字途中按过的键、花了多久，还有每一步
//!   选词（分几次选的整句有几步）：那时还没选的输入、候选框里的前若干个候选、选了第几个、怎么选的；
//! - `abandon`：打到一半放弃了（Esc、删光、失去焦点）；
//! - `backspace`：上屏以后紧接着按了退格（多半是选错了）。
//!
//! 不记什么：密码框（外壳给的 [`crate::session::key_hints::NO_LEARN`]）里的；英文模式下直接交给应用的键；
//! 工具栏、表情面板里选的。**没有标成密码框的地方（终端的 sudo 提示）在中文模式下打的密码会记下来。**
//!
//! 会话（[`crate::session::Session`]）只把事件攒在内存里，C 接口每次调用完取走交给 [`write`]：
//! 加上时刻、版本、应用名，追加进文件（0600）。每次写都重新打开文件：Windows 上几个应用进程各写各的，
//! 设置界面清空（删文件）以后也不会接着写进已经删掉的文件。超过 [`MAX_FILE_BYTES`] 时把当前文件改名成
//! `devlog.jsonl.1`（只留这一份旧的）。

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use serde_json::Value;

/// 记录文件的名字（放在数据目录里，和 stats.json 一起）。
pub const FILE_NAME: &str = "devlog.jsonl";
/// 记录的格式版本（每行的 `v`）。
pub const FORMAT: u32 = 1;
/// 文件超过这么大就换一个（旧的留一份）。一次上屏一两 KB，16 MB 大约一万次。
pub const MAX_FILE_BYTES: u64 = 16 * 1024 * 1024;
/// 一步选词最多记几个候选。
pub const MAX_CANDIDATES: usize = 60;

static ENABLED: AtomicBool = AtomicBool::new(false);
static STATE: Mutex<State> = Mutex::new(State { path: None, app: String::new() });

struct State {
    path: Option<PathBuf>,
    app: String,
}

/// 打开或关上。`path` 是记录文件的绝对路径；关上、没给路径时什么都不记。
pub fn configure(path: Option<&Path>, enabled: bool) {
    let Ok(mut state) = STATE.lock() else {
        return;
    };
    state.path = path.filter(|_| enabled).map(Path::to_path_buf);
    ENABLED.store(state.path.is_some(), Ordering::Relaxed);
}

/// 开着没有（会话的 C 接口每次调用前看一眼，关着时会话什么都不攒）。
pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// 现在有焦点的应用（外壳知道的话告诉一声，记在每行的 `app` 里；不知道是空的）。
pub fn set_app(name: &str) {
    if let Ok(mut state) = STATE.lock() {
        if state.app != name {
            state.app = name.chars().take(200).collect();
        }
    }
}

/// 把会话攒的事件写进文件：每条加上 `v`、`t`（毫秒时间戳）、`ver`、`app`。写不了就丢掉（不影响打字）。
pub fn write(events: Vec<Value>) {
    if events.is_empty() || !enabled() {
        return;
    }
    let Ok(state) = STATE.lock() else {
        return;
    };
    let Some(path) = state.path.as_deref() else {
        return;
    };
    let now = crate::stats::now_ms();
    let mut text = String::new();
    for event in events {
        text.push_str(&line(event, now, &state.app));
        text.push('\n');
    }
    let _ = append(path, text.as_bytes(), MAX_FILE_BYTES);
}

/// 一条事件加上公共的几项，排成一行。
fn line(event: Value, now_ms: i64, app: &str) -> String {
    let mut out = serde_json::Map::new();
    out.insert("v".into(), FORMAT.into());
    out.insert("t".into(), now_ms.into());
    out.insert("ver".into(), env!("CARGO_PKG_VERSION").into());
    if !app.is_empty() {
        out.insert("app".into(), app.into());
    }
    if let Value::Object(fields) = event {
        out.extend(fields);
    }
    Value::Object(out).to_string()
}

/// 换下来的旧文件（`devlog.jsonl.1`）。
pub fn old_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".1");
    path.with_file_name(name)
}

/// 追加一段（整行）。文件加上这段会超过 `max` 时先把它改名成 [`old_path`]。
pub fn append(path: &Path, bytes: &[u8], max: u64) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let size = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    if size > 0 && size + bytes.len() as u64 > max {
        // 别的进程还开着它的话（Windows），改名以后它接着写进旧的那份，下次打开就是新的了
        let _ = fs::rename(path, old_path(path));
    }
    let mut options = fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    // 一次 write：几个进程一起追加时各自的行不会互相插进去
    options.open(path)?.write_all(bytes)
}

/// 清空（设置界面用，输入法开着关着都行）：删掉记录和换下来的旧文件。
pub fn clear(path: &Path) -> Result<(), String> {
    for file in [path.to_path_buf(), old_path(path)] {
        match fs::remove_file(&file) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("删记录文件失败：{error}")),
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wowtype-devlog-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn line_carries_time_version_app_and_the_event() {
        let text = line(json!({"e": "commit", "text": "你好"}), 42, "kitty");
        let value: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(value["v"], FORMAT);
        assert_eq!(value["t"], 42);
        assert_eq!(value["ver"], env!("CARGO_PKG_VERSION"));
        assert_eq!(value["app"], "kitty");
        assert_eq!(value["e"], "commit");
        assert_eq!(value["text"], "你好");
        assert!(!text.contains('\n'));
        // 不知道应用时不写这一项
        let value: Value = serde_json::from_str(&line(json!({"e": "abandon"}), 1, "")).unwrap();
        assert!(value.get("app").is_none());
    }

    #[test]
    fn append_keeps_lines_and_rotates_once_over_the_cap() {
        let dir = temp("rotate");
        let path = dir.join(FILE_NAME);
        append(&path, b"one\n", 10).unwrap();
        append(&path, b"two\n", 10).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "one\ntwo\n");
        // 再加就超了：前面的挪到 .1，新的从头写
        append(&path, b"three\n", 10).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "three\n");
        assert_eq!(fs::read_to_string(old_path(&path)).unwrap(), "one\ntwo\n");
        // 又超了：只留最近换下来的那份
        append(&path, b"four4\n", 10).unwrap();
        assert_eq!(fs::read_to_string(old_path(&path)).unwrap(), "three\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        clear(&path).unwrap();
        assert!(!path.exists() && !old_path(&path).exists());
        // 没有文件时清空也算成功
        clear(&path).unwrap();
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn off_by_default_and_writes_only_while_configured() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp("global");
        let path = dir.join("sub").join(FILE_NAME);
        // 开着的这一会儿，别的测试里走 C 接口的会话也会往里写：只数自己这几条
        let mine = || -> Vec<Value> {
            fs::read_to_string(&path)
                .unwrap_or_default()
                .lines()
                .map(|l| serde_json::from_str::<Value>(l).unwrap())
                .filter(|event| event["mark"] == "devlog-unit")
                .collect()
        };
        let event = |kind: &str| json!({"e": kind, "mark": "devlog-unit"});
        configure(None, false);
        assert!(!enabled());
        write(vec![event("commit")]);
        assert!(!path.exists());
        // 给了路径但没开：不记
        configure(Some(&path), false);
        assert!(!enabled());
        configure(Some(&path), true);
        assert!(enabled());
        set_app("org.example.App");
        write(vec![event("commit"), event("backspace")]);
        let lines = mine();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0]["app"], "org.example.App");
        assert_eq!(lines[1]["e"], "backspace");
        // 清空以后接着写的是新文件
        clear(&path).unwrap();
        write(vec![event("abandon")]);
        assert_eq!(mine().len(), 1);
        configure(None, false);
        set_app("");
        write(vec![event("commit")]);
        assert_eq!(mine().len(), 1);
        let _ = fs::remove_dir_all(dir);
    }
}
