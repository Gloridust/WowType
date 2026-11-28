//! 剪贴板历史（设置 `ClipboardHistory`，默认关），说明见 docs/CONFIG.md「剪贴板历史」。
//!
//! 输入法自己拿不到系统剪贴板：外壳（fcitx5 插件、macOS 的输入法进程、Windows 的后台进程）每秒看一次，
//! 把现在的文字交给 [`observe`]，变了才记；别的设备复制过来的由跨设备复制粘贴交给 [`add_received`]。
//! 工具栏的「剪贴板」页从 [`history`] 取，设置界面的「剪贴板历史」窗口从 [`entries`] 取。
//!
//! 外壳给了文件（[`configure`]）就存在那里，只有自己能读：重启以后还在，设置界面那个进程也看得到、删得掉。
//! 没给（只开了跨设备复制粘贴）就只在内存里。几个进程可以共用一个文件（Windows 上每个应用里都有一份
//! 输入法，设置界面也会删）：每次读、改之前看文件变没变，变了先读进来；写的时候整份换掉，不会写一半。
//!
//! 文件格式（`clipboard-history.json`，最新的在前）：
//!
//! ```json
//! {"version":1,"forgotten":"9a1f…","items":[{"text":"…","time":1764300000,"app":"firefox","device":""}]}
//! ```
//!
//! `time` 是 Unix 秒；`app` 是复制时在用的应用，`device` 是别的设备复制过来的那台的名字，不知道是空串。
//! `forgotten` 是最近一次删掉的那段文字的 [`text_hash`]：删掉的那段多半还在系统剪贴板上，输入法重启后
//! 第一次看剪贴板时不该把它又记回来；剪贴板换成别的文字以后就作废。

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

/// 最多记多少条。
pub const CAPACITY: usize = 200;
/// 一条最多多少字节，再长的不记（大段代码、整篇文章选了再上屏也不方便）。
pub const MAX_BYTES: usize = 16 * 1024;
/// 默认留几天（设置 `ClipboardHistoryDays`，0 是不按时间删）。
pub const DEFAULT_KEEP_DAYS: u32 = 7;
/// 同一段文字这么多秒以内又报上来，算同一次复制：来源（应用、设备）不改。
/// 别的设备传来的放进系统剪贴板以后，下一秒外壳会把它当成本机复制的再报一次。
const SAME_COPY_SECS: i64 = 5;

/// 一条记录。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub text: String,
    /// 记下（最近一次复制）的时间，Unix 秒
    pub time: i64,
    /// 复制时在用的应用（程序名、bundle id、exe 名），不知道是空串
    pub app: String,
    /// 别的设备复制过来的：那台设备的名字；本机复制的是空串
    pub device: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stamp {
    len: u64,
    modified: Option<SystemTime>,
}

fn stamp_of(path: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    Some(Stamp {
        len: meta.len(),
        modified: meta.modified().ok(),
    })
}

struct Store {
    path: Option<PathBuf>,
    keep_days: u32,
    items: Vec<Entry>,
    /// 上次读、写文件时它的样子；和现在不一样就是别的进程改过
    stamp: Option<Stamp>,
    /// 外壳上次报的剪贴板文字（没变就不记）
    last_seen: Option<String>,
    forgotten: Option<String>,
}

static STORE: Mutex<Store> = Mutex::new(Store {
    path: None,
    keep_days: DEFAULT_KEEP_DAYS,
    items: Vec::new(),
    stamp: None,
    last_seen: None,
    forgotten: None,
});

fn lock() -> std::sync::MutexGuard<'static, Store> {
    STORE.lock().unwrap_or_else(|e| e.into_inner())
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// 一段文字的指纹（FNV-1a 64 位，16 位小写十六进制）。设置界面（Python）删条目时算同一个。
pub fn text_hash(text: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    format!("{hash:016x}")
}

fn worth_keeping(text: &str) -> bool {
    !text.trim().is_empty() && text.len() <= MAX_BYTES
}

