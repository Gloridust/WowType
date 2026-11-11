# 移植到 macOS：一套代码，两个外壳

> 状态：设计稿（2026-11），还没开始写 macOS 代码。讨论在 [#42](https://github.com/Gloridust/WowType/issues/42)。

## 结论

可以做，而且应该在**同一个仓库**里做，不另开项目。

- `core/`（Rust 引擎）和 `voice/`（语音）已经能在 macOS 上编、测试全过（#42 在 M2 上实测：`cargo test --workspace` 全绿，`abi-smoke.sh` 通过，NEON 路径也测过）。
- 真正不能复用的是外壳：`fcitx5-addon/src/wowtype_engine.cpp`（2400 多行）。问题是它不只是「把 fcitx5 的按键翻译给引擎」，**所有输入行为都写在这里**：选词栈、退格撤销、整句上屏、标点、翻页和展开面板、选词键、V 模式、Shift 中/英/译 状态机、互译的流式显示、语音键、表情面板……
- 如果照现在的样子直接写一个 macOS 外壳，就得把这 2400 行按行为再抄一遍，以后每个功能都要在两边各写一次、各测一次，很快就会对不上。

所以先做一件事：**把输入行为从 fcitx5 外壳挪进 core，变成一个「会话」接口**。之后 fcitx5 和 macOS（IMK）两个外壳都只负责：平台按键 → 会话 → 按会话给的结果画编辑区和候选框、上屏。

## 现在的分层

| 层 | 代码 | 跨平台吗 |
|---|---|---|
| 引擎 | `core/`：音节切分、词库、语言模型、纠错、双拼、繁简、emoji、日期、计算器、翻译请求 | 是 |
| C 接口 | `core/include/wowtype_core.h`（76 个函数）、`core/src/ffi.rs` | 是，但没有版本号，也没写成文档 |
| 语音 | `voice/`：wtlocal 推理（纯 Rust）+ cpal 采集 | 是（cpal 在 macOS 上走 CoreAudio） |
| 输入行为 | `fcitx5-addon/src/wowtype_engine.cpp` | **否**，和 fcitx5 的类型绑死 |
| 设置界面 | `settings/wowtype-config`（Python + GTK 4，读写 fcitx5 配置、D-Bus） | 否，macOS 要另写 |
| GNOME 扩展 | `themes/gnome-shell/`（候选框主题、语音浮条） | 只有 Linux |

## 会话接口（要挪进 core 的部分）

外壳里的状态和规则按这个边界拆：

| 挪进 core（`session`） | 留在外壳 |
|---|---|
| 编辑区内容、已选词栈、光标所在候选 | 平台按键 → 平台无关的键码 |
| 空格 / 回车 / 退格 / Esc / 数字 / 选词键 / 翻页键的含义 | 画编辑区（fcitx5 preedit / IMK `setMarkedText:`） |
| 标点样式、数字后的小数点（需要「光标前一个字符」，外壳给） | 画候选框（fcitx5 候选列表 / macOS 自绘窗口） |
| 横排展开面板、表情面板的光标移动 | 上屏（`commitString` / `insertText:`） |
| 中 / 英 / 译 三态、单按 Shift 的判定（只看「按下-松开之间没有别的键」） | 读周围文字（fcitx5 surrounding text / IMK `attributedSubstring`） |
| 互译：攒原文、去抖、流式译文、回车上屏 | 定时器（会话说「多少毫秒后叫我」，外壳去排） |
| 语音键的按住 / 点按判定、录音状态 | 语音浮条（GNOME 扩展 / macOS 小窗） |
| 学习（选词记录、上下文） | 配置文件在哪、怎么读 |

接口大致是这样（C，名字待定）：

```c
typedef struct WowtypeSession WowtypeSession;

/* 平台无关的按键：键码用 XKB keysym 的子集（字母、数字、标点、方向、功能键），
 * 修饰键是位掩码。macOS 外壳负责把 kVK_* / flagsChanged 翻成这个。 */
typedef struct {
    uint32_t keysym;
    uint32_t modifiers;   /* SHIFT | CTRL | ALT | SUPER | CAPS */
    uint8_t  release;     /* 0 按下，1 松开 */
    uint32_t prev_char;   /* 光标前一个字符，不知道给 0 */
} WowtypeKey;

/* 一次按键之后外壳要做的事。字符串在下一次调用前有效。 */
typedef struct {
    uint32_t    size;          /* sizeof，留给以后加字段 */
    int         handled;       /* 0 交给应用 */
    const char *commit;        /* 要上屏的字，没有为 NULL */
    const char *preedit;       /* 编辑区文字 */
    int         preedit_cursor;
    const char *aux;           /* 候选框上方的提示（互译状态等） */
    int         panel;         /* 0 普通 1 展开面板 2 表情面板 */
    size_t      cand_count;    /* 当前页候选，用 wowtype_session_candidate() 取 */
    int         cand_cursor;
    int         has_prev, has_next;
    uint32_t    wake_after_ms; /* >0：这么久后调 wowtype_session_tick */
} WowtypeFrame;

WowtypeSession *wowtype_session_new(WowtypeEngineHandle *engine, const WowtypeSessionConfig *cfg);
const WowtypeFrame *wowtype_session_key(WowtypeSession *s, const WowtypeKey *key);
const WowtypeFrame *wowtype_session_select(WowtypeSession *s, size_t index); /* 鼠标点候选 */
const WowtypeFrame *wowtype_session_tick(WowtypeSession *s);                 /* 定时器到了 */
const WowtypeFrame *wowtype_session_reset(WowtypeSession *s, int commit_pending);
void wowtype_session_free(WowtypeSession *s);
```

> 已经落地的部分（ABI 1.6）以 `core/include/wowtype_core.h` 为准，和上面的草案有几处不同：`WowtypeKey`、`WowtypeSessionConfig` 也以 `size` 开头，`release` 是 `uint32_t`；`wowtype_session_new` 的 `engine` 可以传 NULL，载入好了用 `wowtype_session_set_engine` 补上，设置用 `wowtype_session_configure` 改；`wowtype_session_select`（点这一屏的候选）1.6 加了，`wowtype_session_tick`（定时器）还没加，等互译挪进来时再加（fcitx5 外壳没打开选词键之前，点候选、按数字键还是过渡函数 `wowtype_session_choose`，按的是整个候选列表的序号）；另有几个标了「过渡」的函数，挪完删。规则见 [ABI.md](ABI.md)「输入会话」。

要点：

- **按键测试跟着搬**。现在 `fcitx5-addon/test/key_harness.cpp` 里的 117 条按键检查（`nihao,` → 你好，、退格撤销选词、翻页、互译……）改写成 `core/tests/` 里对会话接口的测试。这样 macOS 外壳天然继承同一套行为，CI 在两个平台都跑。
- **配置走结构体**。外壳从自己的配置文件读出来，填 `WowtypeSessionConfig`（带 `size` 字段）。键名和取值在两个平台一样，见 [CONFIG.md](CONFIG.md)。
- **一点一点挪，不一次重写**。每挪一块（比如先挪退格和选词栈），fcitx5 外壳就改成调会话接口，现有按键测试必须照样过。fcitx5 用户看不出变化。

## C 接口当成契约

回答 #42 的第一个问题：现在的 `wowtype_core.h` 是「插件和核心一起发版」的内部接口，没有承诺过稳定。要让第三方外壳放心依赖，需要：

1. 加版本：头文件里 `#define WOWTYPE_ABI_VERSION`，再导出 `wowtype_abi_version()`，外壳启动时比对主版本。
2. 规则：同一个主版本里只加函数、只在结构体末尾加字段（靠 `size` 判断）；删函数、改参数含义要升主版本，并在 CHANGELOG 写清楚。
3. `docs/ABI.md`：每个函数的所有权（谁释放、指针活多久）、线程要求（引擎句柄可以跨线程，会话只能在一个线程用）、错误怎么取（`wowtype_last_error`）。
4. `scripts/abi-smoke.sh` 在 Linux 和 macOS 的 CI 上都跑，用 C 编译器直接链静态库，接口一变就会编不过。

会话接口做好以后，外壳只需要依赖会话那一组函数加少量引擎函数（建引擎、载词库），契约会小很多。

## 目录

不改名搬家（会让所有人的分支冲突），只加：

```
core/            Rust 引擎 + 会话（两边共用）
voice/           语音（两边共用；GNOME 浮条的 D-Bus 信号在 fcitx5 外壳里，不在这里）
fcitx5-addon/    Linux 外壳（照旧）
settings/        Linux 设置界面（照旧）
themes/          Linux 主题和 GNOME 扩展（照旧）
macos/           macOS 外壳：IMK 输入法 + 设置窗口 + 打包脚本
```

`macos/` 里用 Swift（或 Objective-C）写 `IMKInputController` 子类，链 `core` 编出来的静态库。构建不依赖 Xcode 工程文件也行（`swiftc` + 脚本），这样 CI 和本地都简单。

## macOS 上要另外处理的

| 事情 | Linux 现在 | macOS 做法 |
|---|---|---|
| 编辑区 | fcitx5 preedit | `setMarkedText:selectionRange:replacementRange:`；终端和部分 Electron 应用画得不对时，准备「在候选框里显示编辑区」的兜底 |
| 候选框 | fcitx5 / kimpanel 画 | 自己画一个无边框 `NSPanel`（`IMKCandidates` 撑不起横排、展开 6 列和主题）；位置用 `attributesForCharacterIndex:lineHeightRectangle:` |
| 单按 Shift、按住右 Option 说话 | 普通按键事件 | 只能从 `flagsChanged:` 的 keyCode 判断左右和按下松开 |
| 表情面板快捷键 | `Super+.` | Command 组合键到不了输入法，要换（比如 `Control+.` 或候选框里的按钮），默认值两边可以不同 |
| 读周围文字（小数点、自动空格） | surrounding text | `attributedSubstringFromRange:`，很多应用不给，就靠会话自己记 |
| 语音浮条 | GNOME 扩展 + D-Bus 信号 | 输入法进程里直接开一个小窗；麦克风要在 Info.plist 写 `NSMicrophoneUsageDescription` |
| 设置界面 | GTK 4 | SwiftUI 小窗，和输入法同一个 bundle；配置文件 `~/Library/Application Support/WowType/wowtype.conf`，键名同 Linux |
| 安装 | deb / rpm / Arch / Nix | 输入法不能沙盒，上不了 App Store；先发 zip，解到 `~/Library/Input Methods`，ad-hoc 签名；以后再考虑 Developer ID 签名和公证 |
| 更新 | 设置里下载对应发行版的包 | 同一套「查 GitHub Release」逻辑，下载 zip 替换 bundle |
| CI | ubuntu、debian、fedora、arch、nix | 加 `macos-latest`（Apple Silicon）：`cargo test --workspace`、`abi-smoke.sh`、编外壳、打 zip |

## 数据和许可证

- 词库包（rime-ice，GPL-3.0）和 `words.lm`（CC BY-SA 4.0）两边一样打进安装包，许可证说明照搬。
- 微信输入法的模型（语音 `wtlocal`、`nlrgpt2_nnlm.bin`）是腾讯的，**不进任何安装包**，macOS 也一样。语音在 macOS 上和 Linux 一样，用户自己下载模型后才能用。

## 步骤

1. **契约**（小）：`WOWTYPE_ABI_VERSION` + `wowtype_abi_version()`、`docs/ABI.md`、CI 加 macOS 跑 `cargo test` 和 `abi-smoke.sh`。
2. **会话接口**（大头）：在 core 里建 `session` 模块，按上面的表一块一块从 fcitx5 外壳挪过来，按键测试同步搬到 `core/tests/`。每一步单独发 PR，fcitx5 行为不变。
3. **最小 macOS 外壳**：IMK bundle，打 `nihao` 出「你好」，验证 marked text 和自绘候选框。只依赖会话接口。
4. **补齐**：展开面板、表情、互译、设置窗口、打包和更新。
5. **语音**：cpal 采集 + 小窗浮条。

进度：第 1 步做完了（ABI 1.0）。第 2 步的第一块（ABI 1.3）：`core/src/session.rs` 和 `wowtype_session_*` 建好了，编辑区的原始输入、已选词栈、字母 / 隔音符 / 退格 / Esc 挪进了会话，fcitx5 外壳改成调会话，对应按键测试在 `core/tests/session_keys.rs`。第二块（ABI 1.4）：候选列表（含计算器、emoji 推荐、数字按键 emoji、日期时间）和编辑区分音节挪进了会话，fcitx5 外壳先把候选整个抄过去。第三块（ABI 1.5）：选词、整句上屏和学习挪进了会话（`wowtype_session_choose`、`_commit_input`），外壳只管把按键翻成序号、上屏以后记上文和存用户词库。第四块（ABI 1.6，macOS 外壳先用）：翻页、选词键、展开面板、标点、单按 Shift 加进会话，由 `WowtypeSessionConfig.keys` 打开，fcitx5 外壳还是 0（行为不变）；对应按键测试在 `core/tests/session_full_keys.rs`，点候选用 `wowtype_session_select`。fcitx5 外壳改成打开这几块以后，`_choose`、`_commit_input` 这些过渡函数就能删。接下来按这个顺序挪：翻页、选词键（空格、回车、数字、分号引号）、展开面板 → 标点和小数点 → 中 / 英 / 译 和单按 Shift → 互译 → 语音键 → 表情面板和工具栏。

第 1 步可以马上做；第 3 步可以在第 2 步挪完「编辑区 + 选词 + 翻页」这几块之后就开始，不用等全部挪完。
