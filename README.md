<div align="center">

<img src="icons/hicolor/scalable/apps/wowtype.svg" width="112" alt="WowType 图标">

# WowType

**在 Linux 上打字，像微信输入法一样顺手。**

一个 fcitx5 拼音输入法：长句一次打完、打一半就有词、按错键也能认出来，越用越懂你。

[![CI](https://github.com/Gloridust/WowType/actions/workflows/ci.yml/badge.svg)](https://github.com/Gloridust/WowType/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Gloridust/WowType?include_prereleases&label=release)](https://github.com/Gloridust/WowType/releases)
![fcitx5](https://img.shields.io/badge/fcitx5-%E2%89%A5%205.1-blue)
![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-green)

[安装](#安装) · [使用](#使用) · [设置](#设置) · [更多文档](#更多文档) · [常见问题](#常见问题) · [工作原理](#工作原理) · [参与开发](#参与开发)

[![加入 Telegram 交流群](https://img.shields.io/badge/%E5%8A%A0%E5%85%A5%20Telegram%20%E4%BA%A4%E6%B5%81%E7%BE%A4-26A5E4?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/+Kxk-4VkXIS9lODM1)

https://github.com/user-attachments/assets/b9ee2854-3718-461b-a58c-0a0e72f78253

</div>

## 特性

<p align="center"><img src="docs/images/candidates.png" width="720" alt="在文本编辑器里打 hengxianghouxuanci：横排候选条，第一个是横向候选词，后面是横向、横向后选词……"><br>
<sub>候选横排，和微信输入法一样：整句只留几个，后面是词，最后是单字</sub></p>

- **整句输入**：`xiangquzijieshangban` 直接出「想去字节上班」；后面跟着句子的前半截，可以先上屏一段，剩下的拼音接着改。
- **半成品也有词**：`zhongg` 就有「中国」，不用打全。打全了的拼音正好是个词时，它一定排第一。
- **按错键能认出来**：按成相邻键、两个键按反、多按或漏按一个键（`zhognguo` → 中国）。本来就打对的输入不受影响。
- **越用越懂你**：记住你选过的词和常连着用的词（选过一次「我们再讨论」，下次就不会出「我们在讨论」），30 天不用会慢慢淡掉。
- **简拼、省略韵母、中英混打**：`bjdx` → 北京大学；有的音节只打声母也行，`kyi` → 可以、`yongzwen` → 用中文；zh/ch/sh 可以当一个声母，`zhch`、`zhchi` → 支持；`github` → GitHub。
- **候选横排**，和微信输入法一样：整句只留几个，后面是词，最后是单字。
- **语音输入**：按住右 `Alt` 说话，松开就上屏；也可以点一下右 `Alt` 说，说完停一下自动结束。用微信输入法的离线识别模型，在本机识别，不上传录音。
- **Emoji**：打「开心」「点赞」「生日快乐」时，第三个候选就是对应的 emoji；按 `Super` + `.` 打开表情面板，打拼音或英文搜 emoji 和符号（`xiao` → 😂、`pizza` → 🍕、`youjiantou` → →）。
- **繁体、模糊音、双拼**：可切繁体输出；可开模糊音；双拼支持自然码、小鹤、微软、搜狗、智能 ABC、紫光、拼音加加，双拼也有整句、句首词和分段选词，编辑区显示全拼。
- **图形设置界面**：候选排列、模糊音、语音键都在「WowType 设置」里点一下就改，马上生效；还能加自定义词（人名、公司名、常用的长句），加进去的词排第一，简拼也能打。
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
<tr>
<td align="center">
<img src="docs/images/emoji.png" alt="打 jintianhaokaixin 时第三个候选是开心😊"><br>
<b>打着字，顺手就有表情</b><br>
<sub>第三个候选是「开心😊」，选了上屏「今天好开心😊」</sub>
</td>
<td align="center">
<img src="docs/images/voice.png" alt="按住右 Alt 说话：光标变成声波，下面是正在听、离线和实时波形"><br>
<b>按住右 Alt 说话</b><br>
<sub>离线识别，录音不上传</sub>
</td>
</tr>
</table>

## 安装

需要 Linux、**Fcitx 5.1 或更新**。设置界面需要 Python 3、PyGObject、GTK 4 和 libadwaita 1.5+。
预编译包面向 x86_64；源码构建和 Nix flake 按本机架构编译。Ubuntu 22.04 自带的 Fcitx 5.0 不满足要求。

| 发行版 | 安装方式 |
|---|---|
| Arch Linux、EndeavourOS、Garuda、CachyOS | 一键脚本自动选择 pacman 包；先完整升级系统 |
| Ubuntu 24.04 / 26.04、Debian 13 | 一键脚本自动选择对应版本的 deb |
| Linux Mint、Pop!_OS 等 Ubuntu / Debian 衍生版 | 根据系统明确声明的 `noble` / `resolute` / `trixie` 基线选择包 |
| Fedora 43 / 44 / 45 | 一键脚本选择同一 Fedora 版本的 RPM |
| Manjaro | 在本机用 `makepkg` 构建，避免与 Arch 的动态库版本错配 |
| openSUSE Tumbleweed | 安装 zypper 依赖后从源码构建 |
| NixOS / Home Manager | 把 flake 输出加入 Fcitx 5 的插件列表 |
| Fedora Atomic（Silverblue / Kinoite 等） | 使用宿主的 `rpm-ostree` 分层安装 |

安装包以 [Releases](https://github.com/Gloridust/WowType/releases) 中实际提供的文件为准。
没有对应发布包时，按 [源码构建](docs/INSTALL.md#从源码构建) 安装当前代码。各发行版依赖、桌面设置和卸载命令集中在 [安装说明](docs/INSTALL.md)。

### 一键安装

已有对应发布包的系统可以运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh | bash
```

脚本识别当前发行版，下载匹配的包，逐文件验证 `SHA256SUMS`，再调用 `apt-get`、`pacman` 或 `dnf`。
它会安装设置界面和 GTK / Qt 输入法前端，并帮助把 WowType 加进 Fcitx 5 输入法列表。
Arch 系统会先执行完整的 `pacman -Syu`，请保存正在进行的工作；Manjaro 请使用下面的本机打包方式。

想先检查脚本和安装目标：

```bash
curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh -o install.sh
bash install.sh --print-plan     # 显示发行版、包管理器和包名，不联网或安装
bash install.sh                  # 安装；再次运行即可升级
```

不要在脚本前加 `sudo`；需要提权时它会自行调用。安装指定版本可用 `WOWTYPE_VERSION=v0.3.8 bash install.sh`。
`WOWTYPE_NO_IM_CONFIG=1` 保留输入法框架设置，`WOWTYPE_NO_RESTART=1` 保留正在运行的 Fcitx 5。

### Arch Linux / Manjaro 本机打包

这种方式直接编译当前代码，也适合发布页还没有安装包的情况。用普通用户执行，`makepkg` 不接受 root：

```bash
sudo pacman -Syu --needed base-devel rust cmake extra-cmake-modules pkgconf git curl xz \
  fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool alsa-lib \
  python python-gobject gtk4 libadwaita

git clone https://github.com/Gloridust/WowType.git
cd WowType
scripts/make-data.sh "" dist/data
version=$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml)
scripts/package-arch.sh "$version" dist/pkg
sudo pacman -U "dist/pkg/wowtype-$version-1-$(uname -m).pkg.tar.zst"
```

打包会包含完整词库、设置界面和自检工具。安装后按下方步骤启用。
本项目提供 pacman 包和本机打包脚本；AUR 中是否有同名条目不影响这两种安装方式。

### Debian / Ubuntu 与 Fedora 手动安装

从 Releases 下载**与系统版本一致的一个包**，然后在下载目录执行对应命令：

```bash
# Debian / Ubuntu
sudo apt install ./wowtype_*_amd64.deb fcitx5-frontend-all fcitx5-config-qt im-config \
  python3-gi gir1.2-gtk-4.0 gir1.2-adw-1

# Fedora：只选择与 /etc/os-release 中 VERSION_ID 一致的 .fc<版本>.rpm
sudo dnf install ./wowtype-*.rpm fcitx5-configtool \
  fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 \
  python3-gobject gtk4 libadwaita gobject-introspection
```

目录中只保留这次要安装的那个包。RPM 的发行版后缀有实际含义，Fedora 包应在对应 Fedora 系统上使用。

### NixOS / Nix

在系统 flake 中添加输入，再注册到 Fcitx 5：

```nix
# flake.nix
inputs.wowtype = {
  url = "github:Gloridust/WowType";
  inputs.nixpkgs.follows = "nixpkgs";
};

# configuration.nix，inputs 通过 specialArgs 传入
# 插件和系统 Fcitx 5 使用同一份 nixpkgs。
i18n.inputMethod = {
  enable = true;
  type = "fcitx5";
  fcitx5.addons = [ inputs.wowtype.packages.${pkgs.stdenv.hostPlatform.system}.default ];
};
```

执行 `sudo nixos-rebuild switch` 后重新登录。Home Manager 和 overlay 用法见 [安装说明](docs/INSTALL.md#nixos--nix)。

### 从源码构建

[安装说明](docs/INSTALL.md#从源码构建) 提供 Debian / Ubuntu、Arch / Manjaro、Fedora 和 openSUSE 的完整依赖命令。
通用构建步骤如下；先安装对应发行版的依赖和当前稳定版 Rust：

```bash
git clone https://github.com/Gloridust/WowType.git
cd WowType
cargo build --release --locked -p wowtype-core
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j"$(nproc)"
sudo cmake --install build
sudo install -m755 target/release/wowtype-check target/release/wowtype-show /usr/bin/
scripts/make-data.sh "" dist/data
install -Dm644 -t "${XDG_DATA_HOME:-$HOME/.local/share}/wowtype" \
  dist/data/lexicon.tsv dist/data/english.txt dist/data/words.lm
```

插件会使用 Fcitx 5 自己声明的安装目录，覆盖 Debian 的 multiarch 路径、Arch 的 `lib` 和 Fedora / openSUSE 的 `lib64`。
只用文字输入、关闭语音，或不安装设置界面的构建方法见完整说明。

### 启用并检查

按桌面环境完成 [Fcitx 5 设置](docs/INSTALL.md#启用-fcitx-5)，再运行：

```bash
wowtype-config --add-to-group --restart
wowtype-config --self-test
```

也可以在 `fcitx5-configtool` 中取消勾选“仅显示当前语言”，搜索并添加 **WowType**。
然后按 `Ctrl+Space` 切换输入法，输入 `nihao`。
Debian / Ubuntu 可用 `im-config -n fcitx5` 选择框架；Arch 不需要 `im-config`。
KDE Plasma Wayland 在“系统设置 → 虚拟键盘”选择 Fcitx 5，其他会话见完整说明。

如果切换了输入法框架，请注销并重新登录。重启 Fcitx 5 后，正在运行的 Chromium / Electron 程序可能需要退出后重新打开。

## 使用

更多输入示例见 [docs/USAGE.md](docs/USAGE.md)。

| 按键 | 作用 |
|---|---|
| 空格 | 上屏第一个（或光标所在的）候选 |
| `1`–`9` | 上屏对应的候选 |
| `←` `→` | 在候选之间移动光标 |
| `↓` | 展开候选面板（6 列，像微信输入法），在面板里用方向键挪、空格或 `1`–`6` 选；第一行按 `↑` 或 `Esc` 收起 |
| `↑`、`-` `=`、`PgUp` `PgDn` | 翻页；fcitx5 全局设置里配的翻页、移动候选热键（比如 `,` `.` 翻页）也认 |
| 回车 | 把打的字母原样上屏 |
| `Esc` | 清空正在打的内容 |
| 退格 | 删一个字母；刚选过词时先撤销那次选词 |
| `'` | 分隔音节，比如 `xi'an` → 西安 |
| `Super` + `.` | 表情面板：打拼音或英文搜 emoji 和符号，见下 |
| 单按 `Shift` | 切到英文（字母、半角标点直接上屏），再按一下回中文；打了一半的字母原样上屏。左右 Shift 都行，设置里能改成只用一边或关掉 |
| 右 `Alt` | 语音输入，见下 |

**编辑区自动分音节**：打 `hengxiang` 显示 `heng'xiang`，按第一个候选的切法分；打了一半、简拼、按错键也分（`zhong'g`、`b'j'd'x`）。
显示的还是你打的字母，回车上屏时不带隔音符。英文候选在第一位时不分。

**长句可以分段上屏**：打完一整句，候选里除了整句，还有它的前半截（比如「我今天晚上要」）。
选了前半截就只上屏这一段，剩下的拼音留着继续选。

中文标点自动转全角（`,` → ，`?` → ？）。`/`、`+`、`"` 这类没有对应中文标点的符号原样上屏；打拼音途中按它们，先上屏当前候选。

### Emoji 和符号

**打字时推荐**：打的词有对应的 emoji 时，它排在第三个候选（`kaixin` → 开心、开行、😊），按 `3` 只上屏 emoji。
一句话以这样的词结尾时，推荐的是「开心😊」这种，选了上屏整句再加 emoji（`jintianhaokaixin` → 今天好开心😊）。
只看两个字以上的词，「是」「好」这种单字不推荐。不想要可以在设置里关掉。

**表情面板**：按 `Super` + `.`（Windows 键 + 句号，和 Windows 上一样）打开，再按一次或 `Esc` 关闭。

- 没打字时列出全部 emoji，最近用过的排最前
- 打拼音或英文搜索：`xiao` → 😄😂…，`gou` → 🐶，`pizza` → 🍕，`heart` → ❤️；符号名也能搜：`gou` → ✓、`youjiantou` → →、`juhao` → 。
- 方向键挑，空格、回车或 `1`–`6` 上屏，退格删搜索词
- 打了一半的拼音再按快捷键，直接拿它来搜（`gou` + `Super` + `.`）

快捷键可以在设置里换成 `Ctrl` + `;`、`Ctrl` + `Shift` + `E`，或者不用。

### 语音输入

在 WowType 打字的地方（没在打拼音时）：

- **按住右 `Alt` 说话，松开**：说的话上屏。
- **点一下右 `Alt`**：开始听，说完停 1.5 秒自动上屏，或者再点一下右 `Alt` 马上结束。
- 说话时编辑区里是正在识别的字；按 `Esc` 不要这次说的话；按别的键也会放弃这次说的话，那个键照常打字。
- **GNOME** 上光标下面会弹出一条语音浮条：绿色话筒（外圈跟着音量呼吸）、「正在听… 离线」和一排跟着你音量跳动的竖条，
  光标右边也会裂成几根跳动的绿色竖条；松开后显示「识别完成」再淡出。浮条是 WowType 的 GNOME 扩展画的
  （和绿色主题是同一个扩展，见[主题](#主题)），**装好或升级后要注销重新登录一次**才会出现。
  其他桌面（或关掉了绿色主题）在候选框里显示 🎙 和用字符画的波形。

识别用的是微信输入法的离线语音模型，在你的电脑上算，录音不上传。模型不随 WowType 分发：
**第一次按右 `Alt` 时**会从腾讯的服务器下载（约 100MB，存到 `~/.local/share/wowtype/wtlocal/`），
下载完之后再说话才能识别。载入后常驻内存，约 150MB。

换语音键（右 Ctrl、菜单键、F8–F10）或者关掉语音，在 [WowType 设置](#设置)的「语音」页里改。

<img src="docs/images/voice.png" width="560" alt="按住右 Alt 说话：光标变成声波，下面是正在听、离线和实时波形">

### 设置

从应用菜单打开 **WowType 设置**（或者运行 `wowtype-config`）。改完立刻生效，不用重启 fcitx5。

<table>
<tr>
<td align="center" width="50%">
<img src="docs/images/settings-input.png" alt="WowType 设置的输入页：拼音输入或双拼输入、双拼方案、单按 Shift 切换中英文、模糊音、按错键纠正、繁体字"><br>
<b>输入</b><br>
<sub>全拼还是双拼（7 种方案）、Shift 切英文、模糊音、纠错、繁体</sub>
</td>
<td align="center" width="50%">
<img src="docs/images/settings-words.png" alt="WowType 设置的自定义词页：输入词后拼音自动填好，下面是已经加过的词"><br>
<b>自定义词</b><br>
<sub>填上词，拼音自动查好</sub>
</td>
</tr>
<tr>
<td align="center">
<img src="docs/images/settings-voice.png" alt="WowType 设置的语音页：语音输入开关、语音键选右 Alt、识别模型已下载"><br>
<b>语音</b><br>
<sub>开关、换语音键</sub>
</td>
<td align="center">
<img src="docs/images/settings-update.png" alt="WowType 设置的更新页：有新版本 0.3.5，下载并安装按钮，下面是更新内容"><br>
<b>更新</b><br>
<sub>有新版本发通知，点一下装好</sub>
</td>
</tr>
</table>

| 页面 | 能改什么 |
|---|---|
| 常规 | 候选排列（横排 / 竖排）、每页个数（3–9）、WowType 绿色主题（见[主题](#主题)）。还会检查 WowType 有没有加进 fcitx5 的输入法列表，没有的话一键添加；底下的「问题反馈」能[导出日志](#出问题时导出日志) |
| 输入 | 拼音输入还是双拼输入、双拼方案（自然码、小鹤、微软、搜狗、智能 ABC、紫光、拼音加加）、单按哪个 Shift 切中英文、模糊音（z=zh、c=ch、s=sh，an=ang、en=eng、in=ing）、按错键自动纠正、繁体字 |
| 表情 | 打字时推荐 emoji、表情面板快捷键 |
| 语音 | 语音输入开关、语音键（右 Alt / 右 Ctrl / 菜单键 / F8–F10）、识别模型下没下载 |
| 自定义词 | 人名、公司名、常用的长句。填上词，拼音自动查好（多音字记得检查一下）；可以搜索，删错了能撤销 |
| 更新 | 检查新版本、看更新内容、下载并安装（见[更新](#更新)），自动检查的开关 |

各设置项对应的配置文件键名、环境变量、数据文件位置，见 [docs/CONFIG.md](docs/CONFIG.md)。

右上角菜单里还有：用文本编辑器打开自定义词文件、导出日志、恢复默认设置（不影响自定义词）、关于。

- `wowtype-config --page voice`（或 `general`、`words`、`update`）直接打开某一页。
- **Fcitx 5 配置**里选中 WowType 点「配置」，也能改上面这些设置，里面的「自定义词和更多设置」会打开 WowType 设置。

#### 主题

WowType 默认用自己的绿色主题：圆角候选框，选中的词是图标里的那种绿，系统换深色模式时跟着换深色版。
第一次切到 WowType 时自动打开（只这一次；你在用别的 fcitx5 主题时不动）。
不喜欢的话在「WowType 设置 → 常规 → 外观」里关掉「WowType 绿色主题」，换回默认。

<table>
<tr>
<td align="center" width="50%"><img src="docs/images/theme-light.png" alt="WowType 浅色主题：白底圆角候选框，第一个候选是绿底白字"><br><sub>浅色</sub></td>
<td align="center" width="50%"><img src="docs/images/theme-dark.png" alt="WowType 深色主题：下键展开的候选面板，当前行是绿底"><br><sub>深色（按下键展开）</sub></td>
</tr>
</table>

候选框由谁来画，决定了主题怎么生效：

- **KDE、X11 等**：fcitx5 自己画（经典界面），用的是主题 `wowtype` / `wowtype-dark`，打开开关马上生效。
  也可以在 Fcitx 5 配置 → 附加组件 → 经典用户界面里手动选。
- **GNOME（Wayland）**：候选框是 Input Method Panel 扩展画的，fcitx5 的主题管不到。WowType 另带一个只有样式表的小扩展
  `wowtype-theme@gloridust.github.io` 给它换色，打开开关会顺带启用它。**第一次启用要注销重新登录一次**（GNOME 只在登录时加载新装的扩展）。
  这个扩展同时画[语音浮条](#语音输入)，关掉绿色主题，语音提示也会回到候选框里的文字版。

主题文件在 `themes/`：`themes/fcitx5/` 是经典界面主题，图片由 `themes/src/*.svg` 经 `themes/render.sh` 生成；`themes/gnome-shell/` 是 GNOME 扩展。

### 更新

通过 deb、pacman 或 Fedora RPM 安装的版本，可以在“WowType 设置 → 更新”中下载并安装新版本。
更新器按本机发行版选择包，验证 SHA256，再通过对应包管理器安装；Arch 更新会先完整升级系统。
没有匹配资产或采用源码、NixOS、Manjaro、不可变系统安装时，界面会给出对应的手动更新说明。

Fcitx 5 启动后第一次切到 WowType 时会在后台检查更新，有新版本时发通知。
可在更新页关闭自动检查，也可重新运行[一键安装命令](#一键安装)。
从源码安装的版本用 `git pull --ff-only` 获取更新，再重复原来的构建安装步骤；Manjaro 重新运行本机打包脚本。

## 常见问题

| 现象 | 处理 |
|---|---|
| 输入法列表里找不到 WowType | 添加时取消勾选「仅显示当前语言」；确认 `/usr/share/fcitx5/inputmethod/wowtype.conf` 存在；`fcitx5 -r -d` 重启 |
| 某个程序里打不了中文，别的程序可以 | 重启 fcitx5 以后 Chrome / Electron 程序要彻底退出再打开 |
| 能打，但候选很少、很多常用词没有 | 没找到词库，用的是演示词库。用安装包装的话重装一遍（安装包自带词库）；从源码装的把 `lexicon.tsv` 放进 `~/.local/share/wowtype/` |
| 第一次切到 WowType 时要等一两秒 | 正常：第一次要载入词库并生成快照，之后约 0.3 秒 |
| 按右 Alt 提示「开不了麦克风」 | 在系统设置的「声音」里确认有输入设备；`arecord -l` 应该能列出麦克风 |
| 按 Super + . 打不开表情面板 | 只在 WowType 是当前输入法时有效；桌面或别的程序占了这个键的话，到设置里换成 Ctrl + ; |
| emoji 显示成方块 | 安装彩色 emoji 字体：Debian / Ubuntu 用 `fonts-noto-color-emoji`，Arch 用 `noto-fonts-emoji`，Fedora 用 `google-noto-color-emoji-fonts` |
| 按右 Alt 没反应 | 只在 WowType 是当前输入法、没在打拼音时有效；有的键盘右边是 AltGr，到设置的「语音」页换个键 |
| 应用菜单里没有「WowType 设置」，或者打不开 | 按[安装说明](docs/INSTALL.md#从源码构建)补齐本发行版的 PyGObject / GTK 4 / libadwaita。运行 `wowtype-config --self-test` 查看具体缺项 |
| 设置里改了，打字时没变化 | 看看是不是设了 `WOWTYPE_*` 环境变量（`env \| grep WOWTYPE`），它们优先于设置；fcitx5 没在运行时，设置会在它下次启动时生效 |
| 想看日志 | `~/.local/state/wowtype/wowtype.log`，或者[导出日志](#出问题时导出日志) |
| 怎么确认 fcitx5 在工作 | 运行 `fcitx5-diagnose`，它会列出缺的环境变量和前端 |

### 出问题时导出日志

「WowType 设置 → 常规 → 问题反馈 → 导出日志」，或者右上角菜单里的「导出日志…」，会存一个 `wowtype-log-时间.txt`，
里面有版本、系统和桌面环境、fcitx5 的输入法列表和主题、WowType 的设置、数据文件在不在、WowType 和 fcitx5 最近的日志。
**不含你打过的字**，自定义词、自动学到的词和输入习惯只写条数；家目录写成 `~`。导出后可以先打开看一眼再发。

没有图形界面时：`wowtype-config --export-log`（存到当前目录）或 `wowtype-config --export-log -`（打到终端）。

WowType 自己的日志在 `~/.local/state/wowtype/wowtype.log`（满 512 KB 换一个，旧的留一份 `.1`）。

问题没解决，欢迎[提 issue](https://github.com/Gloridust/WowType/issues)，把导出的日志拖进去。

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
| `settings/` | 设置界面 `wowtype-config`（Python、GTK 4、libadwaita） |
| `voice/` | 语音输入：热键状态机、麦克风采集、微信离线模型推理（插件通过 `core/src/voice_ffi.rs` 调用） |
| `voice-daemon/` | 不依赖输入法的语音守护进程（X11，实验性，没进安装包） |
| `tools/` | 词库转换、评测用例生成 |
| `docs/` | [引擎细节](docs/ENGINE.md)、[体验审查](docs/UX-AUDIT.md)、[接手指南](docs/HANDOFF.md)、[语音](docs/VOICE.md)、[数据格式](docs/DATA.md) |

## 更多文档

- 输入示例：[docs/USAGE.md](docs/USAGE.md)
- 设置项、环境变量、数据文件：[docs/CONFIG.md](docs/CONFIG.md)
- 卸载：[docs/INSTALL.md](docs/INSTALL.md#卸载)
- 目前做不到的：[docs/LIMITATIONS.md](docs/LIMITATIONS.md)

## 致谢

- [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)：词库和英文词表（GPL-3.0，随安装包一起分发，许可证见 `/usr/share/doc/wowtype/copyright`）
- [OpenCC](https://github.com/BYVoid/OpenCC)：简繁对照表（Apache-2.0）
- [Unicode CLDR](https://cldr.unicode.org/)：emoji 的中英文关键词（Unicode License v3）
- [fcitx5](https://github.com/fcitx/fcitx5)：输入法框架
- [voicekey](https://github.com/J3n5en/voicekey)：离线语音识别部分的代码
- 微信输入法：体验和设计上的参照

## 许可证

代码按 MIT 或 Apache-2.0 双许可证发布，任选其一。安装包里的词库数据遵循 rime-ice 的 GPL-3.0，词级语言模型 `words.lm` 是 CC BY-SA 4.0，编进程序里的 emoji 关键词来自 Unicode CLDR（Unicode License v3）。
