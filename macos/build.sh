#!/usr/bin/env bash
# 打 macOS 输入法安装包（只能在 macOS 上跑）。
#
#   macos/build.sh <数据目录> [输出目录]
#
# 数据目录是 scripts/make-data.sh 的输出（lexicon.tsv、english.txt、words.lm、LICENSE、SOURCE.txt、VERSION）。
# 产物：<输出目录>/WowType.app 和 WowType-<版本>-macos.zip（arm64 + x86_64 通用，ad-hoc 签名）。
#
# 环境变量：WOWTYPE_VERSION（默认取 core/Cargo.toml），WOWTYPE_MACOS_ARCHS（默认 "arm64 x86_64"）。
# 核心不带语音（--no-default-features）：语音用的是微信输入法的模型，不能随安装包分发。
set -euo pipefail
cd "$(dirname "$0")/.."

[[ "$(uname)" == Darwin ]] || { echo "只能在 macOS 上打包" >&2; exit 1; }
DATA=${1:?用法：macos/build.sh <数据目录> [输出目录]}
OUT=${2:-dist/macos}
VERSION=${WOWTYPE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' core/Cargo.toml | head -1)}
ARCHS=${WOWTYPE_MACOS_ARCHS:-arm64 x86_64}
export MACOSX_DEPLOYMENT_TARGET=12.0
TARGET_DIR=target/macos

for f in lexicon.tsv english.txt; do
  [[ -f "$DATA/$f" ]] || { echo "数据目录里没有 $f" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
bins=()
for arch in $ARCHS; do
  case $arch in
    arm64) rust=aarch64-apple-darwin ;;
    x86_64) rust=x86_64-apple-darwin ;;
    *) echo "不认识的架构 $arch" >&2; exit 1 ;;
  esac
  cargo build --release --locked -q -p wowtype-core --no-default-features --target "$rust" --target-dir "$TARGET_DIR"
  swiftc -O -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -module-name WowType -I macos/CWowtype \
    macos/Sources/Shared/*.swift macos/Sources/App/*.swift \
    "$TARGET_DIR/$rust/release/libwowtype_core.a" \
    -framework Cocoa -framework InputMethodKit -framework Carbon \
    -liconv -o "$work/WowType-$arch"
  bins+=("$work/WowType-$arch")
done

app="$OUT/WowType.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${bins[@]}" -output "$app/Contents/MacOS/WowType"
sed "s/@VERSION@/$VERSION/g" macos/Resources/Info.plist > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

res="$app/Contents/Resources"
# 菜单栏图标：16pt，一张 16×16（72 dpi）加一张 32×32（144 dpi，Retina）。
# 直接给 32×32、72 dpi 的 PNG，系统当成 32pt 来摆，图标会往下掉出菜单栏。
cp icons/hicolor/32x32/apps/wowtype.png "$work/menu@2x.png"
sips -s dpiWidth 144 -s dpiHeight 144 "$work/menu@2x.png" >/dev/null
tiffutil -cathidpicheck icons/hicolor/16x16/apps/wowtype.png "$work/menu@2x.png" -out "$res/menu.tiff" 2>/dev/null
# 应用图标：设置窗口（WowType --settings）在程序坞、关于窗口里用。没有 512 的 PNG，最大到 256（128pt@2x）
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256; do
  cp "icons/hicolor/${spec%%:*}x${spec%%:*}/apps/wowtype.png" "$iconset/icon_${spec#*:}.png"
done
iconutil -c icns "$iconset" -o "$res/AppIcon.icns"
for lproj in macos/Resources/*.lproj; do
  cp -R "$lproj" "$res/"
  plutil -lint "$res/$(basename "$lproj")/InfoPlist.strings"
done
cp "$DATA/lexicon.tsv" "$DATA/english.txt" "$res/"
[[ -f "$DATA/words.lm" ]] && cp "$DATA/words.lm" "$res/"
# 简繁对照表（设置里 Traditional=True 时用），和 Linux 包里的 /usr/share/wowtype/s2t.tsv 是同一份
cp "${WOWTYPE_S2T:-core/data/s2t.tsv}" "$res/s2t.tsv"
[[ -f "$DATA/LICENSE" ]] && cp "$DATA/LICENSE" "$res/DATA-LICENSE"
[[ -f "$DATA/SOURCE.txt" ]] && cp "$DATA/SOURCE.txt" "$res/DATA-SOURCE.txt"
[[ -f "$DATA/VERSION" ]] && cp "$DATA/VERSION" "$res/DATA-VERSION"

# 安装包里只能有这些文件（微信输入法的模型、HY-MT 翻译模型等都不许带）
allowed='^(menu\.tiff|AppIcon\.icns|[A-Za-z-]+\.lproj|[A-Za-z-]+\.lproj/InfoPlist\.strings|lexicon\.tsv|english\.txt|words\.lm|s2t\.tsv|DATA-LICENSE|DATA-SOURCE\.txt|DATA-VERSION)$'
bad=$(cd "$res" && find . -mindepth 1 | sed 's#^\./##' | grep -Ev "$allowed" || true)
if [[ -n "$bad" ]]; then
  echo "安装包里有不该带的文件：" >&2
  echo "$bad" >&2
  exit 1
fi

codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --verbose=1 "$app"
mkdir -p "$OUT"
zip="$OUT/WowType-$VERSION-macos.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
