//! 语音链路的端到端测试：合成音频 → VAD → WAV → 外部识别器 → 上屏。
//!
//! 这些都不需要麦克风，所以能在 CI/开发机上跑通。真正的采集（cpal）
//! 和全局热键（X11）只能在实机上验证。

use std::sync::{Arc, Mutex};

use wowtype_voice::asr::{AsrChannel, ProcessChannel};
use wowtype_voice::sink::TextSink;
use wowtype_voice::{read_wav, vad::Vad, write_wav, Typer};

const FRAME: usize = 160; // 16kHz 下 10ms

fn silence(frames: usize) -> Vec<i16> {
    vec![0i16; FRAME * frames]
}

fn tone(frames: usize, amplitude: i16) -> Vec<i16> {
    let mut out = Vec::with_capacity(FRAME * frames);
    for i in 0..FRAME * frames {
        // 简单的方波，保证能量稳定
        let v = if (i / 8) % 2 == 0 {
            amplitude
        } else {
            -amplitude
        };
        out.push(v);
    }
    out
}

#[test]
fn vad_separates_speech_from_silence() {
    let mut vad = Vad::new(6.0, 15);
    let mut speech = 0usize;
    let mut quiet_speech = 0usize;

    for chunk in silence(20).chunks(FRAME) {
        if vad.push(chunk) {
            quiet_speech += 1;
        }
    }
    for chunk in tone(20, 8000).chunks(FRAME) {
        if vad.push(chunk) {
            speech += 1;
        }
    }
    assert_eq!(quiet_speech, 0, "静音不应该被判为语音");
    assert_eq!(speech, 20, "持续音应当全程判为语音，实际 {speech}");

    // 挂起（hangover）结束后应当停止判语音
    let mut tail = 0usize;
    for chunk in silence(40).chunks(FRAME) {
        if vad.push(chunk) {
            tail += 1;
        }
    }
    assert!(tail <= 15, "挂起帧数应不超过配置的 15，实际 {tail}");
    assert!(!vad.is_speech(), "静音足够久后应停止录音");
}

#[test]
fn wav_roundtrip_preserves_samples() {
    let path = std::env::temp_dir().join(format!("wowtype_rt_{}.wav", std::process::id()));
    let samples = tone(10, 4000);
    write_wav(&path, &samples).expect("写 WAV 失败");
    let (rate, channels, back) = read_wav(&path).expect("读 WAV 失败");
    assert_eq!(rate, 16_000);
    assert_eq!(channels, 1);
    assert_eq!(back, samples);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn process_channel_receives_valid_wav() {
    // 用 {wav} 占位符让脚本自己检查文件是否存在且非空
    let mut ch =
        ProcessChannel::from_command_line("probe", r#"sh -c "test -s {wav} && echo 收到音频""#);
    ch.feed(&tone(10, 4000));
    assert_eq!(ch.finish().as_deref(), Some("收到音频"));
}

/// 捕获上屏内容的测试用后端
#[derive(Default, Clone)]
struct Capture {
    text: Arc<Mutex<String>>,
}

impl TextSink for Capture {
    fn insert(&mut self, text: &str) {
        self.text.lock().unwrap().push_str(text);
    }
    fn backspace(&mut self, count: usize) {
        let mut guard = self.text.lock().unwrap();
        for _ in 0..count {
            guard.pop();
        }
    }
}

#[test]
fn pipeline_types_partial_results() {
    let mut typer = Typer::new();
    let mut sink = Capture::default();

    // 模拟「边说边出字」：中间结果不断修正
    for partial in ["今天", "今天天", "今天天气"] {
        let update = typer.update(partial);
        sink.apply(update);
    }
    assert_eq!(sink.text.lock().unwrap().as_str(), "今天天气");

    // 识别器最后把中间结果整个改掉，Typer 应当退格重打
    let update = typer.update("明天");
    sink.apply(update);
    assert_eq!(sink.text.lock().unwrap().as_str(), "明天");
}
