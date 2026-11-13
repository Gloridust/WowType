# Linux 安装与更新

WowType 是 Fcitx 5 的输入法插件。安装时需要让插件、Fcitx 5 和系统动态库使用兼容的版本；
安装包因此按发行版构建。源码构建会使用本机的 Fcitx 5 开发文件。

最低要求：Fcitx 5.0、C++20 编译器、CMake 3.16。构建使用当前稳定版 Rust 和仓库的 `Cargo.lock`。
默认启用的语音功能需要 ALSA。设置界面需要 Python 3、PyGObject、GTK 4、**libadwaita 1.5+**；
绿色候选框主题和语音浮条（GNOME 扩展）需要 GNOME 45+。

## 选择安装方式

| 系统 | 方式 | 说明 |
|---|---|---|
| Arch Linux | 一键安装或本机 `makepkg` | 预编译包只有 x86_64；依赖不满足时先 `sudo pacman -Syu` |
| EndeavourOS / Garuda / CachyOS | Arch 安装路径或本机打包 | 系统必须与所用 Arch 动态库兼容；加载失败时本机重编译 |
| Manjaro | 本机 `makepkg` | 使用自己的软件源，脚本不会自动套用 Arch 包 |
| Ubuntu 24.04 / 26.04 | 对应版本 deb | amd64、arm64；不跨 Ubuntu 版本混装 |
| Debian 13 / 13.x | Debian 13 deb | amd64、arm64 |
| Ubuntu 22.04 | 本机源码安装 | fcitx5 5.0；没有设置界面和 GNOME 主题，见[下面](#ubuntu-2204fcitx5-50) |
| Mint / Pop!_OS 等衍生版 | 明确声明兼容基线时使用 deb | `noble → ubuntu24.04`、`resolute → ubuntu26.04`、`trixie → debian13` |
| Fedora 43 / 44 / 45 | 对应 `.fc<版本>` RPM | x86_64、aarch64；一键安装只匹配当前系统版本 |
| openSUSE Tumbleweed | 本机源码安装 | 独立的 zypper 依赖和 Fcitx 插件路径 |
| NixOS / Home Manager | flake | x86_64、aarch64；与系统共用 nixpkgs，注册到 Fcitx 插件列表 |
| Fedora Atomic | 宿主 `rpm-ostree` 分层 | 普通 dnf 安装脚本会给出手动说明 |

[Releases](https://github.com/Gloridust/WowType/releases) 中存在对应资产后才能使用二进制安装。
没有发布包、其他 CPU 架构或其他发行版，先使用下面的源码构建方法。
Alpine 使用 musl，需要单独完成构建与运行验证；这里不把 glibc 安装包用于 Alpine。
openSUSE Leap、RHEL / Rocky / AlmaLinux 也需要先核对 Fcitx 5 和 libadwaita 的可用版本。

## 一键安装与升级

用普通用户运行；脚本会在安装软件包时调用 sudo：

```bash
curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh | bash
```

下载目标来自当前仓库，按系统和 CPU 架构选择 `.deb`、`.pkg.tar.zst` 或 `.rpm`，每个文件都校验 SHA256。
缺少匹配包、校验记录重复、哈希不符或下载失败时，脚本在安装前停止。
Arch 不会替你升级整个系统；提示依赖不满足时，先运行 `sudo pacman -Syu` 再重新安装。

查看安装目标、固定版本或保留当前桌面设置：

```bash
curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh -o install.sh
bash install.sh --help
bash install.sh --print-plan
WOWTYPE_VERSION=v0.3.8 bash install.sh
WOWTYPE_NO_IM_CONFIG=1 WOWTYPE_NO_RESTART=1 bash install.sh
```

`--print-plan` 不查询网络、不安装软件、不修改配置。`WOWTYPE_YES=1` 可用于非交互安装。
`WOWTYPE_REPO=owner/repo` 可选择其他发布仓库；系统和版本的匹配规则仍然生效。
对应发行版的 Release 资产不存在时，请从本仓库源码构建。

## 从源码构建

### 1. 安装本发行版的依赖

#### Debian 13 / Ubuntu 24.04、26.04 / 兼容衍生版

```bash
sudo apt update
sudo apt install build-essential pkg-config cmake extra-cmake-modules git curl xz-utils \
  libasound2-dev libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
  fcitx5 fcitx5-frontend-all fcitx5-config-qt im-config \
  python3 python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```

已有可用的 Rust 工具链可以直接使用；未安装时按 [Rust 官方说明](https://www.rust-lang.org/tools/install)安装：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --profile minimal
. "$HOME/.cargo/env"
```

#### Ubuntu 22.04（fcitx5 5.0）

22.04 的 fcitx5 是 5.0.14（backports 里也没有更新的），WowType 支持，但没有现成安装包，要从源码编。
两样东西在 22.04 上用不了：

- **设置界面**：要 libadwaita 1.5+，22.04 是 1.1。编译时加 `-DWOWTYPE_INSTALL_SETTINGS=OFF` 不装它；
  设置直接改 `~/.config/fcitx5/conf/wowtype.conf`（键名和取值见[设置说明](CONFIG.md)），
  也可以用 Fcitx 5 自带的配置工具（`fcitx5-config-qt`）改 WowType 的选项，改的是同一个文件。
- **绿色候选框主题和语音浮条**：GNOME 扩展要 GNOME 45+，22.04 是 42。候选框是 Fcitx 5 默认的样子，
  语音输入的提示显示在候选框里。

```bash
sudo apt update
sudo apt install build-essential pkg-config cmake extra-cmake-modules git curl xz-utils \
  libasound2-dev libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
  fcitx5 fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-config-qt im-config
```

22.04 没有 `fcitx5-frontend-all`，GTK、Qt 前端分开装。Rust 照上面的方法装。编译、安装照[第 4 节](#4-通用源码编译与安装)，CMake 那一步加上 `-DWOWTYPE_INSTALL_SETTINGS=OFF`：

```bash
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
  -DWOWTYPE_INSTALL_SETTINGS=OFF
```

装好以后用 `fcitx5-config-qt` 把「WowType 拼音」加进输入法列表（没有设置界面，`wowtype-config --add-to-group` 也用不了）。

#### Arch / EndeavourOS / Garuda / CachyOS / Manjaro

```bash
sudo pacman -Syu --needed base-devel rust cmake extra-cmake-modules pkgconf git curl xz \
  fcitx5 fcitx5-gtk fcitx5-qt fcitx5-configtool alsa-lib \
  python python-gobject gtk4 libadwaita
```

Arch 的 `fcitx5` 包已经包含头文件和 CMake 配置，不需要另找 `fcitx5-devel`。
使用 rustup 管理工具链的用户保留现有 rustup 安装，不要再安装与它冲突的 `rust` 包。
Manjaro 在自己的仓库内完整升级后，本机编译下面的安装包。

#### Fedora

```bash
sudo dnf install rust cargo gcc-c++ make cmake extra-cmake-modules pkgconf-pkg-config git curl xz \
  fcitx5 fcitx5-devel alsa-lib-devel \
  fcitx5-configtool fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 \
  python3 python3-gobject gtk4 libadwaita gobject-introspection
```

GTK 和 Qt 前端显式安装各自的版本子包，适用于禁用弱依赖的系统。
需要制作本机 RPM 时，再安装 `rpm-build`。

#### openSUSE Tumbleweed

```bash
sudo zypper refresh
sudo zypper install rust cargo gcc-c++ make cmake extra-cmake-modules pkgconf-pkg-config git curl xz \
  fcitx5 fcitx5-devel fcitx5-configtool fcitx5-gtk3 fcitx5-gtk4 alsa-devel \
  python3 python3-gobject python3-gobject-Gdk \
  typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1
```

Qt 应用还需要与应用 Qt 版本对应的 Fcitx 前端，可用 `zypper search fcitx5-qt` 查看仓库提供的子包。
Python 的实际版本包名会随 Tumbleweed 更新；上面的通用名字采用 [PyGObject 官方安装说明](https://pygobject.gnome.org/getting_started.html#opensuse)。

### 2. 获取源码与词库

```bash
git clone https://github.com/Gloridust/WowType.git
cd WowType
scripts/make-data.sh "" dist/data
```

词库脚本下载并转换 rime-ice，合并项目热词，下载经过固定 SHA256 校验的语言模型。
输出包含 `lexicon.tsv`、`english.txt`、`words.lm` 和许可证、来源信息。
已有 rime-ice checkout 时可传入其路径，避免重复下载。

### 3. Arch / Manjaro：制作原生安装包

安装好第 1 节依赖并准备数据后，用普通用户执行：

```bash
version=$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml)
scripts/package-arch.sh "$version" dist/pkg
sudo pacman -U "dist/pkg/wowtype-$version-1-$(uname -m).pkg.tar.zst"
```

`makepkg` 会在独立目录编译并把插件、设置界面、自检工具和完整词库一起打包。
之后可用 `pacman -Q wowtype` 查询安装版本、`pacman -Qkk wowtype` 检查已安装文件。
无需继续执行通用源码安装步骤，直接进入“启用 Fcitx 5”。

### 4. 通用源码编译与安装

其他发行版或不需要原生安装包时，在仓库根目录执行：

```bash
cargo build --release --locked -p wowtype-core
cargo test --locked -p wowtype-core
./scripts/abi-smoke.sh
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j"$(nproc)"
sudo cmake --install build
sudo install -m755 target/release/wowtype-check target/release/wowtype-show /usr/bin/
install -Dm644 -t "${XDG_DATA_HOME:-$HOME/.local/share}/wowtype" \
  dist/data/lexicon.tsv dist/data/english.txt dist/data/words.lm
```

CMake 使用 Fcitx 5 导出的安装路径：Debian / Ubuntu 通常为 `/usr/lib/<multiarch>/fcitx5`，
Arch 为 `/usr/lib/fcitx5`，Fedora / openSUSE 为 `/usr/lib64/fcitx5`。
可用 `pkg-config --variable=libdir Fcitx5Core` 查看本机库目录。
设置界面、输入法注册文件和简繁映射表由 CMake 一起安装；真实词库放入当前用户的数据目录。

需要可由包管理器卸载的包时，Debian / Ubuntu 可用
`scripts/package-deb.sh engine "$version" dist/pkg`，Fedora 可用
`scripts/package-rpm.sh "$version" dist/pkg`，其中 `version` 按上一节从 `core/Cargo.toml` 读取。
Debian 打包还需要 `dpkg-dev`，Fedora 打包需要 `rpm-build`；两者都需要第 2 节的数据。

只保留文字输入时，Rust 和 CMake 两侧一起关闭语音：

```bash
cargo build --release --locked -p wowtype-core --no-default-features
cmake -S fcitx5-addon -B build-text -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr -DWOWTYPE_VOICE=OFF
cmake --build build-text -j"$(nproc)"
sudo cmake --install build-text
```

这条构建路径不需要 ALSA 开发包；后续仍按通用步骤安装词库和自检工具。
如果不需要设置界面，再添加 `-DWOWTYPE_INSTALL_SETTINGS=OFF`，使用 `fcitx5-configtool` 添加输入法。
维护开发环境时可用 `scripts/build-linux.sh --addon` 统一构建与测试。
真实词库存在时会运行按键测试，测试失败会直接返回非零状态。

## 启用 Fcitx 5

先让桌面启动 Fcitx 5，再添加 WowType。修改会话配置后注销并重新登录。

| 桌面 / 系统 | 设置 |
|---|---|
| Debian / Ubuntu | `im-config -n fcitx5`，然后重新登录 |
| KDE Plasma Wayland | 系统设置 → 虚拟键盘 → Fcitx 5，由 KWin 启动输入法 |
| Fedora 的其他桌面 | 可安装 `fcitx5-autostart`，或使用 `im-chooser` 选择 Fcitx 5 |
| Arch / openSUSE 的 X11 桌面 | 在桌面自启动项中启用 Fcitx 5，并按下面设置 X11 环境变量 |
| GNOME / 其他 Wayland 合成器 | 按合成器的启动方式配置 Fcitx 5；GNOME 可安装 Input Method Panel 扩展 |

X11 会话通常需要在桌面读取的登录配置文件中设置：

```bash
export XMODIFIERS=@im=fcitx
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
```

Wayland 的客户端支持不同：KDE / KWin 的原生 Qt 通道通常应让 `QT_IM_MODULE` 保持未设置，
支持 text-input-v3 的 GTK 应用也可使用原生通道。按 [Fcitx 官方 Wayland 指南](https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland/en)
配置自己的桌面，不要把上面的 X11 变量统一写入所有 Wayland 会话。
需要自启动文件的 XDG 桌面可将 `/usr/share/applications/org.fcitx.Fcitx5.desktop` 复制到 `~/.config/autostart/`；
KDE Wayland 使用其虚拟键盘设置，避免重复启动。

添加输入法：

```bash
wowtype-config --add-to-group --restart
```

或打开 `fcitx5-configtool`，取消“仅显示当前语言”，搜索并添加 WowType。
按 `Ctrl+Space` 切换，输入 `nihao`。重启 Fcitx 5 后，Chromium / Electron 程序可能需要退出后重新打开。

## 检查与排错

```bash
wowtype-config --self-test
# 安装包自带的系统词库：
wowtype-check --lexicon /usr/share/wowtype/lexicon.tsv
wowtype-show --lexicon /usr/share/wowtype/lexicon.tsv nihao
# 源码安装到当前用户目录的词库：
wowtype-check --lexicon "${XDG_DATA_HOME:-$HOME/.local/share}/wowtype/lexicon.tsv"
fcitx5-diagnose
```

| 现象 | 检查方式 |
|---|---|
| CMake 找不到 Fcitx5Core 或版本过旧 | `pkg-config --modversion Fcitx5Core`；安装第 1 节的开发包 |
| 找不到 `libwowtype_core.a` | 先构建 Rust 核心；自定义 target 目录时用 `-DWOWTYPE_CORE_LIB=/绝对路径/libwowtype_core.a` |
| 输入法列表没有 WowType | 检查 `/usr/share/fcitx5/addon/wowtype.conf`、`/usr/share/fcitx5/inputmethod/wowtype.conf` 和插件库目录 |
| 插件报 undefined symbol | 按本机发行版安装匹配包；Arch 完整升级，Manjaro 本机重编译 |
| 设置界面缺 `gi` / `Gtk` / `Adw` | 按第 1 节补齐当前发行版的 Python GI / GTK / libadwaita 包 |
| 只有少量候选 | 真实词库未加载，程序退回演示词典；检查 `lexicon.tsv` 路径 |
| 只在部分应用里无法输入 | 检查应用所用 GTK / Qt 前端、X11 / Wayland 配置，并重启应用 |
| emoji 显示方框 | Debian / Ubuntu 安装 `fonts-noto-color-emoji`；Arch 安装 `noto-fonts-emoji`；Fedora 安装 `google-noto-color-emoji-fonts` |

用户数据优先于系统词库；环境变量优先于设置界面配置。完整变量说明见 [CONFIG.md](CONFIG.md)，语音说明见 [VOICE.md](VOICE.md)。
[CI](../.github/workflows/ci.yml) 定义了安装与更新回归、Debian / Ubuntu / Arch / Fedora 打包安装、openSUSE 源码安装和 Nix 检查。
桌面候选框、真实麦克风和具体应用兼容性需要在对应桌面会话中确认。

## NixOS / Nix

构建或检查 flake：

```bash
nix build github:Gloridust/WowType
nix flake check github:Gloridust/WowType
```

系统 flake 配置：

```nix
# flake.nix 的 inputs
wowtype = {
  url = "github:Gloridust/WowType/release";
  inputs.nixpkgs.follows = "nixpkgs";
};

# configuration.nix，inputs 通过 specialArgs 传入
# 与系统使用同一份 Fcitx 5，避免插件 ABI 不匹配。
i18n.inputMethod = {
  enable = true;
  type = "fcitx5";
  fcitx5.addons = [ inputs.wowtype.packages.${pkgs.stdenv.hostPlatform.system}.default ];
};
```

运行 `sudo nixos-rebuild switch` 后重新登录。Home Manager 将同一个包加入自己的 `i18n.inputMethod.fcitx5.addons`。
也可以使用 `nixpkgs.overlays = [ inputs.wowtype.overlays.default ];` 后引用 `pkgs.wowtype`。
插件作为系统 Fcitx 的 addon 注册；单独把包放进 Nix profile 不会自动完成插件注册。
词库使用 `nix/package.nix` 中固定 URL 和哈希的上游数据资产。

flake 输入选哪个：

| 写法 | 拿到的是 |
|---|---|
| `github:Gloridust/WowType/release` | 最新正式版（推荐）；每次发版时 CI 把 `release` 分支移到新版本的标签 |
| `github:Gloridust/WowType/v0.3.10` | 锁定这一版，升级时手动改版本号 |
| `github:Gloridust/WowType` | main 分支最新提交，可能包含还没发布的改动 |

更新时先在自己的 flake 中执行 `nix flake update wowtype`，再重建系统或 Home Manager 配置。
CI 在 nixos-unstable（x86_64、aarch64）和当前稳定版 nixos-26.05（x86_64）上构建并自检，
发布要等这些检查都通过。设置界面的更新提醒在 NixOS 上只提示新版本，不会去调用其他包管理器。

### 单按 Shift 在 NixOS 上

fcitx5 默认用左 Shift「临时切换输入法」，它先拿到这一下，WowType 收不到。设置界面的「Shift 只给 WowType 用」
是让正在跑的 fcitx5 改掉这个快捷键，再由 fcitx5 存进 `~/.config/fcitx5/config`。
用 Home Manager 的 `i18n.inputMethod.fcitx5.settings` 时，整个 `~/.config/fcitx5` 是指向 `/nix/store` 的只读目录，
fcitx5 存不进去，重新登录后左 Shift 又被拿走（设置界面会提示「只在这次有效」）；WowType 自己的设置也存不了，
要写在 `settings.addons.wowtype.globalSection` 里。这种情况把快捷键写进 Nix 配置：

```nix
# Home Manager
i18n.inputMethod.fcitx5.settings.globalOptions = {
  Hotkey.AltTriggerKeys = "";   # 空值 = 不用 Shift「临时切换输入法」；切输入法还是 Ctrl+空格
};
```

NixOS 模块的同名选项（`i18n.inputMethod.fcitx5.settings.globalOptions`，写法相同）写的是 `/etc/xdg/fcitx5/config`，
只在没有 `~/.config/fcitx5/config` 时才生效；已经有这个文件时，用设置界面的开关就行（它能写这个文件）。
fcitx5 其他全局快捷键（`EnumerateForwardKeys` 等）里也不要放单按的 Shift。

### 维护：发版时的 Nix 相关步骤

- `release` 分支由发布 job 自动更新。`GITHUB_TOKEN` 不能把分支移到改过 `.github/workflows` 的提交上，
  两次发版之间改过 CI 时会失败并在 Actions 里留下提醒，此时在本机运行
  `git push --force origin v<版本>^{commit}:refs/heads/release`。
  想全自动，在仓库 Secrets 里加 `RELEASE_BRANCH_TOKEN`：细粒度 PAT，只给本仓库，权限 Contents 和 Workflows 读写。
- 词库换了版本（rime-ice 更新，或 `scripts/make-data.sh` 的 REV 加一）时，新词库包要等发版后才有下载地址，
  发布 job 会自动开一个 issue，写好 `nix/package.nix` 里 `dataVersion`、`url`、`hash` 要改成什么。

## Fedora Atomic

Silverblue / Kinoite 等桌面在宿主上使用匹配当前 Fedora 版本的 RPM。
下载并按 Release 的 `SHA256SUMS` 核对后，使用宿主终端：

```bash
rpm-ostree install ./wowtype-*.rpm fcitx5 fcitx5-configtool \
  fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 \
  python3-gobject gtk4 libadwaita gobject-introspection
systemctl reboot
```

重启进入新部署后按桌面说明启用 Fcitx 5。Toolbox 内构建的插件需要打包并安装到宿主，
只在容器里执行 `dnf install` 不会为宿主桌面注册输入法。

## 更新与卸载

deb、Arch 和 Fedora 原生安装包可使用设置界面的更新页；它只选择与本机匹配并通过校验的资产。
源码安装运行 `git pull --ff-only` 后重复原有构建安装步骤。Manjaro 重做本机包，NixOS 更新自己的 flake。

| 安装方式 | 卸载命令 |
|---|---|
| Debian / Ubuntu | `sudo apt remove wowtype` |
| Arch / Manjaro | `sudo pacman -R wowtype` |
| Fedora | `sudo dnf remove wowtype` |
| Fedora Atomic | `rpm-ostree uninstall wowtype`，然后重启 |
| NixOS / Home Manager | 从 `fcitx5.addons` 移除 WowType，再重建配置 |
| 通用源码 | 在原仓库中检查 `build/install_manifest.txt` 后运行下方命令 |

源码安装的卸载：

```bash
sudo xargs -d '\n' -r rm -v -- < build/install_manifest.txt
sudo rm -f /usr/bin/wowtype-check /usr/bin/wowtype-show
```

如果使用 `build-text` 等其他构建目录，应使用对应的 `install_manifest.txt`。
卸载保留用户词库、学习记录和配置。随后在 Fcitx 5 配置中移除 WowType，再重启输入法。

## 官方参考

- [Arch 的 Fcitx 5 包与开发文件](https://archlinux.org/packages/extra/x86_64/fcitx5/)
- [Manjaro 软件源分支](https://wiki.manjaro.org/index.php/Switching_Branches)
- [Fedora 的 Fcitx 5 开发包](https://packages.fedoraproject.org/pkgs/fcitx5/fcitx5-devel/)与 [GTK 前端](https://packages.fedoraproject.org/pkgs/fcitx5-gtk/fcitx5-gtk3/)
- [PyGObject 各发行版安装方式](https://pygobject.gnome.org/getting_started.html)
- libadwaita 1.5 起提供的 [AlertDialog](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.AlertDialog.html) 和 [AboutDialog](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/class.AboutDialog.html)
- [Fcitx 5 启动与会话设置](https://fcitx-im.org/wiki/Setup_Fcitx_5)和 [Wayland 配置](https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland/en)
