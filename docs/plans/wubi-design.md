# 五笔模式设计说明

状态：设计稿，供实现五笔模式的人照着做（数据见 `scripts/make-wubi.sh`，PR #193）。
实现：PR #208。和这份设计稿不一样的地方（日期时间、自定义编码、编码提示画在哪等）以 PR 说明和 README 的「五笔」一节为准。
目标：这一版就能上五笔，体验对得上主流五笔输入法，设置保持简单。

## 0. 结论先行

- **一个「输入方案」单选**：全拼 / 双拼 / 五笔，替代现在独立的 `Shuangpin` 开关。五笔下只多 **2 个**开关：
  「四码唯一自动上屏」（开）、「编码提示」（开）。
- **v1 必做**：码表查词与排序、四码唯一自动上屏、第五码顶字、空码处理、标点顶字、`z` 临时拼音（带五笔编码提示）、
  五笔选词不进拼音词库、和现有功能（计算器、工具栏、日期时间、emoji、简繁、以词定字、互译）的冲突处理、全平台打包。
- **v1 不做**：五笔拼音混输（v1.1 再加，作为第 3 个开关，默认关）、自动调频、98/新世纪、万能键、增广字集。
- **在会话层做，不在 `Engine::input` 里特判**（同意计划，理由见第 2 节）。

## 1. 参考：主流五笔怎么做

搜狗 / QQ、极点两列凭使用经验，没有逐项核对出处，默认值以实际版本为准。Rime 一列来自 rime-wubi 的 `wubi86.schema.yaml`，fcitx5 一列来自 fcitx5-chinese-addons 的 `wbx.conf.in.in`。

| 行为 | 微信输入法（本机 3.0.1） | 搜狗 / QQ 五笔（经验） | 极点五笔（经验） | Rime wubi86 | fcitx5 五笔（libime 码表） |
|---|---|---|---|---|---|
| 四码唯一自动上屏 | 开关，本机为开 | 有，默认开 | 有，默认开 | 默认不自动（`auto_select` 未开） | `AutoSelect=True` |
| 第五码顶字 | 开关（「第五码首选词上屏」），本机为**关** | 有 | 有，默认开 | 码长不限（拼句） | `NoMatchAutoSelectLength=-1`（按键名理解为无匹配时顶字，未实测） |
| 拼音混输 | 开关，本机为开 | 默认混输 | 有单独的「五笔拼音」方案 | 有单独的 `wubi_pinyin` 方案 | 有单独的 Wubi Pinyin |
| `z` 键 | 未确认（混输开着时拼音直接打） | 临时拼音 | 万能键 / 临时拼音 | 拼音反查（`z` 前缀），候选带五笔码 | `PinyinKey=z` 且 `MatchingKey=z` |
| 编码提示 | 开关，本机为开 | 逐码提示 | 逐码提示 | 反查时提示 | `Hint=True` |
| 调频 | 有用户五笔词典 | 可选，默认固定 | 可选，默认固定 | 用户词典调频 | `OrderPolicy=Freq`，但码长 ≤2 不调（`NoSortInputLength=2`） |
| 造词 | 有用户五笔词典 | 自动 + 手动造词 | 手动造词 | 按规则编码造词（`encode_commit_history`） | 用 3 次自动成词（`SaveAutoPhraseAfter=3`） |

微信输入法一列只记**规则**，没有取任何数据。

**直接看到的：**

- 程序里有四个设置项文字：「五笔编码提示」「四码唯一上屏」「五笔拼音混输」「第五码首选词上屏」，还有「86五笔」。
- 用户设置存储（`~/Library/Application Support/WeType/mmkv/`，不在安装目录里）有：
  - 三个方案键：`InputScheme`、`ShuangpinScheme`、`WubiScheme`；
  - 一个 `WubiConfig` JSON，四个键是 `enableComment`、`emitUniqueCandidate`、`enablePinyin`、`emitWhenInputNextRune`，本机值依次是 开、开、开、关。
