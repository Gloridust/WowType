# 修改方案：排序打磨 + 双端架构整理（2026-11-13）

给接手实现的人看。行号都是 `origin/main`（cbd0734）上的；动手前先 `git fetch` 再核对一遍。
每一项都写了：现象、根因（已用真实词库 + `words.lm` 验证过的会标「已验证」）、怎么改、怎么验收。
实验补丁在 `docs/plans/experiments/`，都是能跑通的草稿，**不要原样合**（里面有环境变量开关和调试输出），照着重写成正式改动。

## 0. 总览和顺序

| 阶段 | 内容 | PR 数 | 依赖 |
|---|---|---|---|
| R0 | 先发一版 main（不改代码） | 0 | — |
| R1 | 排序：单字、上文、补全混入（核心） | 2 | #137 |
| R2 | 排序：怪候选、换位纠错、模糊音兜底（核心） | 3 | R1 |
| R3 | 词库和热词数据 | 1–2 | — |
| R4 | 语言模型重建（治本，需要语料） | 1 | R1 评测集 |
| A1 | 数据安全：user.tsv 原子写、存盘计数 | 1 | — |
| A2 | macOS PR 收拢成一条线 | 合并操作 | — |
| A3 | 把外壳里的行为挪进会话（分 4 步） | 4 | A2 |
| A4 | 测试收拢、清过渡函数 | 2 | A3 |

R 线（排序）和 A 线（架构）互不依赖，可以并行。R 线只动 `core/` 和 `data/`，两个平台自动受益。

所有 PR 的通用要求：
- 提交信息和 PR 用中文，照仓库现有写法；不加署名行。
- 核心改动必须跑：`cargo test -p wowtype-core --no-default-features --locked`、`macos/test.sh`、`scripts/abi-smoke.sh`。
- 排序改动必须贴评测前后对比（见 §1 评测）。

---

## 1. 评测（R 线每个 PR 都要用，先做）

现有工具：`core/src/bin/eval.rs`（`wowtype-eval`）、`tools/make_eval.py`、`tools/make_sentence_eval.py`、`tools/eval/daily_sentences.txt`。
问题：评测集**没有上文一列**，所以上文排序的问题从来没被测到。

**PR R1-0（可并进 R1-a）：评测加上文**
1. `core/src/bin/eval.rs`：用例格式加可选第三列「上文」（`输入<TAB>期望<TAB>上文`），有就 `engine.set_context`。
2. 新增 `tools/make_context_eval.py`：把 `daily_sentences.txt` 每句分词，逐词生成「拼音、词、前面的文字」。实验版见 `experiments/ctxeval.py`（用了 jieba；正式版改用词库做最大匹配，免得多一个依赖）。产物提交到 `tools/eval/context.tsv`（533 条左右）。
3. 新增 `tools/eval/regress.tsv`：把本文列出的失败用例和「现在是对的、不许退步」的用例都放进去（见各节的验收）。CI 里加一步跑它，top-1 必须 100%。

基线（origin/main，真实词库）：

| 集合 | top-1 |
|---|---|
| 常用词 top | 93.2% |
| 中低频 mid | 82.5% |
| 简拼 jp | 49.3% |
| 截断 trunc | 65.7% |
| 日常整句 daily | 84.8% |
| **带上文逐词 context** | **69.8%** |

生成方法：`tools/make_eval.py lexicon.tsv --count 500`（另有 `--skip 30000 --top 300000`、`--jianpin`、`--truncate 1`），`tools/make_sentence_eval.py --text tools/eval/daily_sentences.txt`（要 pypinyin）。

---

## 2. R1：单字、上文、补全混入

