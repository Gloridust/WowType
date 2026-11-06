# Wowtype

把微信输入法（WeType）的输入体验搬到 Linux：拼音 + 语音，跑在 fcitx5 上。

> 状态：**算法与框架就绪，数据管线在建。** 文字输入的引擎骨架可运行、有测试；
> 语音的可测核心完成；Linux 平台层（X11 热键、麦克风采集）是脚手架，需要在
> Linux 实机上收尾。

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

```bash
# 1. 系统依赖
sudo apt install -y build-essential pkg-config libasound2-dev libx11-dev \
  extra-cmake-modules libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev

# 2. 测试核心算法
cargo test -p wowtype-core -p wowtype-voice

# 2.5 验证 C ABI（fcitx5 插件依赖的就是这套）
./scripts/abi-smoke.sh

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
python3 tools/rime2tsv.py rime_ice.dict.yaml > lexicon.tsv
cargo run -p wowtype-core --bin wowtype-demo -- --lexicon lexicon.tsv nihao
```

引擎支持**半成品输入**：尾部还没成音节时会自动补全（`nih` → 你好，`zhongg` → 中国），
不会出现"打到一半没有候选"。

支持**模糊音**（默认关闭）：`--fuzzy` 或 `WOWTYPE_FUZZY=1` 开启后，
`zidao` → 知道（zh/z）、`sangdian` → 商店（ang/an）。覆盖平翘舌与前后鼻音。

英文/未登录串会把原始输入本身作为候选（保留大小写）：`hello` → `hello`，
纯拼音输入被完整覆盖时不会插入原始串。

支持**双拼**（自然码，默认关闭）：`--shuangpin` 或 `WOWTYPE_SHUANGPIN=1`。
`vsgo` → 中国，`nihk` → 你好；自然码里少量重叠码（如 `jp`）会同时展开成多种全拼再合并候选。

语言模型支持三种来源：内置一元回退、bigram TSV（`--lm`）、ARPA（`--arpa`）。
WeType 自己的 `lmcnmac.bin` 因为只存哈希、无法导出，见 [docs/DATA.md](docs/DATA.md)。

## 性能

合成 10 万条词库压测（`cargo run --release -p wowtype-core --bin wowtype-bench`，M 系列 Mac）：

| 输入 | 耗时 |
|---|---|
| 载入 10 万条词库 | ~140 ms（一次性） |
| `a` | 0.003 ms |
| `zhong` | 0.14 ms |
| `zhongguo` | 0.03 ms |
| `zhongg`（半成品，触发 32 路补全） | 0.19 ms |

交互预算（<10ms）有很大余量。

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
