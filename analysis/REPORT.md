# WeType（微信输入法）macOS 版引擎行为分析报告

> 目标：判断「候选词排序」等输入法核心能否从 `WeTypeInstaller.app` 中解析出来，并评估移植到 Ubuntu 的可行路径。
> 分析时间：2026-11-06 ｜ 版本：CFBundleShortVersionString 2.2.0 (Build 637)

---

## 1. 安装包解包结果

`/Users/gloridust/Downloads/WeTypeInstaller.app` **本身不含输入法**，只是一个 7.5 MB 的下载/安装壳：

| 文件 | 说明 |
|---|---|
| `Contents/MacOS/WeTypeInstaller` | 7.5 MB 主程序（UI + 下载逻辑） |
| `Contents/Resources/install.sh` | 真正干活的安装脚本 |
| `Contents/Resources/Assets.car` | 图标资源 |

`install.sh` 的行为（关键部分）：

```sh
INPUT_METHODS_DIR="/Library/Input Methods"
WETYPE_INSTALL_PATH="$INPUT_METHODS_DIR/WeType.app"
unzip -qq "$ZIP_PATH" -d /tmp/wetype/
mv -f /tmp/wetype/WeType.app "/Library/Input Methods/"
chown -R root:staff ...; chmod -R 775 ...
```

即：接收一个 zip 路径 → 解压 → 覆盖安装到 `/Library/Input Methods/WeType.app` → 杀掉 SystemUIServer 让输入法菜单刷新。

**本机已装好真正的载荷**：`/Library/Input Methods/WeType.app`（668 MB），后续分析全部基于它。

---

## 2. 引擎形态

- 主二进制 `Contents/MacOS/WeType`：**155 MB，universal（x86_64 + arm64）Mach-O**
- **未 strip**：`nm` 有 **251,463 个符号**，其中大量 C++ 符号带完整命名空间和模板参数
- 静态链接进来的第三方库（从符号可直接读出）：
  TensorFlow Lite、ONNX Runtime、**LightGBM**、sentencepiece、leveldb、
  CryptoPP、asio、absl、Eigen、ruy、glslang + SPIRV-Cross（GPU 推理着色器编译）
- 系统框架：InputMethodKit、AppKit、CoreML、Metal、Accelerate、CoreGraphics、WebKit
- 内部命名空间：`wxime::`(11,630 符号，拼音引擎)、`mmime::`、`mmkb::`(键盘)、`wetap::`、`xnet::`(网络)
- 编译路径泄漏：`/Volumes/data/workspace/ime/wxime/engine/...`（有内部源码结构）

### 关键发现：引擎是「可嵌入库 + 平台外壳」架构

导出了 **49 个纯 C ABI**（`wxime_*`），这就是引擎的公共接口：

```
wxime_initialize        wxime_create_session     wxime_process_input
wxime_candidate_next    wxime_select_candidate   wxime_drop_last
wxime_config_dict       wxime_add_cell_dict      wxime_reset_session
wxime_get_most_likely_sequel  wxime_get_version  wxime_finalize
...（完整列表见 analysis/wxime_api.txt）
```

也就是说：**拼音引擎是独立于 macOS 的 C++ 核心，macOS 层（ObjC/Swift + IMKit）只是外壳。**
这决定了移植策略——不需要移植 AppKit 那套，只需要移植 C++ 核心 + 换外壳。

---

## 3. 候选词排序流水线（已解析出结构）

符号表把整条链路暴露得很清楚，按数据流排序：

```
按键输入
  └─ session::PreProcessInputSessionV2        输入预处理 / 纠错 / 简拼展开
  └─ graphs_v2::SyllableGraphHolder           音节图（切分歧义）
  └─ searchers_v2::Searcher::FeedBeam         束搜索
       BeamSizeScheduler：CosineDecay / ExpDecay / Nonlinear /
                          Sequence / WarmUpCosine / WarmUpNegativeExp（AB 实验可切）
  └─ PathV2::CalculateScore                   ★ 单条路径基础打分
       · 词典频次（RawFreqDict / ChineseStaticDictV3）
       · BiGramPlainPredictor（lmcnmac.bin 二元语言模型）
       · CoverageScore（覆盖率惩罚）
       · AdjustScoreWithUserWord / V2（用户词加权、回滚）
       · 参数来自 HyperParams::SentenceSearchParams
  └─ PathV2::CalculateScoreByModel(LRModel)   ★ LightGBM LTR 模型打分
  └─ CandidateV2Collector::CompleteImpl       候选汇总 + 去重 + 分类
  └─ NNLMRanker::ReRankPaths / LTRInfer       ★ TFLite 神经语言模型重排
  └─ MixRank + MixRankerPostProcessorV2       ★ 多特征融合、最终排序
  └─ 各类 Searcher 并行产出：
       WordSearchBySyllableGraph / PredictedWordSearcher / SentenceSearcherV3 /
       SecondLevelWordSearchBySyllableGraph / EnglishRankSearcher /
       SpecialSymbolsSearchBySyllableGraph / StrokesSearcherV2 / UserDictSyllableGraphV2
```

