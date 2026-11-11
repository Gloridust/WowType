# macOS 版

WowType 的 macOS 版是一个 InputMethodKit 输入法，和 Linux 版用同一个 Rust 核心。
这份文档写清楚它怎么分层、按键行为从哪来、装在哪、怎么构建和发布。

## 分层

```
core/            Rust 核心（两个平台共用）
  src/session.rs   输入会话：按键 → 编辑区 / 候选 / 上屏 / 学习，和平台无关（macOS 打开全部按键块，
                   WowtypeSessionConfig.keys = WOWTYPE_SESSION_KEYS_ALL）
  src/config.rs    wowtype.conf 的键名、取值和默认值（只有这一份）
  include/wowtype_core.h   C ABI（会话部分见「输入会话」一节）
macos/           macOS 前端（Swift，SwiftPM，不在 Cargo workspace 里）
  Sources/CWowTypeCore     把 wowtype_core.h 交给 Swift 的模块
  Sources/WowTypeKit       和 InputMethodKit 无关、能单测的部分：按键翻译、候选框位置、设置文件、数据路径、
                           会话外面的记账（SessionShell.swift：上文、学习计数、共用的中英文模式、光标前一个字符）
  Sources/WowTypeEngine    会话和引擎的 Swift 封装（只有它 import CWowTypeCore）
  Sources/WowTypeIME       输入法程序本身：IMKServer、输入控制器、候选框窗口、安装、设置窗口
  Tests/WowTypeKitTests    swift test 直接跑，不用装输入法
fcitx5-addon/    Linux 前端（这一版不动；以后改用会话 ABI，见「以后」）
```

为什么把会话放进核心：fcitx5 插件 2400 行 C++ 里约 1600 行是和平台无关的会话逻辑（分段选词和退格撤销、
上屏和学习、emoji/日期/计算器候选、翻页、单按 Shift）。如果 Swift 再写一份，两份会慢慢不一样。
librime（鼠须管、小狼毫、ibus-rime 共用）和 Mozc 都是这么分的：引擎里有会话，前端只翻译按键、画界面。

## 按键行为

会话照 fcitx5 插件的行为做，依据是 `fcitx5-addon/src/wowtype_engine.cpp` 和
`fcitx5-addon/test/key_harness.cpp` 里的按键测试。会话是上游的 `session.rs`（fcitx5 外壳也在用），
选词键、翻页、展开面板、标点、单按 Shift 这几块按 `keys` 位掩码加在上面：fcitx5 外壳不开（`keys` = 0，
行为不变，`core/tests/session_keys.rs` 测），macOS 全开（`core/tests/session_full_keys.rs` 的 44 个测试，
从 key_harness 逐条搬来）。会话外面的记账（fcitx5 外壳的 finishCommit / rememberContext）在 Swift 里，
和 `session_full_keys.rs` 里的测试外壳是同一份逻辑。
插件里几处容易被当成 bug 的行为也照搬，并且有测试钉住：

- 回车上屏原始字母（不带显示用的隔音符），并把原始字母记一次选词。
- 第一页按 `-`、最后一页按 `=`：先上屏当前候选，再上屏这个符号。
- 退格先撤销最后一次选词（拼音回到编辑区），再退格才删字母；撤销时不撤销已经记下的那次选词。
- 打字途中按 F1 这类功能键交给应用，编辑区不动；Home、End、Tab、Delete 吃掉。

这一版的会话不含：互译、语音、表情面板（macOS 自带表情面板 Ctrl+Cmd+空格）。

### macOS 上需要另外定下的事

