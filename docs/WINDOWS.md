# Windows 版（预览）

> 状态（2026-11）：**预览版**。CI 的「Windows 输入法（x64）」任务在 `windows-latest`（真的 Windows Server，有桌面）上编核心、输入法 DLL
> 和设置窗口，跑核心测试、按键测试和设置契约，打 zip 和安装程序，用安装程序真装、升级、卸载一遍，**并在装好的系统上真打字**
> （[端到端打字测试](#端到端打字测试)）；x64 的安装程序随发版进 Release。还没在很多台电脑、很多种应用里用过，
> 见下面[还没验证的](#还没验证的)。

## 和另两端的关系

和 macOS 版一样，**输入行为都在 Rust 核心的输入会话里**（[ABI.md](ABI.md)「输入会话」、[PORTING.md](PORTING.md)），
Windows 外壳只做平台的事：把按键翻成会话的键码、照会话给的结果画编辑区和候选框、上屏、读光标旁边的字。
所以打字、选词、翻页、标点、Shift 切中英文、以词定字、工具栏和表情面板、联想、自动配对、互译这些行为和 Linux、macOS 是同一份代码。

| 部分 | 代码 | 说明 |
|---|---|---|
| 组字（和平台无关） | `windows/src/common/composer.*` | macOS `Shared/Composer.swift`（加 `Toolbar.swift` 的画法）的 C++ 版，一个函数一个函数对着写的 |
| 设置 | `windows/src/common/config.*` | 读 `wowtype.conf`，键名、取值、默认值、读法和另两端一样，`spec/config.json` 里 `platforms` 带 `windows` 的项 |
| 按键翻译 | `windows/src/common/keys.*` | 虚拟键码（`VK_*`）+ `ToUnicodeEx` 打出的字符 → 会话的键码（XKB keysym 子集） |
| TSF 文本服务 | `windows/src/tsf/text_service.*` | `ITfTextInputProcessorEx`、按键（`ITfKeyEventSink`）、组字和编辑会话、焦点 |
| 候选框 | `windows/src/tsf/candidate_window.*` | 分层的弹出窗口，Direct2D + DirectWrite 画（彩色 emoji），位置用 `ITfContextView::GetTextExt` |
| 任务栏「中 / 英」 | `windows/src/tsf/langbar.*` | `GUID_LBI_INPUTMODE` 按钮：左键切中英文，右键菜单切模式、打开设置文件和数据目录 |
| 设置窗口 | `windows/src/settings/settings_app.cpp` | 单独的 `wowtype-settings.exe`，控件按设置项表生成，写回用 `Config::merged`（macOS `merged(changesFrom:into:)` 的 C++ 版） |
| 引擎、数据 | `windows/src/tsf/engine_host.*` | 一个进程一份引擎（后台载入），设置文件改了下一次按键生效，学到的词每 20 次上屏存一次 |
| 注册 | `windows/src/tsf/register.cpp`、`dllmain.cpp` | `regsvr32`：COM 类、简体中文下的输入法配置、能力类别（含沉浸式 / UWP） |
| 测试 | `windows/tests/`、`windows/test.sh` | 按键测试照 `macos/Tests/main.swift`、`fcitx5-addon/test/key_harness.cpp` 的同名用例；Linux 上也能跑 |

核心为了在 Windows 上编过加的东西都在 `core/src/platform.rs`：本地时间用 CRT 的 `localtime_s`，家目录、缓存目录用
`%USERPROFILE%`、`%LOCALAPPDATA%`，起 `curl`、`llama-server` 时不弹黑框（`CREATE_NO_WINDOW`），`llama-server` 放进
一个「输入法所在的进程退出就一起杀掉」的 Job Object（Linux 上是 `PR_SET_PDEATHSIG`）。Linux、macOS 上行为不变。
互译和 Linux 一样用系统的 `curl` 发请求：Windows 10 1803 起系统自带 `C:\Windows\System32\curl.exe`，`-K -`（从标准输入读配置）
CI 上的核心测试会真的起 `curl.exe` 对着本机的假服务跑一遍。

## 编译

要 Visual Studio 2022（带「使用 C++ 的桌面开发」）、CMake 3.21+、Rust（`x86_64-pc-windows-msvc`）。在「x64 Native Tools Command Prompt」里：

```bat
set RUSTFLAGS=-C target-feature=+crt-static
cargo build --release -p wowtype-core --target-dir target\windows
cmake -S windows -B build\windows -A x64 -DWOWTYPE_CORE_LIB=%CD%\target\windows\release\wowtype_core.lib
cmake --build build\windows --config Release
```

产物在 `build\windows\Release\`：`wowtype.dll`（输入法）、`wowtype-windows-harness.exe`（按键测试）、
`wowtype-windows-config-dump.exe`（设置契约：`python scripts\test-config-contract.py --windows build\windows\Release\wowtype-windows-config-dump.exe`）。
核心和 DLL 都静态链 C 运行库，DLL 不依赖 VC++ 运行库。不想自己编的话，用 CI 的 `windows-x64` artifact 里的安装包（见下面）。

和平台无关的部分（组字、设置、按键翻译）在 Linux 上也能测：`windows/test.sh`（要 `c++` 和 Python 3）。

## 装上试试

**用安装程序**（推荐）：[Releases](https://github.com/Gloridust/WowType/releases) 里的 `WowType-<版本>-windows-x64-setup.exe`
（Inno Setup，`windows/installer/wowtype.iss`），双击装，会问一次管理员权限。装到 `%ProgramFiles%\WowType`、用 `DllRegisterServer`
注册、以装的人自己的身份把 WowType 加进键盘列表（系统 `input.dll` 的 `InstallLayoutOrTip`，没有中文就连中文一起加；
和 macOS 装完加进输入法、Linux 加进 fcitx5 一样）、开始菜单放「WowType 设置」，「设置 → 应用」里能卸载（学到的词、设置留着）。升级直接装新版：正在用着输入法的应用锁着旧的
`wowtype.dll`，安装程序把它改名换下来、装上新的，这些应用重开以后用新版；下次安装时删掉换下来的。没有代码签名：第一次运行时
SmartScreen 会提示「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。静默安装：`setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`。
CI 每次都在 runner 上静默装一遍、建一个文本服务对象、在 DLL 被用着时升级一遍、再卸载，检查注册表、开始菜单和卸载项；
发版时 x64 的安装程序进 Release（ARM64 的在 `windows-arm64` artifact 里，没有在真机上试过，不进 Release）。

**用 zip**（开发、试用）：CI 每次跑完都有一个 `windows-x64` 的 artifact，里面是 `WowType-<版本>-windows-x64.zip`
（`windows/package.sh` 打的：`wowtype.dll`、`data\` 下的词库和许可证、`install.ps1`）。解开以后，以管理员身份打开 PowerShell，进到解开的目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1             # 装到 %ProgramFiles%\WowType 并注册
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall  # 卸载（用户数据留着）
```

装好以后在「设置 → 时间和语言 → 语言和区域 → 中文（简体，中国）→ 语言选项 → 键盘」里能看到 **WowType**（注册时默认启用），
用 `Win + 空格` 切过去。重装、升级直接再跑一遍 `install.ps1`：正在用着输入法的应用锁着旧的 `wowtype.dll`，
脚本把它改名留着、照样装上新的，这些应用重开以后用新的。装到 `%ProgramFiles%` 是因为商店应用、开始菜单的搜索框
只能载入这种位置的输入法。CI 每次都用这个脚本在 runner 上真装、建一个文本服务对象、再卸载一遍。

**手动装**（自己编的 DLL）：照 `install.ps1` 的样子放文件，再注册：

```
C:\Program Files\WowType\wowtype.dll
C:\Program Files\WowType\data\lexicon.tsv      词库（必须有）
C:\Program Files\WowType\data\english.txt      英文词表
C:\Program Files\WowType\data\words.lm         词级语言模型（可选，没有也能打，候选差一些）
C:\Program Files\WowType\data\nnlm.bin         整句增强模型（可选）
C:\Program Files\WowType\data\s2t.tsv          简繁表（繁体输出要，仓库里的 core\data\s2t.tsv）
C:\Program Files\WowType\data\wubi86.tsv       五笔码表（选五笔才要）
```

数据文件和 Linux、macOS 安装包里的是同一份：CI 的 `data` artifact（`scripts/make-data.sh`、`scripts/make-wubi.sh` 的输出），
或者用 7-Zip 打开 [Releases](https://github.com/Gloridust/WowType/releases) 里的 `wowtype-data_*.deb`，取出 `usr/share/wowtype/` 下的文件。

```bat
regsvr32 "C:\Program Files\WowType\wowtype.dll"
regsvr32 /u "C:\Program Files\WowType\wowtype.dll"
```

DLL 装进每个应用的进程里，载入以后不会卸载：换 DLL 前先关掉用着输入法的应用（或者像 `install.ps1` 那样先改名）。

## 检查更新

和 macOS 一样（`windows/src/common/app_update.*` 是 macOS `AppUpdate.swift` 的 C++ 版，`windows/src/win/updater.*` 联网）：
`CheckUpdate` 开着时，输入法每天最多问一次 GitHub 的发布页（切到 WowType 时后台查，不挡打字；`BetaUpdates` 开着时预发布也算），
结果记在数据目录的 `update-state`；有新版时任务栏「中」按钮的右键菜单里多一项「有新版本 …，下载并安装…」，点它打开设置窗口
「常规」页。设置窗口里「检查更新」随时查，「下载并安装」下载 `WowType-<版本>-windows-<架构>-setup.exe` 和同一页的 `SHA256SUMS`、
校验，给你看「这一版」的更新内容，确认后运行安装程序（问一次管理员权限），设置窗口自己退出好让安装程序换掉它。
开发版（版本号不是数字开头）不查。有新版的提醒只在任务栏菜单里，不弹系统通知（和 macOS 一样）。
查有没有新版、有哪些文件走网页，不用 GitHub 的接口（不登录时每个 IP 每小时只能问 60 次，校园网、公司网很多人共用一个 IP），
和 Linux、macOS 一样：`releases/latest` 跳到的 tag 页是最新正式版，Beta 计划开着时再看 `releases.atom`、从版本号大的往下试
（只推了 tag、还没发出来的没有 `SHA256SUMS`，跳过），文件列表和下载地址从这一版的 `SHA256SUMS` 拼；网页那条路走不通时才问接口。
更新说明只在比现在装的新时才取：先下这一版的 `RELEASE-NOTES.md`（0.7.1 起发布任务单独传的「这一版要注意」），更早的版本
没有这个文件就问一次接口，都拿不到就是一句「见发布页」，不算检查失败。每个应用进程各有一个输入法：查不成时 `update-state` 记下试过的时间，
所有应用合起来一小时最多再试一次。模型下载（语音、本地翻译、llama.cpp）用的是固定的下载地址，不走接口。

## 设置和数据

数据目录是 `%LOCALAPPDATA%\WowType\`（`WOWTYPE_DATA_DIR` 可以换，测试用）：

| 文件 | 说明 |
|---|---|
| `wowtype.conf` | 设置，**键名、取值、默认值和 Linux、macOS 一样**，文件拷过来就能用（[CONFIG.md](CONFIG.md)）。用设置窗口改（开始菜单「WowType 设置」或任务栏「中」按钮右键 →「WowType 设置…」），也可以右键 →「打开设置文件」用记事本改；存了以后下一次按键生效 |
| `user.tsv`、`history.tsv` | 学到的词和输入习惯，格式同另两端 |
| `custom.tsv` | 自定义词，格式同 Linux（[CONFIG.md](CONFIG.md#自定义词)） |
| `emoji-recent.txt` | 最近用过的 emoji |
| `translate.key` | 互译的 API Key（一行） |
| `sync.json`、`sync-relay.key` | [跨设备复制粘贴](SYNC.md)的配对文件（设备编号、组密钥）和中转服务的访问口令 |
| `wetype\nlrgpt2_nnlm.bin` | 导入的微信输入法整句增强模型（有就先用它） |
| `models\Hy-MT3-1.8B-Q4_K_M.gguf`、`llama\llama-server.exe` | 本地翻译模型和 llama.cpp（`TranslateLlamaServer` 留空时先在 PATH 里找） |
| `wtlocal\` | 语音识别模型（微信输入法的离线模型，不随安装包分发，自己放进来） |
| `stats.json` | 打字统计（`TypingStats=True` 才记，默认关），格式同另两端 |
| `update-state`、`update\` | 检查更新的结果、下载的新版安装程序 |
| `wowtype.log` | 日志（载入词库、设置、出错），超过 1 MB 从头写 |

和另两端一样的：`EmojiKey` 默认是 `Control+period`（Windows 键的组合多半被系统拿走，`Win + .` 是系统的表情面板，
所以和 macOS 一样把 `Super` 当 `Control`）；候选框是自己画的，所以和 macOS 一样认 `CandidateFontSize`（候选字号，默认 17）。

切到别处（点了别的地方、换了输入框、切走输入法）时打到一半的字母原样上屏，和 macOS 一样（Linux 上是丢掉，原因见 macOS 的说明）。

## 设置窗口

设置窗口（`wowtype-settings.exe`，`windows/src/settings/`）有常规、候选、输入、模糊音、标点与表情、语音、翻译、自定义词八页，
按 `spec/config.json` 里 Windows 认的项生成，只写改过的键（和 macOS 一样，别处改的、注释、不认识的键留着），API Key 存 `translate.key`。
「自定义词」页能加词（照词库自动猜拼音）、删词、导入，规则和 macOS 的 `CustomWords` 一样（`windows/src/common/custom_words.*`）。
「输入」页能导入整句增强模型（核心先试着解析，放到 `wetype\`）；「语音」页能一键下载语音模型（和 Linux 设置同一个地址，
校验大小和 MD5，用系统的 `tar.exe` 解包到 `wtlocal\`），也能导入现成的模型文件夹；「统计」页看打字统计
（今天、一共、最快的一天、连续天数，最近 30 天的柱状图，键盘热力图，口径、键盘排法、深浅五档都和 macOS 一样），能清空；「常规」页能复制诊断信息
（版本、数据文件、打过码的设置、最近的日志）。
「翻译」页能一键下载本地翻译模型（Hy-MT3 1.8B，和另两端同一个文件、同一个 SHA256；以前下载过上一代 HY-MT 1.5 的照旧能用，
再点下载会换成新的、下好以后删掉旧的）和 llama.cpp 官方的
Windows 程序（`b12110` 的 CPU 包，钉死 SHA256，解到 `llama\`；PATH 里、设置里有 llama-server 就不下）。
「翻译」页的「翻译引擎」和 Linux、macOS 一样三选一（本地翻译 / 哔哩哔哩 / 自定义翻译服务，[CONFIG.md](CONFIG.md#翻译引擎)），
选哪个下面只出现哪个的设置：本地是模型文件、llama-server、下载按钮；哔哩哔哩是模型（Index-Translate-2B / 9B / 35B-A3B）
和隐私说明；自定义是地址、API Key、模型。选中哪个从 `TranslateLocal` 和 `TranslateBaseUrl` 推出来，换引擎时写上这个引擎的
地址和模型；自定义的地址、模型换到哔哩哔哩再换回来照原样写回（只记在这次打开的窗口里），`translate.key` 不动，也不发给哔哩哔哩。
「跨设备」页是[跨设备复制粘贴](SYNC.md)：开关、局域网直连、中转服务地址、设备名，下面是配对（显示配对码 / 输入配对码 / 取消配对）、
中转服务的访问口令和测试。「剪贴板」页是[剪贴板历史](CONFIG.md#剪贴板历史)：开关、留几天，「查看剪贴板历史…」打开一个窗口，
列出记录（时间、来源、内容），能搜索、复制、删除（`Delete`）、全部清空，双击一条复制。
输入法是加载进每个应用进程的 DLL，不能每个进程各起一份同步、各听一份剪贴板，所以这两样在一个后台进程里：
`wowtype-settings.exe --sync-agent`（一个不显示的窗口，同一时间只有一个）。保存时剪贴板历史或跨设备复制粘贴开着就起它，并在
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 里登记登录时自启；两个都关掉以后它下一秒自己退，自启也去掉；卸载时停掉。
它听剪贴板变化（`AddClipboardFormatListener`），密码管理器标了 `ExcludeClipboardContentFromMonitorProcessing`、
`CanIncludeInClipboardHistory=0`、`CanUploadToCloudClipboard=0` 的不读；开着剪贴板历史时把复制的记进数据目录的
`clipboard-history.json`（记着前台程序的 exe 名），输入法 DLL 只读、删这个文件；别的设备复制过来的放进系统剪贴板。
规则在 `windows/src/common/translate_engine.*`。哔哩哔哩和自定义下面有「测试连接」：用核心的翻译器（和输入法同一套请求，
系统的 `curl.exe`）译一次「你好」，显示译文和用了几秒；自定义的 Key 没保存时用框里的。
下载（模型、新版安装程序）断了从断的地方接着下：没下完的先存成 `.part`，一次下载里断了自动接几次，还不行就留着，
再点一次下载接着下；服务器不认续传（HTTP Range）就从头下。下完照旧校验（SHA256、MD5），不对就删掉。
「常规」页最后一行是设置窗口自己的主题（跟随系统 / 浅色 / 深色，`SettingsTheme`）和强调色（`SettingsAccent`），选了马上换，
存盘还是点「保存」。跟随系统时看「设置 → 个性化 → 颜色」的应用模式（`AppsUseLightTheme`），系统换了也跟着换；深色时标题栏、
按钮、下拉框、输入框用系统自带的深色样式（`DarkMode_Explorer`、`DarkMode_CFD`），勾选框去掉样式好让字是浅色的。
标签那一排自己画，选中的标签是强调色，统计图的柱子、热力图也跟着强调色。颜色表在 `windows/src/common/look.*`，和另两端对照同一份规格。

## 这一阶段还没有的

这些在 Linux、macOS 上有（或者另两端用不着），Windows 上还没做：

- 代码签名：现在安装程序和 DLL 都没签，SmartScreen 会拦一下。CI 已经准备好了：在仓库的「Settings → Secrets and variables → Actions」
  里加 `WINDOWS_SIGNING_PFX`（代码签名证书 .pfx 文件的 base64，`base64 -w0 cert.pfx`）和 `WINDOWS_SIGNING_PASSWORD`，
  之后每次 CI 都用 `signtool` 签 `wowtype.dll`、`wowtype-settings.exe` 和 x64 安装程序（带时间戳）。卸载程序 `unins000.exe` 还不签。
  证书要自己买（OV 证书要攒下载量 SmartScreen 才不拦，EV 证书一上来就不拦）
- ARM64 只编不跑：CI 编出 `WowType-<版本>-windows-arm64.zip`（`windows-arm64` artifact），但没有 ARM64 的机器试过；
  ARM64 的 Windows 上，原生 ARM64 的应用载入 ARM64 的 DLL，模拟运行的 x64 应用要 x64 的 DLL，两个怎么一起装还没做
- 32 位
- 全屏游戏里的候选框（`ITfUIElement`，让游戏自己画）

## 端到端打字测试

`windows/tests/typing_test.cpp`（`wowtype-windows-typing-test.exe`），CI 用安装程序装好以后跑：开一个带输入框（系统的 EDIT 控件）的窗口，
用 TSF 把这个进程的输入法切到 WowType，用 `SendInput` 按真的键，读输入框里的字、看候选框窗口。走的是和真实应用一样的路：
系统的按键 → TSF → `wowtype.dll`（文本服务、Composer、核心的会话）→ 组字、上屏 → 输入框。现在测的（真实词库）：

- 切到 WowType（安装程序已经把它加进了键盘列表）
- `nihao` 空格 → 你好；打字途中候选框出来、在输入框附近；数字选第二个候选，上屏以后候选框收起
- 打字途中按逗号先上屏候选再上屏「，」，没在打字时句号是「。」
- 回车上屏原始字母、退格删一个字母、Esc 清空不上屏
- 单按 Shift 切英文（字母原样上屏）、再单按切回中文；任务栏输入指示器上 WowType 的按钮跟着变「中 → 英 → 中」（通过 TSF 读按钮的字）
- 打到一半失去焦点：不留下编辑区
- RichEdit（TSF 原生的富文本框，写字板和很多应用用它）：你好、候选框、回车上屏字母
- Microsoft Edge（Chromium 的 TSF，Chrome、VS Code、各种 Electron 应用走同一条路）：在另一个进程里开一个网页输入框，
  **用 `Win + 空格` 切到 WowType**（认准出来的是 WowType 的候选框，不是系统自带的微软拼音），打出你好、候选框在输入框附近、
  数字选候选、打字途中按逗号
- 两个进程（两个应用）之间：B 开着，A 学到 shi 的第三个候选，B 不用重开再打一次就是它；A 用 Ctrl+退格忘掉它，
  B 也忘了，B 存过盘以后 A 也没有回来。清空输入框以后不拿上一次上屏的字当上文（和 fcitx5、macOS 一样）

下载续传另有一个测试（`windows/tests/download_test.cpp` 配 `windows/tests/range_server.py`，一个会掐断连接的服务器）：
一次下载里断了好几次自动接上；服务器不认续传时从头下；这一次下不完留着 `.part`，下一次从断的地方接着下完、校验对得上。

它第一次跑就抓到了两个只有真打字才看得出的问题：英文系统上键盘列表里没有 WowType 就切不过去（安装程序现在会加进去），
TSF 先问后给的两次按键回调 `lParam` 高位不一样、每个键被处理了两遍（`nihao` 出成 `nniihhaaoo`，现在只比键码和扫描码）。
没过的时候 CI 打出输入法日志（测试开着 `WOWTYPE_DEBUG_KEYS`，每个按键回调都记一行）。

## 还没验证的

CI 的端到端打字测试在一台 Windows Server 上、三种输入框（EDIT、RichEdit、Edge 的网页输入框）里打。下面这些还要在真的电脑、真的应用里试：

- 任务栏输入指示器的样子（图标画得清不清楚）、点它切换、右键菜单
- 别的应用里打字：Word、微信 / QQ、Windows Terminal、商店应用（UWP）、开始菜单的搜索框
- 编辑区的虚线下划线（显示属性）、光标在编辑区里的位置、选了一半时的编辑区
- 候选框：多显示器、高 DPI、深色模式、彩色 emoji、鼠标点候选和翻页箭头、滚轮（位置在 EDIT 控件里已经对了）
- 单按 Shift 的边角：右 Shift、按住不放的自动重复、和 Ctrl / Alt / Win 一起按（左 Shift 单按已经测了）
- 自动配对（`AutoPairPunct`）挪光标、成对删：用 `ITfContext::SetSelection` 和删字实现，各应用支不支持不知道
- 读光标前后的字（自动加空格、数字后的标点、自动配对的核对）、密码框 / 网址框的识别（InputScope）
- 语音输入：TSF 的按键回调收不收得到右 Alt（`WM_SYSKEYDOWN`），吃掉右 Alt 以后应用的菜单栏还会不会被激活；
  麦克风（「设置 → 隐私 → 麦克风 → 允许桌面应用访问」）；商店应用里没有麦克风权限，用不了
- 互译：`curl.exe` 在各种应用进程里能不能起（沙盒里的 UWP 应用起不了子进程，这时会报翻译失败）、本地模型的 `llama-server` 跟着应用退出
- 沉浸式 / UWP 应用里：数据目录会被重定向到应用自己的容器，读不到 `%LOCALAPPDATA%\WowType` 的设置和学到的词（只用自带的词库、默认设置）
- 同一个进程几个界面线程（资源管理器）共用一个引擎（用锁串起来）
- 每个应用进程各载一份词库（几十 MB 内存）、各自学词。学到了词最多隔 2 秒存一次（核心的存盘线程写，不挡打字），
  每个应用每次按键都看一眼 `user.tsv`、`history.tsv` 有没有被别的应用存过，存过就合并进来（用户词取并集，输入习惯同一条留
  最近用过的，核心的 `load_history` 这样合并），所以在一个应用里学到的词，几秒以后在别的应用里也有了，和 Linux、macOS 的
  一个输入法进程差不多。在一个应用里 Ctrl+Delete 忘掉的词，连同忘掉的时间记进 `history.tsv`（`f` 行），别的应用
  合并时把在这之前学到的（用户词、热度、搭配、候选新词）都去掉，存盘时也不会写回去；忘掉以后又选过的照常留着
  （CI 的两个进程测试：A 学到、B 也有；A 忘掉、B 也忘了；B 存过盘以后 A 也没有回来）。还不一样的：每个应用多占
  几十 MB 内存。根本的办法是改成一个单独的输入法进程，文本服务通过进程间通信用它（和小狼毫、PIME 一样），还没做