### R1-a 合 #137，并修它的副作用
- 现象：无上文时 `le`→乐、`he`→何、`bei`→备、`ma`→马、`hui`→回。
- 根因（已验证）：单字路径也加了句首 `<s>` 的 LM 分（`core/src/lib.rs:1302`）。例：(`<s>`,何) +0.50，(`<s>`,和) −1.88。
- #137 的做法：单词单音节路径去掉 `path.lm_score`。实测上面几条全部修好（`ba`→把、吧）。
- **要改的地方**：`path.lm_score` 里还含用户学到的搭配加成（`core/src/learn.rs:119`），一起减掉会让「学过的单字」不再靠前。改成只减基础模型的 `<s>` 分：在 `LearnedLm` 上加一个只返回基础分的方法（或在 `BeamPath` 里把 base 和 learned 分开记），`make_candidate` 里只减 base。
- 加测试：学过「乐」之后 `le` 第一是「乐」；没学过时第一是「了」。
- 验收：`le/he/bei/li/ma/hui` 首选 = 了/和/被/里/吗/会；daily 不低于 84.8%。

### R1-b 上文排序（最重要）
- 现象：上一个上屏的是单字时，下一个词排错。稳定复现的：我+`zhidao`→直到；我+`yao/hui/he`→腰/悔/喝；你好+`le/ma`→勒/忙。
  （注意：你+`juede`、不+`xihuan` 在 main 上首选其实是对的，靠的是 `protect_exact_input` 兜底，原始分数仍是错的那个高。）
- 根因（已验证，四条）：
  1. **建库分词的洞**：`core/src/bin/lmbuild.rs:112-148` 按词库做最大概率分词，词库里有「我要、我会、我是、我的、我觉得、不知道、好吗」，一个整词总是赢过两个词，所以 (我,要) 这类搭配**从没被计数**。
     实测：(我,要)(我,会)(我,知道)(我,觉得) = −2.452（没见过的回退分）；而 (我,腰) +1.489、(我,悔) +1.926、(你好,忙) +4.465。
  2. **权重**：`context_bigram_score` 权重 2.0（`core/src/rank.rs:137`），字频只有 1.0。我+要 vs 我+腰：上文项差 7.9，字频只领先 3.5。
  3. **上文怎么取 prev**（`core/src/lib.rs:1401-1407`）：只试「整个上文串」和「最后一个字」。整串不在模型里时返回 0（`wordlm.rs:112`），反而把负分夹成 0，所以「今天我」碰巧正常。
  4. 有上文时仍加了 `<s>` 分（`core/src/learn.rs:117`）。
- 改法（实验见 `experiments/ranking-a-context-completion.diff`）：
  1. `LanguageModel` trait 加 `fn knows_word(&self, w: &str) -> bool`（`WordLm` 用 `ids.contains_key`，其它实现默认 false）。
  2. `make_feature`（`lib.rs:1382-1410`）里取 prev：上文末尾 1–4 个字的每个后缀，只要模型认识就算一个 prev，取各自分数的最大值。不再因为整串不认识而得 0。
  3. **合词保底**：如果「后缀 + 候选」本身是模型词表里的词（我+要 = 我要），分数不低于 `MERGED_BONUS`。实验扫过：0.5→80.9%，1.0→83.3%，1.5/2.0→84.8%，3.0→85.9%。**取 1.5**，定成 `rank.rs` 里的常量并写明来源。
  4. `LearnedLm::score`：有上文词时用上文词，不再固定 `None`（即不再多加一次 `<s>`）。这一条实验里没做，做完要重新跑评测，退步就先不改。
- 验收：
  - context top-1 ≥ 83%（基线 69.8%），daily 不低于 84.8%。
  - 回归用例：我+`zhidao/yao/hui/he`→知道/要/会/和；你好+`le/ma`→了/吗；不+`zhidao`→知道；我们+`xiang/hui/shi/zai/yao`→想/会/是/在/要；吃饭+`le/ma`→了/吗。

