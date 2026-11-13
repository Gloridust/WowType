//! 轻量能量 VAD：自适应噪声底 + 起始确认 + 挂起（hangover）。
//!
//! 时序参数对齐微信输入法的 VAD 配置（`Resources/vad/configure.16k.*.offline`）：
//! `begin_confirm_ms = 300`（连续有声 300ms 才算开始）、
//! `end_padding_ms = 480`（最后一个有声帧后 480ms 内仍算有声）。

/// 起始确认帧数：300ms / 20ms 一帧（微信 `begin_confirm_ms`）。
pub const CONFIRM_FRAMES: u32 = 15;
/// 结束挂起帧数：480ms / 20ms 一帧（微信 `end_padding_ms`）。
pub const HANGOVER_FRAMES: u32 = 24;

#[derive(Debug)]
pub struct Vad {
    noise_floor: f32,
    /// 高于噪声底多少 dB 判为语音
    threshold_db: f32,
    /// 语音帧后仍算「有声」的帧数
    hangover: u32,
    left: u32,
    /// 连续有声多少帧才算真的开始（防住敲键、咳嗽这类短促声）
    confirm: u32,
    /// 当前连续有声帧数
    run: u32,
    speech: bool,
}

impl Default for Vad {
    fn default() -> Self {
        Self::with_confirm(6.0, CONFIRM_FRAMES, HANGOVER_FRAMES)
    }
}

impl Vad {
    pub fn new(threshold_db: f32, hangover_frames: u32) -> Self {
        Self::with_confirm(threshold_db, 1, hangover_frames)
    }

    /// `confirm_frames`：连续多少帧有声才算开始；`hangover_frames`：之后还保持多少帧。
    pub fn with_confirm(threshold_db: f32, confirm_frames: u32, hangover_frames: u32) -> Self {
        Self {
            // 全幅能量为 1.0（0 dB）；静音底取约 -60 dB
            noise_floor: 1e-6,
            threshold_db,
            hangover: hangover_frames,
            left: 0,
            confirm: confirm_frames.max(1),
            run: 0,
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
            self.run = 0;
        }

        if active {
            self.run = self.run.saturating_add(1);
            if self.run >= self.confirm {
                self.left = self.hangover;
                self.speech = true;
            }
        } else if self.left > 0 {
            self.left -= 1;
            self.speech = true;
        } else {
            self.speech = false;
        }
        self.speech
    }
}