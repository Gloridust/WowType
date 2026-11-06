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

/// 把命令行拆成参数，支持单/双引号和反斜杠转义。
///
/// 不能直接用 split_whitespace：模型路径里常有空格（如
/// "/home/me/My Models/ggml.bin"，按空格切会把它拆坏。
fn split_command(cmdline: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    let mut has_token = false;
    let mut chars = cmdline.chars().peekable();
    while let Some(ch) = chars.next() {
        match quote {
            Some(q) => {
                if ch == q {
                    quote = None;
                } else if ch == '\\' && q == '"' {
                    if let Some(next) = chars.next() {
                        cur.push(next);
                    }
                } else {
                    cur.push(ch);
                }
            }
            None => match ch {
                '\'' | '"' => {
                    quote = Some(ch);
                    has_token = true;
                }
                c if c.is_whitespace() => {
                    if has_token || !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                        has_token = false;
                    }
                }
                '\\' => {
                    if let Some(next) = chars.next() {
                        cur.push(next);
                        has_token = true;
                    }
                }
                c => {
                    cur.push(c);
                    has_token = true;
                }
            },
        }
    }
    if has_token || !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// 命令行里可以用 \`{wav}\` 指定音频路径的位置；没写的话就追加到末尾。
pub const WAV_PLACEHOLDER: &str = "{wav}";

impl ProcessChannel {
    pub fn new(name: impl Into<String>, program: Vec<String>) -> Self {
        Self {
            name: name.into(),
            program,
            pcm: Vec::new(),
        }
    }

    pub fn from_command_line(name: impl Into<String>, cmdline: &str) -> Self {
        Self::new(name, split_command(cmdline))
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
        use std::sync::atomic::{AtomicUsize, Ordering};
        static SEQ: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "wowtype-asr-{}-{}.wav",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        if crate::wav::write_wav(&path, &self.pcm).is_err() {
            return None;
        }
        let wav_path = path.to_string_lossy().to_string();
        let mut argv = self.program.clone();
        let mut replaced = false;
        for arg in argv.iter_mut() {
            if arg.contains(WAV_PLACEHOLDER) {
                *arg = arg.replace(WAV_PLACEHOLDER, &wav_path);
                replaced = true;
            }
        }
        if !replaced {
            argv.push(wav_path);
        }
        let (program, args) = argv.split_first()?;
        let output = std::process::Command::new(program).args(args).output().ok();
        let _ = std::fs::remove_file(&path);
        self.pcm.clear();
        let output = output?;
        if !output.status.success() {
            return None;
        }
        let mut text = clean_transcript(&String::from_utf8_lossy(&output.stdout));
        if text.is_empty() {
            // 有些识别器把结果打到 stderr
            text = clean_transcript(&String::from_utf8_lossy(&output.stderr));
        }
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
    fn split_command_handles_quotes() {
        assert_eq!(
            split_command(r#"sh -c "echo 你好 世界""#),
            vec!["sh", "-c", "echo 你好 世界"]
        );
        assert_eq!(
            split_command("whisper-cli -m '/tmp/My Models/ggml.bin' -l zh"),
            vec!["whisper-cli", "-m", "/tmp/My Models/ggml.bin", "-l", "zh"]
        );
    }

    #[test]
    fn wav_placeholder_is_substituted() {
        // 识别器需要 --wav=路径 这种形式时，用占位符指定位置
        let mut ch =
            ProcessChannel::from_command_line("probe", r#"sh -c "test -f {wav} && echo ok""#);
        ch.feed(&[1i16; 160]);
        assert_eq!(ch.finish().as_deref(), Some("ok"));
    }

    #[test]
    fn falls_back_to_stderr() {
        let mut ch = ProcessChannel::new(
            "err",
            vec!["sh".into(), "-c".into(), "echo 你好 1>&2".into()],
        );
        ch.feed(&[1i16; 160]);
        assert_eq!(ch.finish().as_deref(), Some("你好"));
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