### R1-c 补全和纠错不再混进精确读音前排
- 现象：`xian` 第 2 是「想」，`ji` 第 2 是「就」，`zhe` 第 2 是「真」，`ni` 第 2 是「年」。
- 根因（已验证）：`run_query` 总是带 `completion: true`（`lib.rs:1167`）；`build_completion_edges`（`core/src/graph.rs:269`）在末尾已经是完整音节时也加 xian→xiang。补全每个字母只罚 1.2（`beam.rs:68`）+0.2（`rank.rs:154`）；`protect_exact_input` 只保第一位（`lib.rs:1493`）。
- 改法：`query_once` 截断前（`lib.rs:1261`）做一次稳定分区：只要存在「精确、单词、单音节」的候选，补全/纠错出来的候选一律排到所有精确候选后面。
- 再加一条（实验没做）：输入是**一个合法音节**时不出纠错候选（`neng` 的「嫩个、哼、梦」，`gei` 的「备、黑」）。在 `build_typo_edges` 入口判断，或在上面的分区后直接丢掉 `typo_count>0` 的。
- 「西安」在 `xian` 里排第 14：给「整个输入能切成两个音节且是词库整词」的候选一个固定名次（比如第 5 位），做法参照现有 `protect_exact_input`。频次 55k 靠分数上不来。
- 验收：`xian`→先 现 显 线…（前 9 无想/像/相），西安在前 5；`ji/zhe/de/ni` 前 5 全是本音节的字；`neng` 第 2 不是「嫩个」。

---

## 3. R2：怪候选、换位纠错、模糊音

实验补丁：`experiments/ranking-b-junk-fuzzy-typo.diff`（开关 `WT_X=ABCD`、`WT_SWAP`、`WT_OOV`、`WT_FUZZY_PEN`）。

### R2-a 去掉硬拼的怪候选
- 现象：`nihao`→你好、泥好；`diannao`→电脑、点脑；`pingan`→平安、凭按；`iphone`→iPhone、屁好呢；`hello`→hello、合理了哦。
- 根因（已验证）：
  - `compose_candidates`（`lib.rs:1856`）把所有「用完整个输入」的候选排在句首词前面，`sentence_cap`（`lib.rs:1790`）保证至少留 1 条句子，**不看分差**：你好 −6.58 vs 泥+好 −15.48。
  - `differs_only_at_tail` 会丢掉更好的那条句子、留下更差的（`pingan` 丢了「平岸」留「凭按」）。
  - 英文：`append_raw_candidate`（`lib.rs:1033`）只把英文词插到第 0 位，后面 2 处纠错或夹简拼硬解出来的中文照留。
- 改法：
  1. 第一候选是「精确整词」且比最好的句子领先 > `JUNK_MARGIN`（实验用 3.0）时，丢掉这条句子，位置让给句首词/其它整词。
  2. 修 `differs_only_at_tail`：两条只差尾巴时留分数高的。
  3. 英文词排第一时：丢掉 `typo_count ≥ 2` 的和「中间夹简拼」的中文候选；丢完没东西就不再补句首词。
  4. 第一候选是「纠错得到的整词」时同样适用第 1 条（`zhognguo` 现在还会出「钟国」）。
- 验收：`nihao`→你好、你、尼…；`fangan`→方案、反感、返港；`iphone/hello/deepseek/github/python` 只出英文（加可能的精确中文词，如 `app` 的阿婆不算精确，要去掉）；整句用例不受影响（daily 不退步）。

### R2-b 换位纠错优先、纠错词能露出来
- 现象：`meiyuo`→美国在没有前；`tianqu` 出不来天气。
- 根因（已验证）：所有纠错边一个价（6.0，`beam.rs:67`，加排序器共 8.5）；`tianqu` 的「天气」其实找到了（−15.92），被 `compose_candidates` 的 `exact_first`（约 `lib.rs:1890`）挪到所有句首词后面。
- 改法：
  1. `Edge` 加 `swap` 标记（`graph.rs` 的 `build_typo_edges:339`、`add_edge:245`），相邻两键换位少罚 1.5。
  2. 第一候选是「全由单字拼成的句子」，且有一个只纠 1 处的整词分数差在 6.5 以内：把它插到第 2 位。不额外搜索。
- 验收：`meiyuo`→没有；`tianqu`→天去、天气；`nihoa/zhognguo/wiexin/jitnian` 不变。

