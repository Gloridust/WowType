//! 轻量能量 VAD：自适应噪声底 + 挂起（hangover）。
//!
//! 不追求精度，只用于决定「用户还在说话吗」，驱动点按模式的自动结束。

#[derive(Debug)]
pub struct Vad {
    noise_floor: f32,
    /// 高于噪声底多少 dB 判为语音
    threshold_db: f32,
    /// 语音帧后仍算「有声」的帧数
    hangover: u32,
    left: u32,
    speech: bool,
}

impl Default for Vad {
    fn default() -> Self {
        Self::new(6.0, 15)
    }
}

impl Vad {
    pub fn new(threshold_db: f32, hangover_frames: u32) -> Self {
        Self {
            // 全幅能量为 1.0（0 dB）；静音底取约 -60 dB
            noise_floor: 1e-6,
            threshold_db,
            hangover: hangover_frames,
            left: 0,
            speech: false,
        }
    }

    pub fn is_speech(&self) -> bool {
        self.speech
    }

    pub fn noise_floor(&self) -> f32 {
        self.noise_floor
    }

    /// 输入一帧 16bit 采样，返回该帧是否算语音
    pub fn push(&mut self, frame: &[i16]) -> bool {
        if frame.is_empty() {
            return self.speech;
        }
        let energy = frame
            .iter()
            .map(|&s| (s as f32 / 32768.0).powi(2))
            .sum::<f32>()
            / frame.len() as f32;
        let db = 10.0 * (energy.max(1e-10)).log10();

        // 噪声底只在非语音段缓慢下降/上升
        let floor_db = 10.0 * self.noise_floor.max(1e-10).log10();
        let active = db > floor_db + self.threshold_db;

        if !active {
            self.noise_floor = self.noise_floor * 0.98 + energy * 0.02;
        }

        if active {
            self.left = self.hangover;
            self.speech = true;
        } else if self.left > 0 {
            self.left -= 1;
            self.speech = true;
        } else {
            self.speech = false;
        }
        self.speech
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn silence(n: usize) -> Vec<i16> {
        vec![0i16; n]
    }

    fn loud(n: usize) -> Vec<i16> {
        vec![8000i16; n]
    }

    #[test]
    fn silence_is_not_speech() {
        let mut v = Vad::default();
        for _ in 0..20 {
            assert!(!v.push(&silence(320)));
        }
    }

    #[test]
    fn loud_is_speech() {
        let mut v = Vad::default();
        let mut hit = false;
        for _ in 0..5 {
            hit |= v.push(&loud(320));
        }
        assert!(hit);
    }

    #[test]
    fn hangover_keeps_speech_briefly() {
        let mut v = Vad::new(6.0, 3);
        for _ in 0..5 {
            v.push(&loud(320));
        }
        assert!(v.push(&silence(320)));
        assert!(v.push(&silence(320)));
    }
}
