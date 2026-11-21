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

在设置界面「翻译」页的「翻译引擎」里选一个：**本地翻译（离线）**（默认，要先下载模型）、
**哔哩哔哩（免费，不用 API Key）**，或者**自定义翻译服务**（填一个 OpenAI 格式、`chat/completions` 的接口），再打开「互译」，
单按 Shift 就在 **中 → 英 → 译 → 中** 之间切换（没填好服务时只在中英之间切）。
也可以在「输入」页设一个**互译的快捷键**（`TranslateModeKey`，比如 `Ctrl+Shift+Y`）：按它进「译」，在「译」里再按回到原来的模式（中文或英文）；设了以后单按 Shift 只在中英之间切。

不想每次都 Shift 一路切过去、翻完再切回来，在「翻译」页打开「**双击 Shift 单次互译**」（`TranslateOneShot=True`，#191）：
单按 Shift 只在中英之间切；0.35 秒内连按两下 Shift（或按互译的快捷键）进「译」，只翻这一句，
译文上屏后自动回到原来的中文或英文（`Esc`、`Shift+回车`、单按 Shift 算放弃，一样回去；在「译」里再双击也回去）。
拼音打到一半时双击，打的拼音会带进「译」接着打。关着（默认）时和以前一样：连按两下 Shift 不切换（JetBrains 的双击 Shift）。
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
| 单按 `Shift`、另设的切换键 | 回到中文，原文原样上屏 |
| 互译的快捷键 | 回到进「译」之前的模式，原文原样上屏 |

- 打的是外文（比如英文）就翻成中文。数字、`/` `+` 这些符号也进原文。
- 同一句话翻过一次会记住（最近 64 句），再打不用等。出错时候选框底下写原因，按回车重试。
- 有的程序不让输入法把编辑区画在它的输入框里，这时译文写在候选框最下面一行。
- **打的字会发给你选的服务**（WowType 自己不经手）。密码框里不翻译。
- API Key 存在 `~/.config/wowtype/translate.key`（权限 0600，只有自己能读），不写进 `wowtype.conf`、不进日志。
  手动写也行：一行，就是 Key 本身。本机的服务（Ollama 等）可以不填。
- 发请求用的是系统的 `curl`（没装的话装一下），走系统的代理设置；连本机的服务不走代理。
- 打字时要等它翻译，挑又小又快的模型（各家的 mini、flash、turbo 版）；推理模型会慢很多。
  设置里的「测试连接」会显示一次要多久。

### 翻译引擎

「翻译引擎」不是单独的设置项，是从下面几项推出来的（Linux 设置界面、macOS、Windows 设置窗口都一样，见 `spec/config.json` 的 `translateEngines`）：