impl Store {
    /// 文件被别的进程改过（或删了）就读进来。
    fn refresh(&mut self) {
        let Some(path) = self.path.clone() else {
            return;
        };
        let current = stamp_of(&path);
        if current == self.stamp {
            return;
        }
        self.stamp = current;
        let (items, forgotten) = match std::fs::read(&path) {
            Ok(data) => parse(&data).unwrap_or_else(|| {
                eprintln!("wowtype: {} 不是认得的剪贴板历史，当成空的", path.display());
                (Vec::new(), None)
            }),
            // 没有文件：还没记过，或者设置界面清空、关掉了
            Err(_) => (Vec::new(), None),
        };
        self.items = items;
        self.forgotten = forgotten;
    }

    fn save(&mut self) {
        let Some(path) = self.path.clone() else {
            return;
        };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let text = to_json(&self.items, self.forgotten.as_deref());
        match crate::fsutil::write_private(&path, text.as_bytes()) {
            Ok(()) => self.stamp = stamp_of(&path),
            Err(error) => eprintln!("wowtype: 剪贴板历史存不进 {}：{error:#}", path.display()),
        }
    }

    /// 去掉太旧的、超出条数的；去掉了返回 true。
    fn prune(&mut self, now: i64) -> bool {
        let before = self.items.len();
        if self.keep_days > 0 {
            let oldest = now.saturating_sub(i64::from(self.keep_days) * 86_400);
            self.items.retain(|e| e.time >= oldest);
        }
        self.items.truncate(CAPACITY);
        self.items.len() != before
    }

    fn add(&mut self, text: &str, app: &str, device: &str, now: i64) -> bool {
        if !worth_keeping(text) {
            return false;
        }
        self.refresh();
        let mut entry = Entry {
            text: text.to_owned(),
            time: now,
            app: app.to_owned(),
            device: device.to_owned(),
        };
        if let Some(at) = self.items.iter().position(|e| e.text == text) {
            let old = self.items.remove(at);
            let same_copy = at == 0 && now.saturating_sub(old.time) <= SAME_COPY_SECS;
            if same_copy || (entry.app.is_empty() && entry.device.is_empty()) {
                entry.app = old.app;
                entry.device = old.device;
            }
            if same_copy {
                entry.time = old.time;
            }
        }
        self.items.insert(0, entry);
        self.prune(now);
        self.save();
        true
    }
}

fn parse(data: &[u8]) -> Option<(Vec<Entry>, Option<String>)> {
    let value: Value = serde_json::from_slice(data).ok()?;
    let items = value.get("items")?.as_array()?;
    let field = |item: &Value, key: &str| item.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let entries = items
        .iter()
        .filter_map(|item| {
            let text = item.get("text")?.as_str()?;
            worth_keeping(text).then(|| Entry {
                text: text.to_owned(),
                time: item.get("time").and_then(Value::as_i64).unwrap_or(0),
                app: field(item, "app"),
                device: field(item, "device"),
            })
        })
        .collect();
    let forgotten = value
        .get("forgotten")
        .and_then(Value::as_str)
        .filter(|h| !h.is_empty())
        .map(str::to_owned);
    Some((entries, forgotten))
}

fn entry_json(e: &Entry) -> Value {
    json!({"text": e.text, "time": e.time, "app": e.app, "device": e.device})
}

fn to_json(items: &[Entry], forgotten: Option<&str>) -> String {
    let items: Vec<Value> = items.iter().map(entry_json).collect();
    let mut value = json!({"version": 1, "items": items});
    if let Some(hash) = forgotten {
        value["forgotten"] = Value::from(hash);
    }
    value.to_string()
}

/// 存在哪、留几天（0：不按时间删）。path 是空串：只记在内存里（只开了跨设备复制粘贴时），
/// 原来存在文件里的连文件一起删掉（设置里关掉了剪贴板历史）。换了文件就读进那个文件；
/// 内存里已有的（跨设备收到的）并进去。返回现在有几条。
pub fn configure(path: &str, keep_days: u32) -> usize {
    configure_at(path, keep_days, now())
}