- 符号表里能看到这几个引擎组件：
  - `WubiSessionV2`：独立的五笔会话；
  - `WubiComment`：给候选加编码注释的装饰层；
  - `ReverseWubiDict`：词 → 码，用于反查和提示；
  - `UserWubiDict`：用户五笔词，和拼音的用户词典分开。

**推断的，没有直接看到：**

- 输入方案是一个单选。
- 四个 JSON 键按名字对应上面四个设置项。
- `WubiScheme` 对应 86 / 98 / 新世纪：词典目录里有 `swbd86/98/nc.bin`，但 98、新世纪的界面文字没找到。
- 本机值是不是出厂默认，无法确认。

**混输和第五码顶字的关系**：本机恰好是混输开、顶字关，但不能据此说微信输入法把两者绑定。

两者确实有歧义：混输时第 5 个字母可能是拼音的一部分，也可能是下一个字的码。WowType v1 不做混输，没有这个歧义，所以第五码顶字固定开。

## 2. 架构：在会话层做

PR #194 在 `Engine::try_input_at`（`core/src/lib.rs:670`）里加 `if wubi { wubi_candidates }` 特判。这样做有几个问题。

- **引擎只能返回候选列表，表达不了「上屏」。** 四码唯一自动上屏、第五码顶字、空码清空都是按键流程上的决定。现在这些决定都在 `Session` 里，fcitx5 和 macOS 两个外壳共用。
- **绕开了引擎里的后处理。**
  - 简繁转换（`apply_traditional`）在拼音路径里调，#194 的五笔候选不转繁体（读 diff 得出，没有实际跑）。
  - 候选的 `pinyin` 是空的，会话的学习（`learn` → `record_selection`）照样记进**拼音**的选词历史。
- **会话里按原始字母触发的功能会误触发。** 比如 `v`+空格开工具栏、`v` 开头的计算器、`rq`/`sj` 日期时间。只有会话能按方案关掉它们。

建议的分工：

- **数据**：`core/src/wubi.rs` 的 `WubiDict` 可以沿用 #194，按码查、按前缀查。再加一个反查表 `字/词 → 码`，由同一份 `wubi86.tsv` 构建，取每个字最长的码当全码。
- **引擎**：
  - 持有 `Arc<WubiDict>`，提供 `wubi_lookup(code) -> Vec<WubiCand>`（带码和剩余码）和 `wubi_code_of(word)`。
  - 查出来的结果统一走 `apply_traditional`。
  - 不改 `try_input_at` 的拼音路径。
- **会话**：
  - 按 `InputScheme` 分流：五笔时 `compute_candidates`（`session.rs:2147`）调 `wubi_lookup`。
  - 按键规则写在 `handle_key` / `composing_key` / `symbol_key` 里（第 3 节）。
- **用户五笔词**：单独一个文件（如 `~/.local/share/wowtype/wubi_user.tsv`），格式同 `wubi86.tsv`，不进拼音的 `lexicon`。

## 3. 行为规则（v1）

### 3.1 码长、自动上屏、顶字、空码

