# 数据格式分析笔记

记录 WeType `imeData.bundle` 里各二进制格式已确认的结构。所有结论都来自
静态分析 + 实际文件字节核对。

## 1. 词典容器（通用头部）

`_wxime_dict_item`（24 字节，来自 `ResourceMgr::Impl::ConfigDicts`）：

```c
struct item { void* fd_desc; const char* path; uint32_t id; };
// fd_desc 非空时走文件描述符：{ int fd; int size; int offset; }
```

`id` 取 `index.json` 的 `type` 字段。已知取值：

| type | 词典 |
|---|---|
| 65536 | bwcnmac.bin（旧版中文，含明文拼音） |
| 65537 | bwcnenmac.bin |
| 65538 | bccn.bin |
| 65546 | bwcjpmac_jianpin.bin（简拼） |
| 65551 | slwd_pc_second_level.bin |
| 65581 | bwcnmacv8.bin（新版中文） |
| 131072 | lmcnmac.bin（二元语言模型） |
| 262144 | hpmac_base.bin（超参数） |
| 524291 | swbd86/98/nc.bin（五笔） |

## 2. 中文词库

- 结构：LOUDS 压缩 trie（`wxime::data::ImeTrie` / `trie::LoudsTrie`）
- 节点标签是 `std::string_view`（`Cursor::MoveImpl` 里 `ldp x7,x22,[base+label_id*16]`）
- 词条正文 UTF-16LE
- `bwcnmac.bin`（type 65536）里能搜到明文拼音（5 万处），`bwcnmacv8.bin`（65581）没有，
  拼音被压成整数音节 ID
- 值的编码：`LargeDictValueHuffmanCodec` / `SecondLevelDictEntryHuffmanCodec` —— 词频与
  附加信息是 Huffman 编码的，需要连码本一起解

## 3. 二元语言模型 `lmcnmac.bin`

### 头部（`bi_gram::Reader::Impl::Impl` 指令级分析）

```
u32[0]   flags       0x80000001  （最高位表示扩展头；低字节 = 版本 1）
u32[1]   bucket 数   18852
u32[2..] CSR 偏移表  严格递增，共 bucket 数项
```

- 偏移表占 `4 + 18852*4 = 75416` 字节，数据正好从 75416 开始
- 最后一个偏移 16757388，文件大小 16758278（尾部 890 字节是别的段）
- 每个桶的条目落在 `[off[i], off[i+1])`，桶大小 860~1256 字节

### 查找逻辑（`bi_gram::Reader::LookUp`）

1. **把 key 反转**（原地首尾交换）——说明文件里的 key 是倒序存的
2. 走 `HashMapReader<DefaultKeyHash, DefaultKeyCheckHash>::operator[]`
3. 命中后读两个 `int16`（偏移 0 和 2），各解成一个 fp16 风格的定点概率：

```
mag = ((h & 0x7fff) << 13) | 0x70000000   // 当作 float 位模式
mag *= 2^-112                             // 等价于 (h & 0x7fff) * 2^-15
if ((h >> 10) & 0x1f) == 0 {              // 指数段为 0 的次正规情况
    mag = (h & 0x7fff) * 2^-15            // 线性公式
}
value = (h & 0x8000) 符号位 | mag
```

所以每个条目的值 = **4 字节（两个 16 位概率）**。

### 桶内布局（已解出）

`HashMapReader<DefaultKeyHash, DefaultKeyCheckHash>::operator[]`：

```
idx   = CityHash32(key) % size_          // size_ = u32[1]
off   = offsets[idx]                     // CSR
n     = u32  at buf + off
h[i]  = u32  at buf + off + 4 + 4*i      // CityHash64WithSeed(key, len, 0x1DBBA5) 低 32 位
ck[i] = u16  at buf + off + 4 + 4*n + 2*i // 该条目值在值区里的偏移
val   = deserialize(buf + off + 4 + 6*n + ck[i])
```

`[reader+0x30]` 为 0 时线性扫描、为 1 时二分（哈希数组有序）。

### 重要结论：lmcnmac 无法枚举导出

条目里**只存 32 位哈希，不存 key**，所以拿到文件也还原不出「哪些 bigram 存在」，
只能按已知 key 查询。想导出只能拿一份词表逐对算哈希做 join（top 5k 词约 2500 万次
CityHash，可行但重），更实际的是 Rust 侧用开源 bigram 或自建语料统计——
`LanguageModel` trait 已经支持替换实现。

### key 的拼接格式（已确认）

`PathV2::CalculateContextNGramScore` 里：

```
key = absl::StrCat(上下文文本, 候选文本)   // 直接拼，无分隔符
```

