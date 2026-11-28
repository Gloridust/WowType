# 开发者模式：打字记录

调排序用的。打开以后，输入法把每次上屏**明文**记在本机：打了什么、当时有哪些候选、最后选了第几个。
拿这份记录可以看首选命中率、找出总是排不到第一个的词，也可以转成评测用例，改排序前后各跑一遍。

**默认关。** 关着时什么都不记，也不建文件。这和另外两样东西不是一回事：

| | 记什么 | 有没有打的内容 |
|---|---|---|
| 输入法日志（`wowtype.log`，「导出日志」带的就是它） | 启动、载入、出错 | 没有 |
| [打字统计](CONFIG.md#打字统计)（`stats.json`） | 每天的计数：字数、按键次数、候选位置各多少次 | 没有 |
| 开发者模式的打字记录（`devlog.jsonl`） | 每次上屏的输入、上文、候选、选了第几个 | **有，明文** |

## 打开之前

这是一份明文的打字记录，打开时设置界面会弹窗让你确认。要知道的几件事：

- **记下来的有**：每次上屏的拼音（或五笔码）、上屏的字、光标前的几个字（排序用的上文，最多 20 个字）、
  当时候选框里的前若干个候选、选了第几个、在哪个应用里打的。
- **密码框里的不记**（Linux、Windows 上应用标成密码框的输入框；macOS 上密码框里系统会换成英文键盘，按键到不了输入法）。
- **没标成密码框的地方管不住**：终端里的 `sudo` 密码提示、网页里自己画的密码框，在中文模式下打的密码会被记下来。
  打密码前先切到英文（英文模式下的键直接交给应用，不经过这里），或者调试的时候别在这些地方打密码。
- **只存在本机**，不上传。「导出日志」（macOS、Windows 的「复制诊断信息」）不带它。
- 文件只有自己能读（0600），但同一个用户下的别的程序读得到。**调试完关掉开关，并清空记录。**

## 在哪里打开

| | 位置 |
|---|---|
| Linux | WowType 设置 →「常规」→「开发者」→「开发者模式」；下面一行是「打字记录」：条数、大小、「导出…」「清空」 |
| macOS | 设置窗口 →「常规」→「开发者」，同上 |
| Windows | 设置窗口 →「输入」页最后一项「开发者模式」，勾上、确认、再点「保存」；下面两个按钮导出、清空 |

也可以在设置文件里写 `DeveloperMode=True`（不会弹窗）。存了以后下一次按键生效，不用重启输入法。

记录文件在数据目录里：

| | 文件 |
|---|---|
| Linux | `~/.local/share/wowtype/devlog.jsonl` |
| macOS | `~/Library/Application Support/WowType/devlog.jsonl` |
| Windows | `%LOCALAPPDATA%\WowType\devlog.jsonl` |

超过 16 MB 时当前文件改名成 `devlog.jsonl.1`（只留这一份旧的），接着记新的。一次上屏一两 KB，16 MB 大约一万次。
「清空」把两份都删掉；「导出」把两份按先后合成一个文件。

## 记的是什么

一行一个 JSON 对象。每行都有：

| 键 | 意思 |
|---|---|
| `v` | 格式版本，现在是 `1` |
| `t` | 写这一行的时刻，Unix 毫秒 |
| `ver` | WowType 的版本 |
| `app` | 在哪个应用里打的（Linux 是 fcitx5 报的程序名，macOS 是 bundle id，Windows 是 exe 名）；不知道时没有这一项 |
| `e` | 事件：`commit`、`abandon`、`backspace` |

### `commit`：一次上屏

```json
{"v":1,"t":1764086228774,"ver":"0.7.13","app":"kitty","e":"commit",
 "mode":"zh","scheme":"pinyin","input":"nihao","context":"","text":"你好",
 "keys":"nihao<space>","ms":412,
 "cfg":{"english":true,"fuzzy":false,"nnlm":8,"traditional":false,"typo":true},
 "steps":[{"via":"space","rest":"nihao","pick":1,"page":0,"page_size":9,"total":37,
           "text":"你好","pinyin":"ni hao","consumed":5,"kind":"word",
           "cands":[{"t":"你好","p":"ni hao","n":5},{"t":"拟好","p":"ni hao","n":5},
                    {"t":"👋","n":5,"k":"emoji"},{"t":"你","p":"ni","n":2}]}]}
```

（这里为了好读换了行、调了键的顺序；文件里一条就是一行，键按字母顺序排。）

| 键 | 意思 |
|---|---|
| `mode` | `zh` 中文、`translate` 互译里打的 |
| `scheme` | `pinyin` 全拼、`shuangpin:<方案>`（`xiaohe`、`ziranma`……）、`wubi` 五笔、`wubi-pinyin` 五笔下 z 开头的临时拼音 |
| `input` | 这次输入打的全部原始字母（双拼是打的键，不是翻成的全拼） |
| `context` | 光标前已经上屏的字（排序用的上文），最多 20 个字 |
| `text` | 上屏的字 |
| `keys` | 从第一个键到上屏按过的键：可见字符是它自己，别的键写成 `<名字>`（`<space>` `<enter>` `<backspace>` `<esc>` `<left>` `<pgdn>`……），带 Ctrl / Alt / Super 的写成 `<ctrl+a>` |
| `ms` | 从第一个键到上屏用了多久（毫秒）；按键没带时刻、鼠标点的没有这一项 |
| `cfg` | 那时影响排序的几项设置：模糊音、繁体、纠错、英文候选、整句增强模型重排几个。回放时要照着设 |
| `steps` | 每一步选词。一次选完的是一步；长句先选开头的词、再选剩下的，有几步 |

`steps` 里的一步：

| 键 | 意思 |
|---|---|
| `via` | 怎么选的：键的名字（`space`、`enter`、`1`–`9`、`;`……），`click` 鼠标点的，`reset` 切走输入法、失去焦点时原样上屏，`mode` 切英文时原样上屏 |
| `rest` | 这一步之前还没选词的那段输入 |
| `pick` | 选了第几个（全部候选里从 1 数，不分页）；`0` 是没选候选、原样上屏输入 |
| `page`、`page_size`、`total` | 那时翻到第几页（从 0 数）、一页几个、一共多少个候选；`expanded` 为 `true` 是在展开的面板里选的 |
| `text`、`pinyin`、`consumed`、`kind` | 选的候选：字、拼音、用掉 `rest` 的几个字节、类别（`word` 引擎的词、`plain` 计算结果和日期时间、`emoji`、`raw` 原样上屏、`association` 上屏后的联想） |
| `char` | 以词定字：`first` / `last`，只取了这个词的第一个 / 最后一个字 |
| `cands` | 那时候选框里的候选，顺序和显示的一样：`t` 字、`p` 拼音、`n` 用掉的字节数、`k` 类别（引擎的词不写）。记前两页；选的排在更后面时记到它为止，最多 60 个 |

### `abandon`：打到一半放弃了

按 `Esc`、一个一个删光、失去焦点时打到一半的丢了。有 `input`（放弃时编辑区里的输入，删光的是空串）、`keys`、`context`、
已经选了的 `steps`，还有 `via`（哪个键放弃的，`reset` 是失去焦点）。

### `backspace`：上屏以后紧接着按了退格

多半是选错了。只有一项 `text`：刚上屏的那段字。它总是紧跟在对应的 `commit` 后面。
隔了别的键再按退格不算。

### 不记的

- 密码框里的。
- 英文模式下的键（直接交给应用，不经过输入法的编辑区）。
- 直接上屏的标点、数字。
- 工具栏（剪贴板、常用语）、表情面板里选的，语音识别的结果，译文。

## 怎么用

仓库里的 `tools/devlog.py`（只用 Python 标准库）：

```bash
tools/devlog.py summary            # 汇总：首选命中率、选的位置分布、怎么选的、放弃和退格
tools/devlog.py misses             # 没选第一个的：输入、选的词、它排第几、当时的第一个，按次数排
tools/devlog.py eval > my.tsv      # 转成 wowtype-eval 的用例（输入、期望、上文）
```

不给文件名时读 Linux 上输入法写的那份；macOS、Windows 上把设置里导出的文件名写在后面。

转出来的用例只收全靠选引擎的词拼出来、上屏后没有马上退格的；期望是整段上屏的字（分几步选的也按整句算，
目标是一次打出来）。繁体、五笔、互译里打的不收。然后照常跑评测：

```bash
cargo run --release -p wowtype-core --bin wowtype-eval -- --data <数据目录> --eval my.tsv
```

改排序之前跑一遍、改完再跑一遍，就知道对自己真实打的这些是变好了还是变坏了。评测的回放不带你学到的词和输入习惯
（用的是干净的引擎），所以和你打字时看到的排序不完全一样：`misses` 里的是当时真实看到的，`eval` 是引擎本身的。

**转出来的用例也是你打过的字，别提交进仓库**，也别随手发给别人。

## 实现

- 核心 `core/src/devlog.rs`：整个进程一份的开关和写文件；`core/src/session.rs` 的会话在选词、上屏、清空编辑区的地方攒事件，
  C 接口（`core/src/session_ffi.rs`）每次调用完取走写文件。关着时会话什么都不攒。
- C 接口（ABI 1.20）：`wowtype_devlog_configure`、`_enabled`、`_set_app`、`_clear`。外壳读到 `DeveloperMode` 调一次
  `configure`，之后不用管；每次写都重新打开文件，Windows 上几个应用进程各写各的、设置里清空以后也不会接着写进删掉的文件。
- 测试：`core/tests/session_keys.rs` 里 `trace_` 开头的几个（记的内容）、`core/src/devlog.rs`（文件）、
  `scripts/addon-test.sh`（真的 fcitx5 插件里开关、上屏、退格、放弃）、`scripts/test-settings-gui.py`（确认才打开、导出、清空）、
  `macos/test.sh`、`windows/test.sh`。
