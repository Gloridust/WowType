#!/usr/bin/env bash
# 主机 JVM 上跑一遍安卓那层 JNI（不需要设备、不需要模拟器）。
#
#   android/test.sh [数据目录]
#
# 数据目录默认 dist/data（scripts/make-data.sh 的输出）。做的是：把 JNI 桥和核心链接成主机 .so，
# 用 javac 编 Frame / Native / Session，然后真的打拼音：ni'hao → 你好、空格选词、回车原样上屏、
# 退格、weixni → 微信、中英切换、emoji 四字节 UTF-8 过 JNI。
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=${1:-dist/data}
[[ -f "$DATA/lexicon.tsv" ]] || { echo "没有 $DATA/lexicon.tsv（先跑 scripts/make-data.sh，或传数据目录）" >&2; exit 1; }

JAVA_HOME=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}
[[ -f "$JAVA_HOME/include/jni.h" ]] || { echo "找不到 $JAVA_HOME/include/jni.h（设 JAVA_HOME）" >&2; exit 1; }

OUT=target/android-host-test
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/lib"

echo "构建核心（主机）"
cargo build --locked -q -p wowtype-core --no-default-features --target-dir "$OUT/cargo"

echo "链接 JNI 桥"
cc -shared -fPIC -O1 -g \
  -I core/include -I "$JAVA_HOME/include" -I "$JAVA_HOME/include/linux" \
  android/app/jni/wowtype_jni.c \
  "$OUT/cargo/debug/libwowtype_core.a" \
  -o "$OUT/lib/libwowtype.so" -lm -ldl -lpthread

echo "编译 Java"
javac -encoding UTF-8 -source 17 -target 17 -Xlint:-options -d "$OUT/classes" \
  android/app/java/io/github/gloridust/wowtype/Frame.java \
  android/app/java/io/github/gloridust/wowtype/Native.java \
  android/app/java/io/github/gloridust/wowtype/Session.java \
  android/hosttest/NativeTest.java

echo "运行"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# 学习数据写到临时目录，别动 dist/data
java -cp "$OUT/classes" -Djava.library.path="$OUT/lib" \
  io.github.gloridust.wowtype.NativeTest "$DATA"
