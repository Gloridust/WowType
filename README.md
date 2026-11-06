# Wowtype

把微信输入法（WeType）的输入体验搬到 Linux：拼音 + 语音，跑在 fcitx5 上。

> 状态：**文字输入可用，语音待实机验证。**
> 131 项测试全绿；用真实词库（rime-ice 55 万条）测到完整输入 top1 99.2%、半成品 top1 89.7%。
> 语音的可测部分（VAD/WAV/识别器调用/上屏）也都有测试，但 X11 热键和采集
> 没在 Linux 上实机跑过。
>
> **接手先看 [docs/HANDOFF.md](docs/HANDOFF.md)**（从哪开始、哪里可能炸）；安装步骤见 [docs/INSTALL.md](docs/INSTALL.md)；目标完成度见 [docs/STATUS.md](docs/STATUS.md)。

## 目录

| 路径 | 内容 |
|---|---|
| `core/` | 拼音引擎：音节切分、音节图、束搜索、打分、排序、C ABI |
| `voice/` | 语音核心：热键状态机、重采样、VAD、ASR 抽象、边说边上屏 |
| `voice-daemon/` | 常驻进程：全局热键 + 采集 + 上屏（Linux） |
| `fcitx5-addon/` | fcitx5 输入法插件（C++，调 Rust 的 C ABI） |
| `tools/oracle/` | 让官方 WeType 引擎跑起来当数据源/裁判的工具 |
| `analysis/` | 逆向分析报告与产物 |
| `docs/` | 设计文档 |

## 快速开始（Ubuntu）

完整步骤（含词库准备、故障排查、语音依赖）见 **[docs/INSTALL.md](docs/INSTALL.md)**。
最短路径：

```bash
# 1. 系统依赖
sudo apt install -y build-essential pkg-config cmake extra-cmake-modules \
  libasound2-dev libx11-dev libxkbcommon-dev \
  libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev

# 2. 测试核心算法
cargo test -p wowtype-core -p wowtype-voice

# 2.5 验证 C ABI（fcitx5 插件依赖的就是这套）
./scripts/abi-smoke.sh

# 2.6 数据自检：词库/语言模型/简繁表/用户词是否就位
cargo run -p wowtype-core --bin wowtype-check -- --lexicon lexicon.tsv --s2t core/data/s2t.tsv

# 3. 跑一下拼音 demo
cargo run -p wowtype-core --bin wowtype-demo -- xian

# 4. 构建 fcitx5 插件
cargo build --release -p wowtype-core
cmake -S fcitx5-addon -B fcitx5-addon/build -DCMAKE_BUILD_TYPE=Release
cmake --build fcitx5-addon/build
sudo cmake --install fcitx5-addon/build
```

## 架构

```
按键 ──> fcitx5 addon ──C ABI──> wowtype-core (Rust)
                                    ├─ 音节切分 / 音节图（全拼、简拼、隔音符、儿化）
                                    ├─ 束搜索（beam，可自适应）
                                    ├─ 打分：词典频次 + 二元 LM + 覆盖率
                                    ├─ 排序：LTR 特征 + 权重（可替换）
                                    └─ 候选输出

麦克风 ─> wowtype-voiced ──> wowtype-voice (Rust)
                              ├─ 16k/20ms 分帧 + VAD
                              ├─ 多渠道 ASR（本地/云端）
                              └─ 边说边上屏 / 定稿上屏
```

## 词库从哪来

WeType 自己的词库还在逆向（见下）。在那之前可以直接用开源词库跑通：

```bash
# 雾凇拼音：https://github.com/iDvel/rime-ice
# 会自动顺着 import_tables 递归合并被引用的词库（rime-ice 的条目都在被引用文件里）
python3 tools/rime2tsv.py rime_ice.dict.yaml > lexicon.tsv
cargo run -p wowtype-core --bin wowtype-demo -- --lexicon lexicon.tsv nihao
```

引擎支持**半成品输入**：尾部还没成音节时会自动补全（`nih` → 你好，`zhongg` → 中国），
不会出现"打到一半没有候选"。

支持**模糊音**（默认关闭）：`--fuzzy` 或 `WOWTYPE_FUZZY=1` 开启后，
`zidao` → 知道（zh/z）、`sangdian` → 商店（ang/an）。覆盖平翘舌与前后鼻音。

支持**自动学习**：同一个词选够 3 次（可配置）后自动收进用户词库，之后能直接打出来。
词库已有的词也会被记录，相当于记住用户偏好。

支持**符号面板**：输入 `/` 后跟拼音或中文名前缀（`/juhao` → 。，`/kuo` → （））。
ASCII 标点会自动转成中文标点（`,` → ，`?` → ？）。

支持**繁体输出**：`--traditional`（插件用 `WOWTYPE_TRADITIONAL=1`），需要简繁映射表
`--s2t core/data/s2t.tsv`。仓库里的表由 `tools/opencc2tsv.py` 从 OpenCC 数据生成（Apache-2.0），
字符级转换，暂不处理「发/髮」这类词组歧义。

