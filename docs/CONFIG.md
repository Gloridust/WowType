# 设置与配置

## 自定义词

加进去的词总是排在候选第一个，简拼也能打：加了「字节跳动」（`zi jie tiao dong`），打 `zijietiaodong` 或者 `zjtd` 都能出来。

自定义词存在 `~/.local/share/wowtype/custom.tsv`，一行一个，也可以手动编辑：

```
# 拼音<TAB>词[<TAB>频次]
zi jie tiao dong	字节跳动
zhangwei	张伟
```

拼音可以用空格隔开音节，也可以连着写（`zhangwei`）。在设置界面里加的词马上能用；手动改了文件，要让 fcitx5 重新读一下：

```bash
dbus-send --session --dest=org.fcitx.Fcitx5 /controller \
  org.fcitx.Fcitx.Controller1.ReloadAddonConfig string:wowtype
```

手动改 `wowtype.conf` 也一样。（重启 fcitx5 也行，但 Chrome 这类程序要跟着重开，见[第 3 步](#第-3-步把-wowtype-加进输入法列表)。）

## 配置文件和环境变量

设置存在 `~/.config/fcitx5/conf/wowtype.conf`，设置界面和 Fcitx 5 配置改的都是这个文件：

```ini
CandidateLayout=Horizontal
PageSize=9
Fuzzy=False
TypoCorrection=True
Shuangpin=False
ShuangpinScheme=Ziranma
ShiftToggle=Both
Traditional=False
Voice=True
VoiceKey=Alt_R
EmojiSuggest=True
EmojiKey=Super+period
CheckUpdate=True
```

| 键 | 取值 |
|---|---|
| `CandidateLayout` | `Horizontal` 横排、`Vertical` 竖排 |
| `PageSize` | 每页候选个数，3–9 |
| `Fuzzy`、`TypoCorrection`、`Shuangpin`、`Traditional`、`Voice`、`EmojiSuggest`、`CheckUpdate` | `True` / `False` |
| `ShuangpinScheme` | 双拼方案：`Ziranma` 自然码、`Xiaohe` 小鹤、`Microsoft` 微软、`Sogou` 搜狗、`ABC` 智能 ABC、`Ziguang` 紫光、`PinyinJiajia` 拼音加加 |
| `ShiftToggle` | 单按哪个 Shift 切中英文：`Both`、`Left`、`Right`、`Off` |
| `VoiceKey` | fcitx5 的键名，如 `Alt_R`、`Control_R`、`Menu`、`F8` |
| `EmojiKey` | 表情面板快捷键，fcitx5 的键名，如 `Super+period`、`Control+semicolon`；留空不用快捷键 |

文件不存在、或者少写了哪一项，就用默认值（就是上面这些）。注释要单独写一行（`#` 开头），不能写在值后面。

下面这些环境变量主要是**调试和测试用**，设了的话**优先于**配置文件（在设置界面里改了也不起作用），平时用不着：

| 变量 | 作用 |
|---|---|
| `WOWTYPE_FUZZY=1`、`WOWTYPE_SHUANGPIN=1`、`WOWTYPE_TRADITIONAL=1`、`WOWTYPE_TYPO=0`、`WOWTYPE_VERTICAL=1`、`WOWTYPE_EMOJI=0` | 对应上面的开关 |
| `WOWTYPE_SHUANGPIN_SCHEME` | 双拼方案（`xiaohe`、`microsoft` 等，大小写都行），设了就当作打开双拼 |
| `WOWTYPE_SHIFT_TOGGLE` | `both`、`left`、`right`、`off` |
| `WOWTYPE_VOICE_KEY` | 语音键（fcitx5 键名）；`none` 关掉语音 |
| `WOWTYPE_VOICE_OVERLAY=0` | GNOME 上也不用语音浮条，用候选框里的文字提示 |
| `WOWTYPE_LEXICON`、`WOWTYPE_ENGLISH` | 词库、英文词表路径（默认的查找顺序见下） |
| `WOWTYPE_LM` | 词级语言模型，默认找 `words.lm`（`wowtype-lmbuild` 生成），也认旧的 `前词<TAB>后词<TAB>次数` 文本 |
| `WOWTYPE_S2T` | 简繁对照表，默认 `/usr/share/wowtype/s2t.tsv` |
| `WOWTYPE_USER_DICT`、`WOWTYPE_HISTORY`、`WOWTYPE_CUSTOM` | 自动学到的词、输入习惯、自定义词的文件路径 |
| `WOWTYPE_VOICE_MODEL_DIR` | 语音模型目录，默认 `~/.local/share/wowtype/wtlocal` |
| `WOWTYPE_NNLM` | 神经语言模型路径，默认 `~/.local/share/wowtype/wetype/nlrgpt2_nnlm.bin` |
| `WOWTYPE_NO_UPDATE_CHECK=1` | 不自动检查更新，也不自动打开默认主题 |
| `WOWTYPE_LOG` | 日志文件路径，默认 `~/.local/state/wowtype/wowtype.log`；`0` 不写 |

临时试一下：`WOWTYPE_FUZZY=1 fcitx5 -r -d`。长期用写进 `~/.config/environment.d/wowtype.conf`，注销重新登录后生效。

## 数据文件

词库和英文词表按这个顺序找，用第一个找到的：环境变量 → `~/.local/share/wowtype/` → `/usr/share/wowtype/`。
都找不到时用只有十几个词的演示词库（能打 `nihao`，但没法日常用）。

| 文件 | 内容 |
|---|---|
| `lexicon.tsv` | 词库，一行一个：`拼音（空格分隔）<TAB>词<TAB>词频` |
| `english.txt` | 英文词表 |
| `words.lm` | 词级语言模型（哪些词常连着用），有它长句更准；安装包里自带，见下 |
| `custom.tsv` | [自定义词](#自定义词)：在设置里加的词 |
| `user.tsv` | 自动学到的新词（同一个词选够 3 次就收进来） |
| `history.tsv` | 输入习惯：选过哪些词、哪些词常连着用 |
| `emoji-recent.txt` | 最近用过的 emoji（表情面板里排最前） |
| `lexicon.tsv.wcache` | 词库快照，让第二次启动更快（约 0.3 秒）；删了会自动重建 |
| `wtlocal/` | 语音模型（第一次用语音时下载，约 130MB）；删了下次用语音会重新下载 |
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

想用自己的词库：任何 Rime 格式的词库（`.dict.yaml`）都能用 `python3 tools/rime2tsv.py xxx.dict.yaml > lexicon.tsv` 转过来。