| 规则 | 行为 | 挂在哪 |
|---|---|---|
| 码长 | 五笔码最多 4 码，只认 `a`–`y` | `handle_key` 字母分支（`session.rs:762`） |
| 四码唯一自动上屏（开关，默认开） | 打满 4 码、**精确匹配的候选只有 1 个**时直接上屏。<br>计数包括码表词、五笔用户词和用户的自定义编码，emoji、日期这类附加候选不算。<br>自定义编码和码表撞码时就不唯一，不自动上屏，由用户选。 | `push_input` 之后检查 |
| 第五码顶字（固定开） | **只在已有 4 码时**触发：再按字母，先上屏当前首选，再用这个字母开始新码。<br>4 码时只有精确候选，没有前缀候选。<br>码长不到 4 时字母一律接上，不顶字。接上以后没有候选就按下面的「空码」处理。 | `handle_key` 字母分支，`push_input` 之前 |
| 空码 | 当前码没有任何候选（精确和前缀都没有）：<br>- 编辑区保留并标出空码，可以退格改；<br>- 再按字母：丢掉空码，从这个字母开始新码（不上屏字母）；<br>- 空格：清空；<br>- 回车：字母原样上屏（和拼音的回车一致）。<br>不响铃，跨平台做不好。 | `composing_key` 的 `SPACE` 分支（`session.rs:1628`）。<br>现在 `commit_current` 没候选时会把字母上屏（`session.rs:1885`），五笔下要改成清空。 |
| 标点顶字 | 打码时按标点：先上屏首选，再上屏标点。空码时丢掉码，只上屏标点。 | 现成：`symbol_key`（`session.rs:1500`）先 `commit_current` 再出标点。空码那条跟上一行一起改。 |
| 首选是前缀候选时 | 码不满 4、没有精确候选、只有前缀联想时，首选是联想出来的词。例如打 `wq`，首选可能是「你」（`wqiy`）。<br>空格和标点顶字都上屏光标处的这个词，和拼音的空格一样，看到的就是上屏的。<br>第五码顶字不会遇到这种情况，因为 4 码时没有前缀候选。 | `commit_current` 不用改 |
| 数字 | 打码时按当前页选词（现成）。不打码时照常。 | 现成 |
| 大写字母 | 打码时先顶字上屏，再原样上屏大写字母。五笔不做英文候选。 | `handle_key` 字母分支 |

### 3.2 候选排序

1. **精确码优先**，按码表频次排。v1 不调频，见 3.4。
   - 一级简码：单键只有 1 个精确候选，空格就是它。g 一、f 地、d 在、s 要、a 工……共 25 个，`make-wubi.sh` 的输出已核对全对。
   - 二级简码：616 个两码各 1 个精确候选。
2. **再列前缀联想**（逐码提示）：以当前码开头的更长的码，只取码长 ≤4 的。
   - 按频次排，和精确候选去重。
   - 第一页最多占到满页。前缀多时（只打了 1 码）先按频次截断，比如最多 50 个，不要每键全排。
3. **编码提示**（开关，默认开）：前缀联想的候选后面用小字显示**剩余码**，比如打 `wq` 时「你 iy」。精确候选不显示。
   - 复用候选的注释位，和双拼显示全拼用的是同一块区域。
4. **单字优先**：不做开关。码表里同码的单字频次本来就高，用频次排就够了。「只出单字」是小众需求，不做。

### 3.3 `z` 键：临时拼音和反查

- 五笔码不用 `z`。**以 `z` 开头**进入临时拼音：`z` 后面按全拼查，用现有的拼音引擎，不受双拼设置影响。
- 候选后面显示该字/词的**五笔全码**（有简码时显示「简码/全码」，如「工 a/aaaa」）。这就是拼音反查，用来学码。词组的码查不到时，按造词规则（第 3.4 节）现算。
- 选中只上屏：不记五笔用户词，也不记拼音选词历史。Rime 的做法也是 `^z` 不进用户词典。
- 编辑区显示 `z` + 分好音节的拼音。退格删到只剩 `z` 再退格就清空。
- `z` 做万能键（`a?bc` 式模糊）留到以后。fcitx5 两种都有：`z` 开头是拼音，码中间是万能键。

### 3.4 学习：调频、造词、和拼音隔离

