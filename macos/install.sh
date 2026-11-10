#!/usr/bin/env bash
# 在 macOS 上安装 / 卸载 WowType 输入法（装到当前用户的 ~/Library/Input Methods，不要管理员权限）。
#
#   macos/install.sh WowType-<版本>-macos.zip     # 或者解压出来的 WowType.app
#   macos/install.sh --uninstall
set -euo pipefail

[[ "$(uname)" == Darwin ]] || { echo "这个脚本只在 macOS 上用" >&2; exit 1; }
dest="$HOME/Library/Input Methods/WowType.app"

stop_running() {
  # 按进程名精确匹配，只停 WowType 自己
  pkill -x WowType 2>/dev/null || true
}

if [[ "${1:-}" == "--uninstall" ]]; then
  [[ -x "$dest/Contents/MacOS/WowType" ]] && "$dest/Contents/MacOS/WowType" --disable || true
  stop_running
  rm -rf "$dest"
  echo "已卸载。用户数据还在 ~/Library/Application Support/WowType，不要了可以手动删掉。"
  exit 0
fi

src=${1:?用法：macos/install.sh WowType-<版本>-macos.zip | WowType.app | --uninstall}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [[ "$src" == *.zip ]]; then
  ditto -x -k "$src" "$tmp"
  src="$tmp/WowType.app"
fi
[[ -x "$src/Contents/MacOS/WowType" ]] || { echo "$src 不是 WowType.app" >&2; exit 1; }

stop_running
mkdir -p "$HOME/Library/Input Methods"
rm -rf "$dest"
ditto "$src" "$dest"
# 从网上下载的没有公证，去掉隔离标记，不然系统不让输入法跑起来
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

bin="$dest/Contents/MacOS/WowType"
"$bin" --register
# 刚登记完系统可能还没列出来，等一下再打开
for _ in 1 2 3 4 5; do
  if "$bin" --enable >/dev/null 2>&1; then
    "$bin" --enable
    "$bin" --select || true
    echo "装好了。菜单栏的输入法里选 WowType 就能用。"
    exit 0
  fi
  sleep 1
done
cat <<'MSG'
已经装到 ~/Library/Input Methods/WowType.app，但没能自动打开。
请注销重新登录一次，然后在「系统设置 → 键盘 → 输入法 → 编辑 → +」里，
在「简体中文」下面加上 WowType。
MSG
