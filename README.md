<div align="center">

# WowType

**在 Linux 上打字，像微信输入法一样顺手。**

一个 fcitx5 拼音输入法：长句一次打完、打一半就有词、按错键也能认出来，越用越懂你。

[![CI](https://github.com/Gloridust/Wowtype/actions/workflows/ci.yml/badge.svg)](https://github.com/Gloridust/Wowtype/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Gloridust/Wowtype?include_prereleases&label=release)](https://github.com/Gloridust/Wowtype/releases)
![fcitx5](https://img.shields.io/badge/fcitx5-%E2%89%A5%205.1-blue)
![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-green)

[安装](#安装) · [使用](#使用) · [常见问题](#常见问题) · [工作原理](#工作原理) · [参与开发](#参与开发)

<img src="docs/images/candidates.png" width="640" alt="打 hengxianghouxuanci 时的横排候选条：横向候选词、横向、横向后选词……">

<sub>候选横排，和微信输入法一样：整句只留几个，后面是词，最后是单字</sub>

</div>

## 特性

- **整句输入**：`xiangquzijieshangban` 直接出「想去字节上班」；后面跟着句子的前半截，可以先上屏一段，剩下的拼音接着改。
- **半成品也有词**：`zhongg` 就有「中国」，不用打全。打全了的拼音正好是个词时，它一定排第一。
- **按错键能认出来**：按成相邻键、两个键按反、多按或漏按一个键（`zhognguo` → 中国）。本来就打对的输入不受影响。
- **越用越懂你**：记住你选过的词和常连着用的词（选过一次「我们再讨论」，下次就不会出「我们在讨论」），30 天不用会慢慢淡掉。
- **简拼、省略韵母、中英混打**：`bjdx` → 北京大学；有的音节只打声母也行，`kyi` → 可以、`yongzwen` → 用中文；`github` → GitHub。
- **候选横排**，和微信输入法一样：整句只留几个，后面是词，最后是单字。
- **语音输入**：按住右 `Alt` 说话，松开就上屏；也可以点一下右 `Alt` 说，说完停一下自动结束。用微信输入法的离线识别模型，在本机识别，不上传录音。
- **符号和繁体**：`/juhao` → 。；可切繁体输出；可开模糊音、自然码双拼。
- **快、全在本地**：89 万词的词库，按一个键一般几毫秒内出候选；不联网，输入内容不离开你的电脑（语音模型第一次用时下载一次）。

<table>
<tr>
<td align="center" width="50%">
<img src="docs/images/sentence-head.png" alt="打 xiangquzijieshangban 时的候选：想去字节上班、想去字节……"><br>
<b>长句一口气打完</b><br>
<sub>还能只上屏前半截「想去字节」，剩下的接着选</sub>
</td>
<td align="center" width="50%">
<img src="docs/images/typo.png" alt="打 weixni 时第一个候选是微信"><br>
<b>按错顺序，没关系</b><br>
<sub><code>weixni</code> 照样是「微信」</sub>
</td>
</tr>
<tr>
<td align="center">
<img src="docs/images/mixed-jianpin.png" alt="打 wanqky 时第一个候选是完全可以"><br>
<b>全简拼混打，也没问题</b><br>
<sub><code>wanqky</code> → 完全可以</sub>
</td>
<td align="center">
<img src="docs/images/english.png" alt="打 wechat 时第一个候选是 WeChat"><br>
<b>中英混打，不用切换</b><br>
<sub><code>wechat</code> → WeChat，大小写按词表来</sub>
</td>
</tr>
</table>

## 示例

更多例子（默认词库雾凇拼音实际打出来的候选，可以用 `wowtype-show` 自己试）：

| 输入 | 候选（前几个） | 说明 |
|---|---|---|
| `xiangquzijieshangban` | **想去字节上班** · 想去字节 · 想去字节商办 · 想去自解上班 · 想去 | 整句；第 2 个是句子前半截，选了只上屏这一段 |
| `hengxianghouxuanci` | **横向候选词** · 横向 · 横向后选词 · 横 · 哼 · 衡 | 整句只留几个，然后是词，再是单字 |
| `zhongg` | **中国** · 中共 · 忠告 · 中高 · 重工 | 没打完也有词 |
| `weixni` | **微信** · 威信 · 唯心 · 为新 | 两个键按反了（`xin` 打成 `xni`） |
| `zhognguo` | **中国** · 种过 · 重过 | 两个键按反了 |
| `bjdx` | **北京大学** · 北京电信 · 半径大小 | 简拼 |
| `sz` | **设置** · 甚至 · 随着 · 深圳 · 是指 | 简拼 |
| `wanqky` | **完全可以** · 晚期一 · 完企业 · 完其余 · 完全开源 | 全拼和简拼混着打 |
| `yongzwen` | **用中文** · 用正文 · 拥着我 · 用在 · 用作 | 全拼和只打声母的音节混着打 |
| `wechat` | **WeChat** · 色差他 · 色插图 | 英文词按词表里的写法给出 |
| `github` | **GitHub** | 同上 |

## 安装

### 系统要求

- Linux x86_64，输入法框架 **fcitx5 5.1 或更新**
- 有现成安装包的发行版：**Ubuntu 24.04 / 26.04、Debian 13**。其他发行版（Arch、Fedora……）请[从源码构建](#方式二从源码构建)
- Ubuntu 22.04 自带的 fcitx5 是 5.0，不支持

### 第 1 步：确认你在用 fcitx5

Ubuntu 默认用的是 IBus。先装好 fcitx5 并设为默认输入法框架（已经在用 fcitx5 的跳过这步）：

```bash
sudo apt install fcitx5 fcitx5-config-qt \
  fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5
im-config -n fcitx5
```

然后**注销并重新登录**。登录后右上角托盘里应该有一个键盘图标。

> GNOME（Ubuntu 默认桌面）在 Wayland 下，建议再装 GNOME Shell 扩展
> [Input Method Panel](https://extensions.gnome.org/extension/261/kimpanel/)，
> 活动概览的搜索框等地方才能显示候选框。

### 第 2 步：安装 WowType

#### 方式一：安装包（推荐）

到 [Releases](https://github.com/Gloridust/Wowtype/releases) 页面下载两个文件：

| 文件 | 内容 |
|---|---|
| `wowtype_<版本>_<发行版>_amd64.deb` | 输入法本体，选和你系统对应的那个（`ubuntu24.04`、`ubuntu26.04`、`debian13`） |
| `wowtype-data-rime-ice_<日期>_all.deb` | 词库（89 万词 + 英文词表），所有发行版通用 |

不知道自己是哪个发行版：

```bash
. /etc/os-release && echo "$ID$VERSION_ID"     # 例如 ubuntu24.04
```

在下载目录里安装：

```bash
sudo apt install ./wowtype_*_amd64.deb ./wowtype-data-rime-ice_*_all.deb
```

也可以一条命令下载最新版（需要 `curl`）：

```bash
. /etc/os-release
curl -s https://api.github.com/repos/Gloridust/Wowtype/releases/latest \
  | grep -oE "https://[^\"]+(_${ID}${VERSION_ID}_amd64|_all)\.deb" \
  | xargs -n1 curl -LO
sudo apt install ./wowtype_*_amd64.deb ./wowtype-data-rime-ice_*_all.deb
```

#### 方式二：从源码构建

适合其他发行版，或者想用最新代码的情况。下面以 Debian/Ubuntu 为例，其他发行版装对应的包即可
（需要：C++20 编译器、CMake ≥ 3.16、extra-cmake-modules、fcitx5 的开发包、ALSA 开发包（语音输入用）、Rust 1.70+、Python 3、git）。

```bash
# 1. 依赖
sudo apt install build-essential pkg-config cmake extra-cmake-modules \
  libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev libasound2-dev git python3 curl
curl -sSf https://sh.rustup.rs | sh        # 已经装了 Rust 的跳过

# 2. 代码
git clone https://github.com/Gloridust/Wowtype.git
cd Wowtype

# 3. 编译并安装插件（Rust 核心静态链接进插件，不用另装 .so）
cargo build --release -p wowtype-core
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j"$(nproc)"
sudo cmake --install build

# 4. 词库：从雾凇拼音生成，放到用户目录（约 30 秒，需要联网下载 rime-ice）
scripts/make-data.sh "" dist/data
mkdir -p ~/.local/share/wowtype
cp dist/data/lexicon.tsv dist/data/english.txt ~/.local/share/wowtype/
```

> Arch、Fedora 等发行版的 fcitx5 插件目录可能不是 `/usr/lib/x86_64-linux-gnu/fcitx5`。
> 如果装完找不到输入法，把 `-DCMAKE_INSTALL_LIBDIR=` 设成你系统里 `libpinyin.so`、`librime.so` 这类 fcitx5 插件所在目录的上一级（例如 `lib` 或 `lib64`）。

不想用安装包的词库，也可以只下载 Releases 里的 `wowtype-data-rime-ice-<日期>.tar.gz`，解压到 `~/.local/share/wowtype/`。

### 第 3 步：把 WowType 加进输入法列表

1. 重启 fcitx5：`fcitx5 -r -d`（或者注销再登录）
2. 打开 **Fcitx 5 配置**（托盘图标右键 → 配置，或运行 `fcitx5-configtool`）
3. 在右边「可用输入法」里**取消勾选「仅显示当前语言」**，搜索 `WowType`，点 ← 加到左边
4. 关掉配置窗口，按 `Ctrl+Space` 切换到 WowType，打 `nihao` 试试

<!-- 截图（补上后删掉这行注释）：<img src="docs/images/configtool.png" width="560" alt="在 Fcitx 5 配置里添加 WowType"> -->

> **重要：重启 fcitx5 以后，Chrome、VS Code、Slack、微信等 Chromium / Electron 程序要彻底退出再打开**，
> 否则在它们里面打不了中文。终端、GTK、Qt 程序会自动重新连上。

### 检查是否装好

```bash
wowtype-check --lexicon /usr/share/wowtype/lexicon.tsv    # 源码安装的用 ~/.local/share/wowtype/lexicon.tsv
wowtype-show  --lexicon /usr/share/wowtype/lexicon.tsv nihao
# nihao: 1.你好词 2.拟好词 ...
```

`wowtype-show` 和插件用的是同一个引擎、同样的配置，打出来的候选应该和输入法里一样。

## 使用

| 按键 | 作用 |
|---|---|
| 空格 | 上屏第一个（或光标所在的）候选 |
| `1`–`9` | 上屏对应的候选 |
| `←` `→` | 在候选之间移动光标 |
| `↑` `↓`、`-` `=`、`PgUp` `PgDn` | 翻页 |
| 回车 | 把打的字母原样上屏 |
| `Esc` | 清空正在打的内容 |
| 退格 | 删一个字母；刚选过词时先撤销那次选词 |
| `'` | 分隔音节，比如 `xi'an` → 西安 |
| `/` + 拼音 | 符号：`/juhao` → 。，`/kuo` → （） |
| 左 `Shift` | 临时切英文（fcitx5 的设置），打了一半的字母原样上屏 |
| 右 `Alt` | 语音输入，见下 |

**编辑区自动分音节**：打 `hengxiang` 显示 `heng'xiang`，按第一个候选的切法分；打了一半、简拼、按错键也分（`zhong'g`、`b'j'd'x`）。
显示的还是你打的字母，回车上屏时不带隔音符。英文候选在第一位时不分。

**长句可以分段上屏**：打完一整句，候选里除了整句，还有它的前半截（比如「我今天晚上要」）。
选了前半截就只上屏这一段，剩下的拼音留着继续选。

中文标点自动转全角（`,` → ，`?` → ？）。

### 语音输入

在 WowType 打字的地方（没在打拼音时）：

- **按住右 `Alt` 说话，松开**：说的话上屏。
- **点一下右 `Alt`**：开始听，说完停 1.5 秒自动上屏，或者再点一下右 `Alt` 马上结束。
- 说话时显示 🎙 和跟着你音量跳动的波形，编辑区里是正在识别的字；按 `Esc` 不要这次说的话；按别的键也会放弃这次说的话，那个键照常打字。

识别用的是微信输入法的离线语音模型，在你的电脑上算，录音不上传。模型不随 WowType 分发：
**第一次按右 `Alt` 时**会从腾讯的服务器下载（约 100MB，存到 `~/.local/share/wowtype/wtlocal/`），
下载完之后再说话才能识别。载入后常驻内存，约 150MB。

用别的键：`WOWTYPE_VOICE_KEY=Control_R`（fcitx5 的键名）；不想要语音：`WOWTYPE_VOICE_KEY=none`。

### 设置

目前没有图形设置界面，用环境变量设置。写进 `~/.config/environment.d/wowtype.conf`，**注销重新登录**后生效：

```ini
# ~/.config/environment.d/wowtype.conf
WOWTYPE_FUZZY=1
```

想先试一下效果，可以临时带着变量重启 fcitx5：`WOWTYPE_FUZZY=1 fcitx5 -r -d`。

| 变量 | 作用 | 默认 |
|---|---|---|
| `WOWTYPE_FUZZY=1` | 模糊音：平翘舌（z/zh、c/ch、s/sh）和前后鼻音（an/ang 等） | 关 |
| `WOWTYPE_SHUANGPIN=1` | 自然码双拼（`vsgo` → 中国） | 关 |
| `WOWTYPE_TRADITIONAL=1` | 繁体输出（字符级转换） | 关 |
| `WOWTYPE_TYPO=0` | 关掉按错键纠错 | 开 |
| `WOWTYPE_VERTICAL=1` | 候选竖排 | 横排 |
| `WOWTYPE_VOICE_KEY` | 语音热键（fcitx5 键名，如 `Control_R`、`F8`）；`none` 关掉语音 | `Alt_R`（右 Alt） |
| `WOWTYPE_VOICE_MODEL_DIR` | 语音模型目录 | `~/.local/share/wowtype/wtlocal` |
| `WOWTYPE_LEXICON` | 词库路径 | 见下 |
| `WOWTYPE_ENGLISH` | 英文词表路径 | 见下 |
| `WOWTYPE_LM` | 二元语言模型（`前词<TAB>后词<TAB>次数`） | 无 |
| `WOWTYPE_S2T` | 简繁对照表 | `/usr/share/wowtype/s2t.tsv` |
| `WOWTYPE_USER_DICT` | 用户词库 | `~/.local/share/wowtype/user.tsv` |
| `WOWTYPE_HISTORY` | 输入习惯 | `~/.local/share/wowtype/history.tsv` |

### 数据文件

词库和英文词表按这个顺序找，用第一个找到的：环境变量 → `~/.local/share/wowtype/` → `/usr/share/wowtype/`。
都找不到时用只有十几个词的演示词库（能打 `nihao`，但没法日常用）。

| 文件 | 内容 |
|---|---|
| `lexicon.tsv` | 词库，一行一个：`拼音（空格分隔）<TAB>词<TAB>词频` |
| `english.txt` | 英文词表 |
| `user.tsv` | 自动学到的新词（同一个词选够 3 次就收进来） |
| `history.tsv` | 输入习惯：选过哪些词、哪些词常连着用 |
| `lexicon.tsv.wcache` | 词库快照，让第二次启动更快（约 0.3 秒）；删了会自动重建 |
| `wtlocal/` | 语音模型（第一次用语音时下载，约 130MB）；删了下次用语音会重新下载 |

想清空学到的东西：退出 fcitx5，删掉 `~/.local/share/wowtype/user.tsv` 和 `history.tsv`，再启动。

想用自己的词库：任何 Rime 格式的词库（`.dict.yaml`）都能用 `python3 tools/rime2tsv.py xxx.dict.yaml > lexicon.tsv` 转过来。

## 常见问题

| 现象 | 处理 |
|---|---|
| 输入法列表里找不到 WowType | 添加时取消勾选「仅显示当前语言」；确认 `/usr/share/fcitx5/inputmethod/wowtype.conf` 存在；`fcitx5 -r -d` 重启 |
| 某个程序里打不了中文，别的程序可以 | 重启 fcitx5 以后 Chrome / Electron 程序要彻底退出再打开 |
| 能打，但候选很少、很多常用词没有 | 没找到词库，用的是演示词库。装 `wowtype-data-rime-ice`，或把 `lexicon.tsv` 放进 `~/.local/share/wowtype/` |
| 第一次切到 WowType 时要等一两秒 | 正常：第一次要载入词库并生成快照，之后约 0.3 秒 |
| 按右 Alt 提示「开不了麦克风」 | 在系统设置的「声音」里确认有输入设备；`arecord -l` 应该能列出麦克风 |
| 按右 Alt 没反应 | 只在 WowType 是当前输入法、没在打拼音时有效；有的键盘右边是 AltGr，用 `WOWTYPE_VOICE_KEY` 换个键 |
| 想看日志 | 终端里运行 `fcitx5 -r --verbose=*=5 2>&1 \| grep -i wowtype`，日志里有载入了哪个词库、用了多久 |
| 怎么确认 fcitx5 在工作 | 运行 `fcitx5-diagnose`，它会列出缺的环境变量和前端 |

问题没解决，欢迎[提 issue](https://github.com/Gloridust/Wowtype/issues)，附上发行版、桌面环境（GNOME / KDE……，X11 还是 Wayland）和上面的日志。

## 卸载

```bash
# 安装包装的
sudo apt remove wowtype wowtype-data-rime-ice

# 源码装的（在仓库目录里）
sudo xargs rm -v < build/install_manifest.txt

# 学到的数据和缓存（可选）
rm -rf ~/.local/share/wowtype ~/.cache/wowtype
```

卸载后到 Fcitx 5 配置里把 WowType 从输入法列表里删掉，再 `fcitx5 -r -d`。

## 工作原理

```
按键 ─> fcitx5 插件（C++）─C ABI─> 拼音引擎（Rust）
                                    ├─ 切音节：全拼 / 简拼 / 半成品 / 按错键
                                    ├─ 音节图上做束搜索，词频 + 语言模型 + 用户习惯打分
                                    └─ 组织候选：几个整句、句子前半截、词、单字
```

引擎用 Rust 写，编成静态库链进 fcitx5 插件。设计思路参考了微信输入法（WeType）3.0 的公开行为和引擎里的符号名，
但拼音引擎没有用它的任何代码、词库或模型；词库来自开源的雾凇拼音。
语音识别用的是微信输入法的离线模型：不随 WowType 分发，第一次用语音时从腾讯的服务器下载，推理代码来自 voicekey（纯 Rust）。实现细节、评测数字和调参方法见 [docs/ENGINE.md](docs/ENGINE.md)。

## 参与开发

```bash
cargo test --workspace                     # Rust 测试（需要 libasound2-dev，语音守护进程还要 libx11-dev libxkbcommon-dev）
./scripts/abi-smoke.sh                     # C 接口冒烟测试
scripts/addon-test.sh ~/.local/share/wowtype/lexicon.tsv ~/.local/share/wowtype/english.txt
                                           # 插件按键测试：起一个私有的 fcitx5，不影响你正在用的输入法
WOWTYPE_VOICE_WAV=说的话.wav WOWTYPE_VOICE_EXPECT=期望的字 scripts/addon-test.sh ...
                                           # 加跑语音用例：用 WAV 代替麦克风，要先下载好语音模型
```

改了排序，用 `wowtype-eval` 在几百个用例上对比改前改后（用法见 [docs/ENGINE.md](docs/ENGINE.md#调排序)）。
推送 `v*` 标签会自动编译各发行版的安装包并发布到 Releases。

| 目录 | 内容 |
|---|---|
| `core/` | 拼音引擎和 C 接口 |
| `fcitx5-addon/` | fcitx5 插件 |
| `voice/` | 语音输入：热键状态机、麦克风采集、微信离线模型推理（插件通过 `core/src/voice_ffi.rs` 调用） |
| `voice-daemon/` | 不依赖输入法的语音守护进程（X11，实验性，没进安装包） |
| `tools/` | 词库转换、评测用例生成 |
| `docs/` | [引擎细节](docs/ENGINE.md)、[体验审查](docs/UX-AUDIT.md)、[接手指南](docs/HANDOFF.md)、[语音](docs/VOICE.md)、[数据格式](docs/DATA.md) |

## 现在还不行的

- 没有图形设置界面，设置靠环境变量
- 只有 x86_64 的安装包；Arch、Fedora 等要从源码构建
- 没有用语料训练的语言模型，「祝你 / 祝您」「在 / 再」这类同音词，没用过时只能靠词频排
- 语音输入只有一个识别结果，不能在候选里改；不能选麦克风（用系统默认的输入设备）

## 致谢

- [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)：词库和英文词表（GPL-3.0，作为单独的词库包分发）
- [OpenCC](https://github.com/BYVoid/OpenCC)：简繁对照表（Apache-2.0）
- [fcitx5](https://github.com/fcitx/fcitx5)：输入法框架
- [voicekey](https://github.com/J3n5en/voicekey)：离线语音识别部分的代码
- 微信输入法：体验和设计上的参照

## 许可证

代码按 MIT 或 Apache-2.0 双许可证发布，任选其一。词库包的数据遵循 rime-ice 的 GPL-3.0。
