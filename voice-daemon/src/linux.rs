//! Linux 平台层：X11 全局热键 + cpal 采集。
//!
//! 只能在 Linux 上编译。Wayland 下没有全局热键 API，需要外部按键重映射工具
//! （keyd / kanata）把键映射成给本进程发信号，或只在 fcitx5 激活时用插件路径。

use crate::Options;
use anyhow::{anyhow, Context, Result};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};
use wowtype_voice::{
    asr::{MockChannel, MultiChannel, ProcessChannel},
    CommandSink, TextSink, VoiceSession,
};

#[derive(Debug, Clone, Copy)]
pub enum KeyMsg {
    Down,
    Up,
}

pub fn run(opt: Options) -> Result<()> {
    let cfg = crate::trigger_config(&opt);

    // 采集线程通过 channel 把 16k 单声道 PCM 送过来
    let (audio_tx, audio_rx) = channel::<Vec<i16>>();
    start_capture(opt.device.clone(), audio_tx).context("启动麦克风失败")?;

    // 热键线程
    let (key_tx, key_rx) = channel::<KeyMsg>();
    start_hotkey(opt.hotkey.clone(), key_tx).context("启动全局热键失败")?;

    let mut session = new_session(&opt);
    let mut last_tick = Instant::now();

    loop {
        while let Ok(msg) = key_rx.try_recv() {
            let now = Instant::now();
            match msg {
                KeyMsg::Down => {
                    let actions = session.on_key_down(now);
                    log_actions(&actions);
                }
                KeyMsg::Up => {
                    let actions = session.on_key_up(now);
                    log_actions(&actions);
                    if stops(&actions) {
                        finish_and_reset(&mut session, &opt);
                    }
                }
            }
        }

        while let Ok(pcm) = audio_rx.try_recv() {
            session.push_pcm(&pcm, Instant::now());
        }

        if last_tick.elapsed() >= Duration::from_millis(100) {
            last_tick = Instant::now();
            if session.tick(Instant::now()).is_some() {
                finish_and_reset(&mut session, &opt);
            }
        }

        std::thread::sleep(Duration::from_millis(10));
    }
}

fn stops(actions: &[wowtype_voice::Action]) -> bool {
    actions.iter().any(|a| *a == wowtype_voice::Action::Stop)
}

fn log_actions(actions: &[wowtype_voice::Action]) {
    for a in actions {
        println!("[热键] {:?}", a);
    }
}

fn new_session(opt: &Options) -> VoiceSession {
    VoiceSession::new(
        crate::trigger_config(opt),
        build_channel(opt),
        build_sink(),
        false,
    )
}

fn finish_and_reset(session: &mut VoiceSession, opt: &Options) {
    let results = session.finish();
    for t in &results {
        println!("[定稿] {} -> {}", t.channel, t.text);
    }
    if results.is_empty() {
        println!("[定稿] 没有识别结果");
    }
    *session = new_session(opt);
}

/// 有 --asr-cmd 就走外部识别器，否则用 Mock 验证链路。
fn build_channel(opt: &Options) -> MultiChannel {
    match opt.asr_cmd.as_deref() {
        Some(cmd) if !cmd.trim().is_empty() => {
            println!("识别渠道：外部命令 {cmd}");
            MultiChannel::new(vec![Box::new(ProcessChannel::from_command_line(
                "cmd", cmd,
            ))])
        }
        _ => {
            println!("识别渠道：Mock（仅用于验证链路）");
            MultiChannel::new(vec![Box::new(MockChannel::new("mock"))])
        }
    }
}

fn build_sink() -> Box<dyn TextSink> {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() {
        Box::new(CommandSink::wtype())
    } else {
        Box::new(CommandSink::ydotool())
    }
}

fn start_capture(device: Option<String>, tx: Sender<Vec<i16>>) -> Result<()> {
    let cap = wowtype_voice::capture::start(device.as_deref(), move |pcm| {
        let _ = tx.send(pcm);
    })
    .context("启动麦克风失败")?;
    println!(
        "麦克风：{}  {} Hz  {} 声道  {}",
        cap.info.device, cap.info.sample_rate, cap.info.channels, cap.info.format
    );
    // 进程常驻，故意泄漏以保持录音流存活
    std::mem::forget(cap);
    Ok(())
}

fn start_hotkey(name: String, tx: Sender<KeyMsg>) -> Result<()> {
    if std::env::var_os("DISPLAY").is_none() {
        return Err(anyhow!(
            "没有 DISPLAY。Wayland 下请用 keyd/kanata 把热键映射为调用本程序，或改用 fcitx5 插件路径"
        ));
    }
    std::thread::spawn(move || {
        if let Err(e) = hotkey_loop(&name, tx) {
            eprintln!("热键线程退出：{:#}", e);
        }
    });
    Ok(())
}

fn keysym_for(name: &str) -> Result<u32> {
    match name {
        "alt_r" | "alt" => Ok(0xffea),   // XK_Alt_R
        "ctrl_r" | "ctrl" => Ok(0xffe4), // XK_Control_R
        other => Err(anyhow!("不支持的热键：{}（可选 alt_r / ctrl_r）", other)),
    }
}

fn hotkey_loop(name: &str, tx: Sender<KeyMsg>) -> Result<()> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt, GrabMode, ModMask};
    use x11rb::protocol::Event;

    let keysym = keysym_for(name)?;
    let (conn, screen_num) = x11rb::connect(None)?;
    let root = conn.setup().roots[screen_num].root;

    // keysym -> keycode
    let setup = conn.setup();
    let min = setup.min_keycode;
    let count = setup.max_keycode - min + 1;
    let mapping = conn.get_keyboard_mapping(min, count)?.reply()?;
    let per = mapping.keysyms_per_keycode as usize;
    let mut keycode = None;
    for (i, chunk) in mapping.keysyms.chunks(per).enumerate() {
        if chunk.contains(&keysym) {
            keycode = Some(min + i as u8);
            break;
        }
    }
    let keycode = keycode.ok_or_else(|| anyhow!("键盘映射里找不到该键"))?;

    // 抢占用单键：任何修饰组合下都抓到
    conn.grab_key(
        true,
        root,
        ModMask::ANY,
        keycode,
        GrabMode::ASYNC,
        GrabMode::ASYNC,
    )?;
    conn.flush()?;
    println!("已占用 X11 键位 keycode={} ", keycode);

    loop {
        match conn.wait_for_event()? {
            Event::KeyPress(e) if e.detail == keycode => {
                let _ = tx.send(KeyMsg::Down);
            }
            Event::KeyRelease(e) if e.detail == keycode => {
                let _ = tx.send(KeyMsg::Up);
            }
            _ => {}
        }
    }
}

#[allow(dead_code)]
fn _unused(_: Receiver<Vec<i16>>) {}