- **v1 不自动调频**：同码候选的顺序固定。五笔用户靠码位的肌肉记忆，主流默认都是固定。fcitx5 也固定码长 ≤2 的简码。以后要做调频，只对 3–4 码的重码做，且要有开关。
- **五笔选词不进拼音的任何学习**：会话在五笔方案下不调 `learn` / `learn_composed`（`session.rs:2424`、`2434`）。所以 `record_selection` 的选词热度和拼音的用户词库都不碰。
- **Ctrl+Delete 忘词**（`forget_current`，`session.rs:1911`）：五笔下只删五笔用户词里的条目，码表里的词不能删。
- **造词（v1.1）**：
  - 用户分几次选出来、2–4 字的词，用一次就记进 `wubi_user.tsv`。码按标准规则从字的全码算：二字 `AaAbBaBb`，三字 `AaBaCaCb`，四字及以上 `AaBaCaZa`。这和 Rime 的 `encoder.rules` 相同，也接上了现有的「分几次选出来的词」逻辑（`commit_with`，`session.rs:2395`）。
  - 用户词排在同码的码表词后面，不抢码位。

### 3.5 和现有功能的关系

| 功能 | 五笔下 |
|---|---|
| Shift 中/英 | 不变。打码时切英文，已打的码作为字母上屏，和拼音一样。 |
| 互译（「译」） | 不变。上屏走 `emit`，自动进原文。 |
| `v` 计算器 | `v` 是五笔码（一级简码「发」），**改用大写 `V`** 触发，和双拼一样（`calc_active`，`session.rs:2240`）。 |
| `v`+空格 工具栏 | 五笔下关掉（`opens_toolbar`，`session.rs:1032` 加 `!wubi`），`v`+空格要上屏「发」。工具栏走快捷键和菜单。 |
| 日期时间 | 不按原始字母触发（`rq`、`sj` 都是五笔码）。改成**首选是触发词**（日期 / 时间 / 星期……）时出写法，和双拼按首选拼音触发同理（`add_date_time`，`session.rs:2204`）；`z` 拼音里照常。 |
| emoji 推荐 | 保留，但**插在精确码候选之后**，不打乱重码的码位，也不算进「唯一」（现在 `add_emoji_suggestion` 插在第 `EMOJI_SLOT`=2 个之后，`session.rs:2486`）。 |
| 符号、标点 | 不变（`symbols`）。标点顶字见 3.1。 |
| 以词定字 `[ ]` | 不变（`pick_char`，`session.rs:1952`），对多字候选取首字/末字；取出来的字不学。 |
| 繁体输出 | 五笔候选同样走 `apply_traditional`（简入繁出）。#194 漏了这一步。 |
| 自定义编码（`mail`、`wdyx`） | 放最前，用户定义的优先于码表。<br>`prepend_custom_codes` 在 `try_input_at` 里（`lib.rs:676`），五笔路径不经过那里，要**显式调用**。<br>它算不算进「四码唯一」见 3.1。 |
| 英文候选、模糊音、纠错、双拼 | 五笔下不生效，设置里也藏起来。 |
| 语音 | 无关，不变。 |
| 选词键 `;` `'`、翻页键 | 不变。翻页键选了 `, .` 时，打码中的 `, .` 是翻页，不是标点顶字。这和拼音一致。 |

## 4. 设置

现在是 `Shuangpin=True/False` + `ShuangpinScheme`。建议改成：

```
InputScheme=Quanpin | Shuangpin | Wubi86
ShuangpinScheme=Ziranma          # 只在 Shuangpin 时显示
WubiAutoCommit=True              # 四码唯一自动上屏
WubiHint=True                    # 编码提示
```

- 设置界面是**一个单选「输入方案」**。选了双拼才出方案下拉；选了五笔才出两个开关。微信输入法的设置存储也是一个 `InputScheme` 键，五笔另有自己的一组配置；界面上是不是单选是推断。
- 只留这两个开关的理由：
  - **四码唯一自动上屏**：习惯分两派。打词组的人会被误上屏打断，主流都给开关。默认开。
  - **编码提示**：学码期很需要，熟手嫌乱。主流都给开关。默认开。
- 不做成开关的：
  - 第五码顶字：不混输时没有别的含义，固定开。
  - 空码处理：一种合理行为就够了。
  - 调频：v1 不做。
  - 单字优先：频次已经覆盖。
  - 五笔版本：v1 只有 86，有了 98 再出下拉。
