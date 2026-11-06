//! 识别渠道抽象。
//!
//! 一个渠道可以是云端流式（WebSocket/HTTP）也可以是本地引擎（sherpa-onnx、
//! whisper.cpp 等）。上层只关心：喂音频、取中间结果、取最终结果。

/// 一次识别结果
#[derive(Clone, Debug, PartialEq)]
pub struct Transcript {
    pub channel: String,
    pub text: String,
    pub latency_ms: u64,
    pub is_final: bool,
}

pub trait AsrChannel: Send {
    fn name(&self) -> &str;
    /// 喂入 16kHz 单声道 PCM
    fn feed(&mut self, pcm: &[i16]);
    /// 当前中间结果（边说边出字）
    fn partial(&self) -> Option<&str> {
        None
    }
    /// 结束并取最终结果
    fn finish(&mut self) -> Option<String>;
}

/// 多渠道并跑：任一渠道出最终结果即可参与候选
pub struct MultiChannel {
    channels: Vec<Box<dyn AsrChannel>>,
}

impl MultiChannel {
    pub fn new(channels: Vec<Box<dyn AsrChannel>>) -> Self {
        Self { channels }
    }

    pub fn feed(&mut self, pcm: &[i16]) {
        for c in &mut self.channels {
            c.feed(pcm);
        }
    }

    pub fn partials(&self) -> Vec<(&str, &str)> {
        self.channels
            .iter()
            .filter_map(|c| c.partial().map(|p| (c.name(), p)))
            .collect()
    }

    pub fn finish(&mut self) -> Vec<Transcript> {
        let mut out = Vec::new();
        for c in &mut self.channels {
            if let Some(text) = c.finish() {
                if !text.is_empty() {
                    out.push(Transcript {
                        channel: c.name().to_string(),
                        text,
                        latency_ms: 0,
                        is_final: true,
                    });
                }
            }
        }
        out
    }
}

/// 测试/占位用渠道：把收到的音频长度当作「识别结果」
#[derive(Debug, Default)]
pub struct MockChannel {
    name: String,
    samples: usize,
}

impl MockChannel {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            samples: 0,
        }
    }
}

impl AsrChannel for MockChannel {
    fn name(&self) -> &str {
        &self.name
    }
    fn feed(&mut self, pcm: &[i16]) {
        self.samples += pcm.len();
    }
    fn finish(&mut self) -> Option<String> {
        Some(format!("{}:{}", self.name, self.samples))
    }
}

/// 外部命令式识别渠道：把整段音频写成 WAV，交给命令行识别器，读 stdout。
///
/// 这样在 Linux 上不用编译任何原生绑定就能接 whisper.cpp / sherpa-onnx：
///
/// ```text
/// whisper-cli -m ggml-large-v3-turbo.bin -l zh -nt -f
/// sherpa-onnx-offline --tokens=... --paraformer=... --wav=
/// ```
///
/// 命令末尾会自动追加 WAV 路径。
pub struct ProcessChannel {
    name: String,
    program: Vec<String>,
    pcm: Vec<i16>,
}

impl ProcessChannel {
    pub fn new(name: impl Into<String>, program: Vec<String>) -> Self {
        Self {
            name: name.into(),
            program,
            pcm: Vec::new(),
        }
    }

    pub fn from_command_line(name: impl Into<String>, cmdline: &str) -> Self {
        let program = cmdline.split_whitespace().map(String::from).collect();
        Self::new(name, program)
    }

    pub fn sample_count(&self) -> usize {
        self.pcm.len()
    }
}

/// 去掉识别器常见的标记，如 [BLANK_AUDIO]、(音乐)、<|nospeech|>。
fn clean_transcript(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut depth = 0i32;
    for ch in text.chars() {
        match ch {
            '[' | '(' | '<' => depth += 1,
            ']' | ')' | '>' => {
                if depth > 0 {
                    depth -= 1;
                }
            }
            _ if depth == 0 => out.push(ch),
            _ => {}
        }
    }
    out.trim().to_string()
}

impl AsrChannel for ProcessChannel {
    fn name(&self) -> &str {
        &self.name
    }

    fn feed(&mut self, pcm: &[i16]) {
        self.pcm.extend_from_slice(pcm);
    }

    fn finish(&mut self) -> Option<String> {
        if self.pcm.is_empty() || self.program.is_empty() {
            return None;
        }
        let path = std::env::temp_dir().join(format!("wowtype-asr-{}.wav", std::process::id()));
        if crate::wav::write_wav(&path, &self.pcm).is_err() {
            return None;
        }
        let (program, args) = self.program.split_first()?;
        let output = std::process::Command::new(program)
            .args(args)
            .arg(&path)
            .output()
            .ok();
        let _ = std::fs::remove_file(&path);
        self.pcm.clear();
        let output = output?;
        if !output.status.success() {
            return None;
        }
        let text = clean_transcript(&String::from_utf8_lossy(&output.stdout));
        if text.is_empty() {
            None
        } else {
            Some(text)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_channel_runs_command() {
        // sh -c 'echo 你好'：WAV 路径会作为 $0 被忽略
        let mut ch =
            ProcessChannel::new("echo", vec!["sh".into(), "-c".into(), "echo 你好".into()]);
        ch.feed(&[1i16; 320]);
        let text = ch.finish().expect("应当有结果");
        assert_eq!(text, "你好");
    }

    #[test]
    fn clean_strips_tags() {
        assert_eq!(clean_transcript("[BLANK_AUDIO]你好(音乐)"), "你好");
    }

    #[test]
    fn multi_channel_collects_results() {
        let mut m = MultiChannel::new(vec![
            Box::new(MockChannel::new("a")),
            Box::new(MockChannel::new("b")),
        ]);
        m.feed(&[0i16; 320]);
        m.feed(&[0i16; 320]);
        let out = m.finish();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].text, "a:640");
        assert_eq!(out[1].text, "b:640");
    }
}