### R2-c 模糊音
- **关着时的兜底**（默认 `Fuzzy=False`）：`yingai/shengme/zidao/penyou` 现在只有「因该/声梦/自到/喷油」。
  - 改法：`run_query`（`lib.rs:1155`）在精确 `query_once` 之后，如果第一候选是多词句或是补全/纠错得到的，且输入是 2–4 个音节：对每种精确切分做一次 `lookup_fuzzy`，把分数 ≥ 第一候选 + 2.0 的**整词**加进来（排第一）。
  - 成本：只是哈希查找，基准没有可测的变化。模糊索引第一次用要建 140–400 ms，**必须在载入词库时预建**（后台线程），不能等到第一次按键。
  - 注意：词库里有 `应该 yin gai 1` 这种条目，精确命中但频次更低的不能挡住模糊结果。
  - 有 3 个单元测试断言「模糊音关着就没有模糊命中」，要改成新的语义。
  - 加一个设置项 `FuzzyFallback`（默认 True）。设置项要按 `spec/config.json` 的规矩三端一起加（见 A 线）。
- **开着时精确读音被压**：`chenshi`→尘世在城市前，`cifan`→此番在吃饭前。
  - 根因：`FuzzyLexicon::with_fuzzy`（`lexicon.rs:716`）按 `fuzzy_penalty=2.5` 把模糊读音的频次除以 12.2，城市 50 万除完还比尘世高一点，再被句首 LM 分反超。这是 #115 有意的设计（模糊和精确一起排）。
  - 罚分降到 1.5 能修这两条，但模糊音评测整体退步（mid 80.5→79.2，daily 84.1→82.6）。**不改罚分**。R1-a/R1-b 去掉单路径的句首分后重测这两条，多半已经好了；没好再单独处理。
- `laoshi`→老实在老师前、`qinchu` 的「青春」：不是模糊音的问题，前者是词频（§4），后者是补全（R1-c 的分区规则扩展到多音节：有精确整词时补全整词排后面）。

---

## 4. R3：词库数据

根因（已验证）：
- **频次饱和**：rime-ice 里有 2087 个词挤在 [500000, 510000)（现在 503182、行政 500367、我想 500589、我校 500260），它们之间只能靠句首 LM 分决胜负，所以 `xz`→行政、`nh`→您好。
- **热词一刀切 30000**（`tools/add_hotwords.py --freq`，`data/hotwords.tsv` 351 行）：朋友圈 30000 vs 番禺区 21650。
- **词表外的词吃重罚**：不在 `words.lm` 词表里的词拿句首回退分 −4.207（`wordlm.rs:121`），30000 的热词实际效果相当于频次 450。影响：永远的神、黑神话、哈基米、班味、大模型、智能体、提示词。
- 错条目：`去次 qu ci 50000`（聊天语料里的错别字），导致 `wmyqqcf`→我们一起去次饭。

改法：
1. **词表外的词回退分设下限**（`wordlm.rs:121`）：`max(backoff, −1.5)`。实测：mid 82.5→87.8%，top-3 93.8→97.0%，daily 84.8→86.2%，jp +0.7，trunc −0.7。这条收益最大，单独一个 PR，可以排在 R1 之前。
2. `data/hotwords.tsv` 加第三列频次（没写用默认 30000），`tools/add_hotwords.py` 读它。先手工定这一批：
   - 2,000,000：现在、微信；1,000,000：你好；500,000：老师、公众号、朋友圈、小红书；300,000：为啥；100,000：再见了、没事了、等会、词条、永远的神、黑神话、哈基米、班味。
   - 新加：刘洋等常见人名不加（人名靠用户学习），但「去次」加进一个新的 `data/blocklist.tsv`，`make-data.sh` 里过滤掉。
3. 饱和频次的重估放到 R4（要语料）。在那之前只靠第 2 条的手工表。
4. `scripts/make-data.sh` 改完要确认 #128（数据包可复现）的校验值流程还成立，两个 PR 谁后合谁 rebase。