| 情况 | 做法 | 理由 |
|---|---|---|
| 应用调 `commitComposition`（点了别处等） | 已选的词 + 原始字母上屏 | 不丢用户打的字；鼠须管、vChewing 也这么做 |
| `deactivateServer`（切走输入框或切输入法） | 同上，然后关候选框；`take_save_request` 返回 1 就存盘 | macOS 分不清这两种情况，宁可上屏也不丢；插件在 deactivate 时把没存的学习存盘 |
| 多个输入框 | 每个输入框一个会话；中英文模式、上文、学习计数放在 `SessionGroup.shared`，所有会话共用 | 和插件一样全局生效（插件里这些是插件对象的成员） |
| `activateServer` | 清空状态 | 和 Linux 的 activate 一样 |
| Command 组合键 | 交给应用，编辑区保留 | 和 Linux 的 Ctrl/Alt/Super 一样 |
| 密码框（安全输入） | 系统不把按键交给输入法，不用处理 | |
| 单按 Shift | `flagsChanged` 翻译成 SHIFT_L/SHIFT_R 的按下和松开交给会话，`time_ms` 带按键时刻 | 计时、判断都在会话里 |
| Shift+Tab | 翻成 `ISO_Left_Tab`（X11 / fcitx5 的报法） | 会话照 fcitx5 的默认热键处理：上一个候选，开了 PageKeysTab 是上一页 |

## 安装位置和数据

| 东西 | 位置 |
|---|---|
| 输入法本身 | `~/Library/Input Methods/WowType.app`（只装给当前用户，不用管理员密码） |
| 自带数据（只读） | `WowType.app/Contents/Resources/`：`lexicon.tsv`、`english.txt`、`words.lm`、`s2t.tsv`，以及许可证 |
| 设置 | `~/Library/Application Support/WowType/wowtype.conf`，格式同 Linux（见 [CONFIG.md](CONFIG.md)），改了马上生效 |
| 用户数据 | `~/Library/Application Support/WowType/`：`custom.tsv`、`user.tsv`、`history.tsv` |
| 词库快照 | `~/Library/Caches/<bundle id>/`（用 `wowtype_engine_new_with_cache`，不写进签过名的 .app） |
| 日志 | 系统日志（`log stream --predicate 'subsystem == "<bundle id>"'`），不记录打的字 |

安装：下载的 DMG 里只有 `WowType.app`。双击它会出一个安装窗口，点「安装」后它把自己复制到
`~/Library/Input Methods/`，关掉正在运行的旧版本，向系统注册并启用输入源。
第一次装时 macOS 会在系统设置里问「允许 WowType 启用 WowType Pinyin」，点了「允许」才能自动选中；
没批准前安装仍然成功，只是要手动点允许、再从输入菜单选 WowType。
命令行也能做：`WowType.app/Contents/MacOS/WowType --install`、`--uninstall`。
不用 .pkg，所以不需要「Developer ID Installer」证书，也不用注销重新登录。

## 构建

需要 Xcode（Swift 6）和 Rust（`rustup target add aarch64-apple-darwin x86_64-apple-darwin`）。

```bash
macos/scripts/verify.sh                 # 守卫 + cargo test + C ABI + swift test + 编译输入法程序
macos/scripts/build.sh                  # 通用二进制（arm64 + x86_64）的 build/WowType.app，临时签名
macos/scripts/build.sh --install        # 再装到 ~/Library/Input Methods 并启用
```

数据用 `scripts/make-data.sh` 生成（和 Linux 包同一份词库），`build.sh` 默认找 `dist/data/`。

发布时由发布方提供身份，仓库里不写死任何签名信息：

| 变量 | 作用 | 默认 |
|---|---|---|
| `WOWTYPE_BUNDLE_ID` | 输入法的 bundle id，要含 `.inputmethod.` | `io.github.gloridust.inputmethod.WowType` |
| `WOWTYPE_SIGN_IDENTITY` | `codesign` 身份，如 `Developer ID Application: …` | `-`（临时签名，只能本机用） |
| `WOWTYPE_NOTARY_PROFILE` | `xcrun notarytool` 的钥匙串配置名，设了才公证 | 不公证 |

`macos/scripts/package.sh` 打 DMG：签名（hardened runtime）、公证、装订，最后用 `spctl` 确认 Gatekeeper 接受。

## 以后

1. 会话加上互译、语音、表情面板。
2. fcitx5 插件改用会话 ABI：先用编译开关两条路并存，`key_harness` 在两条路上都跑通后删掉 C++ 里的那份。