### 排序特征（从符号与字符串中直接取出的真实特征名）

候选级（`MixRank::Impl::GetRankFeat` / `SetRankUserWordFeat`）：

| 特征 | 含义 |
|---|---|
| `kind` | 候选类型（单字/词/整句/英文/emoji…） |
| `typo_count` | 拼写纠错次数 |
| `history_count` / `history_use_count` | 历史选用次数 |
| `complete_count` | 补全命中次数 |
| `history_time_diff` | 距上次使用的时间差 |
| `history_hot_val` / `spur_history_hot_val` | 历史热度值 |
| `context_bigram_score` | 与上文的二元语言模型分 |
| `lm_score_with_previous_txt` | 结合光标前文本的 LM 分 |
| `head_word_nnlm_feat` | 神经语言模型头词特征 |
| `user_dict_rollback_score` | 用户词回滚分 |
| `user_tail_conf` / `with_context` / `hot_val_conf` | 用户词/上下文置信 |
| `coverage_score` | 音节覆盖度 |
| `ltr_valid` | LTR 模型是否有效 |
| `prob` / `context_flag` / `full_jianpin` / `prefix_completion` / `other_completion` / `force_emit` | 概率、上下文标志、全拼/简拼、补全类型、强制上屏 |

### 超参数文件 `hpmac_base.bin`（1,872 字节）

里面**就是真实的浮点权重/阈值**（小端 float，可直接读出）：

| 值 | 可能的含义 |
|---|---|
| `1.0, 0.1, 0.9, 0.5, 3.0, 6.0, 10.0, 30.0, 40.0` | 各类权重 / beam 上界 |
| `-0.7, -1.4, -3.0, -500.0` | 惩罚项 |
| `0.7, 0.5, 0.1, 0.01, 0.005` | 衰减/缩放系数 |
| `2592000`(30天,s) | 历史记录过期时间 |
| `0.833, 0.0504, 9.37, -1.94` | 模型相关常量 |

配合 `HyperParams::SentenceSearchParams(bool)` 的调用点，可以逐个把字段和数值对上（需要继续做指令级分析确认结构体偏移）。

---

## 4. 数据文件（`Contents/Resources/imeData.bundle`，约 313 MB）

| 文件 | 大小 | 判定 |
|---|---|---|
| `bwcnmacv8.bin` | 31.7 MB | **主中文词库**（拼音→词，LOUDS trie） |
| `bwcnmac.bin` / `bwcnenmac.bin` | 30.4 / 6.0 MB | 旧版中文 / 中英混排词库 |
| `bwcjpmac_jianpin.bin` | 12.6 MB | 简拼词库 |
| `lmcnmac.bin` | 16.8 MB | **二元语言模型**（`lm::bi_gram::Reader`） |
| `nlrgpt2_nnlm.bin` | 16.2 MB | **神经语言模型，TFLite 格式**（`TFL3` magic） |
| `mpd_e2e.bin` | 3.7 MB | 端到端模型 |
| `decgnr.bin` | 74.2 MB | `XLLM` magic，大模型权重 |
| `ckvdmac.bin` | 39.7 MB | 联想/候选缓存 |
| `slwd_pc_second_level.bin` | 51.7 MB | 二级词（PC） |
| `swbd86.bin` / `swbd98.bin` / `swbdnc.bin` | 4.1 MB ×3 | **五笔词库**（内含 `wyve`/`fpgc` 等码表） |
| `sepd.bin` | 875 KB | trie 索引（含 `"Ime trie header"`） |
| `hpmac_base.bin` | 1.8 KB | **超参数**（见上表） |
| `pcc.bin` | 359 KB | 候选分类/打分模型（89,753 个 float） |
| `md.bin` | 22 KB | MD5 清单（hex 文本） |
| `index.json` | 6 KB | 各词典的 type/version/md5（支持热更新） |

---

## 5. 词典格式（已确认部分）

