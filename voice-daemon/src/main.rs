//! wowtype-voiced：语音输入常驻进程。
//!
//! ```
//! wowtype-voiced --hotkey alt_r --mode tap --silence-ms 1500
//! ```
//!
//! 链路：全局热键 -> 采集 -> 重采样/分帧 -> VAD -> 识别 -> 上屏。
//! 识别渠道目前是 Mock（回显音频长度），用于先验证按键到上屏的整条链路；
//! 接真实引擎的位置在 `platform::build_channel`。

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as imp;

#[cfg(not(target_os = "linux"))]
mod other;
#[cfg(not(target_os = "linux"))]
use other as imp;

use std::process::ExitCode;
use std::time::Duration;
use wowtype_voice::TriggerConfig;

/// 启动参数
#[derive(Debug, Clone)]
pub struct Options {
    pub hotkey: String,
    pub mode: String,
    pub silence_ms: u64,
    pub device: Option<String>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            hotkey: "alt_r".into(),
            mode: "tap".into(),
            silence_ms: 1500,
            device: None,
        }
    }
}

fn parse_args() -> Options {
    let mut opt = Options::default();
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--hotkey" => opt.hotkey = it.next().unwrap_or_else(|| "alt_r".into()),
            "--mode" => opt.mode = it.next().unwrap_or_else(|| "tap".into()),
            "--silence-ms" => {
                opt.silence_ms = it.next().and_then(|v| v.parse().ok()).unwrap_or(1500)
            }
            "--device" => opt.device = it.next(),
            "--help" | "-h" => {
                println!(
                    "wowtype-voiced --hotkey alt_r|ctrl_r --mode tap|hold --silence-ms 1500 [--device 名称]"
                );
                std::process::exit(0);
            }
            other => eprintln!("未知参数：{}", other),
        }
    }
    opt
}

pub fn trigger_config(opt: &Options) -> TriggerConfig {
    TriggerConfig {
        hold_threshold: Duration::from_millis(300),
        silence_timeout: Duration::from_millis(opt.silence_ms),
    }
}

fn main() -> ExitCode {
    let opt = parse_args();
    println!(
        "wowtype-voiced 启动：hotkey={} mode={} silence={}ms",
        opt.hotkey, opt.mode, opt.silence_ms
    );
    match imp::run(opt) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("退出：{:#}", e);
            ExitCode::FAILURE
        }
    }
}
