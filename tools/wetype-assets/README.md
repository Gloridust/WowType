# 微信输入法本地资产挖掘

目标：把微信输入法（macOS 版）里**能在本地利用**的规则、数据、模型整理出来，
供 WowType 后续接入。这里只放解析代码，不放任何模型或词库本体。

## 边界

- 只读自己机器上的安装目录，不联网、不上传、不分发权重
- 模型和词典是腾讯的资产：仓库里只保留**格式说明 + 解析代码**
- 用户自己从安装包里取文件（见 `scripts/install_wetype_nnlm.py` 的做法）

## 工具

```bash
# 列出词典目录里每份文件的大小、dict_type、头部魔数
python3 tools/wetype-assets/scan.py "/Library/Input Methods/WeType.app/Contents/Resources/imeData.bundle"

# 解析 XLLM 容器（大模型）：配置、分词器、张量蓝图
python3 tools/wetype-assets/dump_xllm.py path/to/decgnr.bin
```

## 已确认的资产

| 文件 | dict_type | 内容 | 状态 |
|---|---|---|---|
| `decgnr.bin` | 5 | XLLM 容器：GPT-2（12 层 / 768 维 / 词表 10496 / 位置 512） | 头、配置、分词器、张量蓝图已解；权重区待解 |
| `mpd_e2e.bin` | 5 | E2E 配套模型（2.7MB） | 未解 |
| `swbd86/98/nc.bin` | 3 | 五笔码表（86 / 98 / 新世纪），4MB ×3 | 头部可见 ASCII 码（如 `gglg`），容器未解 |
| `bwcjpmac_jianpin.bin` | 9 | 简拼词库，12.6MB | 未解 |
| `slwd_pc_second_level.bin` | 7 | 二级词 / 联想库，51.7MB | 未解 |
| `noun_tag_dict.bin` | 0 | 词性标注，4.3MB | 未解 |
| `nlrgpt2_nnlm.bin` | 8 | TFLite GPT-2，首词语言模型 | **已被 WowType 使用** |
| `Resources/vad/`（不在 imeData） | — | VAD：文本配置 + 40 维 CMS + 85KB DNN | 配置、CMS 已解；模型层结构待确认 |
| `lmcnmac.bin` | 0 | 语言模型 | 键是哈希，不可导出 |
| `bwcnmac.bin` / `bwcnmacv8.bin` | 0 | 拼音词库 | trie 只给音节+频次，词条在 Huffman 值区 |

### XLLM 容器结构（`dump_xllm.py` 的实测结果）

`+0x00` magic `XLLM`，`+0x20` u64 配置 JSON 长度，`+0x28` 配置 JSON
（`model_type`、层数、维度、词表、位置上限等）

配置 JSON 之后：

1. 若干对齐填充
2. 分词器 JSON（约 207KB，10463 个 token，BPE）
3. 张量蓝图表（17 条，protobuf 风格：`0a` 名字、`12` 形状、`1a` 附加、`20` dtype）
4. 权重区（74MB 文件里占大头，逐张量的偏移还没解出来）

`decgnr.bin` 的蓝图合计 23.6M 参数，但配置是 12 层——说明蓝图表是**单层模板**，
权重区里按层重复存储（或者部分权重共享），这是下一步要确认的。


### VAD（`Resources/vad/`）

不在 `imeData.bundle` 里，而是应用资源目录下的 `vad/`：

| 文件 | 大小 | 内容 |
|---|---|---|
| `configure.16k.20221116.offline` | 3.0KB | 文本配置 |
| `CMS_40dim_chi.bin` | 324B | 40 维 fbank 的 CMS 参数（u32 维度 + 40 个 float，另有 160 字节待确认） |
| `model_16k_20210121_iter07.bin` | 85KB | 帧分类 DNN |

配置里能直接读到 VAD 的时序参数（`tools/wetype-assets/vad.py` 会打印）：

```
output_data_ms 40、begin_win_ms 400、begin_confirm_ms 300
begin_padding_ms 150、end_padding_ms 480、sil_timeout 300
frame_classifier.feature.name = FBank_16k_E_C_40_Online
frame_classifier.net_input_win = 4、frame_mtm = 20、sil_thresh = 0.65
```

模型头是 5 个 u32：`1, 4, 0, 200, 64`（版本 / 层数 / ? / 输入 200 维 / 隐藏 64），
之后有 21333 个 float。按 `200->64->64->64->1` 算是 21249 个，差 84 个，
说明文件里还有别的段（标准差在文件中部有明显跳变），需要继续拆。
## 下一步（按投入产出）

1. **解 XLLM 权重区**：确认每层权重偏移和量化方式，实现 12 层 GPT-2 前向 → 长句重排
2. **解五笔码表**：`swbd*.bin` 的容器结构（可以先从 ASCII 码表部分入手）
3. **解简拼 / 二级词**：提升简拼召回和联想
4. **VAD 模型**：确认 DNN 层结构和量化方式，替换现在的能量 VAD

## 贡献注意

- 提交里不要带 `.xnet` / `.gguf` / `.bin` 等模型文件，`.gitignore` 已经排除了常见后缀
- 解析代码要有明确的入口和 `--json` 输出，方便别的工具复用