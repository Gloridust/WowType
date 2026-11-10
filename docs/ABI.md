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
| 1.4 | 0.3.11 | 候选列表和编辑区分音节挪进会话：加 `_set_engine`、`_configure`、`_frame`，`WowtypeSessionConfig` 加 `page_size`、`calculator`、`date_time`、`emoji_suggest`，`frame->preedit` 分好音节；过渡函数加 `_set_context`、`_candidate_total`、`_candidate_info` |
| 1.5 | 0.3.11 | 选词、整句上屏和学习挪进会话：加 `_choose`（按候选序号选，句首词进已选栈，选完上屏并记选词）、`_commit_input`（已选的词 + 原始输入上屏）；删掉过渡函数 `_selection_count`、`_selection_pinyin`、`_push_selection` |

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

## 输入会话（`wowtype_session_*`，1.3 起，1.4 加候选，1.5 加选词）

输入行为正在从 fcitx5 外壳一块一块挪进核心（[PORTING.md](PORTING.md) 第 2 步），外壳以后主要依赖这一组。

- **暂定**：挪完之前，这组函数不在上面「只加不删」的承诺里。标了「过渡」的函数（`wowtype_session_input`、`_remaining`、`_selected_text`、`_append`、`_set_context`、`_candidate_total`、`_candidate_info`、`_choose`、`_commit_input`）是给还没挪完的 fcitx5 外壳用的，挪完就删（`_choose`、`_commit_input` 等空格、回车、数字键挪进 `_key` 以后删，点候选改用草案里的 `_select`）；删的时候次版本加一，写进上面的版本记录。fcitx5 外壳和核心一起发版，不受影响；别的外壳先只用 `_new`、`_set_engine`、`_configure`、`_key`、`_frame`、`_reset`、`_free`。
- **`handled`**：现在 0 的意思是「会话还不管这个键」，外壳接着用自己的逻辑处理。挪完以后 0 就是「交给应用」。
- **结构体**：`WowtypeKey`、`WowtypeSessionConfig`、`WowtypeFrame`、`WowtypeCandidateInfo` 第一个字段都是 `size`。外壳填 `sizeof`，核心按它读，缺的字段当 0（`WowtypeSessionConfig` 例外：缺的字段用默认值）；核心返回的 frame 也带 `size`，外壳读新字段前先看它。
- **所有权**：`wowtype_session_new` 的结果用 `wowtype_session_free` 释放。`_key`、`_reset` 返回的 `WowtypeFrame *`、里面的字符串、过渡函数返回的字符串，都归会话所有，**在同一个会话的下一次调用前有效**（包括松开键那一次），不是线程局部缓冲。要留着就自己拷。
- **引擎**：候选和分音节要用引擎。`wowtype_session_new` 的 engine 可以传 NULL（词库在后台载入，载入好之前也要能打字，这时没有候选，编辑区是原始输入），载入好了用 `wowtype_session_set_engine` 补上。引擎要比会话活得久（或者先 `set_engine(NULL)`）。双拼开不开看引擎（`wowtype_engine_set_shuangpin`）；会话算候选时会把引擎的上文设成「已上屏的字 + 已选的词」的尾部。
- **候选缓存**：候选用到的时候才算（`_key`、`_frame` 要分音节时，或读候选时），编辑区、上文、引擎、设置都没变就不重算。
- **线程**：一个会话只在一个线程里用。
- **键码**：`keysym` 是 XKB keysym 的子集，`modifiers` 是 `WOWTYPE_MOD_*`（取值和 X11 / fcitx5 的 KeyState 一样）。macOS 外壳把 `kVK_*` / `flagsChanged:` 翻成这个。

已经挪进会话的行为（`core/tests/session_keys.rs` 测，和 `fcitx5-addon/test/key_harness.cpp` 里的同名用例对应）：

| 键 | 会话做什么 |
|---|---|
| 字母 | 进编辑区（大写原样保留） |
| `'` | 编辑区不空时进编辑区（隔音符），空的时候不管 |
| 退格 | 编辑区不空时：有已选词就撤销最后一个，没有就删一个字；删空了清空 |
| Esc | 编辑区不空时清空 |

| 其他 | 会话做什么 |
|---|---|
| 候选 | 引擎的候选，加上：首选是整句时推荐一个 emoji（插第 3 个）；第一页里的数字字后面跟按键 emoji（八 → 8️⃣）；没选过词时打 riqi / shijian / xingqi 在首选后面插日期时间（双拼看首选的拼音）；V 模式（`v` + 算式，双拼不开）候选是结果和「算式=结果」 |
| 编辑区 | 已选的词 + 剩余部分分好音节（`nihao` → `ni'hao`，双拼显示成全拼）；没有引擎时是原始输入 |
| 选词（`_choose`） | 候选没用完输入：进已选栈，记一次选词，候选换成剩下的；用完了：已选的词 + 这个候选上屏，记选词（带拼音，选够次数收进用户词库），分几次选出来的整句也记一次；emoji 和日期时间、计算结果这类候选只上屏不记；序号不对 `handled` = 0 |
| 上屏输入（`_commit_input`） | 已选的词 + 原始输入上屏（回车、切输入法、打到一半切英文），原始输入也记一次选词；什么也没打就不上屏 |
| 学习的上文 | 记选词前把引擎的上文设成算候选时那个（已上屏的字 + 已选的词的尾部） |
