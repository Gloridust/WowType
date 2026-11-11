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
| 1.6 | 0.3.11 | 空格、回车、数字、分号引号选词、翻页和展开面板挪进 `_key`：`WowtypeKey` 加 `action`（`WOWTYPE_KEY_ACTION_*`，外壳的全局翻页 / 移光标键），`WowtypeSessionConfig` 加 `horizontal`、`page_keys`（`WOWTYPE_PAGE_KEYS_*`）、`select_keys`（`WOWTYPE_SELECT_KEYS_*`），frame 的 `panel`、`cand_count`、`cand_cursor`、`has_prev`、`has_next` 开始填；加 `_select`（按显示的序号选）、`_candidate`；过渡函数加 `_view`、`_last_choice`，删掉 `_commit_input`（用 `_key` 发回车或 `_reset(s, 1)`） |
| 1.7 | 0.3.11 | 打字途中 `Ctrl+Delete`、`Ctrl+退格`、`Shift+Delete` 忘掉光标处学错的词（会话里处理，带 Ctrl 的这几个键外壳也要交给 `_key`），`WowtypeFrame` 末尾加 `forgot`：1 时外壳马上存用户词库和输入习惯；`wowtype_engine_save_user_dict` 用户词库空的时候也写（只有注释行）、返回 0，以前返回 -1 |

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

## 输入会话（`wowtype_session_*`，1.3 起，1.4 加候选，1.5 加选词，1.6 加选词键、翻页和展开面板，1.7 加 Ctrl+Delete 忘掉学错的词）

输入行为正在从 fcitx5 外壳一块一块挪进核心（[PORTING.md](PORTING.md) 第 2 步），外壳以后主要依赖这一组。

- **暂定**：挪完之前，这组函数不在上面「只加不删」的承诺里。标了「过渡」的函数（`wowtype_session_input`、`_remaining`、`_selected_text`、`_append`、`_set_context`、`_candidate_total`、`_candidate_info`、`_choose`、`_view`、`_last_choice`）是给还没挪完的 fcitx5 外壳用的，挪完就删（`_choose` 现在只给标点上屏首选和鼠标点候选用，标点挪进来、点候选改用 `_select` 以后删；`_view`、`_last_choice` 是外壳照会话摆候选框、上屏后记 emoji 用的，候选框整个由 frame 驱动以后删）；删的时候次版本加一，写进上面的版本记录。fcitx5 外壳和核心一起发版，不受影响；别的外壳先只用 `_new`、`_set_engine`、`_configure`、`_key`、`_frame`、`_candidate`、`_select`、`_reset`、`_free`。
- **`handled`**：现在 0 的意思是「会话还不管这个键」，外壳接着用自己的逻辑处理。挪完以后 0 就是「交给应用」。还在外壳里的：标点、工具栏、表情面板、中 / 英 / 译和互译、语音键。
- **候选框**（1.6）：frame 的 `cand_count` 是候选框里显示的个数（一页，或展开面板的一屏），`cand_cursor` 是光标在里面的位置（光标不在这一页上时是 -1），`has_prev` / `has_next` 是还能不能往前 / 往后翻，`panel` 说现在是普通候选框还是展开面板；显示的第 i 个用 `wowtype_session_candidate(s, i)` 取，点它用 `wowtype_session_select(s, i)`。
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
| `Ctrl+Delete`、`Ctrl+退格`、`Shift+Delete`（1.7） | 编辑区不空时：忘掉光标处的候选（展开面板时是面板的光标）学到的东西（用户词、选词热度、搭配），候选原地重算，编辑区、页和光标不动，`frame->forgot` = 1；没学过的、自定义词、计算结果和 emoji 这类什么也不做，但键照样吃掉（不让应用删掉一个词）。带 Alt、Super 的不算；编辑区空的时候不管 |
| Esc | 编辑区不空时清空（展开面板时只收起面板） |
| 空格 | 选光标处的候选（光标不在这一页上时选这一页第一个）；没有候选就原样上屏 |
| 回车（含小键盘） | 已选的词 + 原始输入上屏，原始输入也记一次选词 |
| 数字（含小键盘，不带 Shift 等修饰键） | 选这一页的第几个；这一页没这么多也吃掉 |
| `;` `'`（`select_keys`） | 选这一页第 2、3 个；微软、搜狗、紫光双拼里 `;` 是韵母键，不拿来选词，等第二个键时进编辑区 |
| V 模式的数字、运算符 | 进编辑区；`=` 上屏计算结果 |
| 方向键 | 横排：左右移光标（整个列表首尾相接，跨页时跟着翻页），上下翻页，下键展开面板（两个以上候选）；竖排：上下移光标，左右翻页 |
| PgUp / PgDn、`page_keys` 里的键 | 翻页；`- =`、`[ ]`、`, .`、`Tab` 翻不动时吃掉（不当标点上屏），只有一页时不管 |
| `action` | 外壳认出来的全局翻页 / 移光标键，有候选时照做，翻不动也吃掉 |
| 展开面板 | 6×6 一屏；方向键移光标，第一行再按上收起，PgUp / PgDn、`- =` 一次一屏，数字选光标那一行的第几个，空格选光标处，Esc 收起；别的键先收起再照常处理。收起后停在光标那一页 |

| 其他 | 会话做什么 |
|---|---|
| 候选 | 引擎的候选，加上：首选是整句时推荐一个 emoji（插第 3 个）；第一页里的数字字后面跟按键 emoji（八 → 8️⃣）；没选过词时打 riqi / shijian / xingqi 在首选后面插日期时间（双拼看首选的拼音）；V 模式（`v` + 算式，双拼不开）候选是结果和「算式=结果」 |
| 编辑区 | 已选的词 + 剩余部分分好音节（`nihao` → `ni'hao`，双拼显示成全拼）；没有引擎时是原始输入 |
| 选词（`_select`、`_choose`） | 候选没用完输入：进已选栈，记一次选词，候选换成剩下的；用完了：已选的词 + 这个候选上屏，记选词（带拼音，选够次数收进用户词库），分几次选出来的整句也记一次；emoji 和日期时间、计算结果这类候选只上屏不记；序号不对 `handled` = 0；`_select` 的序号是候选框里显示的（一页，或展开面板的一屏），`_choose` 是整个列表的 |
| 上屏输入（回车，`_reset` 带 commit_pending 也一样） | 已选的词 + 原始输入上屏（回车、切输入法、打到一半切英文），原始输入也记一次选词；什么也没打就不上屏 |
| 学习的上文 | 记选词前把引擎的上文设成算候选时那个（已上屏的字 + 已选的词的尾部） |
