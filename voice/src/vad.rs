//! 轻量能量 VAD：自适应噪声底 + 起始确认 + 挂起（hangover）。
//!
//! 只用来决定「用户还在说话吗」，驱动点按模式的静音自动结束；音频本身不经过它，
//! 不管判没判成语音都照样送进识别。
//!
//! 起始确认用一个「漏桶」计数：有声帧 +1、静音帧 -1（不低于 0、不高于确认帧数），
//! 到确认帧数才算说话。一两帧的敲键声攒不够；字中间塞音那一两帧的停顿只扣掉一点，不会从头来。

/// 起始确认：净有声 5 帧（100ms）才算开始说话。
///
/// 短到能接住单个字（「好」「嗯」的有声段一般 150ms 以上），又能挡住 1～3 帧的敲键、
/// 点鼠标。点按模式下开口后要过这么久才续命，所以确认越长，开口晚了越容易被静音超时截断。
pub const ONSET_FRAMES: u32 = 5;
/// 结束挂起：最后一个有声帧后 24 帧（480ms）内仍算有声，同微信输入法 VAD 的 `end_padding_ms`。
///
/// 点按模式的自动结束 = 最后一个有声帧 + 480ms + 静音超时（默认 1.5s），约 2 秒。
pub const HANGOVER_FRAMES: u32 = 24;

#[derive(Debug)]
pub struct Vad {
    noise_floor: f32,
    /// 高于噪声底多少 dB 判为语音
    threshold_db: f32,
    /// 语音帧后仍算「有声」的帧数
    hangover: u32,
    left: u32,
    /// 起始确认需要的净有声帧数（1 = 立即生效）
    onset: u32,
    /// 漏桶计数：有声 +1、静音 -1，夹在 0..=onset
    score: u32,
    speech: bool,
}

impl Default for Vad {
    fn default() -> Self {
        Self::new(6.0, HANGOVER_FRAMES).with_onset(ONSET_FRAMES)
    }
}

impl Vad {
    /// 不带起始确认：一帧有声就算说话。
    pub fn new(threshold_db: f32, hangover_frames: u32) -> Self {
        Self {
            // 全幅能量为 1.0（0 dB）；静音底取约 -60 dB
            noise_floor: 1e-6,
            threshold_db,
            hangover: hangover_frames,
            left: 0,
            onset: 1,
            score: 0,
            speech: false,
        }
    }

    /// 起始确认：净有声 `frames` 帧才算开始说话。
    pub fn with_onset(mut self, frames: u32) -> Self {
        self.onset = frames.max(1);
        self
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

        let floor_db = 10.0 * self.noise_floor.max(1e-10).log10();
        let active = db > floor_db + self.threshold_db;

        if active {
            self.score = (self.score + 1).min(self.onset);
        } else {
            self.score = self.score.saturating_sub(1);
            // 噪声底只在非语音帧上缓慢跟随
            self.noise_floor = self.noise_floor * 0.98 + energy * 0.02;
        }

        if active && self.score >= self.onset {
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

    /// 按 (帧数, 是否有声) 推一串 20ms 帧，返回每帧的判定
    fn run(v: &mut Vad, spec: &[(usize, bool)]) -> Vec<bool> {
        spec.iter()
            .flat_map(|&(n, on)| vec![on; n])
            .map(|on| v.push(&if on { loud(320) } else { silence(320) }))
            .collect()
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
        // 默认带起始确认：第 ONSET_FRAMES 帧起判为语音
        let mut v = Vad::default();
        let out = run(&mut v, &[(8, true)]);
        let first = out.iter().position(|&s| s).unwrap();
        assert_eq!(first + 1, ONSET_FRAMES as usize);
        assert!(out[first..].iter().all(|&s| s));
    }

    #[test]
    fn hangover_keeps_speech_briefly() {
        let mut v = Vad::new(6.0, 3);
        run(&mut v, &[(5, true)]);
        assert_eq!(run(&mut v, &[(4, false)]), [true, true, true, false]);
    }

    #[test]
    fn new_is_immediate() {
        // Vad::new 不带确认，保持原语义：第一帧有声就算
        let mut v = Vad::new(6.0, 15);
        assert!(v.push(&loud(320)));
    }

    #[test]
    fn confirm_needs_sustained_speech() {
        let mut v = Vad::new(6.0, 3).with_onset(5);
        assert_eq!(
            run(&mut v, &[(5, true)]),
            [false, false, false, false, true]
        );
    }

    #[test]
    fn key_click_is_not_speech() {
        // 1～3 帧的敲键声，中间隔开，都攒不够确认
        let mut v = Vad::default();
        let spec = [
            (2, true),
            (6, false),
            (3, true),
            (6, false),
            (1, true),
            (4, false),
        ];
        assert!(run(&mut v, &spec).iter().all(|&s| !s));
    }

    #[test]
    fn confirm_tolerates_short_gap() {
        // 字里塞音的一两帧停顿只扣分不清零：3 有声 + 1 静音 + 3 有声 => 第 7 帧确认
        let mut v = Vad::new(6.0, 3).with_onset(5);
        let out = run(&mut v, &[(3, true), (1, false), (3, true)]);
        assert_eq!(out, [false, false, false, false, false, false, true]);
    }

    #[test]
    fn confirm_resets_after_silence() {
        // 停顿够长（≥ 已攒的帧数）计数就漏光，要重新确认
        let mut v = Vad::new(6.0, 3).with_onset(5);
        let out = run(&mut v, &[(4, true), (4, false), (4, true)]);
        assert!(out.iter().all(|&s| !s));
        assert!(run(&mut v, &[(1, true)])[0]);
    }

    #[test]
    fn default_timing() {
        // 20ms 一帧：起始确认 100ms；挂起 480ms（微信输入法 VAD 的 end_padding_ms）
        assert_eq!(ONSET_FRAMES * 20, 100);
        assert_eq!(HANGOVER_FRAMES * 20, 480);
        let mut v = Vad::default();
        let out = run(&mut v, &[(10, true), (30, false)]);
        let tail = out[10..].iter().take_while(|&&s| s).count();
        assert_eq!(tail, HANGOVER_FRAMES as usize);
    }
}