验收：`nh`→你好；`xz`→现在；`wx` 前 2 有微信；`pyq`→朋友圈；`gzh` 前 3 有公众号；`yyds`→永远的神；`weish`→为啥；`zaijianl`→再见了；`msl`→没事了；`laoshi`→老师；`heishenhua`→黑神话；`wmyqqcf` 不出「次饭」。

---

## 5. R4：重建语言模型（治本，可以晚做）

R1-b 的「合词保底」是在排序时打补丁；根子在建库。需要原始语料（LCCC + 中文维基，约 5 GB），没有语料就跳过这一节。

1. `lmbuild.rs` 的 `count_line`：一个词如果能拆成两个词库词（我觉得 = 我 + 觉得），**同时**给内部搭配计数（我→觉得），以及前一个词→第一段、最后一段→后一个词。
2. 低频搭配的 PMI 按次数收缩（比如 `pmi × c/(c+k)`，k≈5），解决「灯+会+再联系」这类靠几次偶然搭配拿到 +4 的问题（`等会再联系你`→灯会）。
3. 顺便导出语料里的词频，用来重估 §4 里饱和在 50 万的那 2087 个词。
4. 做完后把 R1-b 的 `MERGED_BONUS` 降到 0 重测；新模型下不需要就删掉。
5. `words.lm` 是发版时下载的数据包，换模型要升数据版本号，并在 `docs/DATA.md` 写明。

验收：context ≥ 88%，daily ≥ 88%，其它集合不退步。

---

## 6. A1：数据安全（小，建议最先做）

1. **`user.tsv` 原子写**：`core/src/lexicon.rs:858` 的 `save_tsv` 现在是直接 `fs::write`。改成和 `history.tsv`（`core/src/learn.rs:167-169`）一样：写 `<path>.<pid>.tmp` → `fsync` → `rename`。两处的临时文件名都带上 pid（现在 history 的临时名是固定的，两个进程同时存会互相踩）。
2. **macOS 存盘计数**（`macos/Sources/App/AppState.swift` 的 `save`/`didCommit`）：现在存之前就清零，存失败那批不会重试；而且每次上屏（含标点）都计数。改成：只在会话报告「学到了词」时计数，存成功才清零。和 Linux（`wowtype_engine.cpp:1076-1127`）一致。
3. 测试：核心加一个「保存中途文件已存在旧内容，保存失败时旧文件不变」的测试；`macos/Tests` 加存盘计数用例。

---

## 7. A2：把 macOS 的 PR 收成一条线

现状：#138（工具栏/表情）、#139（互译）、#140（设置窗口）、#142（pkg/模板图标）互相冲突（#138+#139 有 7 个文件冲突）。本地分支 `test/macos-all`（未推送，在 `.claude/worktrees/trusting-swartz-8358e2`）已经把四个合在一起、解决了冲突，并且多做了：
- `spec/config.json`、`spec/lexicon-pack.json`：设置项的唯一来源，插件、GTK 设置、macOS 三端用 `scripts/test-config-contract.py` 对照（契约 556 项）。
- 三端读 `wowtype.conf` 的规矩统一、`TranslateLocal` 默认值统一、两端设置文案统一、macOS 本地翻译一键下载、万象词库。

做法：
1. 把 `test/macos-all` 推上去，开一个 PR 取代 #138/#139/#140/#142（在这四个 PR 里留言说明后关闭）。PR 太大就按「设置契约 spec/ + 三端测试」「macOS 功能」拆成两个，契约那个先合。
2. 合之前在 Linux 上跑一遍完整 CI（插件的 C++ 改动本机只在 Docker 里编过）。
3. 这一步**不要求**先把逻辑挪进核心：功能先落地，重复代码在 A3 里还。理由：`test/macos-all` 已经测过、冲突已解，推倒重做成本更高；A3 每一步都会同时删 C++ 和 Swift 两边的代码。

---

## 8. A3：把外壳里的行为挪进会话