fn configure_at(path: &str, keep_days: u32, now: i64) -> usize {
    let mut store = lock();
    store.keep_days = keep_days;
    if path.is_empty() {
        if let Some(old) = store.path.take() {
            let _ = std::fs::remove_file(&old);
            store.items.clear();
            store.stamp = None;
            store.forgotten = None;
        }
    } else if store.path.as_deref() != Some(Path::new(path)) {
        let kept = std::mem::take(&mut store.items);
        store.path = Some(PathBuf::from(path));
        store.stamp = None;
        store.refresh();
        let mut changed = false;
        for entry in kept.into_iter().rev() {
            if !store.items.iter().any(|e| e.text == entry.text) {
                store.items.push(entry);
                changed = true;
            }
        }
        if changed {
            store.items.sort_by(|a, b| b.time.cmp(&a.time));
            store.prune(now);
            store.save();
        }
    } else {
        store.refresh();
    }
    if store.prune(now) {
        store.save();
    }
    store.items.len()
}

/// 外壳看到系统剪贴板现在是这段文字（空串也报：复制的是图片、文件）。和上次报的一样就什么也不做；
/// 不一样就记下，挪到最前。app 是现在在用的应用，不知道传空串。空白、超过 16 KB 的不记。
/// 返回记下了没有。
pub fn observe(text: &str, app: &str) -> bool {
    observe_at(text, app, now())
}

fn observe_at(text: &str, app: &str, now: i64) -> bool {
    let mut store = lock();
    if store.last_seen.as_deref() == Some(text) {
        return false;
    }
    store.last_seen = Some(text.to_owned());
    store.refresh();
    if let Some(hash) = store.forgotten.clone() {
        if hash == text_hash(text) {
            return false; // 刚删掉的那段还在剪贴板上
        }
        // 剪贴板换了别的：删掉的那段以后再复制就照常记
        store.forgotten = None;
        if !worth_keeping(text) {
            store.save();
        }
    }
    store.add(text, app, "", now)
}

/// 旧的接口：等于 `observe(text, "")`。
pub fn remember(text: &str) -> bool {
    observe(text, "")
}

/// 别的设备复制过来的（跨设备复制粘贴）：不管和剪贴板上的一不一样都记下，来源记那台设备。
pub fn add_received(text: &str, device: &str) -> bool {
    lock().add(text, "", device, now())
}

/// 最新的在前（工具栏用）。
pub fn history() -> Vec<String> {
    entries().into_iter().map(|e| e.text).collect()
}

/// 全部记录，最新的在前（设置界面用）。
pub fn entries() -> Vec<Entry> {
    entries_at(now())
}

fn entries_at(now: i64) -> Vec<Entry> {
    let mut store = lock();
    store.refresh();
    if store.prune(now) {
        store.save();
    }
    store.items.clone()
}

/// [`entries`] 写成 JSON：`{"items":[{"text":…,"time":…,"app":…,"device":…}]}`。
pub fn entries_json() -> String {
    let items: Vec<Value> = entries().iter().map(entry_json).collect();
    json!({ "items": items }).to_string()
}

/// 删掉一条（文字一样的那条）。删掉了返回 true。
pub fn forget(text: &str) -> bool {
    let mut store = lock();
    store.refresh();
    let before = store.items.len();
    store.items.retain(|e| e.text != text);
    if store.items.len() == before {
        return false;
    }
    store.forgotten = Some(text_hash(text));
    store.save();
    true
}

/// 全部删掉。存在文件里的留一个空的文件（记着最新那条的指纹，免得输入法重启时把还在剪贴板上的它记回来）。
pub fn clear() {
    let mut store = lock();
    store.refresh();
    let newest = store
        .last_seen
        .clone()
        .filter(|t| worth_keeping(t))
        .or_else(|| store.items.first().map(|e| e.text.clone()));
    store.items.clear();
    if store.path.is_some() {
        store.forgotten = newest.map(|t| text_hash(&t));
        store.save();
    }
}

#[cfg(test)]
pub(crate) static TEST_LOCK: Mutex<()> = Mutex::new(());

