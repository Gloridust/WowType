#!/usr/bin/env bash
# WowType 一键安装：Ubuntu / Debian、Fedora（x86_64、arm64），Arch Linux、deepin、UOS V25（x86_64），macOS 12 以上；
# openSUSE Tumbleweed 没有预编译包，问过以后在本机从源码编译安装。
#
#   curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh | bash
#
# macOS：下载 WowType-<版本>-macos.pkg，按 SHA256SUMS 校验，用系统的 installer 只装给当前用户
# （~/Library/Input Methods，不要密码），装完自动加进输入法并切过去。下面的 1–4 是 Linux 的步骤。
#
# 做这几件事：
#   1. 从 GitHub Release 下载和你系统对应的最新安装包（词库已经在包里），按 SHA256SUMS 校验
#   2. 用 apt-get / pacman / dnf 安装（含 fcitx5、GTK 4 / libadwaita）；
#      openSUSE：用 zypper 装编译依赖，下载这一版的源码，用发布页的词库包按 docs/INSTALL.md 编译安装
#   3. 输入法框架不是 fcitx5 时，用 im-config 切到 fcitx5（之后要注销重新登录一次）
#   4. 把 WowType 加进 fcitx5 的输入法列表（fcitx5 正在运行时会先重启它一次）
#   3、4 两步是 wowtype-config --setup 做的（直接装包的用户在「WowType 设置」第一页点「一键设置」也是它）
#
# 再跑一遍就是升级到最新版。发行版和源码安装说明见 docs/INSTALL.md。
#
# 环境变量：
#   WOWTYPE_VERSION=v0.3.8   装指定版本（默认最新）
#   WOWTYPE_REPO=owner/repo  指定发布仓库（默认 Gloridust/WowType）
#   WOWTYPE_NO_IM_CONFIG=1   不改输入法框架
#   WOWTYPE_NO_RESTART=1     不重启 fcitx5（之后自己重启或注销再登录，再到设置里添加 WowType）
#   WOWTYPE_YES=1            不问，直接按默认做
#   WOWTYPE_SOURCE_URL=...   openSUSE 源码包地址（默认 GitHub 上这一版 tag 的源码，测试时可用 file:///...）
#   WOWTYPE_GITHUB_MIRROR=https://<代理>/
#                            连不上 GitHub 时，从 GitHub 下载的地址前面都加上这个前缀，走你自己选的第三方代理
#                            （「代理地址 + 完整 GitHub 地址」那种）；SHA256SUMS 先试直连，安装包照样校验
set -euo pipefail