| 引擎 | 配置文件里 | 说明 |
|---|---|---|
| 本地翻译（离线） | `TranslateLocal=True`（默认） | 见[本地模型](#本地模型离线) |
| 哔哩哔哩（免费） | `TranslateLocal=False`，`TranslateBaseUrl` 的主机是 `index-translate.bilibili.com` | 见[哔哩哔哩](#哔哩哔哩index-translate) |
| 自定义翻译服务 | `TranslateLocal=False`，别的地址 | 服务商、地址、Key、模型，见上面 |

在设置里换引擎时写上这个引擎的 `TranslateLocal`、`TranslateBaseUrl`、`TranslateModel`。从「自定义」换到哔哩哔哩再换回来，
原来填的地址和模型照原样写回（只记在这次打开的设置窗口里）；API Key 文件一直不动。
升级不会换引擎：默认还是本地翻译、互译默认关，已经在用的服务照旧用，不会自己开始把字发给新的服务。

### 哔哩哔哩（Index-Translate）

哔哩哔哩开源的翻译模型 [Index-Translate](https://github.com/bilibili/Index-Translate)，官方提供免费的公开接口
`https://index-translate.bilibili.com/v1`（OpenAI 格式），**不用注册、不用 API Key**。一句话不到 1 秒。

- 设置里选「哔哩哔哩」，再挑模型：`Index-Translate-2B`（最快，默认）、`Index-Translate-9B`（译得好一点，稍慢）、
  `Index-Translate-35B-A3B`（预览版）。`TranslateModel` 空着时用 2B。
- **隐私**：要翻译的文字会发到哔哩哔哩的服务器（`index-translate.bilibili.com`）。只在切到「译」时发，密码框里不翻译；
  存在 `translate.key` 里给别的服务商的 Key **不会**发给哔哩哔哩。
- Index-Translate 是专门的翻译模型，不认通用的系统提示词，核心用它官方的「带约束翻译」提示词（原文是问题、指令也只翻译，
  不回答；表情、网址、@ 提及、数字和代码照抄；跟着「正式语气」），temperature 0，关掉思考。
  地址的主机是 `index-translate.bilibili.com`，或者模型名以 `Index-Translate` 开头（不分大小写，自己部署的
  Index-Translate 换了地址也认得）时都这样发；「测试连接」也一样。
- 这是哔哩哔哩免费提供的服务，WowType 管不了它能用多久、有没有限流；用不了时换回本地翻译或自定义服务。

### 本地模型（离线）

不想把字发出去，可以在「翻译」页的「翻译引擎」里选「本地翻译（离线）」（设置里默认就是它），用腾讯混元的翻译模型
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
ArrowKeys=Candidates
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
FuzzyAnAi=False
FuzzyHuangWang=False
FuzzyUnIong=False
FuzzyEngOng=False
TypoCorrection=True
RareExtChars=False
InputScheme=Quanpin
ShuangpinScheme=Ziranma
ShuangpinShowKeys=False
ShuangpinAbbrev=True
WubiAutoCommit=True
WubiHint=True
ShiftToggle=Both
InitialMode=Chinese
WindowMode=Same
Traditional=False
SelectKeys=Off
PickChar=True
Association=False
DateTime=True
Calculator=True
Toolbar=True
ClipboardHistory=False
AutoSpace=False
AutoSpaceLetters=True
AutoSpaceDigits=True
AutoPairPunct=False
Voice=True
VoiceKey=Alt_R
VoiceSilenceTimeout=1500
VoiceCopy=False
EmojiSuggest=True
EmojiKey=Super+period
ToggleKey=
TranslateModeKey=
Translate=False
TranslateTarget=en
TranslateBaseUrl=
TranslateModel=
TranslateFormal=False
TranslateOneShot=False
TranslateLocal=True
TranslateLocalModel=
TranslateLlamaServer=
TranslateIdleMinutes=5
CheckUpdate=True
BetaUpdates=False
TypingStats=False
SettingsTheme=System
SettingsAccent=Green
Lexicon=
```

| 键 | 取值 |
|---|---|
| `CandidateLayout` | `Horizontal` 横排、`Vertical` 竖排 |
| `ArrowKeys` | 打字途中方向键做什么（#129），设置界面里叫「方向键」：`Candidates`「都用来选词」（默认），跟着候选排列，横排 `←` `→` 选词、`↑` 上一页、`↓` 展开更多候选，竖排 `↑` `↓` 选词、`←` `→` 翻页；`Caret`「左右键移动光标」，横排竖排都是 `↑` `↓` 选词（到了一页的两头接着翻页），`←` `→` 在拼音里移动光标：打的字母插在光标处，退格删光标前一个，`Home`、`End`、`Delete` 也管光标，到了两头再按什么也不做；方向键不翻页，翻页用 `PgUp` `PgDn` 和翻页键，横排也不展开面板。双拼时光标在中间，编辑区显示打的键；「译」里拼音在原文框里，没有光标 |
| `PageSize` | 每页候选个数，3–9 |
| `VoiceSilenceTimeout` | 点按说话（点一下语音键开始说）时没声音多久自动结束，毫秒，0–60000，默认 `1500`（1.5 秒）。设置「语音」页里叫「停顿多久自动结束」，能选 1.5、3、5、10、30 秒和「不自动结束」（`0`：只有再点一下语音键才结束，`Esc` 取消）。一次最长录 2 分钟，到了照常出结果。长按说话松开就结束，不受这一项影响（#285） |
| `Fuzzy`、`TypoCorrection`、`Traditional`、`DateTime`、`Calculator`、`Toolbar`、`ClipboardHistory`、`Voice`、`VoiceCopy`、`EmojiSuggest`、`Translate`、`TranslateFormal`、`TranslateOneShot`、`CheckUpdate`、`BetaUpdates`、`TypingStats` | `True` / `False` |
| `AutoSpace`、`AutoSpaceLetters`、`AutoSpaceDigits` | 中英文之间自动加空格：总开关（默认关）、汉字和字母之间、汉字和数字之间。要应用报告光标前的文字才生效（终端等不支持），密码、网址、邮箱输入框不加 |
| `AutoPairPunct` | 中文标点自动配对，默认关，在设置的「输入」页（「拼音」那一组）打开。中文标点下打 `(` `[` `<` `{` `"` `'` 上屏成对的（）【】《》「」“”‘’，光标放到中间；在里面打完再按右半边（`)` `]` `>` `}` `"` `'`）不再多上屏一个，而是跳过补好的那个（打拼音途中按的先上屏候选），数字后面也一样：`(` `3` `)` 是（3）。可以套着打（“”）。里面空着时按退格两个一起删。里面打字、空格、退格都不打断配对；按了方向键、`Home` `End`、回车、`Tab`、`Delete`、快捷键，换了窗口、点鼠标挪了光标（应用重置输入法）以后不再跳过。数字后面的左括号照常是半角（`3(`），不配对；互译、半角标点时不配对。Linux 上光标靠插件给应用发方向键挪；macOS 上没有挪光标的接口（发方向键要「辅助功能」权限），靠输入法按位置换字：把光标要停的位置前面那个字原样换一遍，光标就落在那里（和长按出重音字母一样的接口），所以只在应用告诉输入法光标在哪、读得到光标旁边的字时配对，终端这类应用里、空的输入框里第一个字照常一个一个上屏。应用报告光标前后文字时，跳过、一起删之前还核对右边确实是补好的那个 |
| `FuzzyZh`、`FuzzyCh`、`FuzzySh`、`FuzzyNL`、`FuzzyFH`、`FuzzyRL`、`FuzzyAn`、`FuzzyEn`、`FuzzyIn`、`FuzzyIan`、`FuzzyUan`、`FuzzyUn`、`FuzzyAnAi`、`FuzzyHuangWang`、`FuzzyUnIong`、`FuzzyEngOng` | 模糊音的各组（z=zh、c=ch、s=sh、n=l、f=h、r=l、an=ang、en=eng、in=ing、ian=iang、uan=uang、un=ong、an=ai、huang=wang、un=iong、eng=ong），`Fuzzy` 打开时才生效 |
| `SelectKeys` | 分号、引号选词：`Off`、`Semicolon`（`;` 选第 2 个）、`SemicolonQuote`（再加 `'` 选第 3 个，引号不再当隔音符） |
| `RareExtChars` | 也出 CJK 扩展 B 区及以后的单字（比如 `hou` 的 𠯜），默认关：常见中文字体（Noto CJK、思源、苹方）都没有这些字，列出来是方块。打开前先装能显示它们的字体，比如 Ubuntu / Debian 的 `fonts-hanazono`。通用规范汉字表里的扩展区字（𬭩、𫚔，约 200 个，常见字体都有）和含这些字的词（𩽾𩾌）不受这个开关影响 |
| `PickChar` | 以词定字：打拼音时 `[` 上屏光标处候选的第一个字、`]` 上屏最后一个字，默认开；翻页键设成 `[ ]` 时让给翻页 |
| `Association` | 联想：选词、整句上屏以后给出一页常跟在后面的词（词级模型里的，加上自己用过的搭配）。按 `Tab` 进联想行，再用空格、回车、数字上屏，`Esc` 退出，也能用鼠标点；没按 `Tab` 时接着打字、数字、标点、空格、回车都照常（数字不选联想，中文后面常接着打数字）。五笔、互译、密码框里不出。默认关（0.5.0 预发布时默认开），在设置的「输入」页打开 |
| `SettingsTheme`、`SettingsAccent` | 设置窗口自己的主题和强调色（「常规 → 设置窗口」），只管设置窗口，不管候选框，输入法不读；Linux、macOS、Windows 三端都有，选项一样，见下面的[设置窗口的主题和强调色](#设置窗口的主题和强调色) |
| `TypingStats` | [打字统计](#打字统计)，默认关。关着时什么都不记、不建文件；打开以后只在本机记每天的聚合计数，不记打的内容。在设置的「统计」页打开、清除 |
| `InputScheme` | 输入方案，设置界面里是「输入方案」的单选：`Quanpin` 拼音（默认）、`Shuangpin` 双拼、`Wubi86` 五笔 86。五笔要数据目录里有五笔码表 `wubi86.tsv`（安装包里带着，查找顺序和词库一样，环境变量是 `WOWTYPE_WUBI`）；没有时设置里「五笔输入」灰掉，配置文件里写了 `Wubi86` 的照全拼打，候选框上方提示没有码表。五笔怎么打见 [README 的五笔](../README.md#五笔) |
| `Shuangpin` | 0.3.12 及以前的双拼开关，已经不是设置项。文件里没有 `InputScheme` 时，`Shuangpin=True` 读成 `InputScheme=Shuangpin`；有 `InputScheme` 时不看它。三端存盘时都不写它，下次存盘这一行就没了 |
| `WubiAutoCommit` | 五笔打满四码、只有一个字词时直接上屏，默认 `True`。只在五笔时显示 |
| `WubiHint` | 五笔的候选后面显示还要打的码（打 `wq` 时「您 in」「你好 vb」），默认 `True`。只在五笔时显示；`z` 临时拼音反查的五笔码总是显示 |
| `ShuangpinScheme` | 双拼方案：`Ziranma` 自然码、`Xiaohe` 小鹤、`Microsoft` 微软、`Sogou` 搜狗、`ABC` 智能 ABC、`Ziguang` 紫光、`PinyinJiajia` 拼音加加 |
| `ShuangpinShowKeys` | 双拼时编辑区显示打的键（`uivs`），不翻成全拼（`shi'zhong`），中英混打时看得出打了什么。默认 `False` |
| `ShuangpinAbbrev` | 双拼的简拼（#268）：每个键都是声母时也当成只打了声母，`sm` 出「什么」（zh ch sh 用方案里的声母键，自然码、小鹤是 `v` `i` `u`；`s` 和全拼的简拼一样，s、sh 开头的都算）。同样的键按双拼也读得通、有词时（小鹤的 `zg` 是 zeng），双拼读出来的排在前面，简拼的词（词库里的整词）接在它的前五个后面，不顶掉双拼的字。默认 `True` |
| `ShiftToggle` | 单按哪个 Shift 切中英文：`Both`、`Left`、`Right`、`Off`。0.35 秒以内连按两下（双击）两下都不算，JetBrains 的双击 Shift 不会切中英文（#253）；单按以后接着打字照切了以后的模式打，不接着打时 0.35 秒后才切、弹提示。fcitx5 自己的全局快捷键（「临时切换输入法」「切换输入法」「向前切换输入法」等任何一项）里用了同一个 Shift 时，fcitx5 先处理，WowType 收不到；设置界面「输入」页会提示，并能一键把 Shift 从 fcitx5 那边去掉（改的是 `~/.config/fcitx5/config`，关掉开关就还原；这个文件写不了时提示「只在这次有效」，NixOS 见[安装说明](INSTALL.md#单按-shift-在-nixos-上)） |
| `InitialMode` | 从别的输入法切到 WowType、开机后第一次用时的模式：`Chinese`（默认）、`English`、`Last`（和上次切走时一样）。换窗口不算，中英文照旧全局保持（要换窗口也定一次，见 `WindowMode`）；关了 Shift 切换（`ShiftToggle=Off`）、也没另设切换键（`ToggleKey`）时总是中文（`TranslateModeKey` 只进出「译」，不算）。macOS 上每个应用记着自己的中英文：输入法停用以后系统现在用的不是 WowType（切到了别的输入法；密码框里系统临时换成英文键盘不算）就记一笔，之后每个应用第一次用到 WowType 时按这一项定一次，换应用、换窗口不动；`Last` 是每个应用和它上次一样 |
| `WindowMode` | 换到新窗口、新应用时的默认中 / 英（#254）：`Same`（默认，保持当前模式，和以前一样：Linux 上所有窗口一个，macOS、Windows 上每个应用记着自己的）、`Chinese`、`English`。选了中 / 英以后，每次切到一个窗口、应用都先定成它；在窗口里用 Shift 切了只算这一次，切走再回来又按这一项定。从别的输入法切回来的那一下按 `InitialMode`。关了 Shift 切换、也没另设切换键时总是中文（同 `InitialMode`）。Linux 上是输入框获得焦点时；macOS 上看应用和它最前面的窗口换没换，同一个窗口里换输入框不算；Windows 上看输入框所在的顶层窗口换没换、应用从别处切回来，打到一半切走又切回来的接着打、不换。设置界面「输入 → 默认状态 → 默认中/英文」（Windows 设置窗口在「常规」页） |
| `PunctuationStyle` | 标点样式，设置界面「输入 → 默认状态 → 默认全角/半角」：`Fullwidth` 全角中文标点（默认）、`Halfwidth` 半角英文标点 |
| `VoiceKey` | fcitx5 的键名，如 `Alt_R`、`Control_R`、`Menu`、`F8` |
| `ToggleKey` | 另设一个切换中 / 英文的快捷键（fcitx5 键名，如 `Control+Shift+space`），留空不用；单按 Shift 照常。在「译」里按回到中文。fcitx5 自己的全局快捷键先处理：`Control+space` 默认是 fcitx5「切换启用/禁用输入法」的键（macOS 上是系统「选择上一个输入法」的键），设成它 WowType 收不到，所以设置里不再列它；Linux 设置界面会提示被 fcitx5 占着的键 |
| `TranslateModeKey` | 进出「译」的快捷键（如 `Control+Shift+Y`），留空不用：按它进「译」（打到一半的拼音带进去；开着 `TranslateOneShot` 时只翻一句），在「译」里再按回到进来前的模式；设了以后单按 Shift 只在中 ↔ 英之间切（在「译」里单按回中文）。互译没打开、翻译没配好、密码框里这个键交给应用。和 `ToggleKey` 设成同一个键时算这个 |
| `TranslateOneShot` | 双击 Shift 单次互译（#191），默认 `False`：和以前一样，连按两下 Shift 不切换。`True`：单按 Shift 只在中 ↔ 英之间切，0.35 秒内连按两下 Shift 进「译」；双击、`TranslateModeKey` 进的「译」都只翻一句，译文上屏、`Esc`、`Shift+回车`、单按 Shift 以后回到进来前的模式。设置里在「翻译」页，三端一样 |
| `EmojiKey` | 表情面板快捷键，fcitx5 的键名，如 `Super+period`、`Control+semicolon`；留空不用快捷键。macOS 上默认 `Control+period`，`Super` 当 `Control`（见 [macOS](#macos)） |
| `TranslateTarget` | 互译语言：`en` 英、`ja` 日、`ko` 韩、`fr` 法、`de` 德、`es` 西、`ru` 俄、`pt` 葡、`it` 意、`vi` 越、`th` 泰、`id` 印尼、`ar` 阿 |
| `TranslateBaseUrl`、`TranslateModel` | 翻译服务（OpenAI 格式）的地址和模型，见[互译](#互译)。地址是 `https://index-translate.bilibili.com/v1` 时是[哔哩哔哩](#哔哩哔哩index-translate)，模型可以空着（用 `Index-Translate-2B`）、不用 Key |
| `TranslateLocal` | `True` 用本地模型（默认），`False` 用 `TranslateBaseUrl` 的翻译服务（哔哩哔哩或自定义，见[翻译引擎](#翻译引擎)）。配置文件里没写这一项、又填了 `TranslateBaseUrl` 时当 `False`（0.3.10 及以前填过翻译服务的照旧用服务）；Linux 插件、设置界面和 macOS 都这样 |
| `TranslateLocalModel` | 本地模型文件，留空用 `~/.local/share/wowtype/models/HY-MT1.5-1.8B-Q4_K_M.gguf`，见[本地模型](#本地模型离线) |
| `TranslateLlamaServer` | `llama-server` 的路径，留空先在 `PATH` 里找，再用设置里下载的那份 |
| `TranslateIdleMinutes` | 本地模型闲置几分钟后释放，0–240，0 表示不自动释放 |
| `Lexicon` | 词库文件路径，留空用默认的雾凇词库（查找顺序见[数据文件](#数据文件)）。设置界面切到万象时写的是 `~/.local/share/wowtype/dicts/wanxiang/lexicon.tsv`，见[可选词库](#可选词库万象拼音)。文件不存在时退回默认词库；环境变量 `WOWTYPE_LEXICON` 优先 |

文件不存在、或者少写了哪一项，就用默认值（就是上面这些）。注释要单独写一行（`#` 开头），不能写在值后面。

各端（Linux 插件、设置界面、macOS、Windows）读这个文件的规矩一样：

- 开关只认 `True` / `False`，选项区分大小写（`Horizontal`，不是 `horizontal`）；写错了、认不出的用默认值。
- 数字超出范围夹到边上（`PageSize=12` 读成 9），认不出的数字用默认值。
- 键和值两边的空格不算（`PageSize = 5` 读成 5）。
- `[分组]`（比如 fcitx5 的 `[Hotkey]`）下面的行不是设置项；设置界面写回文件时原样留着。
- 两边带双引号的值去掉引号，`\\`、`\"`、`\n` 还原成反斜杠、引号、换行。

**改设置项（加键、改名、改默认值、范围、可选值）要先改规格 [`spec/config.json`](../spec/config.json)**（可选词库包的规矩在
[`spec/lexicon-pack.json`](../spec/lexicon-pack.json)），Linux 插件、设置界面、macOS、Windows 各端的测试都拿它对照，哪一端没跟上 CI 就挂：
插件在 `scripts/addon-test.sh`、设置界面在 `scripts/test-config-contract.py`、macOS 在 `macos/test.sh`、Windows 在 `windows/test.sh`（CI 的 Windows 任务）。
两端故意不一样的（比如 `EmojiKey` 的默认值）、只有一端有的项，规格里都写了原因。

下面这些环境变量主要是**调试和测试用**，设了的话**优先于**配置文件（在设置界面里改了也不起作用），平时用不着：

| 变量 | 作用 |
|---|---|
| `WOWTYPE_FUZZY=1`、`WOWTYPE_SHUANGPIN=1`、`WOWTYPE_TRADITIONAL=1`、`WOWTYPE_TYPO=0`、`WOWTYPE_VERTICAL=1`、`WOWTYPE_EMOJI=0`、`WOWTYPE_DATETIME=0`、`WOWTYPE_CALC=0`、`WOWTYPE_TOOLBAR=0`、`WOWTYPE_CLIPBOARD_HISTORY=0`、`WOWTYPE_VOICE_COPY=1`、`WOWTYPE_AUTO_PAIR_PUNCT=1` | 对应上面的开关 |
| `WOWTYPE_AUTOSPACE` | 自动加空格的位掩码：1 汉字和字母之间、2 汉字和数字之间，`3` 两种都加，`0` 关 |
| `WOWTYPE_FUZZY_GROUPS` | 模糊音分组的位掩码（1 z/zh、2 c/ch、4 s/sh、8 n/l、16 f/h、32 r/l、64 an/ang、128 en/eng、256 in/ing、512 ian/iang、1024 uan/uang、2048 un/ong、4096 an/ai、8192 huang/wang、16384 un/iong、32768 eng/ong） |
| `WOWTYPE_SELECT_KEYS` | `off`、`semicolon`、`quote` |
| `WOWTYPE_SHUANGPIN_SCHEME` | 双拼方案（`xiaohe`、`microsoft` 等，大小写都行），设了就当作打开双拼（这时不是五笔） |
| `WOWTYPE_WUBI` | 五笔码表路径，默认按 `~/.local/share/wowtype/wubi86.tsv`、`/usr/share/wowtype/wubi86.tsv` 的顺序找 |
| `WOWTYPE_SHIFT_TOGGLE` | `both`、`left`、`right`、`off` |
| `WOWTYPE_VOICE_KEY` | 语音键（fcitx5 键名）；`none` 关掉语音 |
| `WOWTYPE_VOICE_OVERLAY=0` | GNOME 上也不用语音浮条，用候选框里的文字提示 |
| `WOWTYPE_LEXICON`、`WOWTYPE_ENGLISH` | 词库、英文词表路径（默认的查找顺序见下） |
| `WOWTYPE_LM` | 词级语言模型，默认找 `words.lm`（`wowtype-lmbuild` 生成），也认旧的 `前词<TAB>后词<TAB>次数` 文本 |
| `WOWTYPE_S2T` | 简繁对照表，默认 `/usr/share/wowtype/s2t.tsv` |
| `WOWTYPE_USER_DICT`、`WOWTYPE_HISTORY`、`WOWTYPE_CUSTOM` | 自动学到的词、输入习惯、自定义词的文件路径 |
| `WOWTYPE_VOICE_MODEL_DIR` | 语音模型目录，默认 `~/.local/share/wowtype/wtlocal`（插件和设置界面都认） |
| `WOWTYPE_NNLM` | 整句增强模型（神经语言模型）路径，只用它；不设时先找导入的 `~/.local/share/wowtype/wetype/nlrgpt2_nnlm.bin`，没有再用自带的 `nnlm.bin` |
| `WOWTYPE_DOMAIN_LM` | 领域词级模型路径，默认数据目录下的 `words.domain.lm`；没有就不混 |
| `WOWTYPE_NO_UPDATE_CHECK=1` | 不自动检查更新，也不自动打开默认主题 |
| `WOWTYPE_LOG` | 日志文件路径，默认 `~/.local/state/wowtype/wowtype.log`；`0` 不写 |
| `WOWTYPE_TRANSLATE=1`、`WOWTYPE_TRANSLATE_URL`、`WOWTYPE_TRANSLATE_MODEL`、`WOWTYPE_TRANSLATE_TARGET` | 互译开关、服务地址、模型、语言 |
| `WOWTYPE_TRANSLATE_KEY_FILE` | 互译 Key 文件，默认 `~/.config/wowtype/translate.key` |

临时试一下：`WOWTYPE_FUZZY=1 fcitx5 -r -d`。长期用写进 `~/.config/environment.d/wowtype.conf`，注销重新登录后生效。

### Windows

Windows 版还在第一阶段（[WINDOWS.md](WINDOWS.md)）：设置在 `%LOCALAPPDATA%\WowType\wowtype.conf`，**键名、取值、默认值和上面一样**，
`EmojiKey` 的默认值和 macOS 一样是 `Control+period`，也认 `CandidateFontSize`。开始菜单的「WowType 设置」（或任务栏上「中」按钮右键 →「WowType 设置…」）打开设置窗口，
和 macOS 一样只写改过的键，注释、不认识的键原样留着；也可以右键 →「打开设置文件」用记事本改。存了以后下一次按键生效。检查更新（`CheckUpdate`、`BetaUpdates`）和 macOS 一样，有新版时任务栏「中」按钮的右键菜单里多一项；打字统计（`TypingStats`）记在同一个目录的 `stats.json`，设置窗口「统计」页看（柱状图、键盘热力图）；
语音输入（`Voice*`）和另两端一样，模型要自己放进同一个目录的 `wtlocal\`（还没有下载按钮）。

### macOS

macOS 上的设置在 `~/Library/Application Support/WowType/wowtype.conf`，**键名、取值、默认值和上面一样**（只有 `EmojiKey` 的默认值不同，见下），Linux 上的文件拷过去就能用。
点菜单栏里的 WowType 图标 →「WowType 设置…」打开设置窗口（页面和 Linux 的设置界面一样：常规、输入、表情、语音、翻译、自定义词，
macOS 还没有的功能不列；Linux 单独一页的「更新」在「常规」页里）。窗口只改它认识的键，文件里的注释、不认识的键、`[分组]` 原样留着，
改过的文件拿回 Linux 照样能用。也可以直接改文件：设置窗口的「文件」菜单 →「用文本编辑打开设置文件」，
还没有文件时会写出一份带说明的，每项都是注释掉的默认值（`# PageSize=9`），去掉 `#` 再改值才生效。
设置窗口只写和默认值不一样的项（就地换掉注释掉的那一行），以后默认值变了，没改过的项跟着变。
窗口开着时在别处改了文件，切回窗口会重新读，不会被窗口里的旧值盖掉。
改完下一次按键时生效，不用重启；换了 `Lexicon` 会在后台重新载入词库，载完之前照旧用原来的。

现在认的项：`CandidateLayout`、`ArrowKeys`、`PageSize`、`PageKeys*`、`SelectKeys`、`PickChar`、`Association`、`Fuzzy` 和 `Fuzzy*` 各组、`TypoCorrection`、`RareExtChars`、
`InputScheme`、`ShuangpinScheme`、`ShuangpinShowKeys`、`ShuangpinAbbrev`、`WubiAutoCommit`、`WubiHint`、`ShiftToggle`、`InitialMode`、`WindowMode`、`Traditional`、`PunctuationStyle`、`AutoPairPunct`、`DateTime`、`Calculator`、`EmojiSuggest`、
`AutoSpace*`、`Lexicon`、`Toolbar`、`ClipboardHistory`、`EmojiKey`、`ToggleKey`、`TranslateModeKey`、`Voice`、`VoiceKey`、`VoiceCopy`、`Translate` 和 `Translate*` 各项、`TypingStats`、`SettingsTheme`、`SettingsAccent`，另外有一项只有 macOS 有的 `CandidateFontSize`（候选字号，10–40 磅，默认 17；Linux 上字号跟着 fcitx5 主题）。
`CheckUpdate`（默认 `True`）：输入法每天最多查一次 GitHub 上的最新正式版（后台，不挡打字），有新版时菜单栏的输入法菜单里多一项
「有新版本 …，下载并安装…」，点它打开设置窗口「常规」页；设置窗口打开时也查。不弹系统通知（输入法没有开发者签名，通知要先授权，打字时弹框也打扰人）。
「下载并安装」下载 `WowType-<版本>-macos.pkg` 和同一页的 `SHA256SUMS`，校验后交给系统的 `installer` 只装给当前用户（不要密码，和一键安装脚本一样），
装的时候输入法和设置窗口会重启一下，装好后设置窗口自动重新打开；失败时写原因，给发布页链接。
`BetaUpdates`（默认 `False`，设置里「更新」下的「Beta 计划」，Linux 和 macOS 都有）：检查更新也算 GitHub 上的预发布版（pre-release），
新功能先到、可能不稳定。开着时查最近 30 个发布，挑 `v` 加数字的 tag 里版本号最大的（数据的发布 `lm-…`、`nnlm-…` 不算，一样大时要正式版）；
关着时只认最新正式版（`releases/latest`）。关掉以后已经装上的预发布版不会退回，等版本号更大的正式版出来再提示。

设置窗口「输入」页的**整句增强模型**：安装包里自带 WowType 自己训的 `nnlm.bin`，不用设置。也可以从微信输入法 macOS 版的安装包（`.zip`）、
装好的 `WeType.app` 或 `nlrgpt2_nnlm.bin` 本身导入微信的（见下面的[整句增强模型](#数据文件)，效果相近），
放到 `~/Library/Application Support/WowType/wetype/nlrgpt2_nnlm.bin`，几秒后生效，不用重新登录；导入了就先用它，能删，删掉以后换回自带的。
导入时只看核心解析得了，不核对版本号、MD5。

「常规」页「帮助」里：「复制诊断信息」把版本、数据文件、设置文件（翻译服务只留主机名，像密钥的值打码）、各模型状态和 WowType 最近两小时的系统日志
复制到剪贴板，贴到问题里；「卸载 WowType」关掉输入法、从系统里去掉、删掉程序，用户数据（`~/Library/Application Support/WowType`）留着，
命令行是 `WowType --uninstall`。设置里 `Lexicon` 指的文件在、但读不出来时，输入法改用自带的雾凇词库（文件换过了再试）。

[工具栏](#v--空格工具栏)和表情面板和 Linux 上一样用，不同的是：

- **表情面板快捷键默认 `Control+.`**（`EmojiKey=Control+period`）。Command 组合键多半被应用的菜单先拿走、到不了输入法，
  所以写 `Super` 的当 `Control` 用：Linux 的默认值 `Super+period` 拷过来就是 `Control+.`。也可以换成 `Control+semicolon`、`Alt+semicolon`（`Alt` 是 Option）这类，留空不用快捷键。
- **中英文切换**：系统自己的 `中/英` 键（大写锁定键）在 WowType 和 ABC 之间切，不经过输入法，所有应用里都管用：
  在「系统设置 → 键盘 → 文字输入 → 输入法」点「编辑…」，打开「使用“中/英”键切换“ABC”输入法」（键盘上没有 中/英 键时叫「使用大写锁定键切换“ABC”输入法」），
  设置窗口「输入」页有按钮直接打开键盘设置。单按 Shift 照常默认开着；`Control+space` 是系统「选择上一个输入法」的键，设成 `ToggleKey` 收不到。
- **剪贴板历史**（默认关，`ClipboardHistory=True` 打开）直接读系统剪贴板：切换输入框、打开工具栏的「剪贴板」页时各看一眼，有新复制的文字就记下（只在内存里，退出输入法就清空，关掉开关立刻清空）。
  连着复制了好几次、中间没切换输入框的话，只记得到最后一次。
- **密码**：密码框里系统不让输入法工作，取不到。很多密码管理器（比如 1Password、KeePassXC）复制密码时会给剪贴板标上 `org.nspasteboard.ConcealedType`，
  带这个标记（还有 `TransientType`、`AutoGeneratedType`）的不记；没按这个约定标记的密码管理器复制的密码会被记下、在工具栏里明文显示，用这类密码管理器的话保持关闭。
  新版 macOS 读剪贴板时可能会问要不要允许 WowType 读，不允许就没有记录。

- 自定义词在同一个目录的 `custom.tsv`，格式和 [Linux 的](#自定义词)一样；菜单里「自定义词…」打开设置窗口的自定义词页
  （加词时自动填拼音，能删、导入、导出），保存后下一次按键时生效。
- `AutoSpace` 只在应用告诉输入法光标前是什么字时才加（很多应用不告诉，这时不猜）。
- [互译](#互译)用法和 Linux 一样（单按 Shift 中 → 英 → 译 → 中，原文在候选框顶上，译文写在输入框里）。在设置窗口的「翻译」页打开互译、
  在「翻译引擎」里选本地翻译、[哔哩哔哩](#哔哩哔哩index-translate)（免费，不用 Key）或自定义翻译服务；自定义的填接口地址和模型（也可以直接改 `wowtype.conf` 里的 `Translate`、`TranslateBaseUrl`、`TranslateModel`）；API Key 也在那一页填，
  存在同一个目录的 `translate.key`（0600，只有自己能读），不写进 `wowtype.conf`。系统开着安全输入（密码框）时照常打中文，不翻译。
- 本地模型（`TranslateLocal=True`）：和 Linux 一样一键下载。设置窗口「翻译」页选「本地翻译（离线）」，点「下载」，
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
  - 还没下载模型时按语音键不碰麦克风，第一次会直接打开设置窗口的「语音」页去下载。第一次说话时系统会问要不要允许 WowType 使用麦克风
    （下载完模型时设置窗口会先问一次）；WowType 更新后系统可能会再问一次。没允许时第一次按语音键会打开「语音」页，
    那里的「麦克风」一行有按钮直接打开系统设置的麦克风权限。在本机识别，录音不上传。
  - `VoiceCopy=True` 时说的话上屏后也复制到剪贴板（密码框里不复制）。
- 上面的环境变量 macOS 不认（输入法是系统启动的，拿不到你设的环境变量）。

## 数据文件

词库和英文词表按这个顺序找，用第一个找到的：环境变量 → 配置里的 `Lexicon`（只管词库） → `~/.local/share/wowtype/` → `/usr/share/wowtype/`。
都找不到时用只有十几个词的演示词库（能打 `nihao`，但没法日常用）。

例外：`~/.local/share/wowtype/` 里的 `lexicon.tsv`、`english.txt`、`wubi86.tsv` 是 WowType 自己生成的标准数据（第一行是
`# 由 tools/rime2tsv.py 生成` / `# Rime dictionary`，五笔码表认第一条），`/usr/share/wowtype/` 里也有一份，而且用户目录这份
不比它新时，插件和设置界面改用 `/usr/share/wowtype/` 的；`words.lm` 的字节数和某一版官方发布的一样时也这样处理。
0.3.4 以前词库不在安装包里，要自己拷进用户目录（源码安装的说明到 0.4.0 还这样写）；后来安装包自带了，
那份旧副本却一直优先，装了新版也用不上新词库。日志里会记一条，设置界面「诊断信息」里那行会标「可以删掉」。
用户目录里自己做的词库和码表（第一行不是上面的标记）、自己重新生成的更新的一份、自己训的 `words.lm` 照旧优先；
想明确指定词库，用设置里的 `Lexicon` 或环境变量。macOS 用的是安装包里的词库（数据目录里那个是指向它的链接），没有这个问题。

| 文件 | 内容 |
|---|---|
| `lexicon.tsv` | 词库，一行一个：`拼音（空格分隔）<TAB>词<TAB>词频` |
| `english.txt` | 英文词表 |
| `words.lm` | 词级语言模型（哪些词常连着用），有它长句更准；安装包里自带，见下 |
| `custom.tsv` | [自定义词](#自定义词)：在设置里加的词 |
| `user.tsv` | 自动学到的新词：分几次选出来拼成的词（四个字以内，比如「霜」「频」「阁」）30 天里第二次这样拼（或者直接选它）就收进来；一次打出来的词选够 3 次（按 30 天减半的热度算）才收 |
| `history.tsv` | 输入习惯：选过哪些词、哪些词常连着用、等第二次的候选新词、忘掉的词（Ctrl+Delete） |
| `emoji-recent.txt` | 最近用过的 emoji（表情面板里排最前） |
| `stats.json` | [打字统计](#打字统计)（默认关，打开了才有）：每天的字数、各类字符数、活跃毫秒、每个键按下的次数、候选位置，不保存输入内容；旁边的 `stats.clear` 是清空计数 |
| `lexicon.tsv.wcache` | 词库快照，让第二次启动更快（约 0.1 秒，快照直接映射进内存用）；删了会自动重建 |
| `wtlocal/` | 语音模型（约 130MB），在设置的「语音」页下载或删除；没有它语音输入打不开，按语音键只提示去下载 |
| `dicts/wanxiang/` | 可选：万象词库包（`lexicon.tsv`、许可证、来源说明），在设置里下载，见下 |
| `wetype/nlrgpt2_nnlm.bin` | 可选：导入的微信输入法的整句增强模型（16MB），有它就先用它，不然用安装包自带的 `nnlm.bin`，见下 |
| `words.domain.lm` | 可选：自己训的领域词级模型，和 `words.lm` 混着用，见下 |

**语料词频**：`scripts/make-data.sh` 用雾凇拼音和仓库里 `data/` 下的表，
其中 `data/tatoeba-freq.tsv` 是从 Tatoeba 中文句子（CC BY 2.0 FR）统计出的词频，默认融进已有词的词频
（只有词频、不含句子，署名在 `SOURCE.txt`，装好后是 `DATA-SOURCE.txt`；`WOWTYPE_NO_CORPUS_FREQ=1` 不融）。
换成本机语料、重新生成这张表和实测效果见 [DATA.md §3.3](DATA.md#33-语料词频)。

**词级语言模型**：`words.lm` 记的是「哪两个词常连着出现」，束搜索靠它把长句拼对。
安装包里自带一份（38 MB，装到 `/usr/share/wowtype/words.lm`，许可证 CC BY-SA 4.0），
是用清华的对话语料 [LCCC](https://huggingface.co/datasets/thu-coai/lccc)（MIT）加中文维基百科（CC BY-SA 4.0）训练的，
单独下载见 [Release lm-2026.11.09](https://github.com/Gloridust/WowType/releases/tag/lm-2026.11.09)。
载入约 0.03 秒，多占约 45 MB 内存，对按键速度几乎没有影响。想用自己的语料重新训练：

```bash
cargo run --release -p wowtype-core --bin wowtype-lmbuild -- \
    --lexicon ~/.local/share/wowtype/lexicon.tsv --s2t /usr/share/wowtype/s2t.tsv \
    --out ~/.local/share/wowtype/words.lm lccc.txt wiki.txt
```

语料是纯文本、一行一段，繁体会转成简体。约 12 亿字、8 线程要 14 分钟，内存峰值约 3GB。

**整句增强模型**：一个按字预测下一个字的小模型（字级神经语言模型），给整句候选重排，长句的首选更准，每次按键多 2ms 左右。
安装包里自带 WowType 自己训的一份（8.6 MB，装到 `/usr/share/wowtype/nnlm.bin`，macOS 在安装包的 Resources 里，许可证 CC BY-SA 4.0），
是用 [LCCC](https://huggingface.co/datasets/thu-coai/lccc)（MIT）加中文维基百科（CC BY-SA 4.0）训练的，开箱即用：
按 `scripts/eval.sh` 的评测，日常整句的首选从 90.6% 提到 94.2%、带上文的从 89.1% 提到 94.0%，单独打词的各组不变。
来源、训练和发布步骤见 [DATA.md §3.5](DATA.md#35-wowtype-自己的整句增强模型-nnlmbin)。

也可以换成微信输入法自带的那个（`nlrgpt2_nnlm.bin`，效果相近）：模型是腾讯的，WowType 不分发，
到微信输入法官网下载 macOS 版（3.0.0）的安装包（.zip，Linux 上也是下这个），
在「WowType 设置 → 输入 → 整句增强模型」点「导入…」选它，马上生效，不用重启；导入了就先用它，删掉以后换回自带的。
命令行也行：`python3 tools/install_wetype_nnlm.py <WeType 的 .zip 或 .app>`。版本对不上（MD5 不认识）时不装。
插件日志里写着用的是哪一份，设置界面的诊断信息里也有。

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

默认词库是[雾凇拼音](https://github.com/iDvel/rime-ice)（随安装包一起装好）。
另外可以换成从[万象拼音](https://github.com/amzxyz/rime_wanxiang)转换的词库（CC BY 4.0），词更多。
它不在安装包里，每次发版作为单独的 `wowtype-data-wanxiang-<版本>.tar.gz` 放在 Release 上。

- **切换**：「WowType 设置 → 输入 → 词库」里选「万象拼音」，第一次会下载（约 20 MB，对照 `SHA256SUMS` 校验），装到 `~/.local/share/wowtype/dicts/wanxiang/`，几秒后生效，不用重启 fcitx5。选回「雾凇拼音」就切回去，万象的文件可以在同一个地方删掉。
  没网时可以用「从文件安装」选手动下载的 `.tar.gz`。
- **命令行**：`wowtype-config --install-lexicon wanxiang`（下载并切过去，也接受本地 `.tar.gz` 路径），`wowtype-config --use-lexicon rime-ice` 切回默认。
- **macOS**：设置窗口「输入 → 词库」里一样有「万象拼音」（下载、更新、从文件安装、不用时删除），装到
  `~/Library/Application Support/WowType/dicts/wanxiang/`。命令行是
  `"~/Library/Input Methods/WowType.app/Contents/MacOS/WowType" --install-lexicon wanxiang`（或 `.tar.gz` 路径）、
  `--use-lexicon rime-ice|wanxiang`。包里只许有哪几个文件、少于多少条不装、怎么校验，和 Linux 的规矩一样
  （`macos/Sources/Shared/LexiconPack.swift`）。正在用万象、开着 `CheckUpdate` 时，输入法每天检查更新时顺带看一眼：
  发布页上有新版万象就在后台下载、校验、换上（和 Linux 设置界面的后台检查一样，不打扰人；没成功的那一版一天以内不再试）。
- **代价**：比雾凇多占约 60 MB 内存，第一次载入（建快照）要四五秒，之后启动约 0.1 秒。
- 只用了万象的词条，没有用它的 `.gram` 语法模型（那是 librime 专用的格式）；整句仍靠 WowType 自己的 `words.lm`。
  万象故意收的错音错字词库（`dicts/cuoyin`，如「秘鲁 mì lǔ」）没收，因为 WowType 没有在候选旁提示正确读音的功能。
- 词库包由 `scripts/make-wanxiang.sh` 生成：拼音去声调，词频整体缩放到和雾凇同一量级，再合进项目热词；包里带万象的 `LICENSE` 和写明来源与改动的 `SOURCE.txt`。

想用自己的词库：任何 Rime 格式的词库（`.dict.yaml`）都能用 `python3 tools/rime2tsv.py xxx.dict.yaml > lexicon.tsv` 转过来。

## 打字统计

设置里的「统计」页：今天 / 累计的字数、活跃时长、速度、连续天数，按键热力图，字符类型、输入模式、双拼方案、候选命中位置。

**默认关**（`TypingStats=False`）。关着时输入法什么都不记：内存里不计数、不记时间、不建也不写文件。
在「统计」页打开开关（或在配置文件里写 `TypingStats=True`）以后才开始记，关掉时还没写进文件的计数直接丢掉。

**记什么**——打开以后，只在本机按天记这些计数（`stats.json` 里只有这些）：

```json
{
  "version": 2,
  "cleared": 0,
  "days": {
    "2026-11-18": {
      "chars": 1982,
      "kinds": {"han": 1800, "latin": 82, "number": 40, "punct": 52, "emoji": 8, "other": 0},
      "activeMs": 2140000,
      "keys": {"KeyA": 310, "Space": 420},
      "sources": {"quanpin": 1900, "english": 82},
      "schemes": {},
      "selections": [500, 200, 30, 0, 0, 0, 0, 0, 0],
      "beyond": 0
    }
  }
}
```

- `chars`、`kinds`：当天 WowType 上屏的字符数，分汉字、字母、数字、标点、表情、其他；空格和换行不算，组合表情算一个，删除不扣减。
- `activeMs`：活跃时长。两次上屏间隔不超过 10 秒的算进去，超过的算休息（上一次上屏的时刻只在内存里，不写进文件）。
- `keys`：每个物理键（`KeyboardEvent.code` 风格的键位名，换键盘布局不影响位置）当天按下的次数，按住不放只算一次。
- `sources`、`schemes`：按输入模式（`quanpin`、`shuangpin`、`wubi`、`english`、`translate`）、双拼方案分的字数。
- `selections`、`beyond`：选第 1–9 个候选上屏的次数、第 10 个以后的次数。
- `cleared`：写这份文件时的清空计数（见下）。

**不记什么**：打的字、词、拼音、按键的先后顺序、每次按键或上屏的时刻、在哪个应用里打的。
密码框和别的敏感输入框（fcitx5 的 `Password` / `Sensitive`，macOS 的安全输入）里的按键和上屏整个不算。
数据不离开这台电脑。

**文件**：`~/.local/share/wowtype/stats.json`（`$XDG_DATA_HOME/wowtype/`；macOS 是 `~/Library/Application Support/WowType/stats.json`），
权限 0600。只有输入法写：按键和上屏只改内存，攒够 20 次上屏或 30 秒、切出输入框、退出时交给后台线程，
后台线程读文件、加上这批、去掉 400 天以前的、原子写回，打字的线程不碰文件。设置界面只读。
文件坏了或超过 16 MB 时挪到 `stats.json.bad`，从空的重新记。

**清除**：「统计」页的「清除统计」（关着时也能点）。它把旁边 `stats.clear` 里的整数加一，再删掉 `stats.json`（和 `stats.json.bad`）。
输入法写文件前看这个数：和开始攒这一批时不一样，就整批丢掉（里面有清除之前打的），不会把清掉的写回来；
文件里的 `cleared` 和 `stats.clear` 对不上的，设置界面当作没有记录，输入法下次写时删掉。
不用设置界面也可以：退出输入法（或先关掉统计）再删掉 `stats.json`。

## 设置窗口的主题和强调色

设置窗口「常规」页的「设置窗口」一组（Windows 在「常规」页最后两项），只改设置窗口自己，不影响候选框，输入法不读这两项：

- **主题**（`SettingsTheme`）：`System` 跟随系统（默认）、`Light` 浅色、`Dark` 深色。
  系统是深色、窗口却显示成浅色（或者反过来）时，固定成浅色或深色。
  Linux 上固定以后连 `~/.config/gtk-4.0/gtk.css` 里系统主题写的颜色（KDE 会把它的配色写在那里）也不跟；
  macOS 换的是窗口的外观（NSAppearance）；Windows 跟随系统时看「设置 → 个性化 → 颜色」里的应用模式。
- **强调色**（`SettingsAccent`）：`Green` 绿色（默认，WowType 绿）、`Blue` 蓝色、`Purple` 紫色、`Orange` 橙色、`Pink` 粉色。
  用在选中的页面、按钮、开关和统计的图上。三端用同一张颜色表（[`spec/config.json`](../spec/config.json) 的 `SettingsAccent`）：
  每种颜色带一个放白字用的深一点的版本（和白字的对比度至少 4.7:1）、一个深色背景上当字用的浅一点的版本（至少 4.5:1）。

不能自己写 CSS 换样式：macOS、Windows 的设置窗口不是用 CSS 画的，三端只做三端都有的选项。

Linux 的设置窗口不管选哪个主题，底色和文字都用 libadwaita 的颜色、成对跟着主题走；次要文字（行的副标题、说明）比 libadwaita
默认的深一些，浅色下和卡片的对比度约 5:1。以前底色写死、文字跟着系统主题，KDE 的深色配色下整页淡得看不清（#255）。
