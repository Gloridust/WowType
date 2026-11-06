# 数据格式逆向笔记

记录 WeType `imeData.bundle` 里各二进制格式已确认的结构。所有结论都来自
反汇编 + 实际文件字节核对。

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

### 头部（`bi_gram::Reader::Impl::Impl` 反汇编）

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

### 待办

- key 的拼接格式（分隔符、是否按字符反转）需要从上游
  `PathV2::CalculateContextNGramScore` 确认，否则 join 时算不出正确哈希

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

## 5. Oracle 当前状态

打通的部分：`dlopen` 引擎 → `wxime_initialize` → `wxime_config_dict`（28 个词典全装载）。

卡点：`wxime_create_session` 在 `ZhMostLikelySequelSearcherV2` 构造函数 +0x330 处，
对 `dict->GetSubDict(7)` 返回的空 shared_ptr 做虚调用 → 段错误。
说明联想词库的某个子词典（label 7）没有注册，最可能来自未正确装载的 cell dict。

## 6. 复现命令

见 `tools/oracle/README.md`。