- v1.1 的「拼音混输」是第 3 个开关，默认关。开了以后第五码顶字要让位：第 5 个字母可能是拼音的一部分，两者有歧义。
- 兼容旧配置：没有 `InputScheme` 时，`Shuangpin=True` 当作 `Shuangpin`，否则当作 `Quanpin`。
  - 写回时两个键都写，旧版本读得懂。
  - 涉及 `settings/wowtype-config`、`macos/Sources/Shared/Config.swift`、`fcitx5-addon` 的 `Shuangpin` 选项，以及 `docs/CONFIG.md`。
  - #194 加的 `Wubi` 开关改成 `InputScheme=Wubi86`。

## 5. 优先级

**v1 必做**
1. `wubi86.tsv` 进所有安装包（见第 6 节）。缺文件时，设置里的「五笔」选项置灰并说明原因。
2. 会话层五笔：精确 + 前缀候选、四码唯一自动上屏（开关）、第五码顶字、空码处理、标点顶字、大写字母。
3. `z` 临时拼音 + 五笔码提示（反查）。
4. 编码提示（开关）。
5. 五笔选词不进拼音学习；繁体输出；计算器 / 工具栏 / 日期时间 / emoji 的冲突处理（3.5）。
6. 「输入方案」单选与旧配置兼容。
7. 测试：一级简码 25 个、`ggll`→一、`wqvb`→你好、四码唯一上屏、顶字、空码、标点顶字、`z` 反查、繁体，fcitx5 和 macOS 的按键用例各一套。

**nice-to-have（v1.1 起）**
- 造词：分次选出的 2–4 字词按规则编码，记进 `wubi_user.tsv`。
- 拼音混输开关：五笔精确码在前，拼音候选在后并带五笔码；只在码 >4 或五笔无候选时让拼音排前；开了就不再第五码顶字（理由见第 1 节）。
- `z` 万能键；3–4 码重码调频（有开关）。
- 98 版：候选来源是 fcitx5-table-extra 的 `wubi98.txt`，但许可说法不一：
  - README 说代码是 GPLv3 或更高，又笼统写了一句「数据文件都已是公有领域」；
  - metainfo 写的是 GPL-2.0+。

  98 表是 2021 年以后别人提交的，那句话是否覆盖它要再确认。这个表也没有频次，要用 WowType 词库的词频补。所以没在 #193 里做。

**明确不做**
- 解微信输入法的五笔词典（`swbd*.bin`）或用其中任何数据。
- 新世纪版：没有来源清楚的公开码表。
- 增广字集：码表里约 4.3 万个零权重的扩展区字已去掉，和 Rime 默认一致。
- 五笔下的整句输入、云候选、AI 候选。

## 6. 打包：`wubi86.tsv` 要到达每条分发路径

现状：每条路径都用**显式文件清单**，没有一处收整个 `dist/data/*`。所以多一个文件不会出错，但也到不了用户手里。以下行号以当前 `pre-release` 为准。

