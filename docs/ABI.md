# C 接口（`core/include/wowtype_core.h`）

外壳（fcitx5 插件，以后还有 macOS）通过这组 C 函数用 Rust 核心。这里写的是承诺：外壳按这些规则用，核心升级时不会悄悄改掉。

## 版本

- 头文件里的 `WOWTYPE_ABI_VERSION_MAJOR` / `WOWTYPE_ABI_VERSION_MINOR` 是接口版本，和 WowType 的版本号无关。
- 库里的 `wowtype_abi_version()` 返回 `主版本 * 1000 + 次版本`。外壳启动时比一下主版本，不一样就别用。
- 同一个主版本里只会：加函数、在结构体末尾加字段（带 `size` 字段的结构体）、给原来返回 NULL 的情况加结果。次版本加一。
- 删函数、改参数或返回值的含义、改结构体已有字段：主版本加一，CHANGELOG 里写清楚。
- `scripts/abi-smoke.sh` 用 C 编译器直接链库跑一遍，Linux 和 macOS 的 CI 都跑。

### 版本记录

| 版本 | WowType | 变化 |
|---|---|---|
| 1.0 | 0.3.11 | 第一版带版本号的接口 |
| 1.1 | 0.3.11 | 加 `wowtype_translate_configure_local`、`wowtype_translate_local_running`（本地翻译模型） |
| 1.2 | 0.3.11 | 加 `wowtype_autospace`（中英文之间自动加空格）、`wowtype_symbol_list`、`wowtype_clipboard_*`（剪贴板历史）、`wowtype_engine_custom_phrases`（按文件顺序的常用语） |
| 1.3 | 0.3.11 | 加输入会话 `wowtype_session_*`（暂定，见下面「输入会话」）：编辑区、已选词栈、字母 / 退格 / Esc |

## 所有权和生命周期

- `wowtype_engine_new` 返回的句柄用 `wowtype_engine_free` 释放；`wowtype_voice_new`、`wowtype_translate_new` 同理各配各的 `_free`。
- 返回 `WowtypeCandidates *` 的函数（`wowtype_engine_input`、`wowtype_symbol_search`、`wowtype_emoji_recommend` 等），结果用 `wowtype_candidates_free` 释放；从里面取出的字符串在释放前有效。
- 返回 `const char *` 而且不属于某个句柄的（`wowtype_fullwidth_punct`、`wowtype_punct`、`wowtype_segment_input`、`wowtype_engine_shuangpin_display`、`wowtype_last_error`），指针在**同一线程**下一次调用同一个函数前有效，要留着就自己拷一份。
- `wowtype_version()` 返回静态字符串，一直有效。
- 外壳传进来的字符串都是 UTF-8、以 0 结尾，函数返回后核心不再持有。

## 线程

- 引擎句柄可以在一个线程建好、交给另一个线程用（插件就是在后台线程建引擎、载词库，再回主线程打字）。同一个句柄不要在多个线程同时调用，这一点没有承诺。
- 「指针在下一次调用前有效」的那些缓冲区是线程局部的，跨线程拿到的指针不要混用。
- 语音、翻译句柄各自管自己的后台线程；`_poll` 不阻塞，外壳在自己的定时器里调。

## 错误

- 返回指针的函数失败时返回 NULL，返回 `int` 的失败时返回负数（个别函数的约定写在头文件注释里）。
- 失败原因用 `wowtype_last_error()` 取（线程局部）。

## 输入会话（`wowtype_session_*`，1.3 起）

输入行为正在从 fcitx5 外壳一块一块挪进核心（[PORTING.md](PORTING.md) 第 2 步），外壳以后主要依赖这一组。

- **暂定**：挪完之前，这组函数不在上面「只加不删」的承诺里。标了「过渡」的函数（`wowtype_session_input`、`_remaining`、`_selected_text`、`_selection_count`、`_selection_pinyin`、`_push_selection`、`_append`）是给还没挪完的 fcitx5 外壳用的，挪完就删；删的时候次版本加一，写进上面的版本记录。fcitx5 外壳和核心一起发版，不受影响；别的外壳先只用 `_new`、`_key`、`_reset`、`_free`。
- **`handled`**：现在 0 的意思是「会话还不管这个键」，外壳接着用自己的逻辑处理。挪完以后 0 就是「交给应用」。
- **结构体**：`WowtypeKey`、`WowtypeSessionConfig`、`WowtypeFrame` 第一个字段都是 `size`。外壳填 `sizeof`，核心按它读，缺的字段当 0；核心返回的 frame 也带 `size`，外壳读新字段前先看它。
- **所有权**：`wowtype_session_new` 的结果用 `wowtype_session_free` 释放。`_key`、`_reset` 返回的 `WowtypeFrame *`、里面的字符串、过渡函数返回的字符串，都归会话所有，**在同一个会话的下一次调用前有效**（包括松开键那一次），不是线程局部缓冲。要留着就自己拷。
- **引擎**：现在会话还不用引擎，`wowtype_session_new` 的 engine 可以传 NULL（词库在后台载入，载入好之前也要能打字）。传了的话引擎要比会话活得久。
- **线程**：一个会话只在一个线程里用。
- **键码**：`keysym` 是 XKB keysym 的子集，`modifiers` 是 `WOWTYPE_MOD_*`（取值和 X11 / fcitx5 的 KeyState 一样）。macOS 外壳把 `kVK_*` / `flagsChanged:` 翻成这个。

已经挪进会话的行为（`core/tests/session_keys.rs` 测，和 `fcitx5-addon/test/key_harness.cpp` 里的同名用例对应）：

| 键 | 会话做什么 |
|---|---|
| 字母 | 进编辑区（大写原样保留） |
| `'` | 编辑区不空时进编辑区（隔音符），空的时候不管 |
| 退格 | 编辑区不空时：有已选词就撤销最后一个，没有就删一个字；删空了清空 |
| Esc | 编辑区不空时清空 |
