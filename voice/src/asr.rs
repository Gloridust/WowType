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

#[cfg(test)]
mod tests {
    use super::*;

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
