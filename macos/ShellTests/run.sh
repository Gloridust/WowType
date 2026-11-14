#!/usr/bin/env bash
# macOS 外壳测试（只能在 macOS 上跑）：真的输入控制器、候选框，假的输入框。
#
#   macos/ShellTests/run.sh <数据目录>
#
# 数据目录是 scripts/make-data.sh + scripts/make-wubi.sh 的输出（lexicon.tsv、english.txt、wubi86.tsv，
# 有 words.lm 也用上）。把 Sources/Shared、Sources/App（除了 main.swift）和这里的文件编成一个可执行文件，
# 数据文件链接到它旁边（当安装包的 Resources），用户数据目录（WOWTYPE_DATA_DIR）和 HOME 都是临时目录。
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ "$(uname)" == Darwin ]] || { echo "只能在 macOS 上跑" >&2; exit 1; }
DATA=${1:?用法：macos/ShellTests/run.sh <数据目录>}
DATA=$(cd "$DATA" && pwd)
for f in lexicon.tsv english.txt wubi86.tsv; do
  [[ -f "$DATA/$f" ]] || { echo "数据目录里没有 $f" >&2; exit 1; }
done

TARGET_DIR=${WOWTYPE_MACOS_TARGET_DIR:-target/macos-novoice}
OUT=$TARGET_DIR/shell-tests
mkdir -p "$OUT"
cargo build --release -q -p wowtype-core --no-default-features --target-dir "$TARGET_DIR"

app_sources=()
for f in macos/Sources/App/*.swift; do
  [[ "$(basename "$f")" == main.swift ]] || app_sources+=("$f")
done
swiftc -O -module-name WowType -I macos/CWowtype \
  macos/Sources/Shared/*.swift "${app_sources[@]}" macos/ShellTests/*.swift \
  "$TARGET_DIR/release/libwowtype_core.a" \
  -framework Cocoa -framework InputMethodKit -framework Carbon -framework SwiftUI \
  -framework AVFoundation -framework AudioUnit -framework CoreAudio \
  -liconv -o "$OUT/wowtype-shell-tests"

# 可执行文件旁边就是 Bundle.main.resourceURL：当安装包的 Resources
for f in lexicon.tsv english.txt words.lm wubi86.tsv; do
  [[ -f "$DATA/$f" ]] && ln -sf "$DATA/$f" "$OUT/$f"
done
ln -sf "$PWD/core/data/s2t.tsv" "$OUT/s2t.tsv"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/data" "$work/home"
# 用户数据、偏好设置（CFFIXED_USER_HOME）都落在临时目录
WOWTYPE_DATA_DIR="$work/data" HOME="$work/home" CFFIXED_USER_HOME="$work/home" \
  "$OUT/wowtype-shell-tests"
