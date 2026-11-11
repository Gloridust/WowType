# WowType macOS 前端

用 InputMethodKit 写的 macOS 输入法外壳。按键怎么处理全在 Rust 核心的会话里（`core/include/wowtype_core.h`
的「输入会话」一节），这里只做翻译按键、显示编辑区和候选框、安装、设置。
设计、安装位置、构建变量都写在 [docs/MACOS.md](../docs/MACOS.md)，这里不重复。

```bash
macos/scripts/verify.sh               # 守卫 + cargo test + C ABI 冒烟 + swift test + 编译输入法程序
macos/scripts/build.sh --demo-data    # 开发构建（演示词库）
macos/scripts/build.sh                # 用 dist/data 的词库构建 build/WowType.app
macos/scripts/package.sh              # 打 DMG（设了 WOWTYPE_NOTARY_PROFILE 才公证）
macos/scripts/make-icons.sh --check   # 图标和 icons/hicolor 一致
```

| 目录 | 内容 |
|---|---|
| `Sources/WowTypeKit` | 不碰 InputMethodKit、AppKit 和核心：按键翻译、候选框位置、设置文件、数据路径、安装复制、崩溃检测 |
| `Sources/WowTypeEngine` | 核心的 Swift 封装：会话、快照、后台载入引擎 |
| `Sources/WowTypeIME` | 输入法程序：IMKServer、输入控制器、候选框、菜单、设置窗口、安装 |
| `Resources` | Info.plist 模板（bundle id 是参数）、图标、权限文件 |
| `Tests/WowTypeKitTests` | `swift test` 跑的单元测试 |

设置项的键名和默认值只在核心里（`wowtype_config_default_ini`），Swift 只读写 `wowtype.conf` 的文本。

## 设计依据

下面的做法来自几个开源输入法，链接指向参考的代码。

- **会话和平台分开，按键序列做测试**：会话在核心里，前端只翻译按键。参考
  [vChewing](https://github.com/vChewing/vChewing-macOS)、[macSKK](https://github.com/mtgto/macSKK)。
- **一个控制器一个会话，每次 handle 重新绑定客户端，nil 事件不丢字**：参考
  [fcitx5-macos](https://github.com/fcitx-contrib/fcitx5-macos)、[McBopomofo](https://github.com/openvanilla/McBopomofo)。
- **Command 组合键交给应用**：参考 [鼠须管 Squirrel](https://github.com/rime/squirrel)。
- **编辑区带下划线和分段，光标按 UTF-16 算；内容没变不重发**：参考 McBopomofo、fcitx5-macos、
  [hallelujahIM](https://github.com/dongyuwei/hallelujahIM)。
- **Swift 6：默认隔离到主线程，IMK 回调用 mainSync 转进来**：参考 vChewing、macSKK。
- **自己画候选框，不用 IMKCandidates**：不抢焦点的 NSPanel、所有桌面都显示、系统语义颜色、
  按下和松开在同一个候选上才选、每个候选是常驻的辅助功能元素。参考 vChewing、McBopomofo、Squirrel、
  [fcitx5-webview](https://github.com/fcitx-contrib/fcitx5-webview)。
- **候选框位置不信应用给的矩形**：校验、往前退、按锚点选屏，下面放不下翻到上面，已在上面就留在上面。参考
  McBopomofo、vChewing、[azooKey-Desktop](https://github.com/azooKey/azooKey-Desktop)、fcitx5-webview。
- **先排版、算大小、设位置，最后 orderFront**：参考 McBopomofo。
- **LSUIElement 的 .app，bundle id 含 `.inputmethod.`，输入模式写法照搬**：参考 Squirrel、vChewing。
- **安装命令做进程序本身；注册后重查，启用不看「已启用」**：参考 Squirrel、McBopomofo。
- **升级先放好再替换，不先删旧的**：参考 fcitx5-macos。
- **有卸载命令**：参考 Squirrel。
- **不进沙盒，最小权限，hardened runtime + 时间戳签名**：参考 Squirrel、macSKK。
- **SwiftPM 加脚本组装 .app，不用 .xcodeproj；每个架构分别编译、按完整路径链接静态库，再 lipo**：参考
  vChewing、[ongeul](https://github.com/hiking90/ongeul)、[karukan](https://github.com/togatoga/karukan)。
- **词库在后台载入，先起 IMKServer**：参考 vChewing。
- **连续崩溃时进安全模式**：参考 Squirrel。
- **自带数据放 Resources，用户数据放 Application Support**：参考 vChewing。
- **只用 os.Logger，不记录打的字**：参考 fcitx5-macos。

没有照搬的：

- 不做 .pkg。DMG 里只有 .app，自己装到 `~/Library/Input Methods`，不需要 Installer 证书和管理员密码（见 docs/MACOS.md）。
- 设置不用 UserDefaults。和 Linux 共用一份 `wowtype.conf`，用文件监视让改动马上生效。