REPO=${WOWTYPE_REPO:-Gloridust/WowType}
MIRROR=${WOWTYPE_GITHUB_MIRROR:-}

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m注意：\033[0m%s\n' "$*" >&2; }
die() { printf '\033[1;31m出错：\033[0m%s\n' "$*" >&2; exit 1; }

# 问一句，默认「是」；curl | bash 时从终端读
confirm() {
  [[ -n "${WOWTYPE_YES:-}" ]] && return 0
  local answer=""
  if [[ -r /dev/tty ]] && { true </dev/tty; } 2>/dev/null; then
    read -r -p "$1 [Y/n] " answer </dev/tty || answer=""
  else
    return 0
  fi
  [[ -z "$answer" || "$answer" =~ ^[Yy是] ]]
}

# GitHub 的地址：github.com、raw.githubusercontent.com、codeload.github.com、发布文件的 *.githubusercontent.com
is_github() { [[ "$1" =~ ^https://([a-z0-9-]+\.)?(github\.com|githubusercontent\.com)/ ]]; }
# 设了 WOWTYPE_GITHUB_MIRROR 时 GitHub 的地址加上代理前缀，别的地址（WOWTYPE_BASE_URL 等）不动
mirrored() {
  if [[ -n "$MIRROR" ]] && is_github "$1"; then printf '%s%s\n' "$MIRROR" "$1"; else printf '%s\n' "$1"; fi
}

# 连不上 GitHub（连接被重置、超时、域名解析不了）又没设代理时，说一次怎么换条路
github_hint() { # <curl / wget 的退出码>
  [[ -z "$MIRROR" && -z "${hinted:-}" ]] || return 0
  case "$1" in 4|5|6|7|28|35|52|56) ;; *) return 0 ;; esac
  hinted=1
  warn "连不上 GitHub（下载出错，代码 ${1}）。可以选一个你信得过的 GitHub 下载代理再装，脚本本身从 jsDelivr 下载："
  printf '    curl -fsSL https://cdn.jsdelivr.net/gh/%s@main/install.sh | WOWTYPE_GITHUB_MIRROR=https://<代理地址>/ bash\n' "$REPO" >&2
  printf '    代理是第三方服务，安装包仍按 SHA256SUMS 校验。见 https://github.com/%s/blob/main/docs/INSTALL.md 的「连不上 GitHub」\n' "$REPO" >&2
}

download() { # <地址> <保存到>
  if command -v curl >/dev/null; then
    curl -fL --retry 3 -C - --progress-bar -o "$2" "$1"
  else
    wget -q -c --show-progress -O "$2" "$1"
  fi
}

fetch() { # <地址> <保存到>：GitHub 的地址在设了代理时走代理
  local code=0
  download "$(mirrored "$1")" "$2" || code=$?
  if ((code)) && is_github "$1"; then github_hint "$code"; fi
  return "$code"
}

# SHA256SUMS：设了代理也先直连 GitHub 下（安装包按它校验），直连不通再走代理
fetch_sums() { # <资产目录> <保存到>
  local url="$1/SHA256SUMS" code=0
  if [[ -n "$MIRROR" ]] && is_github "$url"; then
    if command -v curl >/dev/null; then
      curl -fsSL --connect-timeout 10 --max-time 60 -o "$2" "$url" 2>/dev/null && code=0 || code=$?
    else
      wget -q -T 20 -t 1 -O "$2" "$url" 2>/dev/null && code=0 || code=$?
    fi
    if ((code == 0)); then
      say "SHA256SUMS 直接从 GitHub 下载，其余文件走代理、按它校验"
      return 0
    fi
    warn "直连 GitHub 下载 SHA256SUMS 失败，改从代理下载：校验值也来自代理，只能发现下载损坏，发现不了代理改包"
    code=0
  fi
  download "$(mirrored "$url")" "$2" 2>/dev/null || code=$?
  if ((code)) && [[ -z "$MIRROR" ]] && is_github "$url"; then github_hint "$code"; fi
  return "$code"
}

latest_tag() {
  local page="https://github.com/$REPO/releases/latest" url="" tag="" code=0
  if command -v curl >/dev/null; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$(mirrored "$page")") || code=$?
  else
    url=$(wget -q --max-redirect=5 -S --spider "$(mirrored "$page")" 2>&1 |
          sed -n 's/^ *[Ll]ocation: *//p' | tail -1) || code=4
  fi
  url=${url%$'\r'}
  if [[ "$url" == */tag/* ]]; then
    tag=${url##*/tag/}
  elif [[ -n "$MIRROR" ]]; then
    # 有的代理自己跟着跳转、直接返回发布页：从页面里的 /<仓库>/releases/tag/<版本> 链接取版本
    local -a get=(wget -qO-)
    command -v curl >/dev/null && get=(curl -fsSL)
    tag=$("${get[@]}" "$(mirrored "$page")" 2>/dev/null |
          grep -o "/${REPO//./\\.}/releases/tag/[a-zA-Z0-9._+~^-]*" | head -1) || true
    tag=${tag##*/tag/}
  fi
  if [[ -z "$tag" ]]; then
    ((code)) && github_hint "$code"
    die "查不到最新版本（GitHub 连不上？）。可以到 https://github.com/$REPO/releases 手动下载"
  fi
  echo "$tag"
}

# WOWTYPE_GITHUB_MIRROR：只接受 http(s) 地址，补上结尾的 /；设了就提醒一句下载走第三方代理
setup_mirror() { # <只打印计划：0 / 1>
  [[ -n "$MIRROR" ]] || return 0
  [[ "$MIRROR" =~ ^https?://[a-zA-Z0-9._~:/?#@!\&+,\;=%-]+$ ]] ||
    die "WOWTYPE_GITHUB_MIRROR 必须是 https:// 或 http:// 开头的代理地址前缀，例如 https://<代理地址>/"
  [[ "$MIRROR" == */ ]] || MIRROR="$MIRROR/"
  [[ "$1" == 1 ]] ||
    warn "从 GitHub 下载的文件都经第三方代理 ${MIRROR}（WOWTYPE_GITHUB_MIRROR）转发：代理能看到、也能改你下载的内容，安装包仍按 SHA256SUMS 校验"
}

usage() {
  cat <<'EOF'
用法：bash install.sh [--print-plan | --help]

默认下载、校验并安装匹配当前发行版的 WowType 包。
--print-plan  只显示发行版、包管理器和包名，不联网、不安装、不更改配置。

支持 Ubuntu 22.04 / 24.04 / 26.04、Debian 13 及有明确兼容基线的衍生版，deepin 23 / 25、UOS V25，
Arch Linux / EndeavourOS / Garuda / CachyOS，Fedora；预编译包有 x86_64，
Ubuntu、Debian 的 deb 和 rpm 另有 arm64（aarch64）。macOS 12 以上（Apple 芯片和 Intel）装 pkg。
openSUSE Tumbleweed 没有预编译包：问过以后用 zypper 装编译依赖，在本机从源码编译安装。
Manjaro 请在本机用 scripts/package-arch.sh 构建；NixOS 使用 flake。
Fedora Atomic 桌面使用 rpm-ostree。其他发行版见 docs/INSTALL.md 的源码构建。

环境变量：WOWTYPE_VERSION、WOWTYPE_REPO、WOWTYPE_YES、WOWTYPE_NO_IM_CONFIG、
          WOWTYPE_NO_RESTART、WOWTYPE_GITHUB_MIRROR（连不上 GitHub 时用的代理前缀，
          见 docs/INSTALL.md「连不上 GitHub」）。
测试夹具：WOWTYPE_SYSTEM 代替 uname -s（Linux / Darwin），
          WOWTYPE_OS_RELEASE 指定 os-release 文件，WOWTYPE_ARCH 指定机器架构，
          WOWTYPE_BASE_URL 指定资产目录（可用 file:///...），
          WOWTYPE_SOURCE_URL 指定 openSUSE 用的源码包（可用 file:///...）。
EOF
}

# os-release 的已知字段仅作数据读取，不执行文件里的 shell 代码。
read_os_release() {
  local release=${WOWTYPE_OS_RELEASE:-/etc/os-release} key value
  [[ -r "$release" ]] || {
    [[ -z "${WOWTYPE_OS_RELEASE:-}" ]] && release=/usr/lib/os-release
    [[ -r "$release" ]] || die "找不到 os-release，无法选择安装包"
  }
  ID= ID_LIKE= VERSION_ID= VERSION_CODENAME= UBUNTU_CODENAME= DEBIAN_CODENAME= VARIANT_ID=
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      ID|ID_LIKE|VERSION_ID|VERSION_CODENAME|UBUNTU_CODENAME|DEBIAN_CODENAME|VARIANT_ID)
        case "$value" in
          \"*\") value=${value:1:${#value}-2} ;;
          \'*\') value=${value:1:${#value}-2} ;;
        esac
        [[ "$value" =~ ^[a-zA-Z0-9._[:space:]-]*$ ]] ||
          die "os-release 的 $key 字段格式无效"
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done < "$release"
}

source_install() {
  die "$1。安装与源码构建说明：https://github.com/$REPO/blob/main/docs/INSTALL.md"
}

# macOS：下载 pkg、校验，用系统的 installer 只装给当前用户（不要密码）。curl 下载的文件没有隔离标记，
# 不用到「隐私与安全性」里放行。macOS 自带的是 bash 3.2：这里不能用 ${x,,} 这类 bash 4 的写法。
macos_install() { # <只打印计划：0 / 1>
  local machine=${WOWTYPE_ARCH:-$(uname -m)}
  case "$machine" in
    arm64|aarch64|x86_64) ;;
    *) source_install "macOS 版只有 Apple 芯片（arm64）和 Intel（x86_64）两种" ;;
  esac
  if [[ "$1" == 1 ]]; then
    local requested=${WOWTYPE_VERSION:-<版本>}
    printf '系统：macOS %s\n仓库：%s\n包文件：WowType-%s-macos.pkg\n' "$machine" "$REPO" "${requested#v}"
    [[ -z "$MIRROR" ]] || printf 'GitHub 代理：%s\n' "$MIRROR"
    return
  fi
  [[ $EUID -ne 0 ]] || die "请直接用普通用户运行，不要加 sudo（WowType 只装给当前用户）"
  command -v curl >/dev/null || die "需要 curl"
  local tag version package base expected actual
  tag=${WOWTYPE_VERSION:-$(latest_tag)}
  [[ "$tag" == v* ]] || tag="v$tag"
  version=${tag#v}
  [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+~^-]*$ ]] || die "无效的版本号：$version"
  base=${WOWTYPE_BASE_URL:-"https://github.com/$REPO/releases/download/$tag"}
  package="WowType-$version-macos.pkg"
  tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"' EXIT

  say "WowType ${version}（macOS）"
  fetch_sums "$base" "$tmp/SHA256SUMS" ||
    die "下载 $base/SHA256SUMS 失败，请检查版本和网络；发布页：https://github.com/$REPO/releases"
  expected=$(manifest_hash "$package" "$tmp/SHA256SUMS") ||
    die "WowType $version 没有 macOS 安装包（${package}）；发布页：https://github.com/$REPO/releases"
  say "下载并校验 $package"
  while true; do
      fetch "$base/$package" "$tmp/$package"
      actual=$(shasum -a 256 "$tmp/$package")
      [[ "${actual%% *}" == "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]] && break
      say "$package 校验和对不上，请重新下载"
  done

  say "安装到 ~/Library/Input Methods（只装给当前用户）"
  installer -pkg "$tmp/$package" -target CurrentUserHomeDirectory
  # 安装包的 postinstall 会登记并打开输入法，失败了也不报错：这里再确认一次，没打开就说实话、把面板打开
  local bin="$HOME/Library/Input Methods/WowType.app/Contents/MacOS/WowType"
  if [[ -x "$bin" ]] && "$bin" --enable >/dev/null 2>&1; then
    say "装好了。菜单栏的输入法里选 WowType 就能用。"
  else
    warn "装好了，但没能自动把 WowType 加进输入法。"
    echo "已为你打开「系统设置 → 键盘」：输入法 → 编辑 → +，在「简体中文」里添加 WowType；列表里没有就注销重新登录一次。"
    open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension" 2>/dev/null || true
  fi
}

select_platform() {
  [[ "${WOWTYPE_SYSTEM:-$(uname -s)}" == Linux ]] || source_install "WowType 的 fcitx5 插件需要 Linux"
  read_os_release
  machine=${WOWTYPE_ARCH:-$(uname -m)}
  # deb 和 rpm 对同一种架构叫法不同：amd64 / x86_64、arm64 / aarch64
  case "$machine" in
    x86_64|amd64) deb_arch=amd64; rpm_arch=x86_64 ;;
    aarch64|arm64) deb_arch=arm64; rpm_arch=aarch64 ;;
    *) source_install "当前预编译包只有 x86_64 和 arm64；$machine 请从源码构建" ;;
  esac
  local family=" $ID $ID_LIKE " codename
  # deepin 25 的磐石系统基于 OSTree，但 apt-get install 照常能用（系统转给 deepin-immutable-ctl），
  # 所以要在下面「不可变系统」那条之前认出来。deepin 20 的 ID 是大写的 Deepin。
  # 统信 UOS 的 ID 是 uos：V25 和 deepin 25 同源（同样的 fcitx5、deepin-im），用 deepin 25 的包（#236）；
  # UOS 20 和 deepin 20 一样没有 GTK 4。
  if [[ "$ID" == deepin || "$ID" == Deepin || "$ID" == uos || "$ID" == UOS ]]; then
    local name=deepin
    [[ "$ID" == uos || "$ID" == UOS ]] && name=UOS
    case "$name:$VERSION_CODENAME:$VERSION_ID" in
      deepin:crimson:*|*:25|*:25.*|UOS:*:25[0-9][0-9]) distro=deepin25 ;;
      deepin:beige:*|deepin:*:23|deepin:*:23.*) distro=deepin23 ;;
      *) source_install "$name ${VERSION_ID:-$VERSION_CODENAME} 没有匹配的预编译包（有 deepin 23、25 和 UOS V25 的；deepin 20 / UOS 20 没有 GTK 4，暂不支持）" ;;
    esac
    [[ "$deb_arch" == amd64 ]] || source_install "$name 的预编译包只有 x86_64；$machine 请从源码构建"
    manager=apt-get
    return
  fi
  if [[ -e /run/ostree-booted || "$VARIANT_ID" == *atomic* ]]; then
    source_install "不可变系统请按说明使用 rpm-ostree 或系统自身的包配置"
  fi
  case "$VARIANT_ID" in
    silverblue|kinoite|sericea|onyx|coreos)
      source_install "Fedora $VARIANT_ID 请按说明使用 rpm-ostree" ;;
  esac
  case "$ID" in
    nixos) source_install "NixOS 请使用仓库 flake 和 i18n.inputMethod.fcitx5.addons" ;;
    # 没有预编译包：本机从源码编译（install_packages 的 zypper 一段）
    opensuse-tumbleweed) distro=opensuse-tumbleweed; manager=zypper ;;
    ubuntu)
      case "$VERSION_ID" in
        22.04|24.04|26.04) distro="ubuntu$VERSION_ID"; manager=apt-get ;;
        *) source_install "Ubuntu $VERSION_ID 没有匹配的预编译包" ;;
      esac
      ;;
    debian)
      case "$VERSION_ID" in
        13|13.*) distro=debian13; manager=apt-get ;;
        *) source_install "Debian ${VERSION_ID:-$VERSION_CODENAME} 没有匹配的预编译包" ;;
      esac
      ;;
    fedora)
      [[ "$VERSION_ID" =~ ^[0-9]+$ ]] || source_install "无法识别 Fedora 版本"
      distro="fedora$VERSION_ID"; manager=dnf
      ;;
    *)
      if [[ "$family" == *" manjaro "* ]]; then
        source_install "Manjaro 使用独立软件源，请在本机运行 scripts/package-arch.sh 构建，避免 Arch 二进制 ABI 不匹配"
      elif [[ "$family" == *" arch "* || "$ID" == archlinux || "$ID" == endeavouros || "$ID" == garuda || "$ID" == cachyos ]]; then
        [[ "$rpm_arch" == x86_64 ]] ||
          source_install "Arch Linux 的预编译包只有 x86_64；$machine 请按说明用 scripts/package-arch.sh 在本机构建"
        distro=archlinux; manager=pacman
      elif [[ -n "$UBUNTU_CODENAME" || "$family" == *" ubuntu "* ]]; then
        codename=${UBUNTU_CODENAME:-$VERSION_CODENAME}
        case "$codename" in
          jammy) distro=ubuntu22.04; manager=apt-get ;;
          noble) distro=ubuntu24.04; manager=apt-get ;;
          resolute) distro=ubuntu26.04; manager=apt-get ;;
          *) source_install "$ID 的 Ubuntu 基线 ${codename:-未知} 没有匹配的预编译包" ;;
        esac
      elif [[ -n "$DEBIAN_CODENAME" || "$family" == *" debian "* ]]; then
        codename=${DEBIAN_CODENAME:-$VERSION_CODENAME}
        [[ "$codename" == trixie ]] || source_install "$ID 的 Debian 基线 ${codename:-未知} 没有匹配的预编译包"
        distro=debian13; manager=apt-get
      else
        source_install "$ID 暂无匹配的预编译包，请使用发行版对应的源码构建命令"
      fi
      ;;
  esac
}