目标是 `docs/PORTING.md` 第 26–40 行那张表：外壳只做「平台按键 → 键码」「画编辑区和候选框」「上屏」「读周围文字」「排定时器」。现在会话（`core/src/session.rs`，1465 行）里没有标点、中/英/译、互译、工具栏、表情面板、自动空格的任何代码，这些在 C++（`wowtype_engine.cpp` 2976 行）和 Swift（合并后约 1600 行）各有一份，而且已经不一致。

每一步的做法都一样：**先在核心写好并用 `core/tests/session_keys.rs` 测，再让两个外壳切过去并删掉自己的那份，同一个 PR 里完成**。ABI 按 `docs/ABI.md` 的规矩升次版本，结构体只在末尾加字段。

**A3-1 标点 + 自动空格 + 上文**
- `WowtypeKey` 加 `prev_char`（光标前一个字符）和 `field_flags`（密码/网址/邮箱输入框）。
- 会话处理没在打字时的标点（全角/半角、数字后保持英文、引号配对）。引号左右状态从线程全局量（`core/src/symbols.rs:135`）搬进会话。
- `wowtype_punct` 返回空时的规矩定成 Linux 的：把键交还应用（frame `handled=0`）。macOS 现在是自己上屏并吃掉键（`Composer.swift:357-363`），要改。
- 自动空格进会话，统一跳过密码/网址/邮箱框（macOS 现在不跳）。
- 排序上文：会话自己维护，统一成「最近 20 个字符、每个会话一份」；Linux 现在是 24 字节、全进程共用（`wowtype_engine.cpp:56,1098`）。
- frame 加 `learned`（这次上屏学到了词），外壳据此决定存盘（配合 A1-2）。

**A3-2 中/英/译三态和单按 Shift**
- 会话持有模式；外壳只报「Shift 按下」「Shift 松开」「中间有没有别的键」。0.5 秒阈值进会话配置。
- 模式的作用域定一个：**每个会话一份**（macOS 现状），Linux 的全局 `asciiMode_`（`wowtype_engine.h:455`）改掉；要保留「全局切换」的话做成设置项。
- `org.wowtype.Input` 的 D-Bus 切换（#118）改成调会话的 `set_mode`。

**A3-3 互译**
- 攒原文、去抖、流式译文、回车上屏都进会话。加 `wowtype_session_tick(now_ms)`，frame 加 `aux`（候选框上方的提示）和 `next_tick_ms`（多少毫秒后再叫我）。外壳只排定时器。
- 删掉 C++ 的 `handleTranslateKey/fillTranslateView`（`wowtype_engine.cpp:2738-2975`）和 Swift 的 `Translator.swift` + Composer 里约 385 行。

**A3-4 工具栏、表情面板、剪贴板历史**
- 面板的状态和光标移动进会话；frame 的 `panel` 字段已有，补上面板种类。
- 「互译模式下不开工具栏」（`wowtype_engine.cpp:2119`）这类跨功能规则只在会话里写一次。
- 剪贴板历史从进程全局 `Mutex`（`core/src/clipboard.rs:13`）改为引擎持有。
- 删掉 Swift 的 `Toolbar.swift`（约 480 行）和 C++ 对应部分。

每步验收：两个外壳的按键测试全过；该步对应的 C++ 和 Swift 行为代码被删除（PR 的净行数应为负）；`docs/PORTING.md` 的进度段更新。

---

## 9. A4：收尾

