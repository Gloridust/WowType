# WowType fcitx5 插件

这是把 WeType（微信输入法）拼音排序思路移植到 Linux 的外壳层：

    fcitx5  ->  libwowtype.so (C++ addon，静态链接 Rust 核心 libwowtype_core.a，经 C ABI 调用)

Rust 核心负责音节图、束搜索、词典/LM 打分和排序；C++ 只负责 fcitx5 的
输入上下文、预编辑、候选面板和按键处理。

## 目录

    fcitx5-addon/
      CMakeLists.txt
      conf/wowtype.conf.in          # 输入法注册（fcitx5 里显示的名字）
      conf/wowtype-addon.conf.in    # addon 动态库注册
      src/wowtype_engine.h
      src/wowtype_engine.cpp        # InputMethodEngineV2 实现 + AddonFactory
      test/key_harness.cpp          # 按键行为测试（私有 fcitx5 实例）
    core/
      include/wowtype_core.h        # C ABI
      src/ffi.rs                    # C ABI 的 Rust 实现
      data/demo_lexicon.tsv         # 演示词典

## 依赖、构建和安装

需要 **Fcitx5 5.1 或更新、C++20 和 Rust**。各发行版的软件包名称、词库准备、安装和桌面启用步骤统一见
[安装说明](../docs/INSTALL.md)。Ubuntu 22.04 默认仓库的 Fcitx5 版本不满足要求。

在仓库根目录构建并安装：

```bash
cargo build --release --locked -p wowtype-core
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build --parallel "$(nproc)"
sudo cmake --install build
```

插件使用 Fcitx5 自己导出的安装目录：Arch 通常为 `/usr/lib/fcitx5`，Fedora/openSUSE
为 `/usr/lib64/fcitx5`，Debian/Ubuntu 为 `/usr/lib/<multiarch>/fcitx5`。
输入法注册文件和系统词库安装到 `<前缀>/share/fcitx5` 和 `<前缀>/share/wowtype`；
自定义前缀（包括 Nix store）使用该前缀自己的目录，不会写入另一个 Fcitx5 包的目录。

仓库只带演示词典；日常使用还需要按安装说明准备完整词库。`scripts/build-linux.sh --addon`
也可构建并测试工作区；缺完整数据时会明确跳过真实数据测试，测试失败会返回非零退出码。

Rust 核心默认**静态链接**进 libwowtype.so，不需要再装 libwowtype_core.so，
Rust 的符号也不导出（`--exclude-libs,ALL`），不会和别的插件冲突。
要动态链接用 `-DWOWTYPE_CORE_STATIC=OFF`（此时会一起装 libwowtype_core.so，RPATH 为 `$ORIGIN/..`）。
文字输入专用构建须同时使用 Cargo 的 `--no-default-features` 和 CMake 的 `-DWOWTYPE_VOICE=OFF`，
才能去掉默认语音功能的 ALSA 依赖。

## 启用

重启 fcitx5：

    fcitx5 -r

然后打开配置工具，添加 WowType：

    fcitx5-configtool

或者在“输入法”页把 WowType 加到当前分组。切换过去后输入 xian，应能看到
“先 / 西安”等候选；输入 zg 会走简拼并给出“中国”。

## 数据

每个文件按这个顺序找，用第一个存在的：环境变量 > `~/.local/share/wowtype/`（`$XDG_DATA_HOME`）> `/usr/share/wowtype/`。

| 文件 | 环境变量 | 说明 |
|---|---|---|
| `lexicon.tsv` | `WOWTYPE_LEXICON` | 词库；都没有时退回 `demo_lexicon.tsv`（只有几十个词） |
| `bigram.tsv` | `WOWTYPE_LM` | bigram（可选） |
| `english.txt` | `WOWTYPE_ENGLISH` | 英文词表（可选）；有了它 hello/github 会排第一 |
| `s2t.tsv` | `WOWTYPE_S2T` | 简繁表，开了繁体输出时用 |
| `custom.tsv` | `WOWTYPE_CUSTOM` | 自定义词（`拼音<TAB>词[<TAB>频次]`），设置界面维护；只在用户目录找 |

不用 root 也能装真实词库和英文词表：

    mkdir -p ~/.local/share/wowtype
    python3 tools/rime2tsv.py rime_ice.dict.yaml > ~/.local/share/wowtype/lexicon.tsv
    cat rime-ice/en_dicts/en.dict.yaml rime-ice/en_dicts/en_ext.dict.yaml \
        > ~/.local/share/wowtype/english.txt
    fcitx5 -r

英文词表直接接受 rime 的 `en.dict.yaml`（「上屏<TAB>编码」），也可以每行一个词。

词库在后台线程载入（全量 89 万条约 0.6 秒，有快照缓存时），不会卡住 fcitx5 启动；
载入完成前打字只显示拼音，空格上屏原始字母。

