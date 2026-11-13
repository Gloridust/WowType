#!/usr/bin/env bash
# macOS 外壳的按键测试（不依赖 AppKit，Linux 和 macOS 都能跑）。
#
#   macos/test.sh [lexicon.tsv] [english.txt]
#
# 先编核心的静态库（不带语音，和 macOS 安装包一样），再用 swiftc 把 Sources/Shared 和 Tests/*.swift
# 编成一个可执行文件跑一遍。没给词库时测试自己写一份小词库。
# 测试也拿 spec/ 里的设置契约对照（WOWTYPE_SPEC_DIR，默认仓库的 spec/）。
# 本机没有 swiftc 但有 docker 时：WOWTYPE_SWIFT_DOCKER=swift:6.1-noble macos/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET_DIR=${WOWTYPE_MACOS_TARGET_DIR:-target/macos-novoice}
OUT=$TARGET_DIR/harness
mkdir -p "$OUT"

cargo build --release -q -p wowtype-core --no-default-features --target-dir "$TARGET_DIR"
LIBDIR=$TARGET_DIR/release

if [[ "$(uname)" == Darwin ]]; then
  LINK=("$LIBDIR/libwowtype_core.a" -liconv)
else
  LINK=("$LIBDIR/libwowtype_core.a" -lgcc_s -lutil -lrt -lpthread -lm -ldl)
fi
SWIFTC=(swiftc)
if [[ -n "${WOWTYPE_SWIFT_DOCKER:-}" ]]; then
  SWIFTC=(docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:$PWD" -w "$PWD" "$WOWTYPE_SWIFT_DOCKER" swiftc)
fi

"${SWIFTC[@]}" -O -I macos/CWowtype \
  macos/Sources/Shared/*.swift macos/Tests/*.swift \
  "${LINK[@]}" -o "$OUT/wowtype-macos-harness"

export WOWTYPE_SPEC_DIR=${WOWTYPE_SPEC_DIR:-$PWD/spec}
RUN=("$OUT/wowtype-macos-harness")
if [[ -n "${WOWTYPE_SWIFT_DOCKER:-}" ]]; then
  # 容器里编的可执行文件要容器里的 Swift 运行库
  RUN=(docker run --rm -u "$(id -u):$(id -g)" -e WOWTYPE_EXPECT_FULL_CHARS -e WOWTYPE_SPEC_DIR -v "$PWD:$PWD" -w "$PWD" "$WOWTYPE_SWIFT_DOCKER" "${RUN[@]}")
  # 词库路径要在挂进去的目录里
fi
"${RUN[@]}" "$@"
