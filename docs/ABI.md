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
| 1.8 | 0.3.11 | 以词定字：`WowtypeSessionConfig` 末尾加 `pick_char`（默认 1），打拼音途中 `[` `]` 上屏光标处候选的第一个、最后一个字（`page_keys` 带 `[ ]` 时让给翻页） |
| 1.9 | 0.3.11 | 加 `wowtype_engine_set_rare_ext_chars`：是否出 CJK 扩展 B 区及以后的单字（通用规范汉字表里的除外），默认不出（以前总是出） |
| 1.10 | 0.4.0 | 输入会话接管标点、自动空格、上文、中 / 英 / 译和单按 Shift、互译、工具栏和表情面板：`WowtypeKey` 加 `hints`、`code`、`repeat`、`time_ms`（`KEY_HINT_*`、`KEY_ACTION_OBSERVE`、`KEY_ACTION_TOGGLE_MODE`、`KEY_ACTION_TOGGLE_TRANSLATE`；`KEY_HINT_SURROUNDING`：读得到周围文字时拿 `prev_char` 核对会话记的上文），`WowtypeSessionConfig` 加 `punct_style`、`auto_space`、`shift_toggle`、`shift_tap_ms`、`translate_mode`、`toolbar`、`clipboard_history`，`WowtypeFrame` 加 `learned`、`mode`、`mode_changed`、`translating`、`translate_*`（`aux`、`wake_after_ms` 开始用，`panel` 加 2 表情面板、3 工具栏）；加 `wowtype_session_set_mode`、`_mode`、`_set_translator`、`_set_translate_backend`、`_tick`、`_commit_text`、`_translate_clear`、`_translate_source`、`_toggle_emoji_panel`、`_open_tool`、`_open_panel`、`wowtype_recent_emoji_path`、`_list`、`wowtype_custom_code`、`wowtype_guess_pinyin`（自定义词的编码整理、猜拼音，macOS 设置不再自己抄音节表），`wowtype_engine_set_domain_lm`（混上用户自己训的领域词级模型），`WowtypeSessionConfig` 加 `shuangpin_keys`（双拼编辑区显示打的键）；五笔：加 `wowtype_engine_load_wubi`，`WowtypeSessionConfig` 加 `wubi`、`wubi_auto_commit`、`wubi_hint`，`translate_key`（另设了进出「译」的键，单按 Shift 只切中 / 英），`WowtypeCandidateInfo` 加 `comment`、加 `wowtype_session_candidate_comment`（候选后面的小字）；删掉会话的过渡函数 `_append`、`_set_context`、`_last_choice` |
| 1.11 | 0.5.0 | `KEY_HINT_NO_LEARN`（1 << 4）：确定是密码框，选的词也不学（回车上屏的原始字母串哪里都不学）；加 `wowtype_nnlm_check`（只试着解析字级神经语言模型，不载入引擎，导入前用）；上屏以后的联想：`WowtypeSessionConfig` 末尾加 `association`（默认 0，外壳会画了才开），`WowtypeFrame.panel` 加 4（`WOWTYPE_PANEL_ASSOCIATION`），加 `wowtype_session_association`；`wowtype_engine_predict_next` 把学到的搭配排在模型的前面。退格把句首词退回编辑区、Esc 放弃、上屏后紧接着按退格时撤销学到的（会话里做，外壳不用改）；存盘挪出按键线程：加 `wowtype_engine_save_user_dict_async`、`_save_history_async`（锁里抄一份、引擎自己的线程写，连着的合并成一次）、`wowtype_engine_save_wait`（等写完，进程退出、外壳析构、换词库前调），同步的两个 save 照旧（先等后台排着的写完），`wowtype_engine_free` 也先写完 |
| 1.12 | 0.6.0 | 中文标点自动配对：`WowtypeSessionConfig` 末尾加 `auto_pair_punct`（默认 0，外壳会挪光标、删字了才开），`WowtypeFrame` 末尾加 `cursor_delta`（commit 落到应用以后把光标挪几格，负数左移）、`delete_next`（这次没接的退格要连光标后的右标点一起删），`WowtypeKey` 末尾加 `next_char`（光标后一个字）和 `KEY_HINT_NEXT_CHAR`（1 << 5，`next_char` 为 0 是光标后确实没有字，有选区时别带）；打字统计（默认关）：加 `wowtype_stats_new`、`_free`、`_set_enabled`、`_enabled`、`_key`、`_commit`、`_flush`、`_wait`、`_clear`、`_now_ms`、`WOWTYPE_STATS_SENSITIVE`。记录器新建时关着（不读不建文件、不起线程），外壳按 `TypingStats` 打开；只记按天的聚合计数（字符数和类别、活跃毫秒、各键按下次数、模式和双拼方案的字数、候选位置），不记文字、拼音、按键顺序和时刻，带 `WOWTYPE_STATS_SENSITIVE`（密码框）的整个不算；按键和上屏只改内存，写文件在记录器自己的线程，`_free` 等写完。`WowtypeCandidateInfo` 末尾加 `index`（候选在列表里的位置，1 起），`WowtypeFrame` 末尾加 `choice_index`（这次上屏的候选位置，不是选候选为 0） |
| 1.13 | 0.7.0 | 核心能在 Windows（MSVC）上编（`core/src/platform.rs`），接口不变；`wowtype_stats_key` 的 `platform` 加 2 = Windows（扫描码，扩展键或上 0xE000，只传按下）；`wowtype_engine_load_history` 和引擎里已有的合并（同一条留最近用过的），`wowtype_engine_load_user_dict` 已经有的词留大的频次，新建的引擎上读和以前一样 |
| 1.14 | 0.7.2 | 双击 Shift 不切换（#253）：`WowtypeSessionConfig` 末尾加 `shift_double_tap`（默认 0）。开着时单按 Shift 先不切，`frame->wake_after_ms` 叫外壳过一会儿调 `_tick`；0.35 秒以内又单按一下两下都不算（模式不变，没有 `mode_changed`）。没等到第二下：按别的键（`KEY_ACTION_OBSERVE` 也算，这个键照切了以后的模式处理）、到了时间（`_tick`）、第二下没算成单按时切，这些 frame 都可能带 `mode_changed`（打到一半切英文时还有 `commit`），外壳要跟上；`_set_mode` 让等着的那一下作废 |
| 1.15 | 0.7.2 | 加 `wowtype_engine_set_shuangpin_abbrev`：双拼的简拼（每个键都是声母时当成只打了声母，`sm` -> 什么；同样的键按双拼也读得通时双拼读出来的排在前面，简拼的词只往后加），默认开（#268） |
| 1.16 | 0.7.5 | 加 `wowtype_voice_set_silence_timeout`：点按说话时没声音多久自动结束（毫秒，默认 1500），0 是不因静音结束，只有再按一次热键、`_cancel` 或到了单次最长录音 2 分钟才结束；长按说话不受影响（#285） |
| 1.17 | 0.7.6 | 互译只翻一句（#191）：`WowtypeSessionConfig` 末尾加 `translate_one_shot`（默认 0，`translate_mode` 时才起作用）。开着时单按 Shift 只在中 ↔ 英之间切；开着 `shift_double_tap` 时 0.35 秒以内单按两下不再两下都不算，而是进「译」（打到一半的拼音带进去，进不了「译」时照旧两下都不算）。怎么进的「译」（双击、`KEY_ACTION_TOGGLE_TRANSLATE`、`_set_mode`）都只翻一句：译文上屏（回车、空格；按过回车、译好了才上屏的在 `_tick` 的 frame 里）、Esc（攒着原文时清空，什么都没打时也算）、Shift+回车、单按 Shift、在「译」里再双击 / 按互译键都回到进来前的模式，这些 frame 带 `mode_changed`，外壳要跟上（`_key` 的 frame 也看）。Shift 的按下不再清掉会话记着的 `hints`（外壳报 Shift 时不带提示，密码框里双击进不了「译」） |