package_filename() {
  case "$manager" in
    apt-get) printf 'wowtype_%s_%s_%s.deb\n' "$1" "$distro" "$deb_arch" ;;
    pacman) printf 'wowtype-%s-1-x86_64.pkg.tar.zst\n' "$1" ;;
    dnf) printf 'wowtype-%s-1.fc%s.%s.rpm\n' "$1" "$VERSION_ID" "$rpm_arch" ;;
    zypper) printf 'WowType-%s 源码 + wowtype-data-rime-ice-<词库版本>.tar.gz（本机编译）\n' "$1" ;;
  esac
}

# openSUSE 的编译依赖，和 docs/INSTALL.md「openSUSE Tumbleweed」一节一样（源码用压缩包，不要 git）。
# 已经有 cargo（比如 rustup）就不装 rust、cargo：openSUSE 的 rustup 和 rust 包互相冲突。
zypper_deps() {
  ZYPPER_DEPS=(gcc-c++ make cmake extra-cmake-modules pkgconf-pkg-config curl xz
    fcitx5 fcitx5-devel fcitx5-configtool fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 alsa-devel
    python3 python3-gobject python3-gobject-Gdk typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1)
  command -v cargo >/dev/null || ZYPPER_DEPS=(rust cargo "${ZYPPER_DEPS[@]}")
}

