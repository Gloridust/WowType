# 语音输入设计（Linux）

目标：在 Ubuntu 上提供与微信输入法一致的语音输入体验——按住说话、点按说话、
边说边上屏、多渠道候选——并与拼音输入共用同一个候选面板。

## 1. 链路

```
        ┌── fcitx5 addon（输入法激活时）──┐
热键 ───┤                                 ├──> 语音会话
        └── wowtype-voiced（常驻守护）────┘        │
                                                    ├─ cpal 采集 48k 立体声
                                                    ├─ 降混 + 重采样到 16k 单声道
                                                    ├─ 20ms 分帧 + 能量 VAD
                                                    ├─ ASR 渠道（可多路并发）
                                                    └─ 上屏 / 候选面板
```

已实现（`voice/`，20 个单测通过）：

| 模块 | 说明 |
|---|---|
| `hotkey.rs` | 按下即录音；松开<300ms 判点按继续录，≥300ms 判长按立即停；点按静音 1.5s 自动结束；再按一次提前结束 |
| `audio.rs` | 线性重采样、多声道降混、320 样本定长分帧 |
| `vad.rs` | 自适应噪声底（-60dB 起）+ hangover 15 帧 |
| `typer.rs` | 边说边上屏：公共前缀比对，退格差异部分后补打 |
| `asr.rs` | `AsrChannel` trait、多渠道并发、中间结果 |
| `sink.rs` | 上屏后端：stdout / wtype / ydotool |

## 2. 热键方案

默认键位（对齐 VoiceKey 的右 ⌥ / 右 ⌘）：

| 动作 | macOS（参考） | Linux 建议 |
|---|---|---|
| 长按说话 | 右 Option | `Alt_R` |
| 点按说话 | 右 Command | `Ctrl_R` |

单个修饰键同时承担长按与点按：快按快松为点按，按住 >300ms 为长按。

Linux 没有统一的全局热键 API，按优先级：

| 场景 | 方案 | 说明 |
|---|---|---|
| 输入法激活中 | fcitx5 拦截 | 最干净，不需要任何权限，且能直接 commit |
| X11 全局 | `XGrabKey` | 抢占用单键，事件被独占，正是需要的行为 |
| Wayland 全局 | `keyd` / `kanata` | 把组合键映射为调用 `wowtype-voice toggle` |
| Wayland 兜底 | evdev `EVIOCGRAB` | 需要 `input` 组权限，会独占设备 |

Wayland 下"抢一个键"本质上不被允许（安全模型），所以要么借外部按键重映射工具，
要么只在输入法激活时监听。这两条都写在 `fcitx5-addon` 的实现计划里。

## 3. 识别后端

### 微信离线（wtlocal，纯 Rust）

`voice/src/wtlocal/` 直接加载微信输入法的离线模型包并自己推理，**不需要官方程序**，
全平台可用（无系统依赖）。首次使用时从腾讯 CDN 下载约 100MB 模型并校验 MD5。

```bash
wowtype-voiced --asr wtlocal          # 首次会下载模型
wowtype-asr --download 音频.wav        # 或直接转写一个 WAV（16kHz 单声道）
```

实测（macOS TTS 合成语音，5 句全部正确）：

| 原文 | 识别 |
|---|---|
| 今天天气不错 | 今天天气不错。 |
| 明天下午三点开会 | 明天下午三点开会。 |
| 把这个文件发送给张三 | 把这个文件发送给张三。 |

1.7 秒音频推理约 0.16 秒（4 线程）。来源与适配说明见 `voice/src/wtlocal/NOTICE.md`。

| 后端 | 许可 | 中文效果 | 说明 |
|---|---|---|---|
| **sherpa-onnx** + Zipformer/Paraformer 中文模型 | Apache-2.0 | 好 | 推荐默认，纯本地，ONNX Runtime |
| whisper.cpp + large-v3-turbo | MIT | 中 | 多语种好，中文标点弱一些 |
| 云端渠道 | 各家条款 | 最好 | 需要网络与账号，可选 |

微信输入法自带的离线语音（`stt.bin` + `wx_asr_*` 那套，以及 VoiceKey 从
腾讯 CDN 拉的 `wtoffline` 模型）技术上也能接，但那颗模型是腾讯的资产，
再分发有风险，而且 VoiceKey 已经用 Rust 重写了它的 int8 推理（`crates/wtlocal`
约 40 层 Transformer + FBank）。我们把它列为可选实验项，不作为默认。

## 4. 与 fcitx5 的集成

在 addon 里把语音做成一种输入状态：

1. 收到热键 → 进入语音模式，预编辑显示「正在听…」
2. 中间结果 → 更新预编辑（或走 `Typer` 边说边上屏）
3. 结束 → 多路结果进入候选列表，数字键/回车选定后 `commit`
4. 取消 → 退格清掉已上屏内容（`Typer` 记录过，可精确回滚）