## 所有权和生命周期

- `wowtype_engine_new` 返回的句柄用 `wowtype_engine_free` 释放；`wowtype_voice_new`、`wowtype_translate_new`、`wowtype_stats_new` 同理各配各的 `_free`。
- 返回 `WowtypeCandidates *` 的函数（`wowtype_engine_input`、`wowtype_symbol_search`、`wowtype_emoji_recommend` 等），结果用 `wowtype_candidates_free` 释放；从里面取出的字符串在释放前有效。
- 返回 `const char *` 而且不属于某个句柄的（`wowtype_fullwidth_punct`、`wowtype_punct`、`wowtype_segment_input`、`wowtype_engine_shuangpin_display`、`wowtype_last_error`），指针在**同一线程**下一次调用同一个函数前有效，要留着就自己拷一份。
- `wowtype_version()` 返回静态字符串，一直有效。
- 外壳传进来的字符串都是 UTF-8、以 0 结尾，函数返回后核心不再持有。

## 线程

- 引擎句柄可以在一个线程建好、交给另一个线程用（插件就是在后台线程建引擎、载词库，再回主线程打字）。同一个句柄不要在多个线程同时调用，这一点没有承诺。
- 「指针在下一次调用前有效」的那些缓冲区是线程局部的，跨线程拿到的指针不要混用。
- 语音、翻译句柄各自管自己的后台线程；`_poll` 不阻塞，外壳在自己的定时器里调。
- 引擎有一个存盘线程（1.11，第一次调 `_save_*_async` 时才起）：只写交给它的那份拷贝，不碰引擎；`wowtype_engine_free` 等它写完再释放。
- 打字统计的记录器（1.12）在一个线程用（外壳的按键线程）；它有自己的写文件线程（打开统计时才起），按键线程不读写文件，`wowtype_stats_free` 等它写完。