然后 `LookUp` 把 key **整体反转**再哈希。所以：

- 条目粒度和「上下文长度」强相关，key 是任意长度的文本串，不是简单的词语对
- 加上只存哈希，**lmcnmac 无法用词表 join 反推**，导出这条路实际上走不通

结论：Rust 侧不要指望复刻这份 LM，直接换开源/自建 bigram，
`LanguageModel` trait 已经预留了替换点。

### 3.1 字级神经语言模型 `nlrgpt2_nnlm.bin`（已跑通，`core/src/nnlm.rs`）

微信输入法 3.0.0（macOS）的 `imeData.bundle/nlrgpt2_nnlm.bin`，MD5 `edca685aba600497de298dd68a5d5e4d`，16,211,368 字节。

- 布局：1 字节 `0x01` + u32 长度 + TFLite 模型（15,883,720 字节）+ 一个和 §3 同格式的哈希表（字表）+ 末尾一段 JSON
  （`start_cache`：`<s>` 在位置 0 的 KV；`log_softmax`：`<s>` 之后的分布，可用来自检）。
- 字表哈希表：`flags=0x80000001`、桶数 5594。桶号 = CityHash32(字) % 5594，桶内哈希 = CityHash64WithSeed(字, 0x1DBBA5) 的低 32 位（CityHash **v1.1**）。
  值是 `04 01 <u16 码位> <u8 编号>` 或 `14 01 <u16 码位> <u16 编号>`，值里自带字，所以遍历所有桶就能拿到完整字表，不用算哈希。
  特殊编号：`<pad>`=0、`<unk>`=1、`<s>`=2、`</s>`=3；其余按字频排（，=4、的=5、。=6）。
- 模型：GPT-2，3 层、d=256、4 头×64、FFN 1024、最长 512 位置，词表 5594，输出头和 wte 共享，pre-LN（eps 1e-5），GELU 用 tanh 近似。
  权重全是 float32（没有量化），全连接权重按 [out, in] 存。输入 `input_ids`、`past`（KV 缓存）、`z_flag`（只控制另一个输出的 64 维符号哈希，打分用不到）。
- 验证：Rust 实现和 LiteRT 的输出差 < 2e-5。`我今天很开心` = −15.28，`我今天很开薪` = −35.95。一步约 4M 次乘加，单核约 1ms。
- `decgnr.bin`（12 层、768 维、词表 10496 的 WordPiece 模型）更大，逐键跑太重，没接。

### 3.2 WowType 自己的词级语言模型 `words.lm`（`core/src/wordlm.rs`）

lmcnmac.bin 导不出来（§3），所以自己从语料训练。`wowtype-lmbuild`：

1. 繁体按 `s2t.tsv` 反查转简体；只看汉字，其余字符断开。句号、问号、叹号、分号和行首算句首（前一个词是 `<s>`）。
2. 每段汉字用词库分词：取 ∏ P(词) 最大的切法（词频来自 lexicon.tsv，一个词最多 8 字），词库里没有的字打断搭配。
3. 数一元、二元；P(cur | prev) 用绝对折扣（d = 0.75）插值一元，留次数 ≥ 3 的最多 400 万个搭配。
4. 存的是**相对一元的提升** ln P(cur | prev) − ln P(cur)（上限 6）：词频已经在束搜索的 lexical 里算过，不重复计；
   没见过的搭配给 ln λ(prev)；模型里没有的词给 0（罚分实测更差）。

评测（`tools/make_sentence_eval.py`，日常句是手写的 138 句，维基句是维基第 5 分片里抽的 600 句，训练只用第 0–4 分片）：

| 配置 | 日常句 top1 | 维基句 top1 |
|---|---|---|
| 只有词库 | 74.6% | 37.3% |
| + 微信 NNLM 重排 | 84.1% | 42.0% |
| + 热词 + NNLM | 86.2% | 41.7% |
| + 热词 + words.lm（LCCC + 维基，400 万搭配，38.5 MB） | 84.8% | 60.2% |
| + 热词 + words.lm + NNLM | **90.6%** | **58.2%** |
| 同上，words.lm 200 万搭配（22.4 MB） | 89.9% | 57.0% |
| 同上，words.lm 100 万搭配（14.4 MB） | 89.9% | 54.8% |

只用一种语料时：只用维基对日常句没帮助（74.6%），只用 LCCC 对维基句没帮助（37.5%），两个混着用才两头都好。
400 万搭配的 words.lm 载入约 56 ms、多占约 90 MB 内存；加上 NNLM 后逐键平均 5.9 ms、p99 25 ms。

