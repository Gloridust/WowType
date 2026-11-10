# 从源码构建：每一步怎么验证

普通用户用 [README](../README.md#安装) 里的安装包就行。这里是从源码一步步构建、每步都能验证的版本，
方便出问题时定位到哪一层。需要 fcitx5 5.1 或更新（Ubuntu 24.04 / Debian 13 起）。

## 0. 依赖

```bash
sudo apt update
sudo apt install -y build-essential pkg-config cmake extra-cmake-modules \
  libasound2-dev libx11-dev libxkbcommon-dev \
  libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev \
  fcitx5 fcitx5-frontend-gtk3 fcitx5-frontend-qt5 \
  python3-gi gir1.2-gtk-4.0 gir1.2-adw-1
```

只有语音需要 `libasound2-dev` 和 `libx11-dev`；只想用文字输入可以省掉。
`python3-gi gir1.2-gtk-4.0 gir1.2-adw-1` 是设置界面 `wowtype-config` 运行时要的（libadwaita 1.4+），不影响编译。

## 1. 构建核心并验证

```bash
git clone https://github.com/Gloridust/WowType.git
cd WowType
cargo build --release -p wowtype-core
cargo test --workspace                      # 142 项
./scripts/abi-smoke.sh                      # C ABI 22 项，插件依赖的就是它
```

三条都绿再往下走。`abi-smoke` 失败说明核心有问题，装插件也没用。

## 2. 准备词库

词库是唯一必须自己准备的数据。用雾凇拼音（开源、覆盖好）：

```bash
sudo apt install -y git python3
git clone --depth 1 https://github.com/iDvel/rime-ice.git /tmp/rime-ice
python3 tools/rime2tsv.py /tmp/rime-ice/rime_ice.dict.yaml > /tmp/lexicon.tsv
wc -l /tmp/lexicon.tsv        # 约 55 万行
sudo mkdir -p /usr/share/wowtype
sudo cp /tmp/lexicon.tsv /usr/share/wowtype/lexicon.tsv
```

`rime2tsv.py` 会顺着 `import_tables` 递归合并被引用的词库——rime-ice 的条目几乎都在
`cn_dicts/base` 里，只转主文件会只剩不到一万条。缺 `cn_dicts/ext` 之类的警告可以忽略。

### 语言模型（可选）

有 ARPA 或 bigram TSV 就设置 `WOWTYPE_LM`。**没有真实语料就别用**
`tools/make_bigram.py` 生成的那种，实测会掉点（见 [ENGINE.md](ENGINE.md)）。

## 3. 自检

```bash
cargo run -p wowtype-core --bin wowtype-check -- \
  --lexicon /usr/share/wowtype/lexicon.tsv \
  --s2t core/data/s2t.tsv
```

预期：`[ok] 词库: 552087 条词 ... 跳过 27 行`，以及符号表/双拼/模糊音三项 ok。

首次加载会在词库旁边生成 `lexicon.tsv.wcache`（约 18MB）。`/usr/share` 只读时
快照会落到 `~/.cache/wowtype/`，第二次启动就从 1.4s 降到 0.35s。删除快照没有副作用，
下次自动重建。
词库缺失时退出码为 1。

顺手试一下真实输入：

```bash
cargo run --release -p wowtype-core --bin wowtype-demo -- \
  --lexicon /usr/share/wowtype/lexicon.tsv nihao
# 1. 你好
```

## 4. 构建并安装 fcitx5 插件

```bash
cmake -S fcitx5-addon -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
cmake --build build -j$(nproc)
sudo cmake --install build
```

安装后会看到：

```
/usr/bin/wowtype-config
/usr/share/applications/io.github.Gloridust.WowType.Config.desktop
/usr/lib/x86_64-linux-gnu/fcitx5/libwowtype.so
/usr/include/wowtype/wowtype_core.h
/usr/share/fcitx5/addon/wowtype.conf
/usr/share/fcitx5/inputmethod/wowtype.conf
/usr/share/wowtype/demo_lexicon.tsv
/usr/share/wowtype/s2t.tsv
```

缺词库时代码会退到 `demo_lexicon.tsv`（17 个词），能验证链路但没法日常用。

不想装设置界面：cmake 时加 `-DWOWTYPE_INSTALL_SETTINGS=OFF`，就没有前两个文件。
设置界面自己能跑一遍单元测试（不开窗口）：`python3 settings/wowtype-config --self-test`。

## 5. 启用

```bash
fcitx5 -rd                      # 重启
fcitx5-configtool               # 或在托盘里「配置」
```

在「输入法」页把 **WowType** 加进列表，然后切过去试打 `nihao`。
也可以运行 `wowtype-config`，「常规」页会检查 WowType 在不在列表里，不在就点「添加」。

如果托盘里根本没有 fcitx5，先确认输入法框架是它：

```bash
im-config -n fcitx5             # 然后重新登录
```

## 6. 出问题怎么查

| 现象 | 原因 | 处理 |
|---|---|---|
| `find_package(Fcitx5Core)` 失败 | 缺 `libfcitx5core-dev` | 按第 0 节装依赖 |
| CMake 报找不到 `libwowtype_core.a` | 没先 `cargo build --release -p wowtype-core` | 先构建，或用 `-DWOWTYPE_CORE_LIB=` 指定 |
| 插件编过但输入法列表里没有 | 配置没装对 | 检查 `/usr/share/fcitx5/addon/wowtype.conf` 是否存在 |
| 加载失败 | 看日志里 wowtype 那几行 | `fcitx5 -r --verbose=*=5 2>&1 \| grep -i wowtype` |
| 打得出来但全是英文 | 词库没加载 | 设 `WOWTYPE_LEXICON` 指到词库，重启 fcitx5 |
| `wowtype-config` 报 `Namespace Adw not available` | 缺 libadwaita 的 GI 绑定 | `sudo apt install gir1.2-adw-1` |
| 设置里改了没效果 | 设了同名环境变量，它优先 | `env \| grep WOWTYPE`，去掉它 |
| 候选为空 | 同上 | 跑第 3 步的自检 |

看日志：

```bash
fcitx5 -rd --verbose 2>&1 | grep -i wowtype
fcitx5-diagnose | head -50
```

## 7. 语音（可选）

离线识别（微信离线模型，纯本地，不需要任何外部程序）：

```bash
sudo apt install -y curl unzip
wowtype-voiced --asr wtlocal      # 首次会从 CDN 下载约 100MB 并校验 MD5
```

或者先单独验证引擎能否识别一段 16kHz 单声道 WAV：

```bash
cargo run --release -p wowtype-voice --bin wowtype-asr -- --download 测试.wav
```

```bash
cargo build --release -p wowtype-voiced
# X11 下：默认 Alt+A 触发（可 --hotkey 改）
./target/release/wowtype-voiced \
  --asr-cmd 'sherpa-onnx-offline --tokens=tokens.txt --paraformer=model.onnx --wav={wav}'
```

上屏默认走剪贴板（`wl-copy` + Ctrl+V 或 `xclip` + Ctrl+V），因为 `ydotool type`
**发不出汉字**。按环境装其一：

```bash
sudo apt install -y wl-clipboard          # Wayland
sudo apt install -y xclip xdotool         # X11
```

Wayland 下没有全局热键 API，需要 `keyd` / `kanata` 把按键映射成给本进程发信号。

## 环境变量

平时的设置用 `wowtype-config`（存在 `~/.config/fcitx5/conf/wowtype.conf`，键名见 [CONFIG.md](CONFIG.md#配置文件和环境变量)）。
下面的环境变量主要用来调试和测试，设了就**优先于**配置文件。

| 变量 | 作用 | 默认 |
|---|---|---|
| `WOWTYPE_LEXICON` | 词库路径 | `/usr/share/wowtype/lexicon.tsv` |
| `WOWTYPE_LM` | bigram TSV | 无 |
| `WOWTYPE_S2T` | 简繁表 | `/usr/share/wowtype/s2t.tsv` |
| `WOWTYPE_USER_DICT` | 用户词库 | `$XDG_DATA_HOME/wowtype/user.tsv` |
| `WOWTYPE_FUZZY=1` | 模糊音 | 关 |
| `WOWTYPE_SHUANGPIN=1` | 双拼 | 关 |
| `WOWTYPE_SHUANGPIN_SCHEME` | 双拼方案（`ziranma`、`xiaohe`、`microsoft`、`sogou`、`abc`、`ziguang`、`pinyinjiajia`），设了就打开双拼 | `ziranma` |
| `WOWTYPE_SHIFT_TOGGLE` | 单按哪个 Shift 切英文：`both`、`left`、`right`、`off` | `both` |
| `WOWTYPE_TRADITIONAL=1` | 繁体输出 | 关 |
| `WOWTYPE_TYPO=0` | 关掉按错键纠错 | 开 |
| `WOWTYPE_VERTICAL=1` | 候选竖排 | 横排 |
| `WOWTYPE_VOICE_KEY` | 语音键（fcitx5 键名），`none` 关掉 | `Alt_R` |
| `WOWTYPE_VOICE_OVERLAY=0` | GNOME 上不用语音浮条，用候选框里的文字提示 | 用浮条 |
| `WOWTYPE_CUSTOM` | 自定义词文件 | `$XDG_DATA_HOME/wowtype/custom.tsv` |
| `WOWTYPE_NO_UPDATE_CHECK` | 设了就不自动检查更新 | 不设 |
| `WOWTYPE_SINK` | 语音上屏后端 | `clipboard` |

## 已知限制

- 词库必须自己准备（WeType 原库解不出来，见 `docs/DATA.md`）
- 简繁转换是字符级的，不处理「发/髮」这类词组歧义
- 语音的采集与全局热键**没有在 Linux 上实机验证过**（见 `docs/VOICE.md`）
- fcitx5 插件是本项目唯一没有经过编译验证的代码（API 已逐项核对）

## 卸载

```bash
# 安装包装的
sudo apt remove wowtype

# 源码装的（在仓库目录里）
sudo xargs rm -v < build/install_manifest.txt

# 学到的数据、自定义词、设置和缓存（可选）
rm -rf ~/.local/share/wowtype ~/.local/state/wowtype ~/.cache/wowtype ~/.config/fcitx5/conf/wowtype.conf
```

卸载后到 Fcitx 5 配置里把 WowType 从输入法列表里删掉，再 `fcitx5 -r -d`。
