//! 本地翻译模型的运行时：按需起一个 `llama-server`，闲置一段时间后停掉。
//!
//! 不把 llama.cpp 编进插件：用户自己装 `llama-server`（发行版的 llama.cpp 包，或者官方发布的
//! 二进制），我们只管它的生命周期。
//!
//! - 第一次翻译时才启动：没打开互译、没选本地模型时，不起进程、不占端口
//! - 只监听 127.0.0.1，端口每次随机挑一个空闲的（不会和别的服务抢）
//! - 闲置 `idle_secs` 秒后停掉，把 1 GB 多的内存还给系统；下一次翻译再起
//! - 进程意外退出（被 OOM 杀掉等）时，下一次翻译自动重起

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

/// 默认的模型文件名（腾讯 HY-MT 1.5 1.8B，Q4_K_M 量化）。
pub const MODEL_FILE: &str = "HY-MT1.5-1.8B-Q4_K_M.gguf";

/// 等模型载入的最长时间。老机器从机械硬盘读 1 GB 也够了。
const LOAD_TIMEOUT: Duration = Duration::from_secs(90);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalConfig {
    /// GGUF 模型文件。
    pub model: PathBuf,
    /// `llama-server` 可执行文件；只写名字时在 PATH 里找。
    pub server: String,
    /// 闲置多少秒后停掉；0 表示一直开着（直到关掉互译或退出输入法）。
    pub idle_secs: u64,
}

/// 把开头的 `~/` 换成家目录（设置里常这么写）。
pub fn expand_home(path: &str) -> PathBuf {
    match (path.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(path),
    }
}

impl LocalConfig {
    pub fn model_exists(&self) -> bool {
        self.model.is_file()
    }

    /// 找 llama-server：写了路径就用路径，只写名字就在 PATH 里找。找不到返回 None。
    pub fn server_path(&self) -> Option<PathBuf> {
        let name = if self.server.trim().is_empty() {
            "llama-server"
        } else {
            self.server.trim()
        };
        if name.contains('/') {
            let path = PathBuf::from(name);
            return is_executable(&path).then_some(path);
        }
        let path = std::env::var_os("PATH")?;
        std::env::split_paths(&path)
            .map(|dir| dir.join(name))
            .find(|p| is_executable(p))
    }
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

struct Running {
    child: Child,
    port: u16,
    config: LocalConfig,
}

#[derive(Default)]
struct State {
    running: Option<Running>,
    last_used: Option<Instant>,
    /// 正在用它的请求数；不为 0 时不会因为闲置被停掉。
    busy: usize,
    /// 换配置、退出时置位，让看门狗线程退出。
    generation: u64,
    /// 有线程正在等模型载入；别的线程等它载完再用。
    starting: bool,
}

/// 一个 llama-server 进程的管理者。可以在多个线程里共享。
pub struct LocalServer {
    state: Arc<(Mutex<State>, Condvar)>,
}

impl Default for LocalServer {
    fn default() -> Self {
        Self::new()
    }
}

/// 一次请求期间持有；放掉时记下「最后用过」的时间。
pub struct Lease {
    state: Arc<(Mutex<State>, Condvar)>,
    pub base_url: String,
}

impl Drop for Lease {
    fn drop(&mut self) {
        let (lock, cvar) = &*self.state;
        if let Ok(mut s) = lock.lock() {
            s.busy = s.busy.saturating_sub(1);
            s.last_used = Some(Instant::now());
        }
        cvar.notify_all();
    }
}

impl LocalServer {
    pub fn new() -> Self {
        Self {
            state: Arc::new((Mutex::new(State::default()), Condvar::new())),
        }
    }

    /// 现在有没有在跑（测试和设置界面用）。
    pub fn is_running(&self) -> bool {
        let mut s = self.state.0.lock().unwrap();
        alive(&mut s)
    }

    /// 进程号（测试用）。
    pub fn pid(&self) -> Option<u32> {
        let s = self.state.0.lock().unwrap();
        s.running.as_ref().map(|r| r.child.id())
    }