- 结构：**LOUDS 压缩 trie**（`wxime::data::ImeTrie` / `trie::LoudsTrie`，支持 `CommonPrefixSearch`、`PredictiveSearch`）——和 marisa-trie / succinct 一类的思路。
- 词条正文：**UTF-16LE**。实测在 `bwcnmacv8.bin` 0x1800000 附近可读出「居延泽」「巨野县」等地名词条。
- **拼音不是文本存的**：`bwcnmacv8.bin` 全程没有 `[a-z]{4,}` 的 ASCII 串，拼音被编码成整数**音节 ID**。
- 音节表**内嵌在二进制里**（`zhong` 出现于文件偏移 0x22226cd / 0x71b722d），是 NUL 分隔的拼音列表，并包含 WeType 扩展音节：
  `yvan / xvan / jvan / qvan / yve / yvn / lve / nve / hng / hm / fiao / nou / nun` 等。
  已抽出片段存于 `analysis/syllables.json`。
- 记录级布局（长度/频次字段位置）尚未完全定稿——这是解出完整词库的最后一步。

---

## 6. 移植到 Ubuntu 的可行性

### 路线 A：直接跑 macOS 二进制 —— ❌ 不可行
Mach-O + InputMethodKit + AppKit + Metal/CoreML，Linux 无任何兼容层能加载。Wine 也只能跑 Windows PE，不跑 Mach-O。

### 路线 B：Wine + Windows 版 sidecar —— ⚠️ 可行但脏
微信输入法有 Windows 版，其 DLL 大概率暴露同一套 `wxime_*` C ABI。
做法：fcitx5 插件 → 本地 socket → Wine 里加载的 `wxime.dll`。
问题：输入法对延迟极敏感（>10 ms 就有感知）、Wine 下 CoreML 类算子走 CPU 很慢、崩溃不可控、且**分发/使用条款有法律风险**。

### 路线 C：重写引擎（推荐）✅
**排序算法本身完全可复刻**，因为：
1. 整条流水线结构已从符号还原（见第 3 节）；
2. 全部特征名已拿到（上表 20+ 个）；
3. 超参数文件里的数值可直接读；
4. 二元 LM + TFLite 神经 LM 都是标准格式，能在 Linux 用 tflite-runtime / ONNX 加载。

真正的工作量在两块：**词库解码** 和 **模型文件解析**。

建议架构（正好匹配仓库里已有的 Rust 工程）：

```
fcitx5 (Linux)  ── Unix socket / C ABI ──  wowtype-core (Rust)
                                            ├─ 音节图 + 束搜索
                                            ├─ 词库 (LOUDS trie, 从 WeType 词库导出或 rime 词库)
                                            ├─ 打分: 频次 + 二元 LM + 覆盖率
                                            ├─ LTR 重排 (LightGBM → Rust 推理 / ONNX)
                                            └─ 用户词 / 历史
```

---

## 7. 建议里程碑

| 阶段 | 内容 | 产出 |
|---|---|---|
| M1 | 定稿 `bwcnmacv8.bin` 记录布局，导出「拼音 → 词 → 频次」 | `lexicon.tsv`（约百万级词条） |
| M2 | 解析 `lmcnmac.bin` 二元 LM，导出 n-gram 表 | `bigram.bin` / 通用格式 |
| M3 | Rust 实现音节图 + 束搜索 + 频次/LM 打分（复刻 `PathV2::CalculateScore`） | 能出候选的 CLI |
| M4 | 复刻 MixRank 特征与权重，做 LTR 重排 | 排序质量对齐 |
| M5 | fcitx5 addon 外壳 + 配置 + 用户词持久化 | 可日常使用 |

M1 是当前卡点，也是最值钱的一步（决定能不能用原版词库而不是换 rime 词库）。

---

## 8. 法律与合规提示

WeType 的二进制、词库、语言模型均为腾讯闭源资产。解包分析用于互操作/研究通常在合理范围，但**再分发词库与模型、或把核心做成公开产品存在明确法律风险**。
更稳妥的组合：**自己实现引擎 + 使用开源词库（rime / 中文维基 / OpenCC 生态）**，只借鉴 WeType 的排序思路与特征设计。

---

## 附：分析产物

| 文件 | 内容 |
|---|---|
| `analysis/wxime_api.txt` | 49 个导出 C API |
| `analysis/syllables.json` | 抽出的拼音音节表片段 |
| `analysis/symbols_demangled.txt` | 25 万符号（demangle 后，55 MB） |
| `analysis/strings.txt` | 全部字符串（7.6 MB） |
