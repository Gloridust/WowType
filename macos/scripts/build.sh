#!/usr/bin/env bash
# 构建 macos/build/WowType.app（arm64 + x86_64 通用二进制）。
#
#   macos/scripts/build.sh               用 dist/data 的词库（scripts/make-data.sh 生成）
#   macos/scripts/build.sh --demo-data   用 core/data/demo_lexicon.tsv（只供开发，不发布）
#   macos/scripts/build.sh --install     构建后运行 WowType.app --install（装到 ~/Library/Input Methods）
#
# 环境变量（都可以不设）：
#   WOWTYPE_BUNDLE_ID       bundle id，要含 .inputmethod.（默认 io.github.gloridust.inputmethod.WowType）
#   WOWTYPE_SIGN_IDENTITY   codesign 身份（默认 -，临时签名，只能本机用）
#   WOWTYPE_DATA_DIR        词库目录（默认 dist/data）
#
# 核心用 --no-default-features 构建：不带语音，也就不需要麦克风权限。
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
MAC=$ROOT/macos

die() { echo "build.sh：$*" >&2; exit 1; }

DEMO=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --demo-data) DEMO=1 ;;
    --install) INSTALL=1 ;;
    *) die "不认识的参数 $arg（可用：--demo-data --install）" ;;
  esac
done

BUNDLE_ID=${WOWTYPE_BUNDLE_ID:-io.github.gloridust.inputmethod.WowType}
case "$BUNDLE_ID" in
  *.inputmethod.*) ;;
  *) die "WOWTYPE_BUNDLE_ID=$BUNDLE_ID 不含 .inputmethod.，系统不会把它当输入法" ;;
esac
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || die "WOWTYPE_BUNDLE_ID 只能有字母、数字、点和减号"
SIGN=${WOWTYPE_SIGN_IDENTITY:--}
DATA=${WOWTYPE_DATA_DIR:-$ROOT/dist/data}

VERSION=$(sed -n 's/^version = "\(.*\)"$/\1/p' core/Cargo.toml | head -n 1)
[[ -n "$VERSION" ]] || die "读不到 core/Cargo.toml 的版本"

# ---- 先检查数据，缺了就别白编译 ----
S2T=$ROOT/core/data/s2t.tsv
DATA_FILES=()
if [[ $DEMO == 1 ]]; then
  DATA_FILES=("$ROOT/core/data/demo_lexicon.tsv:lexicon.tsv")
else
  for f in lexicon.tsv english.txt words.lm LICENSE SOURCE.txt; do
    DATA_FILES+=("$DATA/$f:$f")
  done
fi
DATA_FILES+=("$S2T:s2t.tsv")
missing=()
for pair in "${DATA_FILES[@]}"; do
  [[ -f "${pair%%:*}" ]] || missing+=("${pair%%:*}")
done
if (( ${#missing[@]} )); then
  printf '缺少数据文件：\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  die "先运行 scripts/make-data.sh（或用 --demo-data 做开发构建）"
fi
for f in Info.plist.template WowType.entitlements AppIcon.icns MenuIcon.tiff; do
  [[ -f "$MAC/Resources/$f" ]] || die "缺少 macos/Resources/$f"
done

BUILD=$MAC/build
APP=$BUILD/WowType.app
mkdir -p "$BUILD/lib"

# ---- Rust 核心：两个架构的静态库，再合成一个 ----
export MACOSX_DEPLOYMENT_TARGET=13.0
LIBS=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  echo "==> cargo build（$target）"
  cargo build --release --locked -p wowtype-core --no-default-features --lib --target "$target"
  LIBS+=("$ROOT/target/$target/release/libwowtype_core.a")
done
CORE_LIB=$BUILD/lib/libwowtype_core.a
lipo -create "${LIBS[@]}" -output "$CORE_LIB"

# ---- Swift：两个架构分别编译链接，再合成一个 ----
# Package.swift 看到 WOWTYPE_CORE_LIB 才声明输入法程序，并按这个完整路径链接核心。
BINS=()
for arch in arm64 x86_64; do
  case $arch in
    arm64) lib="$ROOT/target/aarch64-apple-darwin/release/libwowtype_core.a" ;;
    x86_64) lib="$ROOT/target/x86_64-apple-darwin/release/libwowtype_core.a" ;;
  esac
  scratch=$BUILD/swift-$arch
  echo "==> swift build（$arch）"
  (cd "$MAC" && WOWTYPE_CORE_LIB="$lib" swift build -c release --arch "$arch" --product WowType \
      --scratch-path "$scratch")
  BINS+=("$(cd "$MAC" && WOWTYPE_CORE_LIB="$lib" swift build -c release --arch "$arch" \
      --scratch-path "$scratch" --show-bin-path)/WowType")
done

# ---- 组装 .app ----
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/WowType"
printf 'APPL????' > "$APP/Contents/PkgInfo"

subst() { sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/g" -e "s/@VERSION@/$VERSION/g" "$1" > "$2"; }
subst "$MAC/Resources/Info.plist.template" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "生成的 Info.plist 不合法"
for lproj in zh-Hans.lproj en.lproj; do
  mkdir -p "$APP/Contents/Resources/$lproj"
  subst "$MAC/Resources/$lproj/InfoPlist.strings.template" "$APP/Contents/Resources/$lproj/InfoPlist.strings"
  plutil -lint "$APP/Contents/Resources/$lproj/InfoPlist.strings" >/dev/null || die "$lproj/InfoPlist.strings 不合法"
done
cp "$MAC/Resources/AppIcon.icns" "$MAC/Resources/MenuIcon.tiff" "$APP/Contents/Resources/"
for pair in "${DATA_FILES[@]}"; do
  cp "${pair%%:*}" "$APP/Contents/Resources/${pair##*:}"
done

# ---- 签名 ----
SIGN_ARGS=(--force --sign "$SIGN" --entitlements "$MAC/Resources/WowType.entitlements")
if [[ "$SIGN" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
echo "==> codesign（${SIGN}）"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

lipo -archs "$APP/Contents/MacOS/WowType"
echo "已生成 $APP（$BUNDLE_ID $VERSION）"

if [[ $INSTALL == 1 ]]; then
  echo "==> 安装"
  "$APP/Contents/MacOS/WowType" --install
fi
