# 设置与配置

## 自定义词

加进去的词总是排在候选第一个，简拼也能打：加了「字节跳动」（`zi jie tiao dong`），打 `zijietiaodong` 或者 `zjtd` 都能出来。

自定义词存在 `~/.local/share/wowtype/custom.tsv`，一行一个，也可以手动编辑：

```
# 编码<TAB>词[<TAB>频次]
zi jie tiao dong	字节跳动
zhangwei	张伟
mail	hello@example.com
di zhi	四川省\n宜宾市
```

- 编码一般是拼音，可以用空格隔开音节，也可以连着写（`zhangwei`）。
- 编码也可以不是拼音，只要全是字母（`mail`、`addr`）：正好打这几个字母时，这个词排第一。
- 词里写 `\n` 表示换行、`\t` 表示制表符，上屏时换成真的；候选窗里画成 `⏎`。带换行的词不记进自动学习。
- 设置界面「自定义词」页右上角能**导入**、**导出**这种文件。导入时同一个词用文件里的编码，别的词保留。
- 自定义词也是**常用语**：只打一个 `v` 再按空格打开[工具栏](#v--空格工具栏)，「常用语」里按文件顺序列出全部，选一条上屏。

在设置界面里加的词马上能用；手动改了文件，要让 fcitx5 重新读一下：

```bash
dbus-send --session --dest=org.fcitx.Fcitx5 /controller \
  org.fcitx.Fcitx.Controller1.ReloadAddonConfig string:wowtype
```

手动改 `wowtype.conf` 也一样。（重启 fcitx5 也行，但 Chrome 这类程序要跟着重开，见[第 3 步](#第-3-步把-wowtype-加进输入法列表)。）

## 互译

在设置界面「翻译」里下载本地模型，或者在「用什么翻译」里选「自定义翻译服务」填一个 OpenAI 格式（`chat/completions`）的接口，打开「互译」，
单按 Shift 就在 **中 → 英 → 译 → 中** 之间切换（没填好服务时只在中英之间切）。
左 Shift 被 fcitx5 拿去「临时切换输入法」时切不到「译」，用右 Shift，或在设置「输入」页打开「Shift 只给 WowType 用」。

切到「译」后照常打中文，用起来和微信输入法的「中英互译」一样：打的字攒在候选框里（顶上写着「中→英 互译」），
不上屏；停 0.5 秒（打了句号、问号就立刻）发给服务，译文边出边写进输入框（带下划线），只给一种。
接着打字时输入框里先留着上一句的译文，新的出来再换。

| 键 | 作用 |
|---|---|
| `回车`、`空格` | 上屏译文；还没译完就等译好了自动上屏 |
| `Shift+回车` | 上屏原文 |
| `退格` | 删原文最后一个字，停一下重新翻 |
| `Esc` | 清空原文 |
| 单按 `Shift` | 回到中文，原文原样上屏 |

- 打的是外文（比如英文）就翻成中文。数字、`/` `+` 这些符号也进原文。
- 同一句话翻过一次会记住（最近 64 句），再打不用等。出错时候选框底下写原因，按回车重试。
- 有的程序不让输入法把编辑区画在它的输入框里，这时译文写在候选框最下面一行。
- **打的字会发给你填的服务**（WowType 自己不经手）。密码框里不翻译。
- API Key 存在 `~/.config/wowtype/translate.key`（权限 0600，只有自己能读），不写进 `wowtype.conf`、不进日志。
  手动写也行：一行，就是 Key 本身。本机的服务（Ollama 等）可以不填。
- 发请求用的是系统的 `curl`（没装的话装一下），走系统的代理设置；连本机的服务不走代理。
- 打字时要等它翻译，挑又小又快的模型（各家的 mini、flash、turbo 版）；推理模型会慢很多。
  设置里的「测试连接」会显示一次要多久。

### 本地模型（离线）

不想把字发出去，可以在「翻译」页的「用什么翻译」里选「本地模型（离线）」（设置里默认就是它），用腾讯混元的翻译模型
[HY-MT 1.5 1.8B](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF)（Q4_K_M，1.13 GB）在本机翻：

- 模型点「下载」获取，放在 `~/.local/share/wowtype/models/`（`TranslateLocalModel` 写了位置就下到那里），下载完校验 SHA256，断了再点会接着下（接着下时不用再确认许可）。两端一样。
  命令行也行：`wowtype-config --download-model`（加 `--accept-license` 跳过确认）。
- 跑模型用 llama.cpp 的 `llama-server`，不用自己装：系统里没有时，下载模型会顺带从
  [llama.cpp 的发布页](https://github.com/ggml-org/llama.cpp/releases)下载官方程序（x86_64 约 22 MB、
  arm64 约 18 MB，MIT 许可，钉死一个版本并校验 SHA256），解到 `~/.local/share/wowtype/llama/`，
  设置里能删。它要 glibc 2.34 以上（Ubuntu 22.04、Debian 12、Fedora 35 起都满足）。
- 找 `llama-server` 的顺序：设置里填的路径 → `PATH`（发行版的 llama.cpp 包）→ 上面下载的那份。
  NixOS 跑不了官方程序，设置里不提供下载，在系统配置里装 `pkgs.llama-cpp`。
- 第一次翻译时才启动 `llama-server`（只监听 127.0.0.1 的随机端口，载入要几秒），
  闲置 `TranslateIdleMinutes` 分钟（默认 5）后停掉，内存还回去；关掉互译或退出 fcitx5 时也停。
  翻译时 llama-server 占 1.5 GB 左右内存，一句话 1–3 秒。
- **许可**：模型用的是腾讯混元社区许可协议（Tencent HY Community License），不是开源协议。
  它**不适用于欧盟、英国和韩国**；月活超过 1 亿的产品要另找腾讯授权。WowType 不分发这个模型，
  是你自己从 Hugging Face 下载，下载前设置界面会让你确认。[协议全文](https://huggingface.co/tencent/HY-MT1.5-1.8B/blob/main/License.txt)

## v + 空格：工具栏

全拼下只打一个 `v`、再按空格，打开工具栏（`vim`、`vscode` 这些照常打字，`v1+2*3` 照常算算式）：

| 项 | 内容 |
|---|---|
| 剪贴板 | 最近复制过的文字，最新的在前，最多 20 条 |
| 常用语 | [自定义词](#自定义词)，按 `custom.tsv` 里的顺序 |
| 符号 | 全部内置符号；也能打拼音搜（`youjiantou` → →） |
| 表情 | 和 `Super+.`（macOS 上是 `Control+.`）打开的表情面板一样 |

数字键或方向键加空格/回车选择，退格返回上一层，Esc 关闭；工具栏开着时别的键不会打进应用，`Ctrl+C` 这类组合键会收起工具栏、交给应用。

**剪贴板历史默认关**，在设置「输入」页打开「记录剪贴板历史」（`ClipboardHistory=True`）。打开后只在内存里记，不写到磁盘，重启 fcitx5 就清空；再关掉时立刻清空。

WowType 自己读不到系统剪贴板，是从 fcitx5 自带的 clipboard 插件拿最新一条：打开工具栏、切换输入框时各取一次，所以连着复制了好几次、中间没切换输入框的话，只记得到最后一次。没装或关掉了 fcitx5 的 clipboard 插件就没有记录。

**密码**：光标在密码框里时不取剪贴板。但从密码管理器复制的密码，fcitx5 自己的剪贴板会显示成圆点、30 秒后清掉，它对外给输入法的接口却不带「这是密码」的标记，所以 WowType 分不出来，会把它当普通文字记下、在工具栏里明文显示，直到重启 fcitx5 或关掉这个开关。常用密码管理器的话，建议保持关闭，或者在 fcitx5 的剪贴板设置里打开「Do not show password from password managers」（这样 fcitx5 根本不收这类内容）。

互译模式（「译」）下不开工具栏。macOS 上的不同见下面的 [macOS](#macos)。

## 配置文件和环境变量

设置存在 `~/.config/fcitx5/conf/wowtype.conf`，设置界面和 Fcitx 5 配置改的都是这个文件：

```ini
CandidateLayout=Horizontal
PageSize=9
Fuzzy=False
FuzzyZh=True
FuzzyCh=True
FuzzySh=True
FuzzyNL=False
FuzzyFH=False
FuzzyRL=False
FuzzyAn=True
FuzzyEn=True
FuzzyIn=True
FuzzyIan=True
FuzzyUan=True
FuzzyUn=False
TypoCorrection=True
RareExtChars=False
Shuangpin=False
ShuangpinScheme=Ziranma
ShuangpinShowKeys=False
ShiftToggle=Both
InitialMode=Chinese
Traditional=False
SelectKeys=Off
PickChar=True
DateTime=True
Calculator=True
Toolbar=True
ClipboardHistory=False
AutoSpace=False
AutoSpaceLetters=True
AutoSpaceDigits=True
Voice=True
VoiceKey=Alt_R
VoiceCopy=False
EmojiSuggest=True
EmojiKey=Super+period
Translate=False
TranslateTarget=en
TranslateBaseUrl=
TranslateModel=
TranslateFormal=False
TranslateLocal=True
TranslateLocalModel=
TranslateLlamaServer=
TranslateIdleMinutes=5
CheckUpdate=True
Lexicon=
```

| 键 | 取值 |
|---|---|
| `CandidateLayout` | `Horizontal` 横排、`Vertical` 竖排 |
| `PageSize` | 每页候选个数，3–9 |
| `Fuzzy`、`TypoCorrection`、`Shuangpin`、`Traditional`、`DateTime`、`Calculator`、`Toolbar`、`ClipboardHistory`、`Voice`、`VoiceCopy`、`EmojiSuggest`、`Translate`、`TranslateFormal`、`CheckUpdate` | `True` / `False` |
| `AutoSpace`、`AutoSpaceLetters`、`AutoSpaceDigits` | 中英文之间自动加空格：总开关（默认关）、汉字和字母之间、汉字和数字之间。要应用报告光标前的文字才生效（终端等不支持），密码、网址、邮箱输入框不加 |
| `FuzzyZh`、`FuzzyCh`、`FuzzySh`、`FuzzyNL`、`FuzzyFH`、`FuzzyRL`、`FuzzyAn`、`FuzzyEn`、`FuzzyIn`、`FuzzyIan`、`FuzzyUan`、`FuzzyUn` | 模糊音的各组（z=zh、c=ch、s=sh、n=l、f=h、r=l、an=ang、en=eng、in=ing、ian=iang、uan=uang、un=ong），`Fuzzy` 打开时才生效 |
| `SelectKeys` | 分号、引号选词：`Off`、`Semicolon`（`;` 选第 2 个）、`SemicolonQuote`（再加 `'` 选第 3 个，引号不再当隔音符） |
| `RareExtChars` | 也出 CJK 扩展 B 区及以后的单字（比如 `hou` 的 𠯜），默认关：常见中文字体（Noto CJK、思源、苹方）都没有这些字，列出来是方块。打开前先装能显示它们的字体，比如 Ubuntu / Debian 的 `fonts-hanazono`。通用规范汉字表里的扩展区字（𬭩、𫚔，约 200 个，常见字体都有）和含这些字的词（𩽾𩾌）不受这个开关影响 |
| `PickChar` | 以词定字：打拼音时 `[` 上屏光标处候选的第一个字、`]` 上屏最后一个字，默认开；翻页键设成 `[ ]` 时让给翻页 |
| `ShuangpinScheme` | 双拼方案：`Ziranma` 自然码、`Xiaohe` 小鹤、`Microsoft` 微软、`Sogou` 搜狗、`ABC` 智能 ABC、`Ziguang` 紫光、`PinyinJiajia` 拼音加加 |
| `ShuangpinShowKeys` | 双拼时编辑区显示打的键（`uivs`），不翻成全拼（`shi'zhong`），中英混打时看得出打了什么。默认 `False` |
| `ShiftToggle` | 单按哪个 Shift 切中英文：`Both`、`Left`、`Right`、`Off`。fcitx5 自己的全局快捷键（「临时切换输入法」「切换输入法」「向前切换输入法」等任何一项）里用了同一个 Shift 时，fcitx5 先处理，WowType 收不到；设置界面「输入」页会提示，并能一键把 Shift 从 fcitx5 那边去掉（改的是 `~/.config/fcitx5/config`，关掉开关就还原；这个文件写不了时提示「只在这次有效」，NixOS 见[安装说明](INSTALL.md#单按-shift-在-nixos-上)） |
| `InitialMode` | 从别的输入法切到 WowType、开机后第一次用时的模式：`Chinese`（默认）、`English`、`Last`（和上次切走时一样）。换窗口不算，中英文照旧全局保持；关了 Shift 切换（`ShiftToggle=Off`）时总是中文。只在 Linux（macOS 每个应用一份模式，还没有这一项） |
| `VoiceKey` | fcitx5 的键名，如 `Alt_R`、`Control_R`、`Menu`、`F8` |
| `EmojiKey` | 表情面板快捷键，fcitx5 的键名，如 `Super+period`、`Control+semicolon`；留空不用快捷键。macOS 上默认 `Control+period`，`Super` 当 `Control`（见 [macOS](#macos)） |
| `TranslateTarget` | 互译语言：`en` 英、`ja` 日、`ko` 韩、`fr` 法、`de` 德、`es` 西、`ru` 俄、`pt` 葡、`it` 意、`vi` 越、`th` 泰、`id` 印尼、`ar` 阿 |
| `TranslateBaseUrl`、`TranslateModel` | 翻译服务（OpenAI 格式）的地址和模型，见[互译](#互译) |
| `TranslateLocal` | `True` 用本地模型（默认），`False` 用 `TranslateBaseUrl` 的翻译服务。配置文件里没写这一项、又填了 `TranslateBaseUrl` 时当 `False`（0.3.10 及以前填过翻译服务的照旧用服务）；Linux 插件、设置界面和 macOS 都这样 |
| `TranslateLocalModel` | 本地模型文件，留空用 `~/.local/share/wowtype/models/HY-MT1.5-1.8B-Q4_K_M.gguf`，见[本地模型](#本地模型离线) |
| `TranslateLlamaServer` | `llama-server` 的路径，留空先在 `PATH` 里找，再用设置里下载的那份 |
| `TranslateIdleMinutes` | 本地模型闲置几分钟后释放，0–240，0 表示不自动释放 |
| `Lexicon` | 词库文件路径，留空用默认的雾凇词库（查找顺序见[数据文件](#数据文件)）。设置界面切到万象时写的是 `~/.local/share/wowtype/dicts/wanxiang/lexicon.tsv`，见[可选词库](#可选词库万象拼音)。文件不存在时退回默认词库；环境变量 `WOWTYPE_LEXICON` 优先 |

文件不存在、或者少写了哪一项，就用默认值（就是上面这些）。注释要单独写一行（`#` 开头），不能写在值后面。

三端（Linux 插件、设置界面、macOS）读这个文件的规矩一样：

- 开关只认 `True` / `False`，选项区分大小写（`Horizontal`，不是 `horizontal`）；写错了、认不出的用默认值。
- 数字超出范围夹到边上（`PageSize=12` 读成 9），认不出的数字用默认值。
- 键和值两边的空格不算（`PageSize = 5` 读成 5）。
- `[分组]`（比如 fcitx5 的 `[Hotkey]`）下面的行不是设置项；设置界面写回文件时原样留着。
- 两边带双引号的值去掉引号，`\\`、`\"`、`\n` 还原成反斜杠、引号、换行。

**改设置项（加键、改名、改默认值、范围、可选值）要先改规格 [`spec/config.json`](../spec/config.json)**（可选词库包的规矩在
[`spec/lexicon-pack.json`](../spec/lexicon-pack.json)），Linux 插件、设置界面、macOS 三端的测试都拿它对照，哪一端没跟上 CI 就挂：
插件在 `scripts/addon-test.sh`、设置界面在 `scripts/test-config-contract.py`、macOS 在 `macos/test.sh`。
两端故意不一样的（比如 `EmojiKey` 的默认值）、只有一端有的项，规格里都写了原因。

下面这些环境变量主要是**调试和测试用**，设了的话**优先于**配置文件（在设置界面里改了也不起作用），平时用不着：

| 变量 | 作用 |
|---|---|
| `WOWTYPE_FUZZY=1`、`WOWTYPE_SHUANGPIN=1`、`WOWTYPE_TRADITIONAL=1`、`WOWTYPE_TYPO=0`、`WOWTYPE_VERTICAL=1`、`WOWTYPE_EMOJI=0`、`WOWTYPE_DATETIME=0`、`WOWTYPE_CALC=0`、`WOWTYPE_TOOLBAR=0`、`WOWTYPE_CLIPBOARD_HISTORY=0`、`WOWTYPE_VOICE_COPY=1` | 对应上面的开关 |
| `WOWTYPE_AUTOSPACE` | 自动加空格的位掩码：1 汉字和字母之间、2 汉字和数字之间，`3` 两种都加，`0` 关 |
| `WOWTYPE_FUZZY_GROUPS` | 模糊音分组的位掩码（1 z/zh、2 c/ch、4 s/sh、8 n/l、16 f/h、32 r/l、64 an/ang、128 en/eng、256 in/ing、512 ian/iang、1024 uan/uang、2048 un/ong） |
| `WOWTYPE_SELECT_KEYS` | `off`、`semicolon`、`quote` |
| `WOWTYPE_SHUANGPIN_SCHEME` | 双拼方案（`xiaohe`、`microsoft` 等，大小写都行），设了就当作打开双拼 |
| `WOWTYPE_SHIFT_TOGGLE` | `both`、`left`、`right`、`off` |
| `WOWTYPE_VOICE_KEY` | 语音键（fcitx5 键名）；`none` 关掉语音 |
| `WOWTYPE_VOICE_OVERLAY=0` | GNOME 上也不用语音浮条，用候选框里的文字提示 |
| `WOWTYPE_LEXICON`、`WOWTYPE_ENGLISH` | 词库、英文词表路径（默认的查找顺序见下） |
| `WOWTYPE_LM` | 词级语言模型，默认找 `words.lm`（`wowtype-lmbuild` 生成），也认旧的 `前词<TAB>后词<TAB>次数` 文本 |
| `WOWTYPE_S2T` | 简繁对照表，默认 `/usr/share/wowtype/s2t.tsv` |
| `WOWTYPE_USER_DICT`、`WOWTYPE_HISTORY`、`WOWTYPE_CUSTOM` | 自动学到的词、输入习惯、自定义词的文件路径 |
| `WOWTYPE_VOICE_MODEL_DIR` | 语音模型目录，默认 `~/.local/share/wowtype/wtlocal`（插件和设置界面都认） |
| `WOWTYPE_NNLM` | 神经语言模型路径，默认 `~/.local/share/wowtype/wetype/nlrgpt2_nnlm.bin` |
| `WOWTYPE_DOMAIN_LM` | 领域词级模型路径，默认数据目录下的 `words.domain.lm`；没有就不混 |
| `WOWTYPE_NO_UPDATE_CHECK=1` | 不自动检查更新，也不自动打开默认主题 |
| `WOWTYPE_LOG` | 日志文件路径，默认 `~/.local/state/wowtype/wowtype.log`；`0` 不写 |
| `WOWTYPE_TRANSLATE=1`、`WOWTYPE_TRANSLATE_URL`、`WOWTYPE_TRANSLATE_MODEL`、`WOWTYPE_TRANSLATE_TARGET` | 互译开关、服务地址、模型、语言 |
| `WOWTYPE_TRANSLATE_KEY_FILE` | 互译 Key 文件，默认 `~/.config/wowtype/translate.key` |

临时试一下：`WOWTYPE_FUZZY=1 fcitx5 -r -d`。长期用写进 `~/.config/environment.d/wowtype.conf`，注销重新登录后生效。

### macOS

macOS 上的设置在 `~/Library/Application Support/WowType/wowtype.conf`，**键名、取值、默认值和上面一样**（只有 `EmojiKey` 的默认值不同，见下），Linux 上的文件拷过去就能用。
点菜单栏里的 WowType 图标 →「WowType 设置…」打开设置窗口（页面和 Linux 的设置界面一样：常规、输入、表情、语音、翻译、自定义词，
macOS 还没有的功能不列）。窗口只改它认识的键，文件里的注释、不认识的键（检查更新这些）、`[分组]` 原样留着，
改过的文件拿回 Linux 照样能用。也可以直接改文件：设置窗口的「文件」菜单 →「用文本编辑打开设置文件」，
还没有文件时会写出一份全是默认值、带说明的。窗口开着时在别处改了文件，切回窗口会重新读，不会被窗口里的旧值盖掉。
改完下一次按键时生效，不用重启；换了 `Lexicon` 会在后台重新载入词库，载完之前照旧用原来的。

现在认的项：`CandidateLayout`、`PageSize`、`PageKeys*`、`SelectKeys`、`PickChar`、`Fuzzy` 和 `Fuzzy*` 各组、`TypoCorrection`、`RareExtChars`、
`Shuangpin`、`ShuangpinScheme`、`ShuangpinShowKeys`、`ShiftToggle`、`Traditional`、`PunctuationStyle`、`DateTime`、`Calculator`、`EmojiSuggest`、
`AutoSpace*`、`Lexicon`、`Toolbar`、`ClipboardHistory`、`EmojiKey`、`Voice`、`VoiceKey`、`VoiceCopy`、`Translate` 和 `Translate*` 各项，另外有一项只有 macOS 有的 `CandidateFontSize`（候选字号，10–40 磅，默认 17；Linux 上字号跟着 fcitx5 主题）。
检查更新 macOS 还没做，对应的项写了也不起作用。

[工具栏](#v--空格工具栏)和表情面板和 Linux 上一样用，不同的是：

- **表情面板快捷键默认 `Control+.`**（`EmojiKey=Control+period`）。Command 组合键多半被应用的菜单先拿走、到不了输入法，
  所以写 `Super` 的当 `Control` 用：Linux 的默认值 `Super+period` 拷过来就是 `Control+.`。也可以换成 `Control+semicolon`、`Alt+semicolon`（`Alt` 是 Option）这类，留空不用快捷键。
- **剪贴板历史**（默认关，`ClipboardHistory=True` 打开）直接读系统剪贴板：切换输入框、打开工具栏的「剪贴板」页时各看一眼，有新复制的文字就记下（只在内存里，退出输入法就清空，关掉开关立刻清空）。
  连着复制了好几次、中间没切换输入框的话，只记得到最后一次。
- **密码**：密码框里系统不让输入法工作，取不到。很多密码管理器（比如 1Password、KeePassXC）复制密码时会给剪贴板标上 `org.nspasteboard.ConcealedType`，
  带这个标记（还有 `TransientType`、`AutoGeneratedType`）的不记；没按这个约定标记的密码管理器复制的密码会被记下、在工具栏里明文显示，用这类密码管理器的话保持关闭。
  新版 macOS 读剪贴板时可能会问要不要允许 WowType 读，不允许就没有记录。

- 自定义词在同一个目录的 `custom.tsv`，格式和 [Linux 的](#自定义词)一样；菜单里「自定义词…」打开设置窗口的自定义词页
  （加词时自动填拼音，能删、导入、导出），保存后下一次按键时生效。
- `AutoSpace` 只在应用告诉输入法光标前是什么字时才加（很多应用不告诉，这时不猜）。
- [互译](#互译)用法和 Linux 一样（单按 Shift 中 → 英 → 译 → 中，原文在候选框顶上，译文写在输入框里）。在 `wowtype.conf` 里写
  `Translate=True` 和 `TranslateBaseUrl`、`TranslateModel`（设置窗口的「文件」菜单能用文本编辑打开它）；API Key 用菜单里的「设置互译 API Key…」填，
  存在同一个目录的 `translate.key`（0600，只有自己能读），不写进 `wowtype.conf`。系统开着安全输入（密码框）时照常打中文，不翻译。
- 本地模型（`TranslateLocal=True`）：和 Linux 一样一键下载。设置窗口「翻译」页选「本地模型（离线）」，点「下载」，
  确认许可后模型（1.13 GB）下到数据目录的 `models/`（`TranslateLocalModel` 写了位置就下到那里），下完校验 SHA256，断了再点会接着下；好了那一行写「已就绪」。
  找不到 `llama-server` 时一起下载 llama.cpp 官方的 macOS 程序（和 Linux 同一个构建，Apple 芯片约 17 MB、Intel 约 12 MB，MIT 许可，钉死 SHA256），
  只解出 `llama-server` 和它的动态库到数据目录的 `llama/`，跑一次 `--version` 确认能用，不用 `brew install llama.cpp`。
  官方程序要 macOS 13.3 以上，更老的系统要自己装 llama.cpp。
  命令行也行：`"~/Library/Input Methods/WowType.app/Contents/MacOS/WowType" --download-model`（加 `--accept-license` 跳过确认）。
  模型文件的位置（`TranslateLocalModel`）、llama-server 的位置、闲置几分钟释放、删除模型都在「更多选项」里。
  `TranslateLlamaServer` 留空时依次找数据目录的 `llama/llama-server`、`/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`（输入法是系统启动的，
  `PATH` 里没有 Homebrew）。模型的许可和上面[本地模型](#本地模型离线)说的一样：不是开源协议，**不适用于欧盟、英国和韩国**。
- [语音输入](../README.md#语音输入)用法和 Linux 一样：按住语音键说话，松开就上屏；点一下语音键开始说，停顿一会儿自动上屏；Esc 取消。
  - 语音键默认右 Option（`VoiceKey=Alt_R`，键名和 Linux 一样，一份配置两边通用），还能选右 Control、F8–F10。
    Mac 键盘没有菜单键，Linux 上的 `VoiceKey=Menu` 拷过来不起作用，设置里会标出来。
    右 Option 按下就开始听，Option+方向键这类组合会让麦克风亮一下就停；F8–F10 在笔记本上默认是媒体键，
    要在「系统设置 → 键盘」里打开「将 F1、F2 等键用作标准功能键」。
  - 模型和 Linux 是同一个：设置窗口「语音」页点「下载」，从腾讯的服务器下载微信输入法的离线语音包（约 103 MB），
    校验后解到数据目录的 `wtlocal/`（约 130 MB），断了再点会接着下。和这台电脑装没装微信输入法无关，WowType 不分发它。
    命令行：`WowType --install-voice-model`（也接受下载好的 `.apk`）、`--remove-voice-model`。
  - 还没下载模型时按语音键只提示去设置里下载，不碰麦克风。第一次说话时系统会问要不要允许 WowType 使用麦克风
    （下载完模型时设置窗口会先问一次）；WowType 更新后系统可能会再问一次。在本机识别，录音不上传。
  - `VoiceCopy=True` 时说的话上屏后也复制到剪贴板（密码框里不复制）。
- 上面的环境变量 macOS 不认（输入法是系统启动的，拿不到你设的环境变量）。

## 数据文件

词库和英文词表按这个顺序找，用第一个找到的：环境变量 → 配置里的 `Lexicon`（只管词库） → `~/.local/share/wowtype/` → `/usr/share/wowtype/`。
都找不到时用只有十几个词的演示词库（能打 `nihao`，但没法日常用）。

| 文件 | 内容 |
|---|---|
| `lexicon.tsv` | 词库，一行一个：`拼音（空格分隔）<TAB>词<TAB>词频` |
| `english.txt` | 英文词表 |
| `words.lm` | 词级语言模型（哪些词常连着用），有它长句更准；安装包里自带，见下 |
| `custom.tsv` | [自定义词](#自定义词)：在设置里加的词 |
| `user.tsv` | 自动学到的新词：分几次选出来拼成的词（四个字以内，比如「霜」「频」「阁」）用一次就收进来；一次打出来的词选够 3 次才收 |
| `history.tsv` | 输入习惯：选过哪些词、哪些词常连着用 |
| `emoji-recent.txt` | 最近用过的 emoji（表情面板里排最前） |
| `lexicon.tsv.wcache` | 词库快照，让第二次启动更快（约 0.3 秒）；删了会自动重建 |
| `wtlocal/` | 语音模型（约 130MB），在设置的「语音」页下载或删除；没有它语音输入打不开，按语音键只提示去下载 |
| `dicts/wanxiang/` | 可选：万象词库包（`lexicon.tsv`、许可证、来源说明），在设置里下载，见下 |
| `wetype/nlrgpt2_nnlm.bin` | 可选：微信输入法的神经语言模型（16MB），有它整句候选更准，见下 |
| `words.domain.lm` | 可选：自己训的领域词级模型，和 `words.lm` 混着用，见下 |

**词级语言模型**：`words.lm` 记的是「哪两个词常连着出现」，束搜索靠它把长句拼对。
安装包里自带一份（38 MB，装到 `/usr/share/wowtype/words.lm`，许可证 CC BY-SA 4.0），
是用清华的对话语料 [LCCC](https://huggingface.co/datasets/thu-coai/lccc)（MIT）加中文维基百科（CC BY-SA 4.0）训练的，
单独下载见 [Release lm-2026.11.09](https://github.com/Gloridust/WowType/releases/tag/lm-2026.11.09)。
载入约 0.06 秒，多占约 90 MB 内存，对按键速度几乎没有影响。想用自己的语料重新训练：

```bash
cargo run --release -p wowtype-core --bin wowtype-lmbuild -- \
    --lexicon ~/.local/share/wowtype/lexicon.tsv --s2t /usr/share/wowtype/s2t.tsv \
    --out ~/.local/share/wowtype/words.lm lccc.txt wiki.txt
```

语料是纯文本、一行一段，繁体会转成简体。约 12 亿字、8 线程要 14 分钟，内存峰值约 3GB。

**神经语言模型（可选）**：微信输入法自带一个按字预测下一个字的小模型（`nlrgpt2_nnlm.bin`），
WowType 能读它来给整句候选重排（日常整句的首选命中率从约 75% 提到约 84%，每次按键多 2ms 左右）。
模型是腾讯的，WowType 不分发；手上有微信输入法 macOS 版（3.0.0）的安装包或程序时，运行
`python3 tools/install_wetype_nnlm.py <WeType 的 .zip 或 .app>` 取出来，重启 fcitx5 生效。

**领域词级模型（可选）**：手上有一批某个领域的语料（工作群聊天、某个专业的文档）时，可以用同一个工具训一个小模型，
放进数据目录叫 `words.domain.lm`，和 `words.lm` 按 6:4 混着用，这个领域里常连着用的词排得更靠前。
安装包里没有这个文件，不放就不混；macOS 放在 `~/Library/Application Support/WowType/words.domain.lm`。
语料只有几万句时把门槛调低：

```bash
cargo run --release -p wowtype-core --bin wowtype-lmbuild -- \
    --lexicon ~/.local/share/wowtype/lexicon.tsv --min-unigram 8 --min-count 2 \
    --out ~/.local/share/wowtype/words.domain.lm corpus.txt
```

拿 Tatoeba 的 7.8 万句训的模型（1.3 万词，0.5MB）试过：Tatoeba 留出 2000 句 top1 从 1194 句到 1266 句；
领域外不掉——手写日常句 138 句 119 -> 122，带上文的 533 例 472 -> 474，热词 351 个 312 -> 321。
涨的主要在训练语料那个领域。重启 fcitx5（macOS 重新登录或重启输入法）生效。

想清空学到的东西：退出 fcitx5，删掉 `~/.local/share/wowtype/user.tsv` 和 `history.tsv`，再启动（自定义词不受影响）。

### 可选词库：万象拼音

默认词库是[雾凇拼音](https://github.com/iDvel/rime-ice)（约 89 万词，随安装包一起装好）。
另外可以换成从[万象拼音](https://github.com/amzxyz/rime_wanxiang)转换的词库（约 168 万词，CC BY 4.0），词更多。
它不在安装包里，每次发版作为单独的 `wowtype-data-wanxiang-<版本>.tar.gz` 放在 Release 上。

- **切换**：「WowType 设置 → 输入 → 词库」里选「万象拼音」，第一次会下载（约 20 MB，对照 `SHA256SUMS` 校验），装到 `~/.local/share/wowtype/dicts/wanxiang/`，几秒后生效，不用重启 fcitx5。选回「雾凇拼音」就切回去，万象的文件可以在同一个地方删掉。
  没网时可以用「从文件安装」选手动下载的 `.tar.gz`。
- **命令行**：`wowtype-config --install-lexicon wanxiang`（下载并切过去，也接受本地 `.tar.gz` 路径），`wowtype-config --use-lexicon rime-ice` 切回默认。
- **macOS**：设置窗口「输入 → 词库」里一样有「万象拼音」（下载、更新、从文件安装、不用时删除），装到
  `~/Library/Application Support/WowType/dicts/wanxiang/`。命令行是
  `"~/Library/Input Methods/WowType.app/Contents/MacOS/WowType" --install-lexicon wanxiang`（或 `.tar.gz` 路径）、
  `--use-lexicon rime-ice|wanxiang`。包里只许有哪几个文件、少于多少条不装、怎么校验，和 Linux 的规矩一样
  （`macos/Sources/Shared/LexiconPack.swift`）。
- **代价**：多占约 300 MB 内存，第一次载入（建快照）慢一些，之后启动约 2 秒。
- 只用了万象的词条，没有用它的 `.gram` 语法模型（那是 librime 专用的格式）；整句仍靠 WowType 自己的 `words.lm`。
  万象故意收的错音错字词库（`dicts/cuoyin`，如「秘鲁 mì lǔ」）没收，因为 WowType 没有在候选旁提示正确读音的功能。
- 词库包由 `scripts/make-wanxiang.sh` 生成：拼音去声调，词频整体缩放到和雾凇同一量级，再合进项目热词；包里带万象的 `LICENSE` 和写明来源与改动的 `SOURCE.txt`。

想用自己的词库：任何 Rime 格式的词库（`.dict.yaml`）都能用 `python3 tools/rime2tsv.py xxx.dict.yaml > lexicon.tsv` 转过来。
