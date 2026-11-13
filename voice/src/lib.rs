//! 语音输入核心（与平台解耦）。
//!
//! 链路：热键状态机 -> 采集 -> 重采样/分帧 -> VAD -> ASR 渠道 -> 上屏
//!
//! 平台相关部分（全局热键、麦克风、按键注入）放在独立模块并由上层组装，
//! 这样这部分逻辑可以在任何系统上单测。

pub mod asr;
pub mod audio;
#[cfg(feature = "capture")]
pub mod capture;
pub mod hotkey;
pub mod sink;
pub mod typer;
pub mod vad;
pub mod wav;
pub mod wtlocal;

pub use asr::{AsrChannel, MultiChannel, Transcript};
pub use audio::{CaptureFormat, Framer, Resampler, FRAME_SAMPLES, TARGET_RATE};
pub use hotkey::{Action, Mode, TriggerConfig, VoiceTrigger};
pub use sink::{ClipboardSink, CommandSink, StdoutSink, TextSink};
pub use typer::Typer;
pub use vad::Vad;
pub use wav::{read_wav, write_wav};

/// 一次语音会话的编排器：把热键动作、音频、识别、上屏串起来。
pub struct VoiceSession {
    trigger: VoiceTrigger,
    framer: Framer,
    vad: Vad,
    asr: MultiChannel,
    sink: Box<dyn TextSink>,
    typer: Typer,
    last_partial: String,
    on_screen: bool,
}

impl VoiceSession {
    pub fn new(
        cfg: TriggerConfig,
        asr: MultiChannel,
        sink: Box<dyn TextSink>,
        speak_as_you_type: bool,
    ) -> Self {
        Self {
            trigger: VoiceTrigger::new(cfg),
            framer: Framer::default(),
            // 时序对齐微信 VAD 配置：300ms 起始确认、480ms 结束挂起
            vad: Vad::with_confirm(6.0, vad::CONFIRM_FRAMES, vad::HANGOVER_FRAMES),
            asr,
            sink,
            typer: Typer::new(),
            last_partial: String::new(),
            on_screen: speak_as_you_type,
        }
    }

    /// 键按下：返回状态机动作
    pub fn on_key_down(&mut self, now: std::time::Instant) -> Vec<Action> {
        self.trigger.on_down(now)
    }

    /// 键松开：返回状态机动作
    pub fn on_key_up(&mut self, now: std::time::Instant) -> Vec<Action> {
        self.trigger.on_up(now)
    }

    /// 周期驱动：点按模式静音超时会返回 Stop
    pub fn tick(&mut self, now: std::time::Instant) -> Option<Action> {
        self.trigger.tick(now)
    }

    pub fn is_recording(&self) -> bool {
        self.trigger.is_recording()
    }

    /// 推入采集到的 16kHz PCM
    pub fn push_pcm(&mut self, pcm: &[i16], now: std::time::Instant) {
        if !self.trigger.is_recording() {
            return;
        }
        for frame in self.framer.push(pcm) {
            if self.vad.push(&frame) {
                self.trigger.note_voice(now);
            }
            self.asr.feed(&frame);
        }
        if self.on_screen {
            let partial = self
                .asr
                .partials()
                .first()
                .map(|(_, t)| t.to_string())
                .unwrap_or_default();
            if partial != self.last_partial {
                let update = self.typer.update(&partial);
                self.sink.apply(update);
                self.last_partial = partial;
            }
        }
    }

    /// 结束会话并把最终文本上屏
    pub fn finish(&mut self) -> Vec<Transcript> {
        if let Some(tail) = self.framer.flush() {
            self.asr.feed(&tail);
        }
        let results = self.asr.finish();
        if let Some(best) = results.first() {
            let update = self.typer.update(&best.text);
            self.sink.apply(update);
        }
        self.typer.finish();
        results
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn session_runs_end_to_end() {
        let t0 = Instant::now();
        let mut s = VoiceSession::new(
            TriggerConfig::default(),
            MultiChannel::new(vec![Box::new(asr::MockChannel::new("mock"))]),
            Box::new(StdoutSink),
            false,
        );
        let key = |_: ()| ();
        key(());
        s.trigger.on_down(t0);
        s.push_pcm(&vec![0i16; 1600], t0 + Duration::from_millis(200));
        let out = s.finish();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].text, "mock:1600");
    }
}