词典格式（TSV，UTF-8）：

    拼音<TAB>词<TAB>频次
    xian	先	30000
    xi an	西安	20000
    hua r	花儿	3000

- 多音节拼音用空格或隔音符分隔；不要写成无分隔连写（fangan 有歧义）。
- 儿化用独立的 r 标记。

bigram 格式（可选）：

    prev<TAB>cur<TAB>count
    你	好	12345

不传 WOWTYPE_LM 时使用空的 LM，不会影响候选生成。

## 当前边界

- 已在 Ubuntu 26.04 + fcitx5 5.1.19 上编译，按键行为用 `scripts/addon-test.sh` 测过；
  还没装进日常使用的 fcitx5 里实际打字。
- fcitx5 5.1 的头文件要求 C++20。
- 排序是骨架版：词典频次 + bigram + 覆盖率 + 线性特征；LTR（LightGBM）、
  NNLM 重排、MixRank 只有 trait/钩子，没有真实模型。
- 云候选没做。

## 配置

插件读 `~/.config/fcitx5/conf/wowtype.conf`（`CandidateLayout`、`PageSize`、`Fuzzy`、`TypoCorrection`、
`Shuangpin`、`ShuangpinScheme`、`ShiftToggle`、`Traditional`、`Voice`、`VoiceKey`、`CheckUpdate`），`getConfig()` 暴露给 fcitx5 配置工具（`Configurable=True`），
里面的「自定义词和更多设置」是 `ExternalOption`，打开 `wowtype-config`。
设置界面改完调 D-Bus `org.fcitx.Fcitx.Controller1.ReloadAddonConfig("wowtype")`，插件 `reloadConfig()`
重读配置文件和 `custom.tsv`（`wowtype_engine_load_custom_words`），不用重启 fcitx5。

## 环境变量

设了就优先于配置文件，主要给测试用（`scripts/addon-test.sh` 靠它们切换选项）。

| 变量 | 作用 |
|---|---|
| `WOWTYPE_LEXICON` | 词库 TSV 路径（查找顺序见上） |
| `WOWTYPE_LM` | bigram TSV 路径（可选） |
| `WOWTYPE_ENGLISH` | 英文词表路径（可选） |
| `WOWTYPE_USER_DICT` | 用户词库路径，默认 `$XDG_DATA_HOME/wowtype/user.tsv` |
| `WOWTYPE_TYPO` | `0` 关闭按错键纠错（默认开；双拼下不生效） |
| `WOWTYPE_FUZZY` | `1` 开启模糊音 |
| `WOWTYPE_SHUANGPIN` | `1` 使用双拼 |
| `WOWTYPE_SHUANGPIN_SCHEME` | 双拼方案：`ziranma`、`xiaohe`、`microsoft`、`sogou`、`abc`、`ziguang`、`pinyinjiajia`；设了就打开双拼 |
| `WOWTYPE_SHIFT_TOGGLE` | 单按哪个 Shift 切英文：`both`（默认）、`left`、`right`、`off` |
| `WOWTYPE_TRADITIONAL` / `WOWTYPE_S2T` | 繁体输出 / 简繁表路径 |
| `WOWTYPE_VERTICAL` | `1` 候选竖排 |
| `WOWTYPE_VOICE_KEY` | 语音键（fcitx5 键名），`none` 关掉语音 |
| `WOWTYPE_CUSTOM` | 自定义词文件路径 |
| `WOWTYPE_NO_UPDATE_CHECK` | 设了就不在后台检查更新 |

## 交互行为

- 字母 / 隔音符 `'` 进入拼音缓冲，实时出候选；大写字母原样保留（`Hello` 上屏 `Hello`）
- 按错相邻键、两个键按反、多按或漏按一个键都会纠正（`zhognguo` → 中国）
- 长句可以**先选开头的词**：候选里有「句首词」（如 `nihaozhongguo` 的「你好」），
  选了它不上屏，编辑区变成「你好zhongguo」，接着选剩下的；整句选完一起上屏。
  剩余拼音删光后再按 `退格` 撤销上一次选词
