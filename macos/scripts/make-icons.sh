#!/usr/bin/env bash
# 用 icons/hicolor 里的图标生成 macOS 要的两个图标，输出提交进仓库：
#   macos/Resources/AppIcon.icns    程序图标（iconutil）
#   macos/Resources/MenuIcon.tiff   菜单栏输入法图标，模板图（黑色 + 透明度，1x/2x）
#
#   macos/scripts/make-icons.sh           重新生成
#   macos/scripts/make-icons.sh --check   只检查提交的文件和重新生成的是否一样
set -euo pipefail
cd "$(dirname "$0")/../.."

CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "用法：$0 [--check]" >&2; exit 2 ;;
esac

HICOLOR=icons/hicolor
OUT=macos/Resources
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

png() {
  local f="$HICOLOR/$1/apps/wowtype.png"
  [[ -f "$f" ]] || { echo "缺少图标 $f" >&2; exit 1; }
  echo "$f"
}

# 程序图标：hicolor 没有 512，iconset 就只放到 256（iconutil 允许缺尺寸）。
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
cp "$(png 16x16)"   "$SET/icon_16x16.png"
cp "$(png 32x32)"   "$SET/icon_16x16@2x.png"
cp "$(png 32x32)"   "$SET/icon_32x32.png"
cp "$(png 64x64)"   "$SET/icon_32x32@2x.png"
cp "$(png 128x128)" "$SET/icon_128x128.png"
cp "$(png 256x256)" "$SET/icon_128x128@2x.png"
cp "$(png 256x256)" "$SET/icon_256x256.png"
iconutil -c icns -o "$WORK/AppIcon.icns" "$SET"

# 菜单栏图标：16pt，1x 用 16x16、2x 用 32x32，抠出白色的 W。
swift macos/scripts/template-icon.swift "$(png 16x16)" "$WORK/menu.png"
swift macos/scripts/template-icon.swift "$(png 32x32)" "$WORK/menu@2x.png"
sips -s dpiWidth 144 -s dpiHeight 144 "$WORK/menu@2x.png" >/dev/null
tiffutil -cathidpicheck "$WORK/menu.png" "$WORK/menu@2x.png" -out "$WORK/MenuIcon.tiff" 2>/dev/null

if [[ $CHECK == 1 ]]; then
  bad=0
  for f in AppIcon.icns MenuIcon.tiff; do
    if ! cmp -s "$WORK/$f" "$OUT/$f"; then
      echo "图标过期或缺失：$OUT/$f（运行 macos/scripts/make-icons.sh）" >&2
      bad=1
    fi
  done
  [[ $bad == 0 ]] && echo "图标和 icons/hicolor 一致"
  exit $bad
fi

mkdir -p "$OUT"
cp "$WORK/AppIcon.icns" "$WORK/MenuIcon.tiff" "$OUT/"
echo "已生成 $OUT/AppIcon.icns $OUT/MenuIcon.tiff"
