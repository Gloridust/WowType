//! 跨设备剪贴板的 C 接口（ABI 1.19）。逻辑在 `wowtype-sync`，这里只是包一层。
//!
//! 外壳定时把本机剪贴板交给 `wowtype_sync_observe`、定时 `wowtype_sync_poll`；这些函数都不阻塞，
//! 网络、加密都在 `wowtype-sync` 自己的线程里。

#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use wowtype_sync::cli::{pair_host, pair_join, PairOptions};
use wowtype_sync::relay::Relay;
use wowtype_sync::store::read_secret_line;
use wowtype_sync::{Config, Service};

pub struct WowtypeSync {
    service: Service,
    text: CString,
    from: CString,
    status: CString,
}

/// 和头文件里的 `WowtypeSyncConfig` 一样；只在末尾加字段。
#[repr(C)]
pub struct WowtypeSyncConfig {
    pub size: u32,
    pub enabled: c_int,
    pub lan: c_int,
    pub relay_url: *const c_char,
    pub relay_key_file: *const c_char,
    pub state_file: *const c_char,
    pub device_name: *const c_char,
}

unsafe fn arg(ptr: *const c_char) -> String {
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().trim().to_string()
    }
}

/// 中间有 NUL 的（不会有，别的设备传来的也过滤过）截到 NUL 之前。
fn c_string(text: &str) -> CString {
    let end = text.find('\0').unwrap_or(text.len());
    CString::new(&text[..end]).unwrap_or_default()
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_new() -> *mut WowtypeSync {
    Box::into_raw(Box::new(WowtypeSync {
        service: Service::new(),
        text: CString::default(),
        from: CString::default(),
        status: CString::default(),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_free(sync: *mut WowtypeSync) {
    if !sync.is_null() {
        drop(Box::from_raw(sync));
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_configure(
    sync: *mut WowtypeSync,
    config: *const WowtypeSyncConfig,
) {
    let (Some(sync), Some(raw)) = (sync.as_ref(), config.as_ref()) else {
        return;
    };
    if (raw.size as usize) < std::mem::size_of::<WowtypeSyncConfig>() {
        return;
    }
    let state_file = arg(raw.state_file);
    let mut config = Config::new(crate::llama::expand_home(&state_file));
    // 没给配对文件就没法配对、也没有密钥：当成关着
    config.enabled = raw.enabled != 0 && !state_file.is_empty();
    config.lan = raw.lan != 0;
    config.relay_url = arg(raw.relay_url);
    let key_file = arg(raw.relay_key_file);
    config.relay_key_file =
        (!key_file.is_empty()).then(|| PathBuf::from(crate::llama::expand_home(&key_file)));
    config.device_name = arg(raw.device_name);
    test_knobs(&mut config);
    sync.service.configure(config);
}

/// 测试、排查用的环境变量（外壳的按键测试拿它把两台「设备」放在同一台机器上）：
/// `WOWTYPE_SYNC_LAN_PORT` 换局域网端口，`WOWTYPE_SYNC_PEERS`（逗号分开的 `地址:端口`）除了广播
/// 还往这些地址发，`WOWTYPE_SYNC_BEACON_MS` 改广播间隔。
fn test_knobs(config: &mut Config) {
    let env = |name: &str| std::env::var(name).ok().filter(|v| !v.trim().is_empty());
    if let Some(port) = env("WOWTYPE_SYNC_LAN_PORT").and_then(|v| v.trim().parse().ok()) {
        config.lan_port = port;
    }
    if let Some(peers) = env("WOWTYPE_SYNC_PEERS") {
        config.extra_targets = peers
            .split(',')
            .filter_map(|p| p.trim().parse().ok())
            .collect();
    }
    if let Some(ms) = env("WOWTYPE_SYNC_BEACON_MS").and_then(|v| v.trim().parse().ok()) {
        config.beacon_interval = std::time::Duration::from_millis(ms);
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_observe(sync: *mut WowtypeSync, text: *const c_char) -> c_int {
    let Some(sync) = sync.as_ref() else {
        return 0;
    };
    if text.is_null() {
        return 0;
    }
    // 不是 UTF-8 的不发（to_string_lossy 会把它改掉，对面拿到的就不是原文了）
    match CStr::from_ptr(text).to_str() {
        Ok(text) => sync.service.observe(text) as c_int,
        Err(_) => 0,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_touch(sync: *mut WowtypeSync) {
    if let Some(sync) = sync.as_ref() {
        sync.service.touch();
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_poll(sync: *mut WowtypeSync) -> *const c_char {
    let Some(sync) = sync.as_mut() else {
        return std::ptr::null();
    };
    let Some(received) = sync.service.poll() else {
        return std::ptr::null();
    };
    // 工具栏的「剪贴板」里看得到，输入法自己就能贴，不依赖系统剪贴板写不写得进去
    crate::clipboard::add_received(&received.text, &received.from);
    sync.text = c_string(&received.text);
    sync.from = c_string(&received.from);
    sync.text.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_from(sync: *const WowtypeSync) -> *const c_char {
    static EMPTY: [u8; 1] = [0];
    match sync.as_ref() {
        Some(sync) => sync.from.as_ptr(),
        None => EMPTY.as_ptr() as *const c_char,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_status(sync: *mut WowtypeSync) -> *const c_char {
    static EMPTY: &[u8] = b"{}\0";
    let Some(sync) = sync.as_mut() else {
        return EMPTY.as_ptr() as *const c_char;
    };
    sync.status = c_string(&sync.service.status().to_json());
    sync.status.as_ptr()
}

// ---- 配对

/// 和头文件里的 `WowtypeSyncPairConfig` 一样。
#[repr(C)]
pub struct WowtypeSyncPairConfig {
    pub size: u32,
    pub state_file: *const c_char,
    pub device_name: *const c_char,
    pub lan: c_int,
    pub relay_url: *const c_char,
    pub relay_key_file: *const c_char,
}

pub const SYNC_PAIR_STARTING: c_int = 0;
pub const SYNC_PAIR_WAITING: c_int = 1;
pub const SYNC_PAIR_DONE: c_int = 2;
pub const SYNC_PAIR_FAILED: c_int = 3;

pub struct WowtypeSyncPairing {
    progress: Arc<Mutex<(c_int, String)>>,
    cancel: Arc<AtomicBool>,
    text: CString,
}

/// 读配对的设置。地址、口令有问题时返回给用户看的原因。
unsafe fn pair_options(config: *const WowtypeSyncPairConfig) -> Result<PairOptions, String> {
    let raw = config
        .as_ref()
        .filter(|c| c.size as usize >= std::mem::size_of::<WowtypeSyncPairConfig>())
        .ok_or("配对的设置不对")?;
    let state_file = arg(raw.state_file);
    if state_file.is_empty() {
        return Err("没有指明配对文件".to_string());
    }
    let mut options = PairOptions::new(crate::llama::expand_home(&state_file), &arg(raw.device_name));
    options.lan = raw.lan != 0;
    options.relay = relay_from(&arg(raw.relay_url), &arg(raw.relay_key_file))?;
    test_knobs_for_pairing(&mut options);
    Ok(options)
}

/// 填了地址才用中转服务；填了地址没有口令、地址不对都说清楚。
fn relay_from(url: &str, key_file: &str) -> Result<Option<Relay>, String> {
    if url.is_empty() {
        return Ok(None);
    }
    let token = (!key_file.is_empty())
        .then(|| read_secret_line(&crate::llama::expand_home(key_file)))
        .flatten()
        .ok_or("还没有填中转服务的访问口令")?;
    Relay::new(url, &token).map(Some).map_err(|e| e.to_string())
}

/// 测试用：`WOWTYPE_SYNC_PAIR_HOST`（`地址:端口`）加入时不靠广播找、直接连它。
fn test_knobs_for_pairing(options: &mut PairOptions) {
    if let Some(host) = std::env::var("WOWTYPE_SYNC_PAIR_HOST")
        .ok()
        .and_then(|v| v.trim().parse().ok())
    {
        options.host = Some(host);
    }
}

fn pairing(
    options: Result<PairOptions, String>,
    work: impl FnOnce(PairOptions, &AtomicBool, &Mutex<(c_int, String)>) -> Result<String, String>
        + Send
        + 'static,
) -> *mut WowtypeSyncPairing {
    let progress = Arc::new(Mutex::new((SYNC_PAIR_STARTING, String::new())));
    let cancel = Arc::new(AtomicBool::new(false));
    match options {
        Err(why) => *progress.lock().unwrap() = (SYNC_PAIR_FAILED, why),
        Ok(options) => {
            let (shared, stop) = (Arc::clone(&progress), Arc::clone(&cancel));
            let spawned = std::thread::Builder::new()
                .name("wowtype-sync-pair".to_string())
                .spawn(move || {
                    let outcome = work(options, &stop, &shared);
                    *shared.lock().unwrap() = match outcome {
                        Ok(name) => (SYNC_PAIR_DONE, name),
                        Err(why) => (SYNC_PAIR_FAILED, why),
                    };
                });
            if spawned.is_err() {
                *progress.lock().unwrap() = (SYNC_PAIR_FAILED, "起不来线程".to_string());
            }
        }
    }
    Box::into_raw(Box::new(WowtypeSyncPairing {
        progress,
        cancel,
        text: CString::default(),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_pair_host(
    config: *const WowtypeSyncPairConfig,
) -> *mut WowtypeSyncPairing {
    pairing(pair_options(config), |options, cancel, progress| {
        pair_host(&options, cancel, &mut |code, _address| {
            *progress.lock().unwrap() = (SYNC_PAIR_WAITING, code.to_string());
        })
        .map(|device| device.name)
    })
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_pair_join(
    config: *const WowtypeSyncPairConfig,
    code: *const c_char,
) -> *mut WowtypeSyncPairing {
    let code = arg(code);
    pairing(pair_options(config), move |options, _cancel, _progress| {
        pair_join(&options, &code).map(|device| device.name)
    })
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_pairing_state(pairing: *mut WowtypeSyncPairing) -> c_int {
    match pairing.as_ref() {
        Some(pairing) => pairing.progress.lock().unwrap().0,
        None => SYNC_PAIR_FAILED,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_pairing_text(
    pairing: *mut WowtypeSyncPairing,
) -> *const c_char {
    static EMPTY: [u8; 1] = [0];
    let Some(pairing) = pairing.as_mut() else {
        return EMPTY.as_ptr() as *const c_char;
    };
    let text = pairing.progress.lock().unwrap().1.clone();
    pairing.text = c_string(&text);
    pairing.text.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_pairing_free(pairing: *mut WowtypeSyncPairing) {
    if !pairing.is_null() {
        let pairing = Box::from_raw(pairing);
        // 还在等的线程看到这个就停（配成了才写配对文件，取消不留痕迹）
        pairing.cancel.store(true, Ordering::SeqCst);
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_unpair(state_file: *const c_char) -> c_int {
    let state_file = arg(state_file);
    if state_file.is_empty() {
        return -1;
    }
    match wowtype_sync::cli::unpair(&crate::llama::expand_home(&state_file)) {
        Ok(()) => 0,
        Err(why) => {
            crate::ffi::set_last_error(why);
            -1
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_paired(state_file: *const c_char) -> *const c_char {
    thread_local! {
        static BUFFER: std::cell::RefCell<CString> = std::cell::RefCell::new(CString::default());
    }
    let state_file = arg(state_file);
    let json = if state_file.is_empty() {
        r#"{"paired":false,"devices":[]}"#.to_string()
    } else {
        wowtype_sync::cli::status_json(&crate::llama::expand_home(&state_file))
    };
    BUFFER.with(|buffer| {
        *buffer.borrow_mut() = c_string(&json);
        buffer.borrow().as_ptr()
    })
}

#[no_mangle]
pub unsafe extern "C" fn wowtype_sync_ping(
    relay_url: *const c_char,
    relay_key_file: *const c_char,
) -> c_int {
    let outcome = match relay_from(&arg(relay_url), &arg(relay_key_file)) {
        Ok(Some(relay)) => relay.ping().map_err(|e| e.to_string()),
        Ok(None) => Err("还没有填中转服务的地址".to_string()),
        Err(why) => Err(why),
    };
    match outcome {
        Ok(()) => 0,
        Err(why) => {
            crate::ffi::set_last_error(why);
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn c(text: &str) -> CString {
        CString::new(text).unwrap()
    }

    #[test]
    fn null_and_unconfigured_are_harmless() {
        unsafe {
            wowtype_sync_free(std::ptr::null_mut());
            wowtype_sync_configure(std::ptr::null_mut(), std::ptr::null());
            assert_eq!(wowtype_sync_observe(std::ptr::null_mut(), c("x").as_ptr()), 0);
            wowtype_sync_touch(std::ptr::null_mut());
            assert!(wowtype_sync_poll(std::ptr::null_mut()).is_null());
            assert_eq!(CStr::from_ptr(wowtype_sync_from(std::ptr::null())).to_bytes(), b"");
            assert_eq!(CStr::from_ptr(wowtype_sync_status(std::ptr::null_mut())).to_bytes(), b"{}");

            let sync = wowtype_sync_new();
            wowtype_sync_configure(sync, std::ptr::null());
            assert_eq!(wowtype_sync_observe(sync, std::ptr::null()), 0);
            assert_eq!(wowtype_sync_observe(sync, c("a").as_ptr()), 0);
            assert_eq!(wowtype_sync_observe(sync, c("b").as_ptr()), 0, "没打开不发");
            assert!(wowtype_sync_poll(sync).is_null());
            let status = CStr::from_ptr(wowtype_sync_status(sync)).to_str().unwrap();
            assert!(status.contains("\"enabled\":false"), "{status}");
            wowtype_sync_free(sync);
        }
    }

    // 两个句柄在本机走局域网。Windows 的外壳还没接同步，那边不跑
    #[cfg(unix)]
    #[test]
    fn two_handles_sync_and_fill_the_clipboard_history() {
        let _clipboard = crate::clipboard::TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        crate::clipboard::reset_for_test();
        let dir = std::env::temp_dir().join(format!("wowtype-sync-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // 两台配好对的设备：同一把组密钥
        let mut services = Vec::new();
        let mut ports = Vec::new();
        for name in ["a", "b"] {
            let state_file = dir.join(format!("{name}.json"));
            let mut state = wowtype_sync::store::State::fresh();
            state.group_key = Some([6u8; 32]);
            state.save(&state_file).unwrap();
            // 不用系统挑的临时端口（挑完到真去绑之间会被并行的别的测试占走）：从临时端口范围下面找空的
            let mut port = 30000 + (std::process::id() as u16 % 2000) + ports.len() as u16 * 7;
            while std::net::TcpListener::bind(("0.0.0.0", port)).is_err()
                || std::net::UdpSocket::bind(("0.0.0.0", port)).is_err()
            {
                port += 1;
            }
            ports.push(port);
            services.push(state_file);
        }
        unsafe {
            let handles: Vec<*mut WowtypeSync> = (0..2).map(|_| wowtype_sync_new()).collect();
            for (i, handle) in handles.iter().enumerate() {
                // C 接口没有测试用的旋钮（端口、额外的广播地址）：直接配里面的服务
                let mut config = Config::new(services[i].clone());
                config.enabled = true;
                config.device_name = ["书房", "客厅"][i].to_string();
                config.lan_port = ports[i];
                config.beacon_interval = Duration::from_millis(100);
                config.extra_targets = vec![format!("127.0.0.1:{}", ports[1 - i]).parse().unwrap()];
                (**handle).service.configure(config);
            }
            let wait = |probe: &mut dyn FnMut() -> bool| {
                let deadline = Instant::now() + Duration::from_secs(15);
                while !probe() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
                probe()
            };
            assert!(wait(&mut || {
                handles.iter().all(|h| {
                    CStr::from_ptr(wowtype_sync_status(*h))
                        .to_str()
                        .unwrap()
                        .contains("\"lan_peers\":1")
                })
            }));
            assert_eq!(wowtype_sync_observe(handles[0], c("原有的").as_ptr()), 0);
            assert_eq!(wowtype_sync_observe(handles[0], c("跨设备的一句").as_ptr()), 1);
            let mut got: *const c_char = std::ptr::null();
            assert!(wait(&mut || {
                if got.is_null() {
                    got = wowtype_sync_poll(handles[1]);
                }
                !got.is_null()
            }));
            assert_eq!(CStr::from_ptr(got).to_str().unwrap(), "跨设备的一句");
            assert_eq!(CStr::from_ptr(wowtype_sync_from(handles[1])).to_str().unwrap(), "书房");
            assert_eq!(
                crate::clipboard::history(),
                vec!["跨设备的一句".to_string()],
                "收到的记进剪贴板历史"
            );
            assert_eq!(crate::clipboard::entries()[0].device, "书房", "记着是哪台设备复制的");
            // 外壳把它写进系统剪贴板再报回来：不往回发
            assert_eq!(wowtype_sync_observe(handles[1], c("原有的 b").as_ptr()), 0);
            assert_eq!(wowtype_sync_observe(handles[1], c("跨设备的一句").as_ptr()), 0);
            for handle in handles {
                (*handle).service.shutdown();
                wowtype_sync_free(handle);
            }
        }
        crate::clipboard::reset_for_test();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 等配对走到某个状态之外，返回（状态, 文字）。
    unsafe fn settle(pairing: *mut WowtypeSyncPairing, while_in: &[c_int]) -> (c_int, String) {
        let deadline = Instant::now() + Duration::from_secs(40);
        loop {
            let state = wowtype_sync_pairing_state(pairing);
            if !while_in.contains(&state) || Instant::now() > deadline {
                let text = CStr::from_ptr(wowtype_sync_pairing_text(pairing))
                    .to_str()
                    .unwrap()
                    .to_string();
                return (state, text);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    // 两台设备用 C 接口在本机配对（和 Linux 设置界面调命令行是同一套代码）
    #[cfg(unix)]
    #[test]
    fn pair_through_the_c_interface() {
        let dir = std::env::temp_dir().join(format!("wowtype-sync-ffi-pair-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let (a, b) = (c(dir.join("a.json").to_str().unwrap()), c(dir.join("b.json").to_str().unwrap()));
        let (name_a, name_b) = (c("书房"), c("客厅"));
        let config = |state: &CString, name: &CString| WowtypeSyncPairConfig {
            size: std::mem::size_of::<WowtypeSyncPairConfig>() as u32,
            state_file: state.as_ptr(),
            device_name: name.as_ptr(),
            lan: 1,
            relay_url: std::ptr::null(),
            relay_key_file: std::ptr::null(),
        };
        unsafe {
            let paired = |state: &CString| {
                CStr::from_ptr(wowtype_sync_paired(state.as_ptr())).to_str().unwrap().to_string()
            };
            assert!(paired(&a).contains("\"paired\":false"));
            // 取消：没配成不留下组密钥
            let host = wowtype_sync_pair_host(&config(&a, &name_a));
            let (state, code) = settle(host, &[SYNC_PAIR_STARTING]);
            assert_eq!(state, SYNC_PAIR_WAITING);
            assert!(code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit()), "{code}");
            wowtype_sync_pairing_free(host);
            std::thread::sleep(Duration::from_millis(400));
            assert!(paired(&a).contains("\"paired\":false"));

            // 没人主持时加入：说得出原因
            let join = wowtype_sync_pair_join(&config(&b, &name_b), c("12345").as_ptr());
            assert_eq!(settle(join, &[SYNC_PAIR_STARTING]), (SYNC_PAIR_FAILED, "配对码是 6 位数字".to_string()));
            wowtype_sync_pairing_free(join);

            // 真配一次。主持的在局域网上广播；这里靠广播找（同一台机器收得到自己的广播）
            let host = wowtype_sync_pair_host(&config(&a, &name_a));
            let (_, code) = settle(host, &[SYNC_PAIR_STARTING]);
            let join = wowtype_sync_pair_join(&config(&b, &name_b), c(&code).as_ptr());
            let joined = settle(join, &[SYNC_PAIR_STARTING]);
            if joined.0 == SYNC_PAIR_FAILED && joined.1.contains("没找到") {
                // 没有能广播的网卡（有的 CI 容器）：这一步跳过
                eprintln!("skip：这台机器上广播收不到自己（{}）", joined.1);
                wowtype_sync_pairing_free(join);
                wowtype_sync_pairing_free(host);
            } else {
                assert_eq!(joined, (SYNC_PAIR_DONE, "书房".to_string()));
                assert_eq!(settle(host, &[SYNC_PAIR_WAITING]), (SYNC_PAIR_DONE, "客厅".to_string()));
                wowtype_sync_pairing_free(join);
                wowtype_sync_pairing_free(host);
                assert!(paired(&a).contains("\"paired\":true") && paired(&a).contains("客厅"));
                assert!(paired(&b).contains("书房"));
                assert!(!paired(&a).contains("group_key"));
                assert_eq!(wowtype_sync_unpair(b.as_ptr()), 0);
                assert!(paired(&b).contains("\"paired\":false"));
                assert!(paired(&a).contains("\"paired\":true"), "取消配对只动自己");
            }

            // 设置不对、空指针
            let bad = wowtype_sync_pair_host(std::ptr::null());
            assert_eq!(wowtype_sync_pairing_state(bad), SYNC_PAIR_FAILED);
            wowtype_sync_pairing_free(bad);
            wowtype_sync_pairing_free(std::ptr::null_mut());
            assert_eq!(wowtype_sync_pairing_state(std::ptr::null_mut()), SYNC_PAIR_FAILED);
            assert_eq!(wowtype_sync_unpair(std::ptr::null()), -1);
            // 中转服务：没填地址、地址不对、没口令，都不联网就说得出原因
            assert_eq!(wowtype_sync_ping(std::ptr::null(), std::ptr::null()), -1);
            let key = dir.join("k");
            std::fs::write(&key, "t\n").unwrap();
            assert_eq!(
                wowtype_sync_ping(c("http://relay.example.com").as_ptr(), c(key.to_str().unwrap()).as_ptr()),
                -1
            );
            let why = CStr::from_ptr(crate::ffi::wowtype_last_error()).to_str().unwrap();
            assert!(why.contains("https://"), "{why}");
            assert_eq!(
                wowtype_sync_ping(c("https://relay.example.com").as_ptr(), c("/nonexistent/key").as_ptr()),
                -1
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn config_struct_matches_the_header() {
        let header = include_str!("../include/wowtype_core.h");
        for field in [
            "uint32_t size;",
            "int enabled;",
            "int lan;",
            "const char *relay_url;",
            "const char *relay_key_file;",
            "const char *state_file;",
            "const char *device_name;",
        ] {
            assert!(header.contains(field), "头文件里没有 {field}");
        }
        // 字段顺序和头文件一样
        let order: Vec<usize> = ["int enabled;", "int lan;", "*relay_url;", "*relay_key_file;", "*state_file;", "*device_name;"]
            .iter()
            .map(|f| header.find(f).unwrap())
            .collect();
        assert!(order.windows(2).all(|w| w[0] < w[1]));
    }
}
