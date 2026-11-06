//! 音频格式、重采样、分帧。
//!
//! 引擎侧（与主流语音识别一致）统一使用 16kHz 单声道 16bit，20ms 一帧。

pub const TARGET_RATE: u32 = 16_000;
pub const FRAME_MS: u32 = 20;
pub const FRAME_SAMPLES: usize = (TARGET_RATE as usize * FRAME_MS as usize) / 1000;

/// 采集参数
#[derive(Clone, Copy, Debug)]
pub struct CaptureFormat {
    pub sample_rate: u32,
    pub channels: u16,
}

impl Default for CaptureFormat {
    fn default() -> Self {
        Self {
            sample_rate: 48_000,
            channels: 1,
        }
    }
}

/// 线性插值重采样；语音够用，且无外部依赖。
#[derive(Debug)]
pub struct Resampler {
    from: u32,
    to: u32,
    /// 上一个输入样本，用于跨界插值
    prev: f32,
    /// 小数相位，范围 [0,1)
    pos: f32,
    started: bool,
}

impl Resampler {
    pub fn new(from: u32, to: u32) -> Self {
        assert!(from > 0 && to > 0);
        Self {
            from,
            to,
            prev: 0.0,
            pos: 0.0,
            started: false,
        }
    }

    pub fn is_identity(&self) -> bool {
        self.from == self.to
    }

    /// 输入 f32 采样，输出重采样后的 f32；长度约为 len*to/from
    pub fn process(&mut self, input: &[f32]) -> Vec<f32> {
        if self.is_identity() {
            return input.to_vec();
        }
        let step = self.to as f32 / self.from as f32;
        let mut out = Vec::with_capacity((input.len() as f32 * step) as usize + 2);
        for &s in input {
            if !self.started {
                self.prev = s;
                self.started = true;
                continue;
            }
            // 在当前区间 [prev, s] 内按相位取样
            while self.pos < 1.0 {
                let v = self.prev + (s - self.prev) * self.pos;
                out.push(v);
                self.pos += 1.0 / step;
            }
            self.pos -= 1.0;
            self.prev = s;
        }
        out
    }
}

/// 把 f32 [-1,1] 转成 i16
pub fn to_i16(samples: &[f32]) -> Vec<i16> {
    samples
        .iter()
        .map(|v| (v.clamp(-1.0, 1.0) * 32767.0) as i16)
        .collect()
}

/// 多声道取平均转单声道
pub fn downmix(interleaved: &[f32], channels: u16) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    let ch = channels as usize;
    interleaved
        .chunks(ch)
        .map(|frame| frame.iter().sum::<f32>() / ch as f32)
        .collect()
}

/// 固定帧长切分器
#[derive(Debug, Default)]
pub struct Framer {
    buf: Vec<i16>,
}

impl Framer {
    pub fn push(&mut self, samples: &[i16]) -> Vec<Vec<i16>> {
        self.buf.extend_from_slice(samples);
        let mut frames = Vec::new();
        while self.buf.len() >= FRAME_SAMPLES {
            let rest = self.buf.split_off(FRAME_SAMPLES);
            frames.push(std::mem::replace(&mut self.buf, rest));
        }
        frames
    }

    pub fn flush(&mut self) -> Option<Vec<i16>> {
        if self.buf.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.buf))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_resample() {
        let mut r = Resampler::new(16000, 16000);
        let out = r.process(&[0.0, 0.5, -0.5]);
        assert_eq!(out, vec![0.0, 0.5, -0.5]);
    }

    #[test]
    fn down_sample_48k_to_16k_length() {
        let mut r = Resampler::new(48000, 16000);
        let input: Vec<f32> = (0..4800).map(|i| (i as f32 / 4800.0).sin()).collect();
        let out = r.process(&input);
        assert!((out.len() as i64 - 1600).abs() < 40, "got {}", out.len());
    }

    #[test]
    fn downmix_stereo() {
        let out = downmix(&[1.0, 0.0, 1.0, 1.0], 2);
        assert_eq!(out, vec![0.5, 1.0]);
    }

    #[test]
    fn framer_splits_320() {
        let mut f = Framer::default();
        let frames = f.push(&vec![0i16; 700]);
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].len(), FRAME_SAMPLES);
        assert_eq!(f.flush().unwrap().len(), 60);
        assert!(f.flush().is_none());
    }
}