    /// 确保服务在跑，返回 OpenAI 格式的地址（`http://127.0.0.1:端口/v1`）。
    ///
    /// 会阻塞到模型载入完（第一次要几秒），只能在后台线程里调。
    pub fn acquire(&self, config: &LocalConfig) -> Result<Lease, String> {
        let (lock, cvar) = &*self.state;
        let mut s = lock.lock().unwrap();
        while s.starting {
            s = cvar.wait(s).unwrap();
        }
        if s.running.as_ref().is_some_and(|r| &r.config != config) {
            stop(&mut s);
        }
        if !alive(&mut s) {
            if !config.model_exists() {
                return Err(format!(
                    "翻译失败：还没下载本地模型（{}）",
                    config.model.display()
                ));
            }
            let server = config.server_path().ok_or_else(|| {
                "翻译失败：没找到 llama-server（装上 llama.cpp，或者在设置里填它的路径）"
                    .to_string()
            })?;
            let port = free_port().ok_or("翻译失败：找不到空闲端口")?;
            let child = Command::new(&server)
                .arg("-m")
                .arg(&config.model)
                .args(["--host", "127.0.0.1", "--port", &port.to_string()])
                // 一句话用不了多少上下文；一个并发槽，内存最省
                .args(["-c", "2048", "-np", "1"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| format!("翻译失败：启动 llama-server 失败（{e}）"))?;
            s.running = Some(Running {
                child,
                port,
                config: config.clone(),
            });
            s.generation += 1;
            s.starting = true;
            let generation = s.generation;
            drop(s);
            // 等模型载入：不拿着锁，免得插件线程的 poll / 配置被卡住
            let ready = wait_healthy(port, LOAD_TIMEOUT, || {
                let mut s = lock.lock().unwrap();
                s.generation == generation && alive(&mut s)
            });
            s = lock.lock().unwrap();
            s.starting = false;
            cvar.notify_all();
            if s.generation != generation {
                return Err("翻译已取消".to_string());
            }
            if let Err(message) = ready {
                stop(&mut s);
                return Err(message);
            }
            if config.idle_secs > 0 {
                spawn_watchdog(
                    Arc::clone(&self.state),
                    generation,
                    Duration::from_secs(config.idle_secs),
                );
            }
        }
        let port = s.running.as_ref().map(|r| r.port).unwrap_or(0);
        s.busy += 1;
        s.last_used = Some(Instant::now());
        cvar.notify_all();
        Ok(Lease {
            state: Arc::clone(&self.state),
            base_url: format!("http://127.0.0.1:{port}/v1"),
        })
    }

    /// 马上停掉（关掉互译、换了模型、退出输入法时）。
    pub fn shutdown(&self) {
        let (lock, cvar) = &*self.state;
        let mut s = lock.lock().unwrap();
        stop(&mut s);
        cvar.notify_all();
    }
}

impl Drop for LocalServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn alive(s: &mut State) -> bool {
    match s.running.as_mut() {
        Some(r) => match r.child.try_wait() {
            Ok(None) => true,
            _ => {
                s.running = None;
                false
            }
        },
        None => false,
    }
}

fn stop(s: &mut State) {
    s.generation += 1;
    if let Some(mut r) = s.running.take() {
        let _ = r.child.kill();
        let _ = r.child.wait();
    }
}

fn free_port() -> Option<u16> {
    // 让系统挑一个；放掉以后马上给 llama-server 用。极少数情况下会被别人抢走，
    // 那样 llama-server 起不来，wait_healthy 会报错，下一次翻译换个端口重来。
    let listener = TcpListener::bind("127.0.0.1:0").ok()?;
    listener.local_addr().ok().map(|a| a.port())
}

/// 轮询 `/health`，直到返回 200（模型载入完）。keep_going 返回 false 时提前放弃。
fn wait_healthy(
    port: u16,
    timeout: Duration,
    mut keep_going: impl FnMut() -> bool,
) -> Result<(), String> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if !keep_going() {
            return Err("翻译失败：llama-server 启动后退出了（模型文件对吗？）".to_string());
        }
        if health(port) == Some(200) {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(150));
    }
    Err("翻译失败：本地模型载入超时".to_string())
}

