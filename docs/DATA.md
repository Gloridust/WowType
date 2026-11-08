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
