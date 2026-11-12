# 图标

`hicolor/scalable/apps/wowtype.svg` 是源文件，其它尺寸的 PNG 由它生成（改了 SVG 后重新跑）：

```bash
for s in 16 22 24 32 48 64 128 256; do
  rsvg-convert -w $s -h $s icons/hicolor/scalable/apps/wowtype.svg \
    -o icons/hicolor/${s}x${s}/apps/wowtype.png
done
```

图标名 `wowtype`：fcitx5 输入法列表、托盘和「WowType 设置」都用它。

## macOS

`macos/` 里是 macOS 输入法用的单色模板图标（黑色 + 透明的矢量 PDF），系统按菜单栏深浅色自己上色，
和系统自带的输入法、微信输入法一样。彩色的 `wowtype.svg` 放在菜单栏里会和系统的图标对不上。

- `menu.pdf`：16 pt，圆里挖出 W。菜单栏、输入法菜单、系统设置的输入法列表用它
- `caret@2x.pdf`：只有 W 那一笔。切换输入法时光标旁边的提示气泡用它

图形和 `wowtype.svg` 是同一笔 W，改了笔画后两边一起改，然后重新生成（只能在 macOS 上跑）：

```bash
swift icons/macos/make-icons.swift
```