## 错误

- 返回指针的函数失败时返回 NULL，返回 `int` 的失败时返回负数（个别函数的约定写在头文件注释里）。
- 失败原因用 `wowtype_last_error()` 取（线程局部）。

## 输入会话（`wowtype_session_*`，1.3 起，1.4 加候选，1.5 加选词，1.6 加选词键、翻页和展开面板，1.7 加 Ctrl+Delete 忘掉学错的词，1.10 加标点、自动空格、上文、中 / 英 / 译和单按 Shift、互译、工具栏和表情面板，1.11 加联想）

输入行为都在会话里，两个外壳（fcitx5、macOS）只把平台的按键翻成键码交给会话、照 frame 画编辑区和候选框、上屏、读周围文字和系统剪贴板、排定时器（[PORTING.md](PORTING.md)）。

- **1.10 删掉的过渡函数**：`wowtype_session_append`、`_set_context`（上文由会话自己记，表情面板的搜索词也在会话里）、`_last_choice`（学没学到词看 `frame->learned`，选了 emoji 由会话记进最近用过）。fcitx5 外壳和核心一起发版，不受影响。
- **留着的读法**：`_input`、`_remaining`、`_selected_text`（外壳判断在不在打字、拼编辑区），以及整个候选列表 `_candidate_total`、`_candidate_info`、`_choose`、`_view`（fcitx5 的候选框 CommonCandidateList 要整个列表和页码、光标）。这些和别的会话函数一样按上面「只加不删」的规矩来。
- **`handled`**：0 就是「交给应用」。还在外壳里的只有语音键（录音、浮条和平台的麦克风绑在一起）。
- **候选框**（1.6）：frame 的 `cand_count` 是候选框里显示的个数（一页，或展开面板的一屏），`cand_cursor` 是光标在里面的位置（光标不在这一页上时是 -1），`has_prev` / `has_next` 是还能不能往前 / 往后翻，`panel` 说现在是普通候选框还是展开面板；显示的第 i 个用 `wowtype_session_candidate(s, i)` 取，点它用 `wowtype_session_select(s, i)`。
- **结构体**：`WowtypeKey`、`WowtypeSessionConfig`、`WowtypeFrame`、`WowtypeCandidateInfo` 第一个字段都是 `size`。外壳填 `sizeof`，核心按它读，缺的字段当 0（`WowtypeSessionConfig` 例外：缺的字段用默认值）；核心返回的 frame 也带 `size`，外壳读新字段前先看它。
- **所有权**：`wowtype_session_new` 的结果用 `wowtype_session_free` 释放。`_key`、`_reset` 返回的 `WowtypeFrame *`、里面的字符串、过渡函数返回的字符串，都归会话所有，**在同一个会话的下一次调用前有效**（包括松开键那一次），不是线程局部缓冲。要留着就自己拷。
- **引擎**：候选和分音节要用引擎。`wowtype_session_new` 的 engine 可以传 NULL（词库在后台载入，载入好之前也要能打字，这时没有候选，编辑区是原始输入），载入好了用 `wowtype_session_set_engine` 补上。引擎要比会话活得久（或者先 `set_engine(NULL)`）。双拼开不开看引擎（`wowtype_engine_set_shuangpin`）；会话算候选时会把引擎的上文设成「已上屏的字 + 已选的词」的尾部。
- **候选缓存**：候选用到的时候才算（`_key`、`_frame` 要分音节时，或读候选时），编辑区、上文、引擎、设置都没变就不重算。
- **线程**：一个会话只在一个线程里用。
- **键码**：`keysym` 是 XKB keysym 的子集，`modifiers` 是 `WOWTYPE_MOD_*`（取值和 X11 / fcitx5 的 KeyState 一样）。macOS 外壳把 `kVK_*` / `flagsChanged:` 翻成这个。