英文/未登录串会把原始输入本身作为候选（保留大小写）：`hello` → `hello`，
纯拼音输入被完整覆盖时不会插入原始串。

支持**双拼**（自然码，默认关闭）：`--shuangpin` 或 `WOWTYPE_SHUANGPIN=1`。
`vsgo` → 中国，`nihk` → 你好；自然码里少量重叠码（如 `jp`）会同时展开成多种全拼再合并候选。

语言模型支持三种来源：内置一元回退、bigram TSV（`--lm`）、ARPA（`--arpa`）。
WeType 自己的 `lmcnmac.bin` 因为只存哈希、无法导出，见 [docs/DATA.md](docs/DATA.md)。

## 真实数据验证

用 rime-ice 全量词库（8105 字表 + base 词库，**552,087 条**）跑了两组评测：

| 评测 | 用例 | 结果 |
|---|---|---|
| 最高频同音词（rank=1） | 400 | **top1 100%** |
| 第 2 / 3 / 5 / 10 高频同音词 | 300 / 300 / 224 / 64 | **top10 均 100%** |
| 长输入（≤20 字母、≤7 字词） | 200 | **top1 100%** |

解读：

- rank=1 全中，说明频次打分的排序方向是对的
- 更深排名的 top10 全中，说明**束搜索和候选收集没有漏词**（不是靠调权重掩盖了召回不足）
- 束宽从 5 到 40 结果完全一致，说明这些输入上束宽不是瓶颈（默认仍取 20，留给长句）

需要说明的局限：这些用例的「期望答案」是按词频取的，所以只能验证**排序与召回的正确性**，
不能验证「人更想要哪个词」。后者需要人工标注的用例，评测工具已支持（见下）。

## 调排序

排序权重不能靠感觉调。仓库带一个离线评测工具：

```bash
# 用例格式：输入<TAB>期望（多个可接受答案用 | 分隔）
cargo run --release -p wowtype-core --bin wowtype-eval -- \
    --lexicon rime.tsv --eval cases.tsv \
    --weights coverage_score=1.5,prob=0,history_count=0.3
```

常用参数：

| 参数 | 作用 |
|---|---|
| `--k n` | 报告 top-n 召回（默认 3） |
| `--max n` | 候选数量上限 |
| `--fuzzy` / `--shuangpin` | 用对应模式评测 |
| `--lm` / `--arpa` | 指定语言模型 |

用例可以从词库自动生成，也可以自己标注：

```bash
python3 tools/make_eval.py rime.tsv --count 300                 # 每拼音取最高频词
python3 tools/make_eval.py rime.tsv --rank 2                    # 取第 2 高频（测候选广度）
python3 tools/make_eval.py rime.tsv --truncate 1                # 截掉末尾 1 字母（测补全）
python3 tools/make_eval.py rime.tsv --jianpin                   # 换成简拼
```

### 语言模型与上下文

`--lm` 吃「prev<TAB>cur<TAB>count」的 bigram TSV，`--arpa` 吃标准 ARPA。
上下文取光标前文本的**最后一个词或最后一个字**去查二元组（中文通常没有空格，
只取「最后一个词」会把整段当成一个词，永远查不到）。

实测上下文消歧：

```bash
wowtype-demo --lexicon lex.tsv --lm lm.tsv xian              # 1. 先
wowtype-demo --lexicon lex.tsv --lm lm.tsv --context 我 xian  # 1. 西安
```

`tools/make_bigram.py` 能从词库反推字二元（`事->情` 这类词内搭配），但它**不能替代真实语料**：
在没有语料的情况下实测，rank1 从 100% 掉到 99%，rank2 的 top10 从 100% 掉到 98.7%——
用它换来的是上下文能力，用频率忠实度做代价。真实语料训练的 LM 才有正收益。

另外，词表里没有的词（例如字级模型评多字词）一律当「无信息」处理，
否则会被按近零概率惩罚，把正确的长词压下去。

### 默认权重的取舍

排序总分是 `path.score + rank_score`。因此 `rank_score` 里**不能**再放已经计入
`path.score` 的特征，否则就是重复计权：

| 特征 | 权重 | 原因 |
|---|---|---|
| `prob` | 0 | 是 `path.score` 的单调变换 |
| `lm_score_with_previous_txt` | 0 | 已计入 `path.score` |
| `context_bigram_score` | 2.0 | 上下文带来的新信息 |

这样上下文才有机会真正影响结果。例子（词库里「先」远高于「西安」）：

```bash
wowtype-demo --lexicon lex.tsv --lm lm.tsv xian            # 1. 先
wowtype-demo --lexicon lex.tsv --lm lm.tsv --context 我 xian  # 1. 西安
```

改完后在真实词库上回归验证：rank1 top1 100%、rank2/3 的 top10 100%、长输入 top1 100%，均无下降。

### 训练权重

有一批「输入 → 我实际想要的词」的标注后，可以直接拟合权重（softmax 交叉熵 + L2）：

```bash
cargo run --release -p wowtype-core --bin wowtype-train -- \
    --lexicon rime.tsv --cases cases.tsv --epochs 300 --out weights.txt
```

