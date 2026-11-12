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

- 模型点「下载」获取，放在 `~/.local/share/wowtype/models/`，下载完校验 SHA256，断了再点会接着下。
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
| 表情 | 和 `Super+.` 打开的表情面板一样 |

数字键或方向键加空格/回车选择，退格返回上一层，Esc 关闭；工具栏开着时别的键不会打进应用，`Ctrl+C` 这类组合键会收起工具栏、交给应用。

**剪贴板历史默认关**，在设置「输入」页打开「记录剪贴板历史」（`ClipboardHistory=True`）。打开后只在内存里记，不写到磁盘，重启 fcitx5 就清空；再关掉时立刻清空。

WowType 自己读不到系统剪贴板，是从 fcitx5 自带的 clipboard 插件拿最新一条：打开工具栏、切换输入框时各取一次，所以连着复制了好几次、中间没切换输入框的话，只记得到最后一次。没装或关掉了 fcitx5 的 clipboard 插件就没有记录。

**密码**：光标在密码框里时不取剪贴板。但从密码管理器复制的密码，fcitx5 自己的剪贴板会显示成圆点、30 秒后清掉，它对外给输入法的接口却不带「这是密码」的标记，所以 WowType 分不出来，会把它当普通文字记下、在工具栏里明文显示，直到重启 fcitx5 或关掉这个开关。常用密码管理器的话，建议保持关闭，或者在 fcitx5 的剪贴板设置里打开「Do not show password from password managers」（这样 fcitx5 根本不收这类内容）。

互译模式（「译」）下不开工具栏。

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
Shuangpin=False
ShuangpinScheme=Ziranma
ShiftToggle=Both
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
| `PickChar` | 以词定字：打拼音时 `[` 上屏光标处候选的第一个字、`]` 上屏最后一个字，默认开；翻页键设成 `[ ]` 时让给翻页 |
| `ShuangpinScheme` | 双拼方案：`Ziranma` 自然码、`Xiaohe` 小鹤、`Microsoft` 微软、`Sogou` 搜狗、`ABC` 智能 ABC、`Ziguang` 紫光、`PinyinJiajia` 拼音加加 |
| `ShiftToggle` | 单按哪个 Shift 切中英文：`Both`、`Left`、`Right`、`Off`。fcitx5 自己的全局快捷键（「临时切换输入法」「切换输入法」「向前切换输入法」等任何一项）里用了同一个 Shift 时，fcitx5 先处理，WowType 收不到；设置界面「输入」页会提示，并能一键把 Shift 从 fcitx5 那边去掉（改的是 `~/.config/fcitx5/config`，关掉开关就还原；这个文件写不了时提示「只在这次有效」，NixOS 见[安装说明](INSTALL.md#单按-shift-在-nixos-上)） |
| `VoiceKey` | fcitx5 的键名，如 `Alt_R`、`Control_R`、`Menu`、`F8` |
| `EmojiKey` | 表情面板快捷键，fcitx5 的键名，如 `Super+period`、`Control+semicolon`；留空不用快捷键 |
| `TranslateTarget` | 互译语言：`en` 英、`ja` 日、`ko` 韩、`fr` 法、`de` 德、`es` 西、`ru` 俄、`pt` 葡、`it` 意、`vi` 越、`th` 泰、`id` 印尼、`ar` 阿 |
| `TranslateBaseUrl`、`TranslateModel` | 翻译服务（OpenAI 格式）的地址和模型，见[互译](#互译) |
| `TranslateLocal` | `True` 用本地模型，`False` 用 `TranslateBaseUrl` 的翻译服务。设置界面里默认 `True`；配置文件里没写这一项时是 `False`（0.3.10 及以前填过翻译服务的照旧用服务） |
| `TranslateLocalModel` | 本地模型文件，留空用 `~/.local/share/wowtype/models/HY-MT1.5-1.8B-Q4_K_M.gguf`，见[本地模型](#本地模型离线) |
| `TranslateLlamaServer` | `llama-server` 的路径，留空先在 `PATH` 里找，再用设置里下载的那份 |
| `TranslateIdleMinutes` | 本地模型闲置几分钟后释放，0–240，0 表示不自动释放 |
| `Lexicon` | 词库文件路径，留空用默认的雾凇词库（查找顺序见[数据文件](#数据文件)）。设置界面切到万象时写的是 `~/.local/share/wowtype/dicts/wanxiang/lexicon.tsv`，见[可选词库](#可选词库万象拼音)。文件不存在时退回默认词库；环境变量 `WOWTYPE_LEXICON` 优先 |

文件不存在、或者少写了哪一项，就用默认值（就是上面这些）。注释要单独写一行（`#` 开头），不能写在值后面。

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
| `WOWTYPE_NO_UPDATE_CHECK=1` | 不自动检查更新，也不自动打开默认主题 |
| `WOWTYPE_LOG` | 日志文件路径，默认 `~/.local/state/wowtype/wowtype.log`；`0` 不写 |
| `WOWTYPE_TRANSLATE=1`、`WOWTYPE_TRANSLATE_URL`、`WOWTYPE_TRANSLATE_MODEL`、`WOWTYPE_TRANSLATE_TARGET` | 互译开关、服务地址、模型、语言 |
| `WOWTYPE_TRANSLATE_KEY_FILE` | 互译 Key 文件，默认 `~/.config/wowtype/translate.key` |

临时试一下：`WOWTYPE_FUZZY=1 fcitx5 -r -d`。长期用写进 `~/.config/environment.d/wowtype.conf`，注销重新登录后生效。

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

想清空学到的东西：退出 fcitx5，删掉 `~/.local/share/wowtype/user.tsv` 和 `history.tsv`，再启动（自定义词不受影响）。

### 可选词库：万象拼音

默认词库是[雾凇拼音](https://github.com/iDvel/rime-ice)（约 89 万词，随安装包一起装好）。
另外可以换成从[万象拼音](https://github.com/amzxyz/rime_wanxiang)转换的词库（约 168 万词，CC BY 4.0），词更多。
它不在安装包里，每次发版作为单独的 `wowtype-data-wanxiang-<版本>.tar.gz` 放在 Release 上。

- **切换**：「WowType 设置 → 输入 → 词库」里选「万象拼音」，第一次会下载（约 20 MB，对照 `SHA256SUMS` 校验），装到 `~/.local/share/wowtype/dicts/wanxiang/`，几秒后生效，不用重启 fcitx5。选回「雾凇拼音」就切回去，万象的文件可以在同一个地方删掉。
  没网时可以用「从文件安装」选手动下载的 `.tar.gz`。
- **命令行**：`wowtype-config --install-lexicon wanxiang`（下载并切过去，也接受本地 `.tar.gz` 路径），`wowtype-config --use-lexicon rime-ice` 切回默认。
- **代价**：多占约 300 MB 内存，第一次载入（建快照）慢一些，之后启动约 2 秒。
- 只用了万象的词条，没有用它的 `.gram` 语法模型（那是 librime 专用的格式）；整句仍靠 WowType 自己的 `words.lm`。
  万象故意收的错音错字词库（`dicts/cuoyin`，如「秘鲁 mì lǔ」）没收，因为 WowType 没有在候选旁提示正确读音的功能。
- 词库包由 `scripts/make-wanxiang.sh` 生成：拼音去声调，词频整体缩放到和雾凇同一量级，再合进项目热词；包里带万象的 `LICENSE` 和写明来源与改动的 `SOURCE.txt`。

想用自己的词库：任何 Rime 格式的词库（`.dict.yaml`）都能用 `python3 tools/rime2tsv.py xxx.dict.yaml > lexicon.tsv` 转过来。
