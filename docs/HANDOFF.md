# 接手须知

给「接下来要在 Linux 上继续」的人（包括未来的我）。一页读完，知道从哪开始、哪里可能炸。

## 一分钟了解

这是一个从零重写的拼音输入法引擎，跑在 fcitx5 上。**没有复用微信输入法的任何二进制**——
官方实现只用来做行为对照（见 `docs/DATA.md`）。

- 引擎：Rust，`core/`，提供 C ABI
- 插件：C++，`fcitx5-addon/`，调 C ABI
- 语音：Rust，`voice/` + `voice-daemon/`（X11 热键 + 麦克风 + 识别器）；内置微信离线识别（`voice/src/wtlocal/`），首次使用下载约 100MB 模型
- 数据：开源词库（rime-ice），仓库自带简繁表

## 最短上手（5 条）

```bash
cargo test                 # 131 项，应当全绿
./scripts/abi-smoke.sh     # 22 项 C ABI 契约
# 词库（唯一需要自己准备的数据）
git clone --depth 1 https://github.com/iDvel/rime-ice /tmp/rime-ice
python3 tools/rime2tsv.py /tmp/rime-ice/rime_ice.dict.yaml > /tmp/lexicon.tsv
# 试打
cargo run --release -p wowtype-core --bin wowtype-demo -- --lexicon /tmp/lexicon.tsv nihao
```

`nihao` 出「你好」就说明引擎链路正常。装插件见 `docs/INSTALL.md`。

## 三个未验证项

按「最可能出问题」排序。每项都给了怎么验、炸了看什么。

### 1. fcitx5 插件从未编译

```bash
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

**最可能的原因**：头文件包名不对（`libfcitx5core-dev` 没装）、或 `libwowtype_core.so` 没先生成。
API 用法我逐项对过头文件（见 `fcitx5-addon/README.md` 的核对表），签名应该没问题。

### 2. 语音的 X11 热键与采集

`voice-daemon/src/linux.rs` 是 `cfg(target_os = "linux")`，我这边（macOS）根本不编译它。

```bash
cargo build -p wowtype-voiced        # 先看能不能编过
./target/debug/wowtype-voiced --asr-cmd 'echo test'   # 再试运行
```

上屏默认走剪贴板（`ydotool type` 发不出汉字），需要 `xclip`+`xdotool`（X11）或 `wl-clipboard`（Wayland）。

### 3. 排序手感

我只验证了「频率忠实度」和「候选召回」，**没验证人到底想选哪个词**。
真实手感要在你打字几百个字之后才知道。攒一批用例后用 `wowtype-eval` 量化：

```bash
# cases.tsv: 输入<TAB>你实际想要的词
cargo run --release -p wowtype-core --bin wowtype-eval -- --lexicon /tmp/lexicon.tsv --eval cases.tsv
```

## 我踩过的坑（按踩到的顺序）

| 坑 | 结论 | 详情 |
|---|---|---|
| 词库连写不是合法拼音 | `nihao` 不能入库，要写 `ni hao`；非法行**静默跳过**，只记 `skipped()` | `core/src/lexicon.rs` |
| 宽容解析害了补全 | `parse()` 对未知音节宽容，导致补全把 `shesh` 当合法前缀 | `fully_splittable()` |
| 排序重复计权 | `prob`/`lm` 已在 `path.score` 里，再乘权重会压死上下文 | `docs/STATUS.md` |
| 上下文中没有空格 | 只取「最后一个词」会拿整段文本去查 bigram，永远查不到 | 同时试最后一个字 |
| 字级 LM 惩罚长词 | 词表外按近零概率处理，把正确长词压下去 | 改为「无信息」 |
| 补全路径慢 | 32 次完整束搜索 = 17ms | 补全用 beam=6 |
| 模糊音拖慢加载 | 索引建了但默认不用 | 改惰性构建，1.28s -> 更快 |
| `ydotool type` 打不出汉字 | 它靠键码，没有 CJK keysym | 改剪贴板 + Ctrl+V |

## 代码地图

| 文件 | 管什么 |
|---|---|
| `core/src/graph.rs` | 音节图：全拼/简拼/隔音符/儿化 |
| `core/src/beam.rs` | 束搜索与路径打分（词频 + LM + 覆盖率） |
| `core/src/lexicon.rs` | 词库、索引、二进制快照 |
| `core/src/lm.rs` | bigram TSV / ARPA |
| `core/src/rank.rs` | 23 维特征与线性重排（可训练） |
| `core/src/lib.rs` | `Engine`：输入→候选、上下文、用户词、自动学习 |
| `core/src/ffi.rs` | C ABI（插件只用这一层） |
| `fcitx5-addon/src/wowtype_engine.cpp` | fcitx5 集成：按键、候选、提交 |
| `voice/src/asr.rs` | 外部识别器调用（`{wav}` 占位符） |
| `voice/src/sink.rs` | 上屏后端（剪贴板/wtype/ydotool） |

## 数据从哪来

| 数据 | 来源 | 说明 |
|---|---|---|
| 词库 | rime-ice | `tools/rime2tsv.py` 会顺着 `import_tables` 合并 |
| 简繁表 | OpenCC（仓库自带生成物） | `tools/opencc2tsv.py` 可重新生成 |
| 语言模型 | 无 | 自建 `tools/make_bigram.py` 效果为负，别默认开 |
| 用户词库 | 运行时产生 | `~/.local/share/wowtype/user.tsv` |
| 词库快照 | 自动生成 | `lexicon.tsv.wcache`，删了会重建 |

## 继续开发的优先级

1. **真实语言模型**。排序质量最大的变量，也是上下文消歧的前提
2. **让插件编过、跑起来**。所有验证链条的最后一环
3. 神经网络重排（`head_word_nnlm` 目前恒为 0）
4. 词组级简繁（现在只做字符级）

## 别做的事

- 别再把「遍历 trie 导词库」当可行路线——已经证明走不通（`docs/DATA.md` §14.4）
- 别用 `tools/make_bigram.py` 的产物当默认 LM——实测掉点
- 别给补全加回大束宽——质量没提升，延迟翻三倍