1. **测试收拢**：行为用例只留在 `core/tests/session_keys.rs`。`fcitx5-addon/test/key_harness.cpp`（2217 行）和 `macos/Tests/main.swift` 只保留键码翻译、存盘节奏、画面相关的。A3 每步挪完就把对应用例迁走，不要留到最后一起做。
2. **macOS App 层测试**：`Sources/App` 现在只有 `--selftest`。加：`flagsChanged` 的 Shift 判定（对应 Linux 的 #82 回归）、`CandidateLayout` 的尺寸计算（纯函数，好测）、配置文件变更检测。
3. **清过渡函数**：frame 末尾加 `composing`、`commit_kind`、`commit_emoji`、已选文本后，删掉 `wowtype_session_input/_set_context/_selected_text/_remaining/_last_choice`（`wowtype_core.h:423-459` 标了「过渡」的那组），`docs/ABI.md:51` 的白名单成为事实。
4. **引擎生命周期**：`session_ffi.rs:366` 把引擎指针当 `&'static`。改成会话持有引用计数的句柄，或 `wowtype_engine_free` 时让会话失效。Linux 换词库（`wowtype_engine.cpp:776-788`）现在没有先 `set_engine(NULL)`；macOS 换词库后没激活的 Composer 还在往旧引擎里学，那部分学习会丢。
5. **音节表和自定义词规则三份**（`core/src/syllable.rs`、`settings/wowtype-config:261,435,466`、`CustomWords.swift:155`）：核心导出「校验/规范化编码」「猜拼音」两个 C 函数，Swift 直接调；Python 设置通过一个小命令行（`wowtype-check`，已有 `core/src/bin/check.rs`）调。
6. macOS 启动时比对核心 ABI 版本（`macos/Sources/App/main.swift:22` 现在只打印）。

**进度（feat/a4-cleanup）**
- 3：删掉了 `_append`、`_set_context`、`_last_choice`。`_input`、`_remaining`、`_selected_text` 两个外壳画编辑区还在用（8 处），frame 里补齐这些字段之前先留着。
- 4：Linux 换词库、换翻译器、关输入法时先让所有会话放开再释放。macOS 的 Composer 拿着 `Engine` 的强引用，旧引擎要等所有输入框都换过去才释放，不会悬空；这期间没激活的输入框学到的词记在旧引擎里，会丢，没改。
- 5：编码整理（`wowtype_custom_code`）和猜拼音（`wowtype_guess_pinyin`）进了核心，macOS 设置直接调，删掉了 Swift 自己的音节表、切分和查词库。Python 设置不链接核心，还是自己一份，但音节表补齐了 biang、cei、nia，核心的测试（`settings_syllable_table_matches`）会比对两份表；改成调 `wowtype-check` 留到以后。
- 6：做了，主版本不一致时启动就退出。
- 1、2 没做：会话的行为用例都写进了 `core/tests/session_keys.rs`；两个外壳的按键测试留着当集成测试（真键码 → 会话 → 上屏），不删。App 层测试要 AppKit，CI 的 docker swift 编不了，留到以后。

---

## 10. 建议的 PR 清单（按合并顺序）

| # | 标题 | 线 | 大小 |
|---|---|---|---|
| 1 | 用户词库原子写入，macOS 存成功才清计数 | A1 | 小 |
| 2 | 语言模型不认识的词不再重罚（回退分下限） | R3-1 | 小 |
| 3 | 评测加上文一列，加回归用例集 | R1-0 | 小 |
| 4 | #137 修订：只减基础模型的句首分 | R1-a | 小 |
| 5 | 上文排序：多后缀取 prev、合词保底 | R1-b | 中 |
| 6 | 精确读音排在补全和纠错前面；单音节不出纠错 | R1-c | 中 |
| 7 | 去掉硬拼的怪候选，英文词后不出硬解的中文 | R2-a | 中 |
| 8 | 换位纠错少罚；纠错整词能排到第 2 | R2-b | 小 |
| 9 | 模糊音关着时的兜底候选 | R2-c | 中 |
| 10 | 热词表加频次列，修一批常用词频次，屏蔽错条目 | R3-2 | 小 |
| 11 | test/macos-all 推上去取代 #138/#139/#140/#142 | A2 | 大（已完成，只需 CI） |
| 12–15 | 会话接管：标点和自动空格 → 模式和 Shift → 互译 → 面板 | A3 | 各为中到大 |
| 16 | 清过渡函数、引擎生命周期、测试收拢 | A4 | 中 |
| 17 | 重建语言模型（要语料） | R4 | 大 |

第 1–10 条互相独立性高，可以一条一条做；每条做完跑 §1 的评测并把数字贴在 PR 里。