# 只提取选定文件的校验值；重复、缺失或无效条目一律拒绝。
manifest_hash() {
  local wanted=$1 manifest=$2 hash filename found= count=0
  while read -r hash filename || [[ -n "$hash" ]]; do
    filename=${filename#\*}
    [[ "$filename" == "$wanted" ]] || continue
    [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    found=$hash
    ((count += 1))
  done < "$manifest"
  [[ "$count" == 1 ]] || return 1
  printf '%s\n' "$found"
}

# 要用户确认的命令从终端读输入（curl | bash 时标准输入是脚本本身）；没有终端就照常
from_tty() {
  if [[ -z "${WOWTYPE_YES:-}" ]] && { : < /dev/tty; } 2>/dev/null; then
    "$@" < /dev/tty
  else
    "$@"
  fi
}

install_packages() {
  local -a paths=("${files[@]/#/$tmp/}") yes=()
  [[ -n "${WOWTYPE_YES:-}" ]] && yes=(--noconfirm)
  case "$manager" in
    apt-get)
      local -a extra
      case "$distro" in
        # 22.04 没有 fcitx5-frontend-all
        ubuntu22.04) extra=(fcitx5-config-qt fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 im-config) ;;
        # deepin 自带 fcitx5 和控制中心里的输入法设置，不装 im-config、fcitx5-config-qt
        deepin*) extra=(fcitx5-frontend-all) ;;
        *) extra=(fcitx5-config-qt fcitx5-frontend-all im-config) ;;
      esac
      "${SUDO[@]}" apt-get update -qq || warn "apt-get update 失败，接着用现有的软件源列表安装"
      "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${paths[@]}" \
        "${extra[@]}" python3-gi python3-gi-cairo gir1.2-gtk-4.0 gir1.2-adw-1
      ;;
    pacman)
      # 不替用户 -Syu（整机升级该由用户自己决定）；-S 不带 y 不会造成部分升级。
      # 依赖装不上多半是软件源太旧：先 sudo pacman -Syu 再重跑。
      # curl | bash 时标准输入是脚本本身，pacman 的确认要从终端读。
      from_tty "${SUDO[@]}" pacman -S --needed "${yes[@]}" fcitx5 fcitx5-gtk fcitx5-qt \
        fcitx5-configtool python-gobject gtk4 libadwaita ||
        die "依赖装不上：先运行 sudo pacman -Syu 升级系统，再重新安装"
      from_tty "${SUDO[@]}" pacman -U "${yes[@]}" "${paths[@]}"
      ;;
    dnf)
      "${SUDO[@]}" dnf install -y "${paths[@]}" \
        fcitx5-configtool fcitx5-gtk3 fcitx5-gtk4 fcitx5-qt5 fcitx5-qt6 fcitx5-autostart \
        python3-gobject gtk4 libadwaita gobject-introspection
      ;;
    zypper)
      # 没有预编译包：装编译依赖，下载这一版 tag 的源码，词库用发布页上校验过的词库包（files[0]），
      # 按 docs/INSTALL.md 第 4 节编译，cmake --install 装到 /usr（插件、设置界面、词库、自检工具）
      local -a zy=()
      [[ -n "${WOWTYPE_YES:-}" ]] && zy=(--non-interactive)
      from_tty "${SUDO[@]}" zypper "${zy[@]}" refresh || warn "zypper refresh 失败，接着用现有的软件源安装"
      from_tty "${SUDO[@]}" zypper "${zy[@]}" install -y "${ZYPPER_DEPS[@]}" ||
        die "编译依赖装不上（软件源连不上，或者系统太旧？）：检查网络，或先运行 sudo zypper dup 更新系统，再重新安装"
      local src="$tmp/src"
      mkdir -p "$src/dist/data"
      say "下载 WowType $tag 的源码"
      fetch "${WOWTYPE_SOURCE_URL:-https://github.com/$REPO/archive/refs/tags/$tag.tar.gz}" "$tmp/source.tar.gz" ||
        die "下载 WowType $tag 的源码失败，请检查版本和网络"
      tar -xzf "$tmp/source.tar.gz" -C "$src" --strip-components=1
      tar -xzf "${paths[0]}" -C "$src/dist/data"
      say "编译（要几分钟）"
      (cd "$src" && cargo build --release --locked -p wowtype-core &&
        cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr &&
        cmake --build build -j"$(nproc)") ||
        die "编译失败。可以按 https://github.com/$REPO/blob/main/docs/INSTALL.md 手动构建"
      "${SUDO[@]}" cmake --install "$src/build"
      ;;
  esac
}

