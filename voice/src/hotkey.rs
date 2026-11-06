//! 语音触发状态机：长按说话 / 点按说话。
//!
//! 语义（对齐主流输入法习惯）：
//! - 按下即开始录音
//! - 松开时按住时长 < hold_threshold(默认 300ms) => 判定为「点按」，
//!   继续录音，直到再次点按或静音超时
//! - 松开时按住时长 >= hold_threshold => 判定为「长按」，立即结束
//! - 同一个键可以同时充当长按键和点按键

use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Mode {
    #[default]
    Hold,
    Tap,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// 开始录音
    Start,
    /// 继续录音（点按已识别，等待静音或再次点按）
    Continue,
    /// 结束录音
    Stop,
}

#[derive(Clone, Copy, Debug)]
pub struct TriggerConfig {
    pub hold_threshold: Duration,
    pub silence_timeout: Duration,
}

impl Default for TriggerConfig {
    fn default() -> Self {
        Self {
            hold_threshold: Duration::from_millis(300),
            silence_timeout: Duration::from_millis(1500),
        }
    }
}

#[derive(Debug, Default)]
pub struct VoiceTrigger {
    cfg: TriggerConfig,
    recording: bool,
    mode: Mode,
    pressed_at: Option<Instant>,
    last_voice: Option<Instant>,
}

impl VoiceTrigger {
    pub fn new(cfg: TriggerConfig) -> Self {
        Self {
            cfg,
            recording: false,
            mode: Mode::Hold,
            pressed_at: None,
            last_voice: None,
        }
    }

    pub fn is_recording(&self) -> bool {
        self.recording
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// 键按下
    pub fn on_down(&mut self, now: Instant) -> Vec<Action> {
        if self.recording {
            // 点按模式下再次按下 = 提前结束
            if self.mode == Mode::Tap {
                self.reset();
                return vec![Action::Stop];
            }
            return Vec::new();
        }
        self.recording = true;
        self.mode = Mode::Hold;
        self.pressed_at = Some(now);
        self.last_voice = Some(now);
        vec![Action::Start]
    }

    /// 键松开
    pub fn on_up(&mut self, now: Instant) -> Vec<Action> {
        let Some(pressed) = self.pressed_at.take() else {
            return Vec::new();
        };
        if !self.recording {
            return Vec::new();
        }
        let held = now.saturating_duration_since(pressed);
        if held < self.cfg.hold_threshold {
            self.mode = Mode::Tap;
            self.last_voice = Some(now);
            vec![Action::Continue]
        } else {
            self.reset();
            vec![Action::Stop]
        }
    }

    /// 有语音活动（VAD 判定为说话）
    pub fn note_voice(&mut self, now: Instant) {
        if self.recording {
            self.last_voice = Some(now);
        }
    }

    /// 周期调用；点按模式下静音超时则返回 Stop
    pub fn tick(&mut self, now: Instant) -> Option<Action> {
        if !self.recording || self.mode != Mode::Tap {
            return None;
        }
        let last = self.last_voice.unwrap_or(now);
        if now.saturating_duration_since(last) >= self.cfg.silence_timeout {
            self.reset();
            Some(Action::Stop)
        } else {
            None
        }
    }

    fn reset(&mut self) {
        self.recording = false;
        self.mode = Mode::Hold;
        self.pressed_at = None;
        self.last_voice = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> TriggerConfig {
        TriggerConfig {
            hold_threshold: Duration::from_millis(300),
            silence_timeout: Duration::from_millis(1500),
        }
    }

    #[test]
    fn hold_stops_on_release() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        assert_eq!(tr.on_down(t0), vec![Action::Start]);
        assert!(tr.is_recording());
        assert_eq!(
            tr.on_up(t0 + Duration::from_millis(600)),
            vec![Action::Stop]
        );
        assert!(!tr.is_recording());
    }

    #[test]
    fn tap_keeps_recording() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        assert_eq!(tr.on_down(t0), vec![Action::Start]);
        assert_eq!(
            tr.on_up(t0 + Duration::from_millis(100)),
            vec![Action::Continue]
        );
        assert!(tr.is_recording());
        assert_eq!(tr.mode(), Mode::Tap);
    }

    #[test]
    fn tap_stops_on_silence() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        tr.on_down(t0);
        tr.on_up(t0 + Duration::from_millis(100));
        assert_eq!(tr.tick(t0 + Duration::from_millis(1000)), None);
        assert_eq!(
            tr.tick(t0 + Duration::from_millis(1700)),
            Some(Action::Stop)
        );
        assert!(!tr.is_recording());
    }

    #[test]
    fn voice_activity_extends_tap() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        tr.on_down(t0);
        tr.on_up(t0 + Duration::from_millis(100));
        tr.note_voice(t0 + Duration::from_millis(1500));
        assert_eq!(tr.tick(t0 + Duration::from_millis(2000)), None);
        assert_eq!(
            tr.tick(t0 + Duration::from_millis(3100)),
            Some(Action::Stop)
        );
    }

    #[test]
    fn second_tap_stops_immediately() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        tr.on_down(t0);
        tr.on_up(t0 + Duration::from_millis(80));
        assert_eq!(
            tr.on_down(t0 + Duration::from_millis(500)),
            vec![Action::Stop]
        );
        assert!(!tr.is_recording());
    }

    #[test]
    fn repeated_down_while_holding_is_ignored() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        tr.on_down(t0);
        assert!(tr.on_down(t0 + Duration::from_millis(50)).is_empty());
        assert!(tr.is_recording());
    }

    #[test]
    fn up_without_down_is_noop() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        assert!(tr.on_up(t0).is_empty());
        assert!(!tr.is_recording());
    }

    #[test]
    fn tick_when_idle_is_none() {
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        assert_eq!(tr.tick(t0 + Duration::from_secs(10)), None);
    }

    #[test]
    fn hold_mode_tick_never_stops() {
        // 长按模式靠松手结束，不该被静音超时打断
        let t0 = Instant::now();
        let mut tr = VoiceTrigger::new(cfg());
        tr.on_down(t0);
        assert_eq!(tr.tick(t0 + Duration::from_secs(5)), None);
        assert!(tr.is_recording());
    }
}
