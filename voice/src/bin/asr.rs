//! 直接转写一个 WAV 文件（16kHz 单声道），用于在没有麦克风/热键的环境里验证离线引擎。
//!
//! ```
//! wowtype-asr --download audio.wav          # 首次会下载约 100MB 模型
//! wowtype-asr --dir ~/.local/share/wowtype/wtlocal audio.wav
//! ```

use std::path::PathBuf;

use wowtype_voice::asr::AsrChannel;
use wowtype_voice::wav;
use wowtype_voice::wtlocal::{download, WtLocalChannel};

fn fail(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut dir: Option<PathBuf> = None;
    let mut wav_path: Option<String> = None;
    let mut force_download = false;
    let mut show_partial = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--dir" => {
                i += 1;
                dir = args.get(i).map(PathBuf::from);
            }
            "--download" => force_download = true,
            "--partial" => show_partial = true,
            "-h" | "--help" => {
                println!("wowtype-asr [--dir 模型目录] [--download] [--partial] <文件.wav>");
                return;
            }
            other => wav_path = Some(other.to_string()),
        }
        i += 1;
    }

    let Some(wav_path) = wav_path else {
        fail("需要一个 WAV 文件路径（16kHz 单声道）");
    };
    let dir = dir.unwrap_or_else(download::default_dir);
    if force_download || !download::is_ready(&dir) {
        eprintln!("准备离线模型到 {}（首次约 100MB）…", dir.display());
        if let Err(e) = download::ensure(&dir) {
            fail(&format!("模型准备失败: {e:#}"));
        }
    }

    let (rate, channels, pcm) = match wav::read_wav(&wav_path) {
        Ok(v) => v,
        Err(e) => fail(&format!("读取 WAV 失败: {e:#}")),
    };
    if rate != 16_000 || channels != 1 {
        fail(&format!("需要 16kHz 单声道，当前 {rate}Hz {channels} 声道"));
    }
    eprintln!("音频 {:.1} 秒", pcm.len() as f32 / 16_000.0);

    let mut channel = match WtLocalChannel::new(&dir) {
        Ok(c) => c,
        Err(e) => fail(&format!("加载模型失败: {e:#}")),
    };
    let mut last = String::new();
    for chunk in pcm.chunks(1600) {
        channel.feed(chunk);
        if show_partial {
            if let Some(p) = channel.partial() {
                if p != last {
                    eprintln!("…{p}");
                    last = p.to_string();
                }
            }
        }
    }
    match channel.finish() {
        Some(text) => println!("{text}"),
        None => println!(""),
    }
}
