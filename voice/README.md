# wowtype-voice

语音输入的核心逻辑，与平台解耦，可在任何系统上单测。

## 模块

| 文件 | 作用 |
|---|---|
| `hotkey.rs` | 长按/点按触发状态机（300ms 区分长按，1.5s 静音自动结束） |
| `audio.rs` | 16kHz 单声道、20ms 分帧、线性重采样、多声道降混 |
| `vad.rs` | 自适应噪声底 + hangover 的能量 VAD |
| `asr.rs` | `AsrChannel` trait、多渠道并跑、中间结果 |
| `typer.rs` | 边说边上屏：公共前缀比对 + 退格补偿 |
| `sink.rs` | 上屏后端（stdout / wtype / ydotool） |

## Linux 上还缺的三块（平台层）

1. **全局热键**
   - X11：`XGrabKey` 抢占用单键（如 `Alt_R`），这会把按键从其它程序手里拿走，正是我们要的。
   - Wayland：没有全局热键 API。可行路线：
     - 首选 fcitx5 内拦截（输入法处于激活态时能收到所有按键，这条与平台无关）；
     - 非输入态用 `keyd`/`kanata` 把组合键映射成调用我们的 CLI；
     - 兜底用 evdev（`/dev/input/event*` + `EVIOCGRAB`，需要 `input` 组权限）。
2. **麦克风采集**：`cpal`（ALSA/PulseAudio/PipeWire 都走它），产物直接喂 `push_pcm`。
3. **上屏**
   - 输入法激活时：走 fcitx5 的 commit，最干净；
   - 非激活时：`wtype`（wlroots）/ `ydotool`（uinput）/ `xdotool`（X11）。

## 与 fcitx5 插件的关系

`fcitx5-addon` 里把语音做成一类输入状态：
- 收到热键 -> 进入语音模式（预编辑显示"正在听…"）
- 中间结果 -> 更新预编辑（可选：边说边上屏走 Typer 逻辑）
- 结束 -> 把最终文本 `commit`
- 多个渠道 -> 候选面板里列出各渠道结果，数字键选择

这样语音和拼音共用同一套候选面板与上屏路径。
