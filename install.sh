#!/usr/bin/env bash
# WowType 一键安装（Ubuntu 24.04 / 26.04、Debian 13，x86_64）：
#
#   curl -fsSL https://raw.githubusercontent.com/Gloridust/WowType/main/install.sh | bash
#
# 做这几件事：
#   1. 从 GitHub Release 下载和你系统对应的最新安装包（词库已经在包里），按 SHA256SUMS 校验
#   2. sudo apt-get install 它（顺带装上 fcitx5 和设置界面要的 GTK 4 / libadwaita）
#   3. 输入法框架不是 fcitx5 时，用 im-config 切到 fcitx5（之后要注销重新登录一次）
#   4. 把 WowType 加进 fcitx5 的输入法列表（fcitx5 正在运行时会先重启它一次）
#
# 再跑一遍就是升级到最新版。卸载：sudo apt remove wowtype
#
# 环境变量：
#   WOWTYPE_VERSION=v0.3.4   装指定版本（默认最新）
#   WOWTYPE_NO_IM_CONFIG=1   不改输入法框架
#   WOWTYPE_NO_RESTART=1     不重启 fcitx5（之后自己重启或注销再登录，再到设置里添加 WowType）
#   WOWTYPE_YES=1            不问，直接按默认做
set -euo pipefail

REPO=Gloridust/WowType

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

fetch() { # <地址> <保存到>
  if command -v curl >/dev/null; then
    curl -fL --retry 3 --progress-bar -o "$2" "$1"
  else
    wget -q --show-progress -O "$2" "$1"
  fi
}