会话的行为（`core/tests/session_keys.rs` 测，和 `fcitx5-addon/test/key_harness.cpp`、`macos/Tests/main.swift` 里的同名用例对应）：

| 键 | 会话做什么 |
|---|---|
| 字母 | 进编辑区（大写原样保留） |
| `'` | 编辑区不空时进编辑区（隔音符），空的时候不管 |
| 退格 | 编辑区不空时：有已选词就撤销最后一个（选它时学到的也退回去），没有就删一个字；删空了清空。编辑区空的时候交给应用，是上屏后紧接着按的（中间没按别的键、没再上屏别的）就退回刚才那次上屏学到的 |
| `Ctrl+Delete`、`Ctrl+退格`、`Shift+Delete`（1.7） | 编辑区不空时：忘掉光标处的候选（展开面板时是面板的光标）学到的东西（用户词、选词热度、搭配），候选原地重算，编辑区、页和光标不动，`frame->forgot` = 1；没学过的、自定义词、计算结果和 emoji 这类什么也不做，但键照样吃掉（不让应用删掉一个词）。带 Alt、Super 的不算；编辑区空的时候不管 |
| Esc | 编辑区不空时清空（展开面板时只收起面板），已选的词学到的退回去（`_reset(s, 0)` 放弃时也是） |
| 空格 | 选光标处的候选（光标不在这一页上时选这一页第一个）；没有候选就原样上屏 |
| 回车（含小键盘） | 已选的词 + 原始输入上屏；原始字母串不记选词（已选的词选的时候记过了） |
| 数字（含小键盘，不带 Shift 等修饰键） | 选这一页的第几个；这一页没这么多也吃掉 |
| `[` `]`（`pick_char`，1.8） | 以词定字：光标处的多字词只取第一个 / 最后一个字；句首词取的字进已选栈，剩下的接着选，否则连同已选的词上屏；不记选词。光标处是单字、emoji、计算结果这类时不管（外壳照常当标点）；`page_keys` 带 `[ ]` 时是翻页 |
| `;` `'`（`select_keys`） | 选这一页第 2、3 个；微软、搜狗、紫光双拼里 `;` 是韵母键，不拿来选词，等第二个键时进编辑区 |
| V 模式的数字、运算符 | 进编辑区；`=` 上屏计算结果 |
| 方向键 | `arrow_keys` 是 `CANDIDATES`（默认）时，横排：左右移光标（跨页时跟着翻页，到了第一个、最后一个停住，不绕到另一头），上下翻页，下键展开面板（两个以上候选）；竖排：上下移光标，左右翻页。`CARET`（1.10）时横排竖排都是上下移候选光标、不翻页、不展开面板；左右键、Home、End、Delete 管拼音里的光标（`frame->preedit_cursor`），到了两头也吃掉，「译」里光标不动 |
| PgUp / PgDn、`page_keys` 里的键 | 翻页；`- =`、`[ ]`、`, .`、`Tab` 翻不动时吃掉（不当标点上屏），只有一页时不管 |
| `action` | 外壳认出来的全局翻页 / 移光标键，有候选时照做，翻不动也吃掉 |
| 展开面板 | 6×6 一屏；方向键移光标，第一行再按上收起，PgUp / PgDn、`- =` 一次一屏，数字选光标那一行的第几个，空格选光标处，Esc 收起；别的键先收起再照常处理。收起后停在光标那一页 |
| 标点、符号（1.10） | 打字途中：先上屏候选（光标在句首词上时接着选，直到整句上屏），再上屏它（全角样式下有中文标点的换成中文标点，数字写法里的符号保持英文）；没在打字：有中文标点的换成中文标点上屏，半角样式、数字写法里的符号、没有中文写法的（`/ + @`）交给应用。顿号、问号这类没有半角形态的数字后面照常换成中文标点（`1\` → `1、`）。引号左右交替的状态每个会话一份 |
| 数字（没在打字，1.10） | 汉字后面要补空格（`auto_space`）时连空格一起上屏，否则交给应用 |
| Shift（1.10） | 单按切换中 → 英 →（`translate_mode` 时）译 → 中，设了 `translate_key` 时只在中 ↔ 英之间切（在「译」里回中文）：按下时带 Ctrl / Alt / Super、开着面板不算；自动重复不重新计时；松开时按键码认；中间按了别的键（外壳自己处理掉的用 `KEY_ACTION_OBSERVE` 报）不算；按住超过 `shift_tap_ms` 不算。切英文时打到一半的原样上屏，离开「译」时原文原样上屏。开着 `shift_double_tap`（1.14）时单按先等 0.35 秒（`SHIFT_DOUBLE_TAP_MS`）：这么久以内又按下 Shift 并单按，两下都不算（JetBrains 的双击 Shift）；按了别的键、到了时间（`_tick`）、第二下按晚了或没算成单按时第一下照切。开着 `translate_one_shot`（1.17）时单按只在中 ↔ 英之间切（在「译」里回到进来前的模式），双击进出「译」、只翻一句 |
| 设置里的快捷键（1.10） | 外壳认出 ToggleKey、TranslateModeKey 后带上 `KEY_ACTION_TOGGLE_MODE` / `_TOGGLE_TRANSLATE` 交给 `_key`（开着面板时别带）。切换键：中 ↔ 英，在「译」里回中文；互译键：进「译」（打到一半的拼音带进去；开着 `translate_one_shot` 时只翻一句，1.17），在「译」里回到进来前的模式（翻译不能用了也回得去）；没有「译」或带 `KEY_HINT_NO_TRANSLATE` 时 `handled` 为 0，键交给应用 |
| 英文模式（1.10） | 只管汉字后面打字母、数字时补空格，别的键交给应用 |
| 互译（1.10） | 上屏的字攒成原文（`frame->translate_*`），0.5 秒没再打字（句末标点立刻）发请求，`frame->wake_after_ms` 时外壳调 `_tick`；没在打拼音时：回车上屏译文（没译完先记下，译好了在 `_tick` 的 commit 里）、Shift+回车上屏原文、空格上屏译文、Esc 清空、退格删原文、方向键吃掉、数字和符号进原文。`translate_one_shot`（1.17）时上屏译文、上屏原文、Esc 以后回到进来前的模式（`mode_changed`，可能在 `_tick` 里） |
| 联想（`association`，1.11） | 选词上屏、整句上屏（选了引擎的词，不是回车原样上屏的字母）以后，按上文末尾查常跟在后面的词（学到的搭配在前，再是词级模型），一页（最多 `page_size` 个）放进候选框：`frame->panel` 是 4，`preedit` 空，提示在 `aux`；去掉标点、单个字母、和刚上屏的一样的。没进联想行时 `cand_cursor` 是 -1（外壳别画序号）：只有 Tab（进联想行）和 Esc（关掉，吃掉）归联想，别的键（字母、数字、标点、空格、回车、退格、方向键、快捷键）先关掉联想再照原来的规则处理——数字不选联想（中文后面接着打数字很常见）；单按的修饰键、松开不关。进了联想行：空格、回车、数字选，左右（上下）键、Tab、Shift+Tab 移光标，Esc 退出，别的键退出联想再照常。鼠标点用 `_select` / `_choose`（没进联想行也能点）。选中的上屏、和普通选词一样记一次选词，接着出下一轮。五笔、「译」、`KEY_HINT_NO_TRANSLATE`（密码框）、英文不出；`_reset`、切模式、开面板、外壳上屏别的字时关掉 |
| 自动配对（`auto_pair_punct`，1.12） | 全角标点、不在「译」里时：打 `( [ < { " '` 上屏成对的（）【】《》「」“”‘’，`frame->cursor_delta` 是 -1（光标放中间）；数字后面的左标点照常是半角、不配对。在里面再按右半边（`) ] > } " '`，数字后面也算）不上屏，`cursor_delta` 是 +1（跳过补好的那个；打字途中按的话 `commit` 是先上屏的候选）。可以套着。会话数着左半边和光标之间有几个字（上屏的、交给应用的字和空格）：交给应用的退格少数一个，数到 0 时（空的一对）`delete_next` 为 1，外壳连光标后的右标点一起删。交给应用的方向键、Home、End、翻页、回车、Tab、Delete、带 Ctrl / Alt / Super 的键和 `_reset`、进出「译」让配对作废（中 ↔ 英不算，Esc 不算）；带 `KEY_HINT_NEXT_CHAR` 时跳过、成对删之前核对光标后确实是那个右标点（成对删再拿 `prev_char` 核对左半边），对不上配对作废、照常处理。外壳挪光标、删字要按顺序：挪光标在这次的 `commit` 落到应用以后、下一个键之前，和 `delete_next` 的两下走同一条路 |
| v + 空格、表情快捷键（1.10） | 工具栏（菜单、剪贴板、常用语，竖排一页 9 个）和表情 / 符号面板（6 列网格，字母搜索）；开着时按键都归面板，带 Ctrl / Alt / Super 的收起面板、交给应用；`frame->panel` 是 3 / 2，提示在 `frame->aux` |
| 五笔（`wubi`，1.10） | 字母是五笔码（a–y，最多四码）：码对上的按码表顺序排在前，后面是逐码提示（更长的码的词，`comment` 是还要打的码，`wubi_hint` 关掉时为空）；四码只有一个候选时直接上屏（`wubi_auto_commit`）；四码再打字母、空码时打字母、按 z 或大写字母先顶字（空码丢掉）；空码时 `frame->aux` 是「空码」，空格清空，标点只上屏标点，回车上屏字母；打码时引号是标点；z 开头临时打全拼（编辑区 `z` + 分好音节的拼音，`comment` 是反查的五笔码）；计算器是大写 `V`，v + 空格不开工具栏；日期时间只在临时拼音里出；`arrow_keys` 是 `CARET` 时打五笔码的方向键照 `CANDIDATES` 用（临时拼音里照常挪光标，挪不到 z 前面）；五笔和临时拼音都不学习，Ctrl+Delete 在五笔码上什么也不忘。引擎没载入码表时照全拼打，`frame->aux` 说没有码表 |

| 其他 | 会话做什么 |
|---|---|
| 候选 | 引擎的候选，加上：首选是整句时推荐一个 emoji（插第 3 个）；第一页里的数字字后面跟按键 emoji（八 → 8️⃣）；没选过词时打 riqi / shijian / xingqi 在首选后面插日期时间（双拼看首选的拼音）；V 模式（`v` + 算式，双拼不开）候选是结果和「算式=结果」 |
| 编辑区 | 已选的词 + 剩余部分分好音节（`nihao` → `ni'hao`，双拼显示成全拼）；没有引擎时是原始输入 |
| 选词（`_select`、`_choose`） | 候选没用完输入：进已选栈，记一次选词，候选换成剩下的；用完了：已选的词 + 这个候选上屏，记选词（带拼音，选够次数收进用户词库），分几次选出来的整句也记一次；emoji 和日期时间、计算结果这类候选只上屏不记；序号不对 `handled` = 0；`_select` 的序号是候选框里显示的（一页，或展开面板的一屏），`_choose` 是整个列表的 |
| 上屏输入（回车，`_reset` 带 commit_pending 也一样） | 已选的词 + 原始输入上屏（回车、切输入法、打到一半切英文），原始字母串不记选词；什么也没打就不上屏。互译时拼音先进原文，原文再原样上屏 |
| 上文（1.10） | 会话自己记上屏的最后 20 个字，排序和学搭配都看它；外壳不用再 `set_context`。记的上文要信得过：带 `KEY_HINT_SURROUNDING`（应用告诉了周围文字）的键，没在打字时上文的最后一个字要和 `prev_char` 对得上，对不上换成 `prev_char`（光标前没字就清空）；没在打字时交给应用的键（退格、Delete、方向键、回车、快捷键、英文和半角的字）和 `_reset(s, 0)`（失去焦点、应用重置）都让上文作废。所以没在打字时外壳也要把这些键交给 `_key`，包括带 Ctrl / Alt / Super 的 |
| 外壳的上屏（`_commit_text`，1.10） | 工具栏、语音这类与拼音无关的字：互译时进原文，否则补好空格放进 commit |
| 学习的上文 | 记选词前把引擎的上文设成算候选时那个（已上屏的字 + 已选的词的尾部） |
