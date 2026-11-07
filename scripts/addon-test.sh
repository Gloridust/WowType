#!/usr/bin/env bash
# 构建 fcitx5 插件并跑按键行为测试。
#
#   scripts/addon-test.sh [lexicon.tsv] [english.txt]
#   WOWTYPE_VOICE_WAV=说的话.wav WOWTYPE_VOICE_EXPECT=期望的字 scripts/addon-test.sh ...  # 加跑语音
#
# 起的是一个私有、无界面、无 D-Bus 的 fcitx5 实例（配置目录都在临时目录里），
# 不会影响正在用的输入法。不给词库时用仓库里的 demo 词典，部分用例会因为缺词失败。
set -euo pipefail
cd "$(dirname "$0")/.."

LEXICON=${1:-$PWD/core/data/demo_lexicon.tsv}
ENGLISH=${2:-}
BUILD=$(realpath -m "${WOWTYPE_ADDON_TEST_BUILD:-fcitx5-addon/build-test}")

cargo build --release -p wowtype-core
cmake -S fcitx5-addon -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DWOWTYPE_BUILD_TESTS=ON >/dev/null
cmake --build "$BUILD" -j

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/data/fcitx5/addon" "$ROOT/data/fcitx5/inputmethod" "$ROOT/config/fcitx5"
cp "$BUILD/wowtype-addon.conf" "$ROOT/data/fcitx5/addon/wowtype.conf"
cp "$BUILD/wowtype.conf" "$ROOT/data/fcitx5/inputmethod/wowtype.conf"
# fcitx5 自带的测试输入法，用来模拟「打到一半切换输入法」
cat > "$ROOT/data/fcitx5/addon/testim.conf" <<'ADDON'
[Addon]
Name=testim
Category=InputMethod
Library=libtestim
Type=SharedLibrary
OnDemand=False
ADDON
cat > "$ROOT/config/fcitx5/profile" <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=wowtype

[Groups/0/Items/0]
Name=wowtype
Layout=

[Groups/0/Items/1]
Name=testim
Layout=

[GroupOrder]
0=Default
PROFILE

# 语音用例要真模型：给了 WOWTYPE_VOICE_WAV（代替麦克风的录音）才跑，模型默认用本机已下载的那份
VOICE_WAV=${WOWTYPE_VOICE_WAV:-}
VOICE_MODEL_DIR=${WOWTYPE_VOICE_MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/wowtype/wtlocal}

SYSTEM_ADDONS=$(pkg-config --variable=libdir Fcitx5Core 2>/dev/null || echo /usr/lib/x86_64-linux-gnu)/fcitx5
env -i PATH="$PATH" HOME="$ROOT" \
  XDG_DATA_HOME="$ROOT/data" XDG_CONFIG_HOME="$ROOT/config" XDG_RUNTIME_DIR="$ROOT" \
  XDG_DATA_DIRS="/usr/share" \
  FCITX_ADDON_DIRS="$BUILD:$SYSTEM_ADDONS" \
  WOWTYPE_LEXICON="$LEXICON" WOWTYPE_ENGLISH="$ENGLISH" \
  WOWTYPE_USER_DICT="$ROOT/user.tsv" \
  WOWTYPE_VOICE_WAV="$VOICE_WAV" WOWTYPE_VOICE_MODEL_DIR="$VOICE_MODEL_DIR" \
  WOWTYPE_NO_UPDATE_CHECK=1 WOWTYPE_HARNESS_SHOW="${WOWTYPE_HARNESS_SHOW:-}" WOWTYPE_VOICE_EXPECT="${WOWTYPE_VOICE_EXPECT:-}" \
  "$BUILD/wowtype-key-harness"