latest_tag() {
  local url
  if command -v curl >/dev/null; then
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
  else
    url=$(wget -q --max-redirect=5 -S --spider "https://github.com/$REPO/releases/latest" 2>&1 |
          sed -n 's/^ *[Ll]ocation: *//p' | tail -1)
  fi
  url=${url%$'\r'}
  [[ "$url" == */tag/* ]] || die "查不到最新版本（GitHub 连不上？）。可以到 https://github.com/$REPO/releases 手动下载"
  echo "${url##*/tag/}"
}

main() {
  if [[ $EUID -eq 0 ]]; then
    [[ -n "${SUDO_USER:-}" ]] && die "请直接用普通用户运行，不要加 sudo（需要时脚本会自己调 sudo）"
    SUDO=()
  else
    command -v sudo >/dev/null || die "需要 sudo 来安装软件包"
    SUDO=(sudo)
  fi
  command -v apt-get >/dev/null || die "这个脚本只支持 Ubuntu / Debian。其他发行版请从源码构建：https://github.com/$REPO#方式二从源码构建"
  command -v curl >/dev/null || command -v wget >/dev/null || die "需要 curl 或 wget：sudo apt install curl"
  local arch distro
  arch=$(dpkg --print-architecture)
  [[ "$arch" == amd64 ]] || die "目前只有 x86_64（amd64）的安装包，你的系统是 $arch"
  # shellcheck disable=SC1091
  . /etc/os-release
  distro="${ID}${VERSION_ID:-}"

  local tag version
  tag=${WOWTYPE_VERSION:-$(latest_tag)}
  [[ "$tag" == v* ]] || tag="v$tag"
  version=${tag#v}
  # WOWTYPE_BASE_URL：测试用，从别的地方（比如 file:///本地目录）取安装包
  local base=${WOWTYPE_BASE_URL:-"https://github.com/$REPO/releases/download/$tag"}
  local deb="wowtype_${version}_${distro}_${arch}.deb"

  tmp=$(mktemp -d)   # 不用 local：退出时的 trap 还要用它
  trap 'rm -rf "${tmp:-}"' EXIT
  chmod 755 "$tmp"   # apt 用 _apt 用户读本地包

  say "WowType $version（$distro）"
  fetch "$base/SHA256SUMS" "$tmp/SHA256SUMS" 2>/dev/null ||
    die "下载 $base/SHA256SUMS 失败（版本 $tag 不存在，或者 GitHub 连不上）"
  if ! grep -q " \*\?$deb\$" "$tmp/SHA256SUMS"; then
    die "WowType $version 没有 $distro 的安装包。有安装包的系统：$(sed -n 's/.*wowtype_[^_]*_\([^_]*\)_amd64\.deb$/\1/p' "$tmp/SHA256SUMS" | xargs | sed 's/ /、/g')。
其他系统请从源码构建：https://github.com/$REPO#方式二从源码构建"
  fi
  local files=("$deb")
  # 0.3.3 及以前词库是单独的包
  local data
  data=$(sed -n 's/.* \*\{0,1\}\(wowtype-data-rime-ice_[^ ]*_all\.deb\)$/\1/p' "$tmp/SHA256SUMS" | head -1)
  [[ -n "$data" ]] && files+=("$data")
  local f
  for f in "${files[@]}"; do
    say "下载 $f"
    fetch "$base/$f" "$tmp/$f"
  done
  say "校验 SHA256"
  (cd "$tmp" && sha256sum -c --quiet --ignore-missing SHA256SUMS) ||
    die "校验和对不上，可能没下载完整，请重新运行"
  chmod 644 "$tmp"/*.deb

  say "安装（需要输入密码）"
  "${SUDO[@]}" apt-get update -qq || warn "apt-get update 失败，接着用现有的软件源列表安装"
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${files[@]/#/$tmp/}"

  # 输入法框架
  local relogin=""
  local -a mode=()
  if [[ -z "${WOWTYPE_NO_IM_CONFIG:-}" ]] && command -v im-config >/dev/null &&
     mapfile -t mode < <(im-config -m 2>/dev/null) && [[ ${#mode[@]} -gt 0 ]]; then
    # im-config -m：第 1 行系统设置，第 2 行当前用户的设置（没设过是 missing）
    local active=${mode[1]:-}
    [[ -z "$active" || "$active" == missing ]] && active=${mode[0]:-}
    if [[ "$active" != fcitx5 ]]; then
      if confirm "现在的输入法框架是「${active:-未知}」，切换到 fcitx5 吗？（要注销重新登录一次）"; then
        if im-config -n fcitx5; then
          relogin=1
          say "已把输入法框架切到 fcitx5（im-config）"
        else
          warn "im-config 切换失败，请手动运行：im-config -n fcitx5，然后注销重新登录"
        fi
      else
        warn "没切换输入法框架，WowType 要在 fcitx5 下才能用"
      fi
    fi
  elif [[ -z "${WOWTYPE_NO_IM_CONFIG:-}" ]]; then
    warn "没法自动确认输入法框架。还没用 fcitx5 的话，请运行 im-config -n fcitx5 后注销重新登录"
  fi

  # 加进输入法列表
  local restarted=""
  if ! command -v wowtype-config >/dev/null || ! wowtype-config --self-test >/dev/null 2>&1; then
    warn "设置界面用不了（缺 python3-gi / GTK 4 / libadwaita？），请在「Fcitx 5 配置」里手动添加 WowType"
  elif command -v pgrep >/dev/null && pgrep -x fcitx5 >/dev/null; then
    if [[ -n "${WOWTYPE_NO_RESTART:-}" ]] || ! confirm "fcitx5 正在运行，重启它并把 WowType 加进输入法列表吗？"; then
      warn "没重启 fcitx5。之后重启它（fcitx5 -r -d）或注销再登录，再在「WowType 设置」第一页点「添加」"
    elif wowtype-config --add-to-group --restart; then
      restarted=1
    else
      warn "没加上，请在「WowType 设置」第一页点「添加」"
    fi
  else
    wowtype-config --add-to-group || warn "没加上，请在「WowType 设置」第一页点「添加」"
  fi

  if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] && command -v gnome-extensions >/dev/null &&
     ! gnome-extensions list 2>/dev/null | grep -q '^kimpanel@kde.org$'; then
    warn "GNOME 下建议装扩展 Input Method Panel（https://extensions.gnome.org/extension/261/kimpanel/），活动概览的搜索框里才能显示候选框"
  fi

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