| 路径 | 要改的 |
|---|---|
| CI data job（`.github/workflows/ci.yml:158`） | `make-data.sh` 之后加 `scripts/make-wubi.sh "" dist/data`。<br>artifact 上传的是整个 `dist/data`（:169-173），下游 job 自动拿到。 |
| 版本号（`scripts/make-data.sh:83` `REV`） | 加了文件要把 `REV` 加 1，否则 `VERSION` 不变。<br>`nix-data-pr.sh:23-26` 看版本号相同就不更新 Nix。 |
| deb（`scripts/package-deb.sh`） | - `check_data` 必需文件（:71）加 `wubi86.tsv WUBI-LICENSE WUBI-SOURCE.txt WUBI-AUTHORS`<br>- 装到 `/usr/share/wowtype` 的循环（:101）加 `wubi86.tsv`<br>- doc 目录加 `WUBI-SOURCE.txt`、`WUBI-AUTHORS`（:106 附近）<br>- `data_copyright()`（:53-67）加一段 `Files: usr/share/wowtype/wubi86.tsv`、`License: LGPL-3.0`，正文缩进贴 `WUBI-LICENSE`<br>- 数据 tarball（:158-160，已按 #203 做成可复现的 tar）的清单加这几个文件<br>- #194 已经在这里加过可选的 wubi，以这次为准合并 |
| rpm（`scripts/package-rpm.sh`） | - 检查（:21）和拷贝（:37）加 `wubi86.tsv WUBI-LICENSE WUBI-SOURCE.txt WUBI-AUTHORS`<br>- `%install`（:127）加 `wubi86.tsv`<br>- `WUBI-LICENSE` 装成 `LICENSE.rime-wubi`，加进 `%license`（:137、:142）<br>- `WUBI-SOURCE.txt`、`WUBI-AUTHORS` 进 doc 目录<br>- COPYRIGHT（:56-64）加一段<br>- `License:`（:81）加 `AND LGPL-3.0-only` |
| Arch（`scripts/package-arch.sh`） | - 检查（:19）、拷贝（:32）加 `wubi86.tsv` 和三个 `WUBI-*` 文件<br>- `install`（:86）加 `wubi86.tsv`<br>- `WUBI-LICENSE` 装成 `/usr/share/licenses/wowtype/LICENSE.rime-wubi`（:92 附近）<br>- `WUBI-SOURCE.txt`、`WUBI-AUTHORS` 进 doc 目录<br>- `license=`（:48）加 `'LGPL-3.0-only'` |
| openSUSE 源码安装（`ci.yml:467`） | 显式的 `install -m644` 清单加 `wubi86.tsv` |
| Nix（`nix/package.nix`） | - `postInstall`（:104）加 `data/wubi86.tsv`，许可证装成 `LICENSE.rime-wubi`（:108 附近），`WUBI-SOURCE.txt`、`WUBI-AUTHORS` 装进 doc 目录<br>- `meta.license`（:130-136）加 `lgpl3Only`<br>- tarball 内容变了，hash 会变：靠上面的 `REV` 让 `nix-data-pr.sh` 发版后自动改 `dataVersion`、URL、hash |
| macOS（`macos/build.sh`） | - 拷贝（:69-75）加 `wubi86.tsv`，另外三个改名放进去：`WUBI-LICENSE`→`DATA-WUBI-LICENSE`、`WUBI-SOURCE.txt`→`DATA-WUBI-SOURCE.txt`、`WUBI-AUTHORS`→`DATA-WUBI-AUTHORS`<br>- **必须**同时把这四个名字加进资源白名单正则（:78），否则构建失败<br>- `main.swift:29` 的自检清单加 `wubi86.tsv`<br>- `AppState.resource()` 通用查找，不用改 |
| fcitx5 插件 | `findDataFile("WOWTYPE_WUBI", "wubi86.tsv")`（`wowtype_engine.cpp:84-98`）能找到 `/usr/share/wowtype` 下的文件，CMake 不用改 |
| `install.sh` | 数据都在各发行版的包里，不用改 |
| 发布说明（`ci.yml:558`）、`README.md` 许可证一节 | 加一行：五笔码表来自 rime-wubi，LGPL-3.0 |
| 不能改的 | 万象可选词库包的四文件白名单（`LexiconPack.swift:16`、`spec/lexicon-pack.json`）。五笔是基础数据，不进那个包。 |

许可证：LGPL-3.0 的码表和 GPL-3.0 的词库、MIT/Apache 的代码放在一起分发没有问题。条件是：
- 随包带 LGPL 全文（`WUBI-LICENSE`）和 GPL-3.0 全文，LGPL-3.0 是 GPL-3.0 的附加许可；
- 带上作者署名（`WUBI-AUTHORS`）；
- 说明来源和钉死的提交、怎么重新生成（`WUBI-SOURCE.txt`，`make-wubi.sh` 写的）。

码表文件本身就是「源码」形式（文本），用户可以替换。