/// GET /health 的状态码；连不上返回 None。只发最简单的 HTTP/1.0 请求，不需要 curl。
pub fn health(port: u16) -> Option<u16> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(300)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .write_all(b"GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
        .ok()?;
    let mut head = [0u8; 64];
    let n = stream.read(&mut head).ok()?;
    let line = std::str::from_utf8(&head[..n]).ok()?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// 看门狗：闲置超过 idle 就停掉。配置换了（generation 变了）就退出。
fn spawn_watchdog(state: Arc<(Mutex<State>, Condvar)>, generation: u64, idle: Duration) {
    thread::Builder::new()
        .name("wowtype-llama-idle".into())
        .spawn(move || {
            let (lock, cvar) = &*state;
            let mut s = lock.lock().unwrap();
            loop {
                if s.generation != generation || s.running.is_none() {
                    return;
                }
                let wait = if s.busy > 0 {
                    idle
                } else {
                    let since = s.last_used.map(|t| t.elapsed()).unwrap_or(idle);
                    if since >= idle {
                        stop(&mut s);
                        return;
                    }
                    idle - since
                };
                s = cvar.wait_timeout(s, wait).unwrap().0;
            }
        })
        .ok();
}

/// 测试用的假 llama-server（translate 的测试也用）。
#[cfg(test)]
pub(crate) mod test_support {
    use std::path::{Path, PathBuf};

    /// 一个 Python 小服务：/health 先装 0.3 秒在载入（503）再回 200；
    /// /v1/chat/completions 按 OpenAI 格式流式返回，提示词里要求译成英语就回 Hello，否则回「你好」。
    pub fn fake_server(dir: &Path) -> PathBuf {
        let path = dir.join("fake-llama-server");
        std::fs::write(
            &path,
            r#"#!/usr/bin/env python3
import sys, time, json, http.server
port = int(sys.argv[sys.argv.index("--port") + 1])
start = time.time()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code = 200 if time.time() - start > 0.3 else 503
        self.send_response(code); self.end_headers(); self.wfile.write(b"{}")
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = body["messages"][-1]["content"]
        reply = "Hello" if "翻译为英语" in prompt else "你好"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream"); self.end_headers()
        for piece in (reply[:2], reply[2:]):
            chunk = {"choices": [{"delta": {"content": piece}}]}
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
"#,
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_server(dir: &Path) -> PathBuf {
        super::test_support::fake_server(dir)
    }

    #[test]
    fn expand_home_only_touches_tilde_slash() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expand_home("~/m.gguf"), PathBuf::from(&home).join("m.gguf"));
        assert_eq!(expand_home("/a/~/b"), PathBuf::from("/a/~/b"));
        assert_eq!(expand_home("~x"), PathBuf::from("~x"));
    }

    fn setup(idle_secs: u64) -> (tempdir::Dir, LocalConfig) {
        let dir = tempdir::Dir::new();
        let server = fake_server(dir.path());
        let model = dir.path().join("model.gguf");
        std::fs::write(&model, b"gguf").unwrap();
        let config = LocalConfig {
            model,
            server: server.to_string_lossy().into_owned(),
            idle_secs,
        };
        (dir, config)
    }

    /// 测试用的临时目录（不引入 tempfile 依赖）。
    mod tempdir {
        pub struct Dir(std::path::PathBuf);
        impl Dir {
            pub fn new() -> Self {
                use std::sync::atomic::{AtomicUsize, Ordering};
                static N: AtomicUsize = AtomicUsize::new(0);
                let p = std::env::temp_dir().join(format!(
                    "wowtype-llama-test-{}-{}",
                    std::process::id(),
                    N.fetch_add(1, Ordering::SeqCst)
                ));
                std::fs::create_dir_all(&p).unwrap();
                Dir(p)
            }
            pub fn path(&self) -> &std::path::Path {
                &self.0
            }
        }
        impl Drop for Dir {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
    }

    fn python_available() -> bool {
        Command::new("python3")
            .arg("-c")
            .arg("")
            .status()
            .is_ok_and(|s| s.success())
    }

    #[test]
    fn starts_on_demand_and_stops_when_idle() {
        if !python_available() {
            return;
        }
        let (_dir, config) = setup(1);
        let server = LocalServer::new();
        assert!(!server.is_running(), "没翻译之前不起进程");
        let lease = server.acquire(&config).unwrap();
        assert!(lease.base_url.starts_with("http://127.0.0.1:"));
        assert!(server.is_running());
        let pid = server.pid().unwrap();
        // 用着的时候不停
        thread::sleep(Duration::from_millis(1300));
        assert!(server.is_running(), "请求没结束不该停");
        drop(lease);
        // 再复用同一个进程
        let lease = server.acquire(&config).unwrap();
        assert_eq!(server.pid(), Some(pid), "还在跑就复用");
        drop(lease);
        let deadline = Instant::now() + Duration::from_secs(5);
        while server.is_running() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(100));
        }
        assert!(!server.is_running(), "闲置 1 秒后应该停掉");
        // 停了以后下一次翻译重新起
        let _lease = server.acquire(&config).unwrap();
        assert!(server.is_running());
        assert_ne!(server.pid(), Some(pid));
    }

    #[test]
    fn restarts_after_crash_and_shutdown_kills() {
        if !python_available() {
            return;
        }
        let (_dir, config) = setup(0);
        let server = LocalServer::new();
        drop(server.acquire(&config).unwrap());
        let pid = server.pid().unwrap();
        Command::new("kill").arg(pid.to_string()).status().unwrap();
        thread::sleep(Duration::from_millis(200));
        drop(server.acquire(&config).unwrap());
        assert_ne!(server.pid(), Some(pid), "进程没了就重起");
        server.shutdown();
        assert!(!server.is_running());
    }

    #[test]
    fn missing_model_or_server() {
        let (_dir, mut config) = setup(0);
        let server = LocalServer::new();
        let mut missing = config.clone();
        missing.model = PathBuf::from("/nonexistent/model.gguf");
        assert!(server.acquire(&missing).err().unwrap().contains("还没下载"));
        config.server = "/nonexistent/llama-server".to_string();
        assert!(server
            .acquire(&config)
            .err()
            .unwrap()
            .contains("没找到 llama-server"));
        assert!(!server.is_running());
    }
}