# GNOME 的候选框靠扩展 Input Method Panel（kimpanel@kde.org）画，活动概览的搜索框里才看得到。
# 发行版仓库里有它的（Debian 12 / 13 的 gnome-shell-extension-kimpanel，Fedora 45 起）就问一句装上并启用；
# 仓库里没有的（Ubuntu、Arch 官方仓库、更早的 Fedora）照旧只给链接。有没有按仓库实际查，不按发行版猜。
KIMPANEL_UUID=kimpanel@kde.org
KIMPANEL_PKG=gnome-shell-extension-kimpanel
KIMPANEL_URL=https://extensions.gnome.org/extension/261/kimpanel/
kimpanel_in_repo() {
  case "$manager" in
    apt-get) apt-cache show "$KIMPANEL_PKG" >/dev/null 2>&1 ;;
    dnf) dnf -q info "$KIMPANEL_PKG" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
enable_kimpanel() {
  gnome-extensions enable "$KIMPANEL_UUID" 2>/dev/null && return 0
  # 刚装的扩展 GNOME Shell 还没扫到（Wayland 下要重新登录），enable 会失败：直接记进启用列表，登录后生效
  command -v gsettings >/dev/null || return 1
  local current
  current=$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null) || return 1
  [[ "$current" == *"'$KIMPANEL_UUID'"* ]] && return 0
  if [[ "$current" == "@as []" || "$current" == "[]" ]]; then
    current="['$KIMPANEL_UUID']"
  else
    current="${current%]}, '$KIMPANEL_UUID']"
  fi
  gsettings set org.gnome.shell enabled-extensions "$current"
}
gnome_kimpanel() {
  [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && command -v gnome-extensions >/dev/null || return 0
  local installed
  installed=$(gnome-extensions list 2>/dev/null) || return 0
  if grep -qx "$KIMPANEL_UUID" <<<"$installed"; then
    gnome-extensions list --enabled 2>/dev/null | grep -qx "$KIMPANEL_UUID" && return 0
    if confirm "GNOME 扩展 Input Method Panel 装了但没启用（候选框要靠它显示），现在启用吗？"; then
      enable_kimpanel && say "已启用 GNOME 扩展 Input Method Panel" ||
        warn "没启用成功，请在「扩展」应用里打开 Input Method Panel"
    fi
    return 0
  fi
  if kimpanel_in_repo &&
     confirm "GNOME 下候选框要靠扩展 Input Method Panel 显示，现在装上（${KIMPANEL_PKG}）并启用吗？"; then
    local ok=""
    case "$manager" in
      apt-get) "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "$KIMPANEL_PKG" && ok=1 ;;
      dnf) "${SUDO[@]}" dnf install -y "$KIMPANEL_PKG" && ok=1 ;;
    esac
    if [[ -n "$ok" ]] && enable_kimpanel; then
      say "已装上并启用 GNOME 扩展 Input Method Panel（注销重新登录后生效）"
      relogin=1
      return 0
    fi
    warn "Input Method Panel 没装好，可以从 ${KIMPANEL_URL} 安装"
    return 0
  fi
  warn "GNOME 下建议装扩展 Input Method Panel（${KIMPANEL_URL}），活动概览的搜索框里才能显示候选框"
}