/// 测试用：回到刚启动的样子（只在内存里、空的，不删文件）。
#[cfg(test)]
pub(crate) fn reset_for_test() {
    let mut store = lock();
    store.path = None;
    store.keep_days = DEFAULT_KEEP_DAYS;
    store.items.clear();
    store.stamp = None;
    store.last_seen = None;
    store.forgotten = None;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wowtype-clipboard-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("clipboard-history.json")
    }

    /// 测试里的时间是假的（几十秒、几千秒）：按「现在是 0 秒」读，不按保留天数删掉它们。
    fn texts() -> Vec<String> {
        entries_at(0).into_iter().map(|e| e.text).collect()
    }

    #[test]
    fn newest_first_dedupe_and_cap() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        assert!(remember("a"));
        assert!(remember("b"));
        assert!(remember("a"));
        assert_eq!(history(), vec!["a", "b"]);
        assert!(!remember("   \n"));
        assert!(!remember(&"x".repeat(MAX_BYTES + 1)));
        for i in 0..CAPACITY + 5 {
            remember(&i.to_string());
        }
        let h = history();
        assert_eq!(h.len(), CAPACITY);
        assert_eq!(h[0], (CAPACITY + 4).to_string());
        clear();
        assert!(history().is_empty());
        reset_for_test();
    }

    #[test]
    fn the_same_clipboard_reported_again_is_not_a_new_copy() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        assert!(observe_at("你好", "gedit", 100));
        // 每秒都报一次：没变就不动，时间还是第一次复制的
        assert!(!observe_at("你好", "gedit", 101));
        assert!(!observe_at("你好", "firefox", 200));
        assert_eq!(entries_at(0)[0].time, 100);
        assert_eq!(entries_at(0)[0].app, "gedit");
        // 复制了图片（剪贴板上没有文字）以后又复制了同一段：算新的一次
        assert!(!observe_at("", "gedit", 300));
        assert!(observe_at("你好", "firefox", 301));
        assert_eq!(entries_at(0)[0].time, 301);
        assert_eq!(entries_at(0)[0].app, "firefox");
        reset_for_test();
    }

    #[test]
    fn saved_to_a_private_file_and_read_back_after_restart() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("restart");
        let p = path.to_str().unwrap();
        assert_eq!(configure_at(p, 7, 1000), 0);
        observe_at("第一条", "gedit", 1000);
        observe_at("第二条\n两行", "", 1010);
        lock().add("别的设备的", "", "MacBook", 1015);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "只有自己能读");
        }
        // 输入法重启
        reset_for_test();
        assert_eq!(configure_at(p, 7, 1020), 3);
        let got = entries_at(1020);
        assert_eq!(got[0].text, "别的设备的");
        assert_eq!(got[0].device, "MacBook");
        assert_eq!(got[1].text, "第二条\n两行");
        assert_eq!(got[2].app, "gedit");
        assert_eq!(got[2].time, 1000);
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn old_entries_go_after_the_kept_days() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("days");
        let p = path.to_str().unwrap();
        configure_at(p, 1, 0);
        observe_at("老的", "", 0);
        observe_at("新的", "", 80_000);
        assert_eq!(entries_at(86_400).len(), 2);
        // 过了一天：老的删掉，文件里也没有了
        assert_eq!(entries_at(86_401).iter().map(|e| e.text.as_str()).collect::<Vec<_>>(), ["新的"]);
        assert!(!std::fs::read_to_string(&path).unwrap().contains("老的"));
        // 0：不按时间删
        configure_at(p, 0, 10_000_000);
        assert_eq!(entries_at(10_000_000).len(), 1);
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn another_process_deleting_is_seen_and_not_undone() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("other");
        let p = path.to_str().unwrap();
        configure_at(p, 7, 0);
        observe_at("密码123", "keepassxc", 10);
        observe_at("普通的", "gedit", 20);
        observe_at("密码123", "keepassxc", 30);
        assert_eq!(texts(), ["密码123", "普通的"]);

        // 设置界面（别的进程）删掉「密码123」：整份换掉文件
        let other = format!(
            "{{\"version\":1,\"forgotten\":\"{}\",\"items\":[{{\"text\":\"普通的\",\"time\":20,\"app\":\"gedit\",\"device\":\"\"}}]}}",
            text_hash("密码123")
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(&path, other).unwrap();
        assert_eq!(texts(), ["普通的"]);
        // 剪贴板上还是它：每秒报上来也不记回去，输入法重启以后也不记
        assert!(!observe_at("密码123", "keepassxc", 31));
        reset_for_test();
        configure_at(p, 7, 40);
        assert!(!observe_at("密码123", "keepassxc", 40));
        assert_eq!(texts(), ["普通的"]);
        // 复制了别的以后，再复制它就照常记
        assert!(observe_at("别的", "gedit", 50));
        assert!(observe_at("密码123", "keepassxc", 60));
        assert_eq!(texts(), ["密码123", "别的", "普通的"]);

        // 文件被删掉（设置界面关掉了这个功能）：当成空的
        std::fs::remove_file(&path).unwrap();
        assert!(texts().is_empty());
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn forget_and_clear_do_not_bring_the_current_clipboard_back() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("forget");
        let p = path.to_str().unwrap();
        configure_at(p, 7, 0);
        observe_at("一", "", 1);
        observe_at("二", "", 2);
        assert!(forget("一"));
        assert!(!forget("没有的"));
        assert_eq!(texts(), ["二"]);
        clear();
        assert!(texts().is_empty());
        // 重启以后剪贴板上还是「二」：不记回来
        reset_for_test();
        configure_at(p, 7, 3);
        assert!(!observe_at("二", "", 3));
        assert!(texts().is_empty());
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn turning_it_off_deletes_the_file_and_memory_only_is_merged_in_when_turned_on() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("off");
        let p = path.to_str().unwrap();
        // 只开着跨设备复制粘贴：收到的只在内存里
        configure_at("", 7, 0);
        add_received("收到的", "台式机");
        assert!(!path.exists());
        // 打开剪贴板历史：并进文件
        assert_eq!(configure_at(p, 7, 5), 1);
        assert!(std::fs::read_to_string(&path).unwrap().contains("收到的"));
        // 关掉：文件删掉，内存清空
        configure_at("", 7, 6);
        assert!(!path.exists());
        assert!(texts().is_empty());
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn received_then_echoed_by_the_local_clipboard_keeps_the_device() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        lock().add("从手机来", "", "Pixel", 100);
        // 外壳把它放进系统剪贴板，下一秒当成本机复制的报上来
        assert!(observe_at("从手机来", "gedit", 101));
        assert_eq!(entries_at(0)[0].device, "Pixel");
        assert_eq!(entries_at(0)[0].app, "");
        reset_for_test();
    }

    #[test]
    fn a_broken_file_is_read_as_empty_and_replaced() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        let path = temp_file("broken");
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(configure_at(path.to_str().unwrap(), 7, 0), 0);
        observe_at("新的", "", 1);
        let saved = std::fs::read_to_string(&path).unwrap();
        assert!(saved.starts_with('{') && saved.contains("新的"), "{saved}");
        reset_for_test();
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn entries_json_lists_every_field() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        reset_for_test();
        observe_at("a\"b", "gedit", 7);
        lock().keep_days = 0;
        let value: Value = serde_json::from_str(&entries_json()).unwrap();
        assert_eq!(value["items"][0]["text"], "a\"b");
        assert_eq!(value["items"][0]["time"], 7);
        assert_eq!(value["items"][0]["app"], "gedit");
        assert_eq!(value["items"][0]["device"], "");
        reset_for_test();
    }

    #[test]
    fn text_hash_is_fnv1a() {
        // 和设置界面（Python）算的一样，见 settings/wowtype-config 的 clipboard_text_hash
        assert_eq!(text_hash(""), "cbf29ce484222325");
        assert_eq!(text_hash("a"), "af63dc4c8601ec8c");
    }
}