- `空格` 上屏光标所在的候选；无候选时上屏原始拼音
- `回车` 上屏已选的词 + 原始拼音
- `1`–`9` 选**当前页**对应的候选
- `↑↓` 移动光标，`PgUp` `PgDn` / `-` `=` 翻页；fcitx5 全局的 `[Hotkey/PrevPage]` `[Hotkey/NextPage]` `[Hotkey/PrevCandidate]` `[Hotkey/NextCandidate]` 也认（方向键除外，它们按横排/竖排走），配成 `,` `.` 时打字途中按它们只翻页，不上屏标点
- 打字途中按标点：先上屏当前候选，再出中文标点（`nihao,` → 你好，）
- 缓冲为空时，ASCII 标点自动转成中文标点；数字直接交给应用
- `/` 等没有对应中文标点的符号原样上屏；打拼音途中按它们，先上屏当前候选（`nihao/` → 你好/）
- 首选候选对得上 emoji 时（`kaixin` → 开心），第三个候选插一个 emoji；`EmojiSuggest=False` 关掉
- `Super+.`（`EmojiKey` 可改）打开表情面板：打拼音或英文搜 emoji 和符号，方向键挑，空格/回车/`1`–`6` 上屏，`Esc` 关闭
- 单按 Shift（按下松开，中间没按别的键、不超过 0.5 秒）切 WowType 自己的英文模式：按键原样交给应用，
  状态栏显示「英」；打到一半切英文时，已选的词 + 原始字母上屏。fcitx5 的「临时切换输入法」热键
  （默认左 Shift）生效时 fcitx5 会先把 Shift 吃掉，两者不会重复切换
- 切换输入法时已选的词 + 原始字母上屏，不会丢。失去焦点时清空编辑区，不往别的窗口上屏
- 双拼时编辑区显示全拼（`vsgo` → `zhong'guo`）；微软、搜狗、紫光的 `;` 是 ing，等第二个键时按 `;` 进编辑区
- 编辑区里 `←→` `Tab` `Delete` 吃掉不处理，免得应用里的光标乱跑

## 选词学习

每次上屏都会调用 `wowtype_engine_record_selection_ex`，带上**纠错后的拼音**
（`wowtype_candidates_pinyin`），选够 3 次自动进用户词库；分几次选出来的整句也记一次。
最近 24 字节的已上屏文本（按 UTF-8 字符边界截）作为上下文传给引擎；
句首词选好后，它也会作为剩余部分的上文。用户词库每 20 次上屏、失去焦点、退出时落盘。

## 测试

    scripts/addon-test.sh [lexicon.tsv] [english.txt]

起一个私有、无界面、无 D-Bus 的 fcitx5 实例（配置目录都在临时目录），只加载 wowtype
和 fcitx5 自带的 testim，用假输入上下文按键并检查上屏结果，不影响正在用的输入法。
用真实词库 + 英文词表时 21 项全过；只用 demo 词典时有 3 项因为缺词失败。

## 已核对的 fcitx5 API（对照 master 头文件）

| 用法 | 头文件 | 结论 |
|---|---|---|
| `InputMethodEngineV2` 的 `keyEvent/activate/deactivate/reset` | `fcitx/inputmethodengine.h` | ✅ 签名一致；V2 只额外加了 `subModeIconImpl/subModeLabelImpl` |
| `CandidateWord::select(InputContext*) const` | `fcitx/candidatelist.h` | ✅ |
| `CandidateList::size()/candidate(i)/cursorIndex()`；翻页在 `toPageable()`，移光标在 `toCursorMovable()` | 同上 | ✅ 5.1.19 上编译通过 |
| **`CandidateList::keyEvent`** | 同上 | ❌ **不存在**，原来调用它的代码必然编译失败，已改为手动映射按键 |
| `CandidateList::append<T>(args...)` | 同上 | ✅ 模板转发 |
| `CommonCandidateList::setPageSize/setLayoutHint` | 同上 | ✅ |
| `InputPanel::setPreedit/setCandidateList/reset` | `fcitx/inputpanel.h` | ✅ |
| `InputContext::commitString/updatePreedit/updateUserInterface/inputPanel` | `fcitx/inputcontext.h` | ✅ |
| `InputContextManager::registerProperty(name, factory*)` | `fcitx/inputcontextmanager.h` | ✅ 第二参数是 `InputContextPropertyFactory*` |
| `FactoryFor<T>` | `fcitx/inputcontextproperty.h` | ✅ 就是 `LambdaInputContextPropertyFactory<T>` |
| `AddonFactory::create(AddonManager*)` | `fcitx/addonfactory.h` | ✅ |
| `FCITX_ADDON_FACTORY_V2(name, cls)` | `fcitx/addoninstance.h`（被 addonfactory.h 引入） | ✅ 宏存在 |

### 翻页的正确写法

fcitx5 不会替你处理候选翻页，引擎必须自己把按键映射过去。翻页和移动光标不在
`CandidateList` 上，要先转成对应的接口；`candidateList()` 返回的是 `shared_ptr`：

```cpp
if (auto list = ic->inputPanel().candidateList()) {
    if (auto *movable = list->toCursorMovable(); movable && sym == FcitxKey_Down)
        movable->nextCandidate();
    if (auto *pageable = list->toPageable(); pageable && pageable->hasNext())
        pageable->next();
    list->candidate(i).select(ic);   // i 是当前页内的下标
}
```