main() {
  local plan=0
  case "${1:-}" in
    --help|-h) usage; return ;;
    --print-plan) plan=1 ;;
    '') ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
  [[ $# -le 1 ]] || die "参数过多（用 --help 查看用法）"
  [[ "$REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || die "WOWTYPE_REPO 必须是 owner/repo"
  setup_mirror "$plan"
  if [[ "${WOWTYPE_SYSTEM:-$(uname -s)}" == Darwin ]]; then
    macos_install "$plan"
    return
  fi
  select_platform
  if ((plan)); then
    local requested=${WOWTYPE_VERSION:-<版本>}
    printf '系统：%s %s\n包基线：%s\n包管理器：%s\n仓库：%s\n包文件：%s\n' \
      "$ID" "$VERSION_ID" "$distro" "$manager" "$REPO" \
      "$(package_filename "${requested#v}")"
    if [[ "$manager" == zypper ]]; then
      zypper_deps
      printf '编译依赖：%s\n' "${ZYPPER_DEPS[*]}"
    fi
    [[ -z "$MIRROR" ]] || printf 'GitHub 代理：%s\n' "$MIRROR"
    return
  fi
  if [[ $EUID -eq 0 ]]; then
    [[ -n "${SUDO_USER:-}" ]] && die "请直接用普通用户运行，不要加 sudo（需要时脚本会自己调 sudo）"
    SUDO=()
  else
    command -v sudo >/dev/null || die "需要 sudo 来安装软件包"
    SUDO=(sudo)
  fi
  command -v "$manager" >/dev/null || die "找不到当前发行版的包管理器 $manager"
  command -v curl >/dev/null || command -v wget >/dev/null || die "需要 curl 或 wget，请先用发行版的包管理器安装"
  command -v sha256sum >/dev/null || die "需要 sha256sum（coreutils）校验安装包"

  local tag version package base
  tag=${WOWTYPE_VERSION:-$(latest_tag)}
  [[ "$tag" == v* ]] || tag="v$tag"
  version=${tag#v}
  [[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+~^-]*$ ]] || die "无效的版本号：$version"
  base=${WOWTYPE_BASE_URL:-"https://github.com/$REPO/releases/download/$tag"}
  package=$(package_filename "$version")

  tmp=$(mktemp -d)   # 退出时的 trap 还要用它
  trap 'rm -rf "${tmp:-}"' EXIT
  chmod 755 "$tmp"   # apt 用 _apt 用户读本地包

  say "WowType ${version}（$ID → ${distro}）"
  if [[ "$manager" == zypper ]]; then
    zypper_deps
    say "$ID 没有预编译包，要在本机从源码编译（几分钟）。先用 zypper 安装这些编译依赖："
    printf '    %s\n' "${ZYPPER_DEPS[*]}"
    confirm "安装这些依赖，再下载 WowType $version 的源码和词库编译安装吗？" || die "已取消，什么都没装"
  fi
  fetch_sums "$base" "$tmp/SHA256SUMS" ||
    die "下载 $base/SHA256SUMS 失败，请检查版本和网络；发布页：https://github.com/$REPO/releases"
  files=()
  if [[ "$manager" != zypper ]]; then
    manifest_hash "$package" "$tmp/SHA256SUMS" >/dev/null ||
      source_install "WowType $version 没有 $distro 的有效安装包（${package}）"
    files=("$package")
  fi
  # 0.3.3 及以前的 deb 词库是单独的包；openSUSE 源码编译用词库压缩包；其他格式不另装词库。
  local hash filename data= pattern=
  case "$manager" in
    apt-get) pattern='^wowtype-data-rime-ice_[a-zA-Z0-9._+~^-]+_all\.deb$' ;;
    zypper) pattern='^wowtype-data-rime-ice-[a-zA-Z0-9._+~^-]+\.tar\.gz$' ;;
  esac
  if [[ -n "$pattern" ]]; then
    while read -r hash filename || [[ -n "$hash" ]]; do
      filename=${filename#\*}
      if [[ "$filename" =~ $pattern ]]; then
        [[ -z "$data" ]] || die "SHA256SUMS 包含多个词库包"
        data=$filename
      fi
    done < "$tmp/SHA256SUMS"
    [[ -z "$data" ]] || files+=("$data")
  fi
  [[ "$manager" != zypper || -n "$data" ]] ||
    source_install "WowType $version 的发布页没有词库包（wowtype-data-rime-ice-*.tar.gz）"
  local f expected actual
  for f in "${files[@]}"; do
    expected=$(manifest_hash "$f" "$tmp/SHA256SUMS") || die "$f 缺少唯一且有效的 SHA256"
    say "下载并校验 $f"
    while true; do
        fetch "$base/$f" "$tmp/$f"
        actual=$(sha256sum "$tmp/$f")
        [[ "${actual%% *}" == "${expected,,}" ]] && break
        say "$f 校验和对不上，请重新下载"
    done
    chmod 644 "$tmp/$f"
  done

  say "安装（需要时会要求输入密码）"
  install_packages

  # 输入法框架、输入法列表交给 wowtype-config --setup（直接装包的用户在设置第一页点「一键设置」是同一套）：
  #   fcitx5 没在跑：输入法框架不是 fcitx5 时问一句再 im-config -n fcitx5，写好 fcitx5 的输入法列表，要注销重新登录
  #   在跑但还没载入 WowType：问一句再重启 fcitx5，加进输入法列表；在跑也认得：直接加
  # 问话从终端读（from_tty）；WOWTYPE_YES / WOWTYPE_NO_IM_CONFIG / WOWTYPE_NO_RESTART 照旧。
  # deepin 默认就是 fcitx5（经 deepin-im），不去动输入法框架
  local relogin="" restarted="" code=0
  local -a setup=(--setup)
  [[ -n "${WOWTYPE_YES:-}" ]] && setup+=(--yes)
  [[ -n "${WOWTYPE_NO_IM_CONFIG:-}" || "$distro" == deepin* ]] && setup+=(--no-im-config)
  [[ -n "${WOWTYPE_NO_RESTART:-}" ]] && setup+=(--no-restart)
  if ! command -v wowtype-config >/dev/null || ! wowtype-config --self-test >/dev/null 2>&1; then
    warn "设置界面用不了（缺 PyGObject / GTK 4 / libadwaita？），请在「Fcitx 5 配置」里手动添加 WowType"
  else
    from_tty wowtype-config "${setup[@]}" || code=$?
    case "$code" in
      0) ;;
      2) relogin=1 ;;   # 切了输入法框架或 fcitx5 没在跑
      3) restarted=1 ;; # 刚重启了 fcitx5
      4) ;;             # 用户没答应或不让重启，wowtype-config 已经说了还差哪一步
      *) warn "没设置好，请在「WowType 设置」第一页点「一键设置」" ;;
    esac
  fi

  gnome_kimpanel

  echo
  say "WowType $version 装好了"
  if [[ -n "$relogin" ]]; then
    echo "    注销并重新登录，然后按 Ctrl+空格 切换到 WowType，打 nihao 试试。"
  else
    echo "    按 Ctrl+空格 切换到 WowType，打 nihao 试试。"
  fi
  [[ -n "$restarted" ]] &&
    echo "    刚重启了 fcitx5：Chrome、VS Code、微信等 Chromium/Electron 程序要彻底退出再打开才能打中文。"
  echo "    设置在应用菜单「WowType 设置」里；以后有新版本会自动提醒。"
}

main "$@"