输出可以直接喂给 `wowtype-eval --weights`。

实测结论要说清楚：
- **特征能区分的场景**（例如「先」vs「西安」，分词特征 `kind` 不同）训练有效，0% → 100%
- **同音词之间**（特征几乎完全相同）训练无效，0% → 0%——这类需要上下文/LM 特征，
  词库自带的信息不足以区分

输出形如 `用例 200  top1 176 (88.0%)  top3 195 (97.5%)`，并列出没进前三的用例。

还有两个辅助工具：

- `wowtype-probe`：逐键输入探针，从第 2 个字母开始逐位截断，看目标词在每一步是否还在候选里。
  它靠「出现过又消失」这个信号抓到了补全的 bug（见下）。
- `wowtype-bench`：真实词库下的载入耗时与逐键延迟。
配合 `--fuzzy` / `--shuangpin` / `--arpa` 可以对比不同配置。仓库里的
`core/data/eval_sample.tsv` 只是演示用的 13 条。

## 半成品输入

即使输入能完整解析（`zhonggu` 就是 zhong+gu），引擎也会把延伸候选（中国）一并给出——
否则用户打到一半时几乎选不对词。延伸候选按「多打的字母数」扣分（每字母 1.5 nats），
避免抢掉完整输入的正确结果。

实测（rime-ice 55 万词库）：

| 场景 | top1 | top3 |
|---|---|---|
| 完整输入 | 99.2% | 100% |
| 截断 1 个字母（`zhonggu`） | 89.7% | 99.0% |
| 截断 2 个字母（`zhongg`） | 55.0% | 73.0% |
| 截断 3 个字母 | 24.0% | 34.3% |

惩罚系数的取舍（完整 / 截断 1 字母）：0.5 → 97.2/85.7，1.0 → 98.5/86.3，
1.5 → 99.2/85.0，2.0 → 99.8/84.0。默认取 1.5。

简拼的质量单测：`--jianpin` 生成只取首字母的用例，300 例 **top1 95.3%**。

逐键输入用 `wowtype-probe` 检查：从第 2 个字母开始逐位截断，统计目标词是否还在候选里。
它抓过一个真 bug——补全把未完成的尾巴当成了合法前缀（`shesh` 被当成能解析的 head），
导致 `设施` 从来没被补出来。修好后「出现过又消失」的用例为 **0**。

简拼的「半成品」（`jz` 想打 `jzm` 江泽民）**不做前缀补全**：`jz` 本身可能就是要打
「记者/戒指」，按词频给精确结果符合主流输入法行为；实测加前缀补全后，10 个候选位
会被同分数的短词占满，长词仍进不了前 10，收益为零而复杂度上升。

## 性能

合成 10 万条词库压测（`cargo run --release -p wowtype-core --bin wowtype-bench`，M 系列 Mac）：

| 输入 | 耗时 |
|---|---|
| 载入 10 万条词库 | ~140 ms（一次性） |
| 载入 rime-ice 全量 55 万条（首次，建快照） | ~1.4 s |
| 同上（之后，读快照） | **~0.35 s** |
| 完整输入（55 万词库） | 0.5~1.0 ms |
| 半成品输入（触发补全，55 万词库） | ~6 ms |
| `a` | 0.003 ms |
| `zhong` | 0.14 ms |
| `zhongguo` | 0.03 ms |
| `zhongg`（半成品，触发 32 路补全） | 0.19 ms |

词库加载会自动生成二进制快照（`lexicon.tsv.wcache`）：按「源文件大小 + mtime + 格式版本」
校验，词库更新后自动重建。词库在只读目录（如 `/usr/share`）时快照落到
`$XDG_CACHE_HOME/wowtype/`（默认 `~/.cache/wowtype/`）。

交互预算（<10ms）有很大余量。模糊音索引是**惰性构建**的（模糊音默认关闭），
55 万词库下省掉了约 45% 的加载时间；代价是第一次用模糊音时多一次建表。

## 已知限制

- `core/data/demo_lexicon.tsv` 只有十几条演示词，真实词库尚未导出（见下）。
- `voice-daemon` 的 X11 热键与 cpal 采集是骨架，未在真机跑过。
- fcitx5 插件未在这台 macOS 上编译验证。

## 数据管线（下一步）

官方 WeType 的词库和排序参数是二进制格式，正在解：

| 目标 | 状态 |
|---|---|
| `bwcnmac.bin`（30MB，含明文拼音）词条布局 | 进行中 |
| `bwcnmacv8.bin`（31MB，整数音节 ID + Huffman） | 待办 |
| `lmcnmac.bin` 二元语言模型 | 待办 |
| `hpmac_base.bin` 超参数 | 已读出浮点值 |
| 候选排序 oracle（官方引擎直接吐分数） | 卡在 create_session 的一个空指针 |

详见 [analysis/REPORT.md](analysis/REPORT.md)、[docs/DATA.md](docs/DATA.md)、
[tools/oracle/README.md](tools/oracle/README.md)、[docs/VOICE.md](docs/VOICE.md)。
