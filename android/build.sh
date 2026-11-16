#!/usr/bin/env bash
# 打安卓输入法 APK（arm64 优先）。
#
#   android/build.sh <数据目录> [输出目录]
#
# 数据目录是 scripts/make-data.sh 的输出（lexicon.tsv、english.txt、words.lm、LICENSE、SOURCE.txt、VERSION）。
# 环境变量：
#   ANDROID_HOME / ANDROID_SDK_ROOT   Android SDK；NDK 取 $ANDROID_HOME/ndk 里最新的，或 ANDROID_NDK_HOME
#   WOWTYPE_ANDROID_ABIS              默认 arm64-v8a；可以写成 "arm64-v8a armeabi-v7a x86_64"
#   WOWTYPE_VERSION                   默认取 core/Cargo.toml
#   WOWTYPE_ANDROID_KEYSTORE          签名用的密钥库；不设就在输出目录生成一个（口令 wowtype）
#   WOWTYPE_ANDROID_KEYSTORE_PASS / WOWTYPE_ANDROID_KEY_PASS  口令，默认都是 wowtype
#   WOWTYPE_ANDROID_KEY_ALIAS         默认 wowtype
#
# 产物：<输出目录>/WowType-<版本>-android-<abi>.apk，每个架构一个（词库和语言模型都在里面，
# 第一次打开时解到应用私有目录）。没有 Gradle：用 SDK 的 aapt2 / d8 / zipalign / apksigner 直接拼，
# 和 macos/build.sh 用 swiftc 直接编一样，CI 和本机只要装了 SDK 就能跑。
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=${1:?用法：android/build.sh <数据目录> [输出目录]}
OUT=${2:-dist/android}
VERSION=${WOWTYPE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)}
ABIS=${WOWTYPE_ANDROID_ABIS:-arm64-v8a}
MIN_SDK=24
TARGET_SDK=35
APP=android/app

for f in lexicon.tsv english.txt words.lm LICENSE SOURCE.txt VERSION; do
  [[ -f "$DATA/$f" ]] || { echo "数据目录里没有 $f（先跑 scripts/make-data.sh）" >&2; exit 1; }
done

SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[[ -n "$SDK" && -d "$SDK" ]] || { echo "要 ANDROID_HOME（或 ANDROID_SDK_ROOT）指向 Android SDK" >&2; exit 1; }
BUILD_TOOLS=$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)
PLATFORM=$(ls -d "$SDK"/platforms/android-* 2>/dev/null | sort -V | tail -1)
[[ -n "$BUILD_TOOLS" && -n "$PLATFORM" ]] || { echo "SDK 里缺 build-tools 或 platforms；用 sdkmanager 装上" >&2; exit 1; }
ANDROID_JAR=$PLATFORM/android.jar
[[ -f "$ANDROID_JAR" ]] || { echo "找不到 $ANDROID_JAR" >&2; exit 1; }
NDK=${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/* 2>/dev/null | sort -V | tail -1)}
[[ -n "$NDK" && -d "$NDK" ]] || { echo "要 Android NDK（ANDROID_NDK_HOME，或 \`sdkmanager \"ndk;27.2.12479018\"\`）" >&2; exit 1; }
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
LLVM_STRIP=$TOOLCHAIN/llvm-strip
D8=$BUILD_TOOLS/d8
AAPT2=$BUILD_TOOLS/aapt2
ZIPALIGN=$BUILD_TOOLS/zipalign
APKSIGNER=$BUILD_TOOLS/apksigner

major=${VERSION%%.*}
rest=${VERSION#*.}
minor=${rest%%.*}
patch=${rest#*.}
patch=${patch%%[!0-9]*}
patch=${patch:-0}
[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || { echo "看不懂版本号 $VERSION" >&2; exit 1; }
VCODE=$((10#$major * 10000 + 10#$minor * 100 + 10#$patch))

echo "WowType $VERSION（软件版本 $VCODE），架构：$ABIS"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$OUT" "$work/assets/wowtype" "$work/lib" "$work/gen" "$work/classes" "$work/dex"

# APK 里带的词库：就是安装包里那一份，许可证和来源一起带上
cp "$DATA/lexicon.tsv" "$DATA/english.txt" "$DATA/words.lm" "$DATA/LICENSE" "$DATA/SOURCE.txt" \
   "$DATA/VERSION" "$work/assets/wowtype/"

# ---- 资源、R.java、manifest ----
"$AAPT2" compile --dir "$APP/res" -o "$work/res.zip"
"$AAPT2" link -o "$work/base.apk" \
  -I "$ANDROID_JAR" \
  --manifest "$APP/AndroidManifest.xml" \
  -A "$work/assets" \
  --java "$work/gen" \
  --min-sdk-version "$MIN_SDK" \
  --target-sdk-version "$TARGET_SDK" \
  --version-code "$VCODE" \
  --version-name "$VERSION" \
  "$work/res.zip"

# ---- Java ----
find "$APP/java" "$work/gen" -name '*.java' > "$work/sources.txt"
javac -encoding UTF-8 -source 17 -target 17 -Xlint:-options \
  -classpath "$ANDROID_JAR" -d "$work/classes" @"$work/sources.txt"
jar cf "$work/classes.jar" -C "$work/classes" .
"$D8" --lib "$ANDROID_JAR" --min-api "$MIN_SDK" --output "$work/dex" "$work/classes.jar"

build_native() {
  local abi=$1 rust=$2 clang=$3
  local linker_var="CARGO_TARGET_$(echo "$rust" | tr 'a-z-' 'A-Z_')_LINKER"
  local lib="$work/lib/$abi"
  mkdir -p "$lib"
  local link_bin=$TOOLCHAIN/$clang
  env "$linker_var=$link_bin" \
    cargo build --release --locked -p wowtype-core --no-default-features \
      --target "$rust" --target-dir target/android
  "$link_bin" -shared -fPIC -O2 -o "$lib/libwowtype.so" \
    -I core/include "$APP/jni/wowtype_jni.c" \
    "target/android/$rust/release/libwowtype_core.a" \
    -llog -ldl -lm
  "$LLVM_STRIP" --strip-unneeded "$lib/libwowtype.so"
}

for abi in $ABIS; do
  case $abi in
    arm64-v8a) build_native "$abi" aarch64-linux-android aarch64-linux-android${MIN_SDK}-clang ;;
    armeabi-v7a) build_native "$abi" armv7-linux-androideabi armv7a-linux-androideabi${MIN_SDK}-clang ;;
    x86_64) build_native "$abi" x86_64-linux-android x86_64-linux-android${MIN_SDK}-clang ;;
    *) echo "不认识的架构 $abi（支持 arm64-v8a、armeabi-v7a、x86_64）" >&2; exit 1 ;;
  esac
done

# ---- 签名：没有给密钥库就生成一个（自用、侧载；发版请在 CI/本机设 WOWTYPE_ANDROID_KEYSTORE） ----
KEYSTORE=${WOWTYPE_ANDROID_KEYSTORE:-$OUT/wowtype-android.keystore}
STORE_PASS=${WOWTYPE_ANDROID_KEYSTORE_PASS:-wowtype}
KEY_PASS=${WOWTYPE_ANDROID_KEY_PASS:-wowtype}
ALIAS=${WOWTYPE_ANDROID_KEY_ALIAS:-wowtype}
if [[ ! -f "$KEYSTORE" ]]; then
  echo "生成签名密钥 $KEYSTORE"
  keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
    -dname "CN=WowType, O=WowType, C=CN" >/dev/null
fi

apks=()
for abi in $ABIS; do
  apk="$OUT/WowType-$VERSION-android-$abi.apk"
  cp "$work/base.apk" "$work/unsigned.apk"
  mkdir -p "$work/apk/lib/$abi"
  cp "$work/dex/classes.dex" "$work/apk/classes.dex"
  cp "$work/lib/$abi/libwowtype.so" "$work/apk/lib/$abi/"
  ( cd "$work/apk" && zip -q -X "$work/unsigned.apk" classes.dex "lib/$abi/libwowtype.so" )
  "$ZIPALIGN" -f -p 4 "$work/unsigned.apk" "$work/aligned.apk"
  rm -f "$apk"
  "$APKSIGNER" sign --ks "$KEYSTORE" --ks-key-alias "$ALIAS" \
    --ks-pass "pass:$STORE_PASS" --key-pass "pass:$KEY_PASS" \
    --out "$apk" "$work/aligned.apk"
  "$APKSIGNER" verify --print-certs "$apk" | head -4
  apks+=("$apk")
done

# ---- 自检：清单里要有输入法服务，包里要有那个架构的原生库 ----
apk=${apks[0]}
"$BUILD_TOOLS/aapt2" dump badging "$apk" | sed -n '1,6p'
unzip -l "$apk" | grep -E 'lib/.+/libwowtype\.so|classes\.dex|assets/wowtype/lexicon\.tsv'
echo
ls -lh "${apks[@]}"
( cd "$OUT" && sha256sum -- *.apk | tee SHA256SUMS.android )
echo "APK 在 $OUT（arm64 优先；别的架构用 WOWTYPE_ANDROID_ABIS=\"arm64-v8a armeabi-v7a x86_64\" 再打）"