日常句和热词表（`data/hotwords.tsv`）是同一时间写的，热词带来的那 3 个点有自评成分。

安装包里自带 400 万搭配的那份（`/usr/share/wowtype/words.lm`，CC BY-SA 4.0；0.3.3 及以前在单独的词库包 `2026.10.31.2` 里），
`scripts/make-data.sh` 从 [Release lm-2026.11.09](https://github.com/Gloridust/WowType/releases/tag/lm-2026.11.09)
下载并核对 sha256。不带 NNLM 时（安装包用户的情况）日常句 84.8%、维基句 60.2%，逐键平均约 1.9 ms，和不带它时一样。

### 3.3 语料词频和构建词库的可选数据源

`scripts/make-data.sh` 用雾凇拼音和 `data/` 下的表。除了热词表、词频修正、黑名单，默认还融一张
**语料词频表 `data/tatoeba-freq.tsv`**：从 Tatoeba 中文句子（2026-11-05 的导出，全部 89248 句，CC BY 2.0 FR）
挖出的两个字以上的词的次数，只有词频、不含句子。融合不联网、不要额外的 Python 包，本机构建和发布的词库一样。

- 融法：按权重 0.3 融进已有词的词频（不加词），每个词最多抬到 20 × max(原频次, 1000)
  （`blend-freq.py --max-factor 20 --floor 1000`）。不封顶时「汤姆」会从 52040 抬到 1563 万，比「现在」还高；
  封顶后是 104 万。
- 重新生成：`scripts/make-tatoeba-freq.sh`（下载钉死的导出、核对 sha256、用钉死版本的 jieba 和 opencc 分词转简）；
  `scripts/make-tatoeba-freq.sh --check` 核对仓库里的表能逐字节重新生成（不进默认构建，要装 `tools/requirements-data.txt`）。
- 不融：`WOWTYPE_NO_CORPUS_FREQ=1`，或者删掉 `data/tatoeba-freq.tsv`。
- 换本机语料现挖：`WOWTYPE_CORPUS="a.txt b.txt.bz2"`（要 jieba），必须用 `WOWTYPE_CORPUS_LICENSE` 写清来源和许可证；
  一行一句，带 TAB 的用 `WOWTYPE_CORPUS_COLUMN` 指定列，繁体加 `WOWTYPE_CORPUS_T2S=1`，权重 `WOWTYPE_CORPUS_WEIGHT`。
  SOURCE.txt 里只记文件名和 sha256，不记路径。
- 署名：SOURCE.txt 正文（所有安装包都带，见下）、deb 的 copyright、README 的致谢和许可证、发版说明。

另外两个数据源默认不开，`WOWTYPE_DATA_EXTRAS` 打开（空格或逗号分隔，写错名字直接报错）：

| 名字 | 做什么 | 来源（钉死版本 + sha256） | 许可证 |
|---|---|---|---|
| `jieba` | jieba 词典里频次 >= 20 的多字词按权重 0.3 融进词频；再补词库没有的词（换算后频次 >= 50），读音用 pypinyin 注 | jieba 0.42.1 的 `dict.txt`（GitHub tag），pypinyin 0.55.0 | MIT |
| `cedict` | 补词库没有的词（最多 4 个字，去掉异体、台湾用词、儿化），频次统一给 10 | CC-CEDICT 2026-11-04 版（Internet Archive 上存的一份） | CC BY-SA 4.0 |

- 下载的文件都核对 sha256，对不上就退出；也能给本机文件（`WOWTYPE_JIEBA_DICT`、`WOWTYPE_CEDICT_FILE`，
  一样校验）。`WOWTYPE_DATA_CACHE=<目录>` 把下载过的文件按 sha256 存起来，下次不再下载。
- Python 包：`python3 -m pip install --require-hashes -r tools/requirements-data.txt`（版本、哈希钉死；
  脚本会核对已装的版本，分词和注音随版本变）。
- 语料词频和可选数据源都在合热词表之前做：`data/rime-ice-freq.tsv`（只提不降）和 `data/blocklist.tsv` 最后套，不会被冲掉；
  外部来源带进来的错条目也能用黑名单去掉。
- 语料词频的署名写在 `SOURCE.txt` 正文；用到的可选数据源的来源、许可证全文和署名追加在末尾的「额外数据源」一节。所有安装包都带 SOURCE.txt
  （deb/rpm/Arch 装成 `/usr/share/doc/wowtype/DATA-SOURCE.txt`，macOS 在 Resources 里，数据压缩包和 Nix 也有），
  deb 的 copyright 文件也会提一句。没用的数据源不写。

工具（`tools/`）：`lexdata.py` 是共用的读写规则，`blend-freq.py` 融合词频，`add-words.py` 补词，
`jieba2tsv.py`、`cedict2tsv.py`、`mine_corpus_freq.py` 把各来源转成这两个工具吃的格式。几条规则：

- 「#」开头的表头和没改的行原样写回；改过的频次取整但不低于 1。频次小于 1 的单字是大字表的生僻读音
  （`LexEntry::is_rare`，不参与组句），一律不动——以前 `:.0f` 会把 3.7 万个这样的读音改成 1，让它们进束搜索。
- 占位频次（雾凇 ext/tencent 词表的 100，引擎加载时按组成部分重估）的词不融合、也不拿来算换算系数。
- 按词融合，不按行：多音词各读音的频次之和当这个词的频次，融合后按原比例分回各读音，
  换算系数也按词算（以前多音词的计数会给每个读音各加一遍、在换算系数里也重复算）。
- jieba 新词的读音：pypinyin 按单字默认读音猜的多音字（雾凇里这个字常用读音不止一个）整个词不要；
  按单字猜的读音还必须是雾凇里这个字的常用读音（频次 >= 1）。

#### 评测（2026-11-14，本机 macOS，release 构建，`wowtype-eval --lm words.lm`）

用例（都不提交）：

- **Tatoeba 留出 A，3000 句**：Tatoeba 中文句子按固定种子 20261114 打乱（`tools/make_corpus_eval.py --split`），取最前面 3000 句。
  选参数（单字要不要、权重、只提不降）时看过它，所以它不算完全没碰过。
- **Tatoeba 留出 B，3000 句**：同一次打乱里接下来的 3000 句，选参数时一次都没打过分；参数定下来以后只跑了这一次。
- **手写日常句 138 句**（`tools/eval/daily_sentences.txt`）、**逐词上下文 533 条**（`tools/eval/context.tsv`）：
  选参数时也看过，量太小，单靠它们说明不了什么。

评测时语料词频是从钉死的 Tatoeba 导出（89248 句）里去掉 A、B 两组和与日常句相同的句子之后挖的（83183 句），
所以表里四组都没进语料。仓库里的 `data/tatoeba-freq.tsv` 用的是全部 89248 句（包括 A、B），
拿它构建的词库不能再在 A、B 上评；下表的数字都是去掉 A、B 的那份挖出来的，融法和发布的一样（权重 0.3、封顶 20 倍）。
同一份 rime-ice（927e1cf）、同一个 words.lm，合进 2026-11-14 的 pre-release 之后重跑。
「+/-」是逐句比较：基线错、新的对 / 基线对、新的错。

| 词库 | Tatoeba B 3000 句 top1 / top3 | Tatoeba A 3000 句 top1 / top3 | 日常句 138 top1 / top3 | 上下文 533 top1 / top3 |
|---|---|---|---|---|
| 基线（不开） | 1794 (59.8%) / 2018 (67.3%) | 1843 (61.4%) / 2051 (68.4%) | 119 (86.2%) / 125 (90.6%) | 472 (88.6%) / 521 (97.7%) |
| 语料词频（发布的融法） | **1864 (62.1%)** / 2066 (68.9%)，+103 -33 | **1905 (63.5%)** / 2104 (70.1%)，+92 -30 | **123 (89.1%)** / 129 (93.5%)，+4 -0 | 473 (88.7%) / 521 (97.7%)，+2 -1 |
| 同上，不封顶 | 1862 (62.1%) / 2067 (68.9%)，+104 -36 | 1905 (63.5%) / 2104 (70.1%)，+93 -31 | 123 / 129，+4 -0 | 473 / 521，+2 -1 |
| `jieba` | 没跑 | 1843 (61.4%) / 2061 (68.7%)，+35 -35 | 118 (85.5%) / 126 (91.3%)，+0 -1 | 473 (88.7%) / 522 (97.9%)，+2 -1 |
| `cedict` | 没跑 | 1843 (61.4%) / 2051 (68.4%)，+0 -0 | 119 (86.2%) / 125 (90.6%)，+0 -0 | 472 (88.6%) / 521 (97.7%)，+0 -0 |

（jieba、cedict 两行是合并 pre-release 之前跑的，语料行之外的数字合并前后一样。）

短输入（`wowtype-show --english --lm --max 18`，和插件一样，#156）：融了语料词频之后 d、l、b、ma、shi、ni、wo、zai、bu、de、le
的 18 个候选和基线完全一样；xz、nh、shim 第 3~9 个有调换（xz 第 5 个多了「鞋子」，nh 第 9 个多了「女孩」），首选不变，
`xz` 仍是「现在」（`data/rime-ice-freq.tsv` 修的那条）。
fcitx5 按键测试里依赖词库的输入（nihao、zhongdi、kyi、yongzwen、kaixin、jixu……）首选也不变；
`macos/test.sh`（`WOWTYPE_EXPECT_FULL_CHARS=1`）和 Ubuntu 24.04 容器里的 fcitx5 按键测试（`scripts/addon-test.sh`）
用默认构建的词库跑通过。

试过、没采用的：

- 语料把单字也融进去：Tatoeba A +137 -67、日常句 +6 -0，但 d、l、b、shi 等首页全变了（shi 的「师」从第 6 掉到第 10），
  改坏的大多是单字同音（再→在、是→市），所以只数两个字以上的词。
- 语料只提不降（`blend-freq.py --raise-only`）：Tatoeba A 1897，比双向融合的 1903 略差，日常句、上下文一样。
- 语料权重 0.15 / 0.5（含单字时）：Tatoeba A 1910 / 1923，日常句 124 / 123，0.3（125）最好。
- jieba 权重 0.15 / 0.5、带不带单字：Tatoeba A 1820~1852，日常句 118~120，都在噪声里，没有一组三项都不掉。
- CC-CEDICT 频次给 100（让引擎当占位频次重估）：Tatoeba 少 1 句，其余不变。
- 语料封顶（只在 A 组、日常句、上下文上挑，B 组只在定下来以后跑一次）：倍数 3 / 4 / 10 / 20 / 30（下限 1000）时
  A 组 1887 / 1894 / 1896 / 1905 / 1904，不封顶 1905；下限 100、10000（10 倍）时 1896、1899。
  20 倍是 A 组上不掉分的最紧的一档：评测那份封顶 56 个词，发布那份（全部句子）57 个。

语料词频已知的毛病：Tatoeba 是翻译腔的短句，人名多。封顶后「汤姆」52040 → 104 万、「玛丽」49655 → 99 万、
「约翰」135770 → 58 万（`tangmu`、`mali` 首选本来就是它们）。雾凇里频次只有 1 的词最多抬到 2 万：
嫉妒、披萨该抬（`pisa` 以前首选是「屁嫂」，现在是「披萨」；`jidu` 的「嫉妒」排第二），
jieba 切出来的碎片也会抬（「道菜」1 → 13114，`daocai` 的首选成了「道菜」）——封顶分不开这两种，要压只能进黑名单。

jieba 新词的读音抽查（固定种子各抽 300 个，我人工核对的，没有第二个人复核；CC-CEDICT 对照是独立的机器核对）：

- 以前的做法（#195，7259 个新词）：5 个确定读错（武都 wu dou、薄一波 bao、泊头 po、贝可勒尔 lei、王大珩 hang），
  另有 4 个人名姓氏读音存疑（区、盖、单），1.7%~3.0%；能用 CC-CEDICT 核对的 933 个里 33 个对不上（3.5%）。
- 现在的做法（6011 个新词，多音字按单字猜的 1250 个不收）：300 个里没有读错的；能用 CC-CEDICT 核对的 827 个里
  10 个对不上，其中儿化写法 2 个、「出血」读 xie 3 个（雾凇也收了这个读音）、半生不熟 shu/shou 1 个，
  真错的是唱喏、恁般、那末、长机 4 个（约 0.5%）。
- 读音之外，新词里有一成左右是 jieba 词典里的碎片和小说人名（黄蓉知、慈禧一、一个三十多岁）。

新词抢首选的情况（用每个新词自己的拼音打一遍，和基线比）：`cedict` 12033 个拼音里新词排第一 3610 个、
首选变了 1379 个（多数是把拼不成词的句子换成了词，比如 aiqitunsuan「爱妻运算」→「嗳气吞酸」，
也有 aiyouteng「哎哟疼」→「爱优腾」这种）；`jieba` 5848 个拼音里首选变了 2880 个。

结论：只有语料词频在留出用例上都不掉、短输入首选不变，所以默认融；`jieba`、`cedict` 在整句上看不出好处，留作可选。

可复现：`data/tatoeba-freq.tsv` 在仓库里，默认构建只用标准库、不联网，同样的 rime-ice 跑两遍逐字节相同。
这张表本身钉的是 Internet Archive 上的 `cmn_sentences.tsv.bz2`（2026-11-05 导出，sha256 `d603c1b9…91743`，
地址和完整 sha256 在表头和 `scripts/make-tatoeba-freq.sh` 里）；`--check` 在 macOS（两个 venv）和 Ubuntu 24.04 容器里
都逐字节重现了它。词库包版本 = rime-ice 日期 + REV 5（4 → 5 因为默认词库变了）；发版后
`.github/scripts/nix-data-pr.sh` 照常开 PR 把 `nix/package.nix` 的 dataVersion 和 hash 改到新的词库包。

## 4. Cell 词典（`cell_dict.*.zh`）

运行中的 WeType 从
`~/Library/Application Support/WeType/DictUpdate/DownloadDicts/` 加载：

```
cell_dict_fi/763/cell_dict.fi
cell_dict_hf_zh/547/cell_dict.hf.zh
cell_dict_newhot_common_zh/7556/cell_dict.newhot.common.zh
cell_dict_sc_zh/867/cell_dict.sc.zh
cell_dict_ssrc_zh/1341|1342|1346/cell_dict.ssrc.zh
```

通过 `wxime_add_cell_dict(const char* path, int slot, const fd_desc*)` 装载，
槽位有类型校验。实测（用已知 dict_type 的文件反推）：

| 槽位 | 要求 dict_type |
|---|---|
| 1 | 4 |
| 2 | 3 |
| 4 | 14 |
| 8 | 21 |

文件自身的 dict_type（从报错里读）：`hf`=4、`sc`=4、`newhot`=4、`fi`=21、`ssrc`=22。
槽位 3/5/6/7/9/10 不报错，语义待确认。

## 5. 参考引擎当前状态

打通的部分：`dlopen` 引擎 → `wxime_initialize` → `wxime_config_dict`（28 个词典全装载）。

卡点：`wxime_create_session` 在 `ZhMostLikelySequelSearcherV2` 构造函数 +0x330 处，
对 `dict->GetSubDict(7)` 返回的空 shared_ptr 做虚调用 → 段错误。
说明联想词库的某个子词典（label 7）没有注册，最可能来自未正确装载的 cell dict。

## 6. 复现命令

见 `tools/ref-engine/README.md`。

## 8. 词典类型系统（已解开）

`_wxime_dict_config.item.id` 的低 16 位就是**词典 kind**，高 16 位是**分组**：

```
id = (group << 16) | kind
group: 1 = 拼音族, 2 = 语言模型, 4 = 参数, 8 = 五笔族
```

`AddDictToResources` 里对 `id & 0xffff` 查跳转表（`0x103191e90`，跳表基址 `adr+16 = 0x101c3d2e4`，
每项 u16 × 4 字节），表项决定构造哪个类。已验证的对应关系：

| kind | 类 |
|---|---|
| 0 | ChineseStaticDict |
| 8 | **AssociateWbDict** |
| 14 | StaticWubiDict |
| 19 | StaticReverseWubiDict |
| 29 | ChineseStaticDictV2 |
| 45 | ChineseStaticDictV3（bwcnmacv8） |
| 86 | CompactKVLargeDict |

`swbd*.bin` 是**复合文件**：group 8 的 id 会被「concat key」拆成两个子词典
（65550 = StaticWubiDict、65555 = StaticReverseWubiDict），所以低 16 位对它们不起作用。

## 9. 枚举已加载词典（工具已可用）

`tools/ref-engine/probe_dict_kinds.cpp`：

```
ResourceMgr::Instance() → operator*() → shared_ptr<Resources> → Resources+0 → DictManager*
DictManager::GetSharedDictByKind(u16) → shared_ptr<IDict>（x8 隐式返回）
```

拿到 `IDict*` 后读 `vtable[-1]` 的 typeinfo name 就能看到具体类名。
当前配置下枚举出 **45 个**词典，其中没有 AssociateWbDict。

## 10. AssociateWbDict 的来源（未定）

- 28 个 `.bin` 逐个用 `id=0x10008` 试过，都没有产出 kind 8
- `cell_dict.*` 用 `wxime_add_cell_dict(path, 8, ...)` 试过，返回 1 但没有 kind 8

下一步：看 `DictManager::Impl::AddCellDict` 那个 `function<unique_ptr<IDict>(unsigned short)>`
的 lambda 里对 kind 的分支，确定 cell 类型到 AssociateWbDict 的映射。

## 11. 直接遍历 trie（已跑通一半）

拿到 `IDict*` 后可以走它的 Cursor 接口，这条路比静态解析二进制省事得多：

```c
// GetRootCursor() 返回 Cursor（96 字节，x8 隐式返回）
// Cursor 布局：
//   +0x00 dict 指针
//   +0x0c 当前节点 freq
//   +0x18 是否为词尾（IsLeaf）
//   +0x1c / +0x20 / +0x24 / +0x28 节点索引与累加值
//   +0x44 std::string（Apple 备用布局：短串 data 在 0，长度在第 23 字节）

bool Move(int label);      // 成功返回 true（普通返回值，无 sret）
void TryMove(int, out);    // 返回 optional<Cursor>，x8 隐式返回 —— 别用这个
uint64 Freq();             // 低 32 位是频次，bit32 是有效标志
bool IsLeaf();
```

实测 root → Move(0..11) 都能成功，读到频次 21578 / 12911 / 13442 …，
说明 DFS 可用。

**未解**：label id → 文本的映射。`MoveImpl` 里从全局 `0x10367a768` 取表，
`base + label*16` 是 `{ptr,len}`，但实测越界/乱码，说明那是个分页表而不是扁平数组，
或者 label 空间不是从 0 连续。下一步要么解分页表，要么用 `Cursor::ToSyllable()`
（返回 Cursor+0x44 的引用）配合正确的字符串布局。

## 12. Cursor 遍历（本轮进展）

已确认：

```
Cursor::Path()       -> Cursor+0x2c 的引用（未解出内容）
Cursor::ToSyllable() -> Cursor+0x44 的引用（音节路径，逗号分隔，如 a,a）
Cursor::Move(int)    -> bool，label 是**全局音节 id**，不是下标
Cursor::Freq()       -> 低 32 位频次，bit32 有效
```

label 表在全局 `0x10367a768`（两层指针：`*(void**)slot` 才是 `string_view` 数组），
元素 16 字节 `{char* ptr; size_t len}`，内容就是拼音音节表：
`a, ai, an, ang, ao, ba, bai, ...`（按字典序）。

DFS 实测输出：

```
\ta\t21578
\ta,a\t10686
\ta,a,a\t10652
```

即「音节路径 + 频次」已经能读，但 `+0x2c` 那个字符串一直是空的，
所以**中文词条本体还没拿到**。`MoveImpl` 里确实会写 `+0x2c`（`stur x9,[x19,#0x2c]`），
说明它由某种条件触发，下一步要找到触发条件。

## 13. 字符串布局与 DFS 结论（本轮）

### libc++ 备用字符串布局（Apple）

```
长串: [0]=data  [8]=size  [16]=capacity（最低位为 1 作为长串标志）
短串: [0..22]=内联数据  [23]=长度（低 7 位）
```

之前按 data@16 读，导致词条永远是空；按上面的布局读才正确。
判长串要用 `(*(u64*)(b+16) & 1)`，并且要加 size < 4096、指针范围合理 之类的校验，
否则短串会被误判成长串而崩溃。

### V3 cursor 能给什么

DFS 实测（`probe_cursor_dfs.cpp`，dict kind 45）：

```
\ta\t21578
\ta,a\t10686
\ta,ai\t3978
\ta,ba\t10245
```

即：**音节路径 + 频次**。
`Cursor::Path()`（+0x2c）在所有叶子上都是空的，说明中文词条不在 cursor 里，
而是存在值区（`LargeDictValueHuffmanCodec` 编码），需要通过 LookUp 的结果拿。

### 其他类

- kind 29（ChineseStaticDictV2）用同一套 cursor 接口没有子节点，说明 API 不同。
- kind 0（ChineseStaticDict）直接崩溃。

### 结论

「遍历 trie 导出词库」这条路走不通：trie 只存音节序列和频次，词条在另一套值编码里。
要拿词条还是得解 `LargeDictValueHuffmanCodec` + 音节 ID 映射，或者换个思路。

## 13.5 本地资产结构查看工具

`tools/wetype-assets/` 下是只读的结构查看工具（互操作/研究用，读的是用户本机已安装的微信输入法，
WowType 不带、不下载其中任何数据）：

- `scan.py`：词典目录每份文件的大小、dict_type、头部魔数
- `dump_xllm.py`：XLLM 大模型容器的配置、分词器概况和张量蓝图
- `vad.py`：VAD 资源的配置参数、CMS 维度、DNN 头部
- `wubi.py`：五笔词典容器（`swbd*.bin`）的结构统计（不输出词条）

用法、边界和已确认的格式见 `tools/wetype-assets/README.md`。

## 14. 复现指南与失败记录（收尾）

这一节给后来者：怎么从零复现这套分析，以及**哪些路走过、为什么没走通**。
失败记录比成功记录更有价值——它能省掉重复踩坑。

### 14.1 环境

- WeType 2.2.0（build 637），universal Mach-O，155MB，未 strip（25 万符号）
- macOS 14 / arm64
- `lipo`、`codesign`、`python3`、`clang++`

### 14.2 让官方引擎可被调用

1. `lipo -thin arm64` 从主二进制切出 arm64
2. 把 Mach-O 头里的 filetype 从 `MH_EXECUTE(2)` 改成 `MH_BUNDLE(8)`
3. `codesign -s - -f` 做 ad-hoc 签名
4. 造一个假的 `.app`：把产物放到 `Contents/MacOS/libwxime.dylib`，
   并软链 `Contents/Resources`、`Contents/Frameworks` 到真实安装目录
5. 设 `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH` 指向真实 Frameworks
6. `dlopen` 之后就能 dlsym 那 49 个 `wxime_*` 函数

（具体命令见 `tools/ref-engine/README.md`，那里有可直接执行的版本。）

常见错误对照：

| 报错 | 原因 |
|---|---|
| `MH_DYLIB is missing LC_ID_DYLIB` | filetype 还是 MH_EXECUTE，改成 8 |
| 找不到 framework | 没设 `DYLD_FRAMEWORK_PATH` |
| `init_context_.logger_ != nullptr` 断言 | 配置结构体第 0 个字段给非空指针即可 |
| `wxime_config_dict` 报 “wxime not init” | 必须先 `wxime_initialize` |
| `create_session` 段错误 | 见 14.4 第 3 条 |

### 14.3 工具索引（`tools/ref-engine/`）

| 文件 | 作用 |
|---|---|
| `probe_basic.c` | 最小可运行示例：初始化 + 建会话 + 输入 + 取候选 |
| `probe_runtime_patch.c` | 运行时改内存（`mach_vm_protect` + `VM_PROT_COPY` + `sys_icache_invalidate`）绕开崩溃点 |
| `probe_dict_kinds.cpp` | 枚举 45 个已加载词典的 kind 与类型名 |
| `probe_cell_kind.cpp` / `probe_cell_types.c` | cell 词典槽位与 dict_type 的对应关系 |
| `probe_cursor_walk.cpp` | 用 `Cursor::Move/Path/ToSyllable` 走 trie |
| `probe_cursor_dfs.cpp` | 深度优先遍历 V3 词库，打印「音节序列 + 频次」 |

`probe_cursor_dfs.cpp` 与 `probe_basic.c` 都验证过能编译：

```sh
clang++ -std=c++17 -o /tmp/pcd tools/ref-engine/probe_cursor_dfs.cpp
/tmp/pcd /tmp/WeTypeFake.app/Contents/MacOS/libwxime.dylib 45 40
# 输出形如：\ta\t21578（音节序列 + 频次）
```

### 14.4 失败的尝试（按投入排序）

**1. 遍历 trie 导出词条 ❌**

V3 词库（kind 45）的 cursor 在叶子上 `Path()` 恒为空，只给 `ToSyllable()`（音节序列）和 `Freq()`。
词条本身存在值区，由 `LargeDictValueHuffmanCodec` 编码。要导库得先解这套编码 + 音节 ID 映射。详见 §11–§13。

**2. 语言模型导出 ❌**

LM 的 key 是 `absl::StrCat(context, candidate)`（无分隔符）再反转后哈希，**键不可枚举**：
知道某个上下文才能查，无法反向列出全部 n-gram。

**3. 构造 AssociateWbDict（kind 8）❌**

`create_session` 依赖它。试过两条路都没成：28 个 bundle 内 `.bin` 逐个加载并检查 `item.id == 0x10008`；
以及 `wxime_add_cell_dict(path, 8, 0)`。怀疑 `DictManager::Impl::AddCellDict` 的槽位到 dict_type 映射没解对
（cell 槽位 1→4、2→3、4→14、8→21；文件 dict_type：hf=4、sc=4、newhot=4、fi=21、ssrc=22）。
已用补丁绕过崩溃点，但会话语义不完整。

**4. kind 29 / kind 0 的 cursor ❌**

kind 29 用同一套 cursor 接口没有子节点（API 不同）；kind 0 直接崩溃。

### 14.5 结论

分析到此为止：**能调用官方引擎（可做 teacher），但导不出它的词库和语言模型**。
可行路线是继续解 `LargeDictValueHuffmanCodec`。
当前项目采用开源词库（rime-ice）+ 自建引擎，实测完整输入 top1 99.2%。

### 14.6 法律边界

WeType 的二进制与模型是腾讯专有资产，**不随本仓库分发**。
`tools/ref-engine/` 里的工具只用于在你自己的机器上分析你自己的那份安装，理解格式与对照行为，不再分发。