这样语音与拼音共用候选面板、翻页、用户词记录，不需要两套 UI。

## 5. 下一步

1. `cpal` 采集 + 设备选择（Ubuntu 上需要 `libasound2-dev`）
2. sherpa-onnx 绑定与模型下载脚本
3. fcitx5 addon 里的语音状态机接线
4. X11 全局热键守护进程（`wowtype-voiced`）
5. Wayland 下用 keyd 配置做热键的文档

## 6. 采集与识别（已落地）

### 麦克风采集

`voice/src/capture.rs`（feature `capture`，cpal）：

```rust
use wowtype_voice::capture;
let cap = capture::start(None, move |pcm: Vec<i16>| { /* 16kHz 单声道 */ })?;
```

- 支持 f32 / i16 / u16 三种采样格式，内部统一降混 + 重采样到 16kHz
- 跨平台：Linux 走 ALSA/PulseAudio，macOS 走 CoreAudio（所以能在 macOS 上编译验证）
- `capture::list_devices()` 枚举设备

### 识别后端

`ProcessChannel`：把整段音频写成 WAV，交给命令行识别器，读 stdout。
这样 Linux 上不用编译任何原生绑定：

```bash
# whisper.cpp
wowtype-voiced --asr-cmd 'whisper-cli -m ggml-large-v3-turbo.bin -l zh -nt -f'
# sherpa-onnx
wowtype-voiced --asr-cmd 'sherpa-onnx-offline --tokens=tokens.txt --paraformer=model.onnx'
```

命令末尾会自动追加 WAV 路径；输出会过滤 `[BLANK_AUDIO]`、`(音乐)`、`<|nospeech|>` 这类标记。

### WAV 工具

`voice/src/wav.rs` 提供 16kHz 单声道 16bit 的读写，无第三方依赖。

## 上屏后端与中文的坑

`sink.rs` 提供三种后端，**默认是剪贴板**：

| 后端 | 命令 | 中文 | 备注 |
|---|---|---|---|
| 剪贴板 | `wl-copy` + `wtype -M ctrl -k v -m ctrl`（Wayland） | ✅ | 需要 `wl-clipboard` |
| 剪贴板 | `xclip -selection clipboard` + `xdotool key ctrl+v`（X11） | ✅ | 需要 `xclip`、`xdotool` |
| wtype | `wtype` | ✅ | 仅 wlroots 系合成器 |
| ydotool | `ydotool type` | ❌ | **打不出汉字** |

`ydotool type` 是通过键码模拟按键的，没有对应 keysym 的字符（也就是汉字）发不出去。
所以默认没有用 ydotool；要强制指定用 `WOWTYPE_SINK=wtype|ydotool|clipboard|wl|x11`。

识别命令里的 `{wav}` 占位符：

```bash
# 追加路径（默认）
wowtype-voiced --asr-cmd 'whisper-cli -m /path/ggml.bin -l zh -nt -f'
# 需要 --wav= 形式时用占位符
wowtype-voiced --asr-cmd 'sherpa-onnx-offline --tokens=tokens.txt --paraformer=model.onnx --wav={wav}'
```

命令行按 shell 规则切分（支持引号），所以模型路径里有空格也没问题；
结果先读 stdout，为空时再读 stderr（部分识别器把文本打到 stderr）。

## 验证状态

| 部分 | 状态 | 说明 |
|---|---|---|
| WAV 读写 | ✅ 已测 | 端到端往返，采样值完全一致 |
| VAD 分段 | ✅ 已测 | 静音判 0 帧语音、持续音判全帧、挂起不超过配置值 |
| 外部识别器调用 | ✅ 已测 | `{wav}` 占位符、引号分词、stderr 回退、真实 WAV 文件校验 |
| 边说边上屏 | ✅ 已测 | 中间结果修正时正确退格重打 |
| 热键状态机 | ✅ 已测 | 长按/点按/静音超时/二次点按/自动重复，9 个用例 |
| 上屏后端 | ✅ 已测（逻辑） | 剪贴板写入用真实子进程验证；实际按键注入未测 |
| cpal 采集 | ⚠️ 仅 macOS 验过 | Linux 需要 ALSA/PulseAudio |
| X11 全局热键 | ❌ 未验证 | `#[cfg(target_os = "linux")]`，这台机器上不会被编译 |
| 端到端录音→识别→上屏 | ❌ 未验证 | 需要真机和麦克风 |

最后一行的意思是：链路每一段都单独测过，但**没有一次真正的「按住说话」跑通过**。
上 Linux 后建议先跑 `cargo test -p wowtype-voice`（31 + 4 项），再用
`wowtype-voiced --asr-cmd '...'` 实机试一次。
