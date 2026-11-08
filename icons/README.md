# 图标

`hicolor/scalable/apps/wowtype.svg` 是源文件，其它尺寸的 PNG 由它生成（改了 SVG 后重新跑）：

```bash
for s in 16 22 24 32 48 64 128 256; do
  rsvg-convert -w $s -h $s icons/hicolor/scalable/apps/wowtype.svg \
    -o icons/hicolor/${s}x${s}/apps/wowtype.png
done
```

图标名 `wowtype`：fcitx5 输入法列表、托盘和「WowType 设置」都用它。
