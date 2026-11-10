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

## 以后

输入行为挪进核心以后（见 [PORTING.md](PORTING.md)），会多一组 `wowtype_session_*`，外壳主要依赖它。那组函数加进来时次版本加一，现有函数不变。
