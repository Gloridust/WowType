# 微信输入法本地资产结构查看工具

这些是**互操作 / 研究用的开发者工具**：读取**用户自己机器上已安装的**微信输入法（WeType，macOS 版），
打印文件的结构（大小、魔数、超参数、张量形状、记录条数），帮助判断哪些格式值得研究。

**WowType 不带、不打包、不下载微信输入法的任何数据。** 词库、码表、模型权重、分词器都是腾讯的资产，
WowType 的发行包和任何构建脚本都不会包含或获取它们。WowType 的五笔码表来自公开的 rime-wubi
（LGPL-3.0，见 `scripts/make-wubi.sh`），拼音词库来自雾凇拼音，都与这里无关。

## 边界（硬规则）

- 只读本机安装目录（默认 `/Library/Input Methods/WeType.app`），**不联网**，不上传
- 默认只打印结构；唯一会写文件的是 `dump_xllm.py --tokens <路径>`，而且**拒绝写进 WowType 仓库目录**
- 从微信输入法提取的任何东西（词典、码表、模型权重、分词器词表）**不得提交、打包，也不得由任何构建脚本下载**；
  `.gitignore` 已排除常见的输出名（`wetype-dump/`、`*_vocab.tsv`、`*.tokens.tsv`、`imeData.bundle/`、
  `swbd*.bin`、`decgnr.bin`、`mpd_e2e.bin`、`nlrgpt2_nnlm.bin`、`*.xnet`）。导出请放在仓库外，比如 `~/wetype-dump/`
- PR、文档里只贴结构信息（大小、形状、条数），不贴词条、token 或数值

唯一的例外是已有的 `tools/install_wetype_nnlm.py`：它也只是把**用户本机**的 `nlrgpt2_nnlm.bin`
拷到用户数据目录，WowType 运行时有就用、没有就不用，同样不分发。

## 工具

都不带参数时读默认安装位置，加 `--json` 输出机器可读结果。格式和预期不符（版本变了、选错文件）时给一句话的错误。

| 脚本 | 读什么 | 打印什么 |
|---|---|---|
| `scan.py [imeData.bundle]` | 词典目录 | 每个文件的大小、`index.json` 里的 dict_type、头 16 字节、可打印比例 |
| `dump_xllm.py [decgnr.bin] [--tokens 路径]` | XLLM 模型容器 | 头、配置 JSON（超参数）、分词器类型和词表条数、张量蓝图（名字/形状/dtype） |
| `vad.py [vad 目录]` | `Resources/vad/` | VAD 时序配置、CMS 维度、DNN 头部和几种层结构的参数量比对 |
| `wubi.py [swbd*.bin …]` | 五笔词典容器 | 文件头、`50 01` 值记录的条数/偏移范围/字数分布、ASCII 码区范围（**不输出词条**）；开头不是 `029d300300130001` 时报格式不符 |

`_common.py` 是共用的读文件、边界检查、安全写出。

## 实测（微信输入法 3.0.1，macOS）

```
$ python3 tools/wetype-assets/scan.py
共 30 个文件，index.json 记了 30 个
（decgnr.bin 74,186,752 字节 dict_type 5；swbd86/98/nc.bin 各约 4.1MB dict_type 3；
  nlrgpt2_nnlm.bin 16,211,368 字节 dict_type 8；slwd_pc_second_level.bin 51,694,531 字节 dict_type 7 …）

$ python3 tools/wetype-assets/dump_xllm.py
XLLM 版本 0；配置 394 字节：12 层 / hidden 768 / 12 头 / 词表 10496 / 位置 512
分词器：0x4000 起 207,575 字节，WordPiece，词表 10463 条
张量蓝图 17 条（合计 23,604,480 参数），蓝图表结束于 0x128a

$ python3 tools/wetype-assets/vad.py
begin_win_ms 400、begin_confirm_ms 300、begin_padding_ms 150、end_padding_ms 480、sil_timeout 300
CMS：40 维，324 字节（剩 160 字节未解）
模型：85,352 字节，头 [1, 4, 0, 200, 64]，头后 21,333 个 float（4 层 200→64→64→64→1 需 21,249，差 84）

$ python3 tools/wetype-assets/wubi.py
swbd86.bin：38,797 条值记录（字数 1~5），尾部结构 33 字节，ASCII 码区约 0x0–0x40000
swbd98.bin：38,624 条；swbdnc.bin：37,766 条
```

## 已确认的格式

### XLLM 容器（`decgnr.bin`）

`+0x00` magic `XLLM`、`+0x04` u32 版本、`+0x20` u64 配置 JSON 长度、`+0x28` 配置 JSON；
之后是分词器 JSON（WordPiece，无 merges）、张量蓝图表（protobuf 风格记录 `1a <len> {0a 名字, 12 形状, 20 dtype}`）、权重区。
蓝图合计 23.6M 参数而配置是 12 层，说明蓝图是**单层模板**，权重区按层重复（或部分共享），逐张量偏移和量化方式未解。

### 五笔词典（`swbd86/98/nc.bin`）

由 `LoudsTrieHashMapReader<SVDeserializer, …>` 读取：LOUDS trie + 哈希表 + 值区。文件末尾 33 字节是单独结构
（构造时用 `size - 0x21` 切出正文）；前 256KB 左右是 ASCII 码区；值区记录形如 `50 01 <字数 u8> <UTF-16LE>`。
码 ↔ 词的对应没有解，也**不打算继续解**：五笔码表是公开标准，WowType 直接用 rime-wubi。

### VAD（`Resources/vad/`）

文本配置 + 40 维 CMS + 85KB 帧分类 DNN。时序参数见上面的实测；DNN 的层结构还差 84 个 float 对不上。

### 行为规则（只记选项，不取数据）

看到的（只读）：
- 程序里有「五笔编码提示」「四码唯一上屏」「五笔拼音混输」「第五码首选词上屏」四个设置项文字，和「86五笔」；
- 用户设置存储（`~/Library/Application Support/WeType/mmkv/wetype.settings`，不在安装目录里）有 `InputScheme`、
  `ShuangpinScheme`、`WubiScheme` 三个方案键，和一个 `WubiConfig` JSON，键为 `enableComment`、`emitUniqueCandidate`、
  `enablePinyin`、`emitWhenInputNextRune`，本机值依次是 开、开、开、关。

推断的（没有直接看到）：输入方案是一个单选；四个 JSON 键按名字对应上面四个设置项；
`WubiScheme` 对应 86 / 98 / 新世纪，因为词典目录里有 `swbd86/98/nc.bin`，98、新世纪的文字没找到；
本机值是不是出厂默认也无法确认。
这些规则用于 WowType 五笔模式的设计，见 `docs/plans/wubi-design.md`（随 #193 合入）。

## 贡献注意

- 新工具同样只读、不联网、默认只打印结构；需要写文件就用 `_common.open_output`
- 解析二进制时每次取数都做边界检查（`_common.need` / `unpack` / `uvarint`），格式不符抛 `FormatError`
