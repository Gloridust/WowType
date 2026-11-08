#!/usr/bin/env bash
# 把 src/*.svg 渲染成 fcitx5 主题用的 PNG（结果提交进仓库，构建时不需要 rsvg-convert）。
# 用法：themes/render.sh        需要 rsvg-convert（apt install librsvg2-bin）
set -euo pipefail
cd "$(dirname "$0")"
render() { # <svg 名> <主题目录> <png 名>
  rsvg-convert "src/$1.svg" -o "fcitx5/$2/$3.png"
}
for theme in wowtype wowtype-dark; do
  mkdir -p "fcitx5/$theme"
  s=""; [[ $theme == *-dark ]] && s="-dark"
  render "panel$s" "$theme" panel
  render "highlight$s" "$theme" highlight
  render "prev$s" "$theme" prev
  render "next$s" "$theme" next
  render "arrow$s" "$theme" arrow
  render "radio$s" "$theme" radio
done
echo "已生成 fcitx5/wowtype、fcitx5/wowtype-dark 的图片"
