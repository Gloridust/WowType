#!/usr/bin/env bash
# 把 macos/build/WowType.app 打成 DMG：签名、公证、装订、Gatekeeper 检查，最后打印 sha256。
#
#   macos/scripts/build.sh && macos/scripts/package.sh
#
# 环境变量：
#   WOWTYPE_SIGN_IDENTITY    给 DMG 签名的身份（默认 -：不给 DMG 签名）
#   WOWTYPE_NOTARY_PROFILE   xcrun notarytool 的钥匙串配置名；设了才公证和装订
#
# 没公证的 DMG 只能本机用：这时 spctl 一定不接受，脚本说明这一点但不算失败。
# 公证过的 DMG 必须让 spctl 说 accepted，否则失败。
set -euo pipefail
cd "$(dirname "$0")/../.."
MAC=$PWD/macos

die() { echo "package.sh：$*" >&2; exit 1; }

APP=$MAC/build/WowType.app
[[ -d "$APP" ]] || die "没有 $APP，先运行 macos/scripts/build.sh"
codesign --verify --strict "$APP" || die "$APP 的签名不对，重新运行 build.sh"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
SIGN=${WOWTYPE_SIGN_IDENTITY:--}
NOTARY=${WOWTYPE_NOTARY_PROFILE:-}
DMG=$MAC/build/WowType-$VERSION.dmg

# DMG 里只有 WowType.app。
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/WowType.app"
rm -f "$DMG"
hdiutil create -volname "WowType $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "已生成 $DMG"

if [[ "$SIGN" != "-" ]]; then
  codesign --force --sign "$SIGN" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
fi

if [[ -n "$NOTARY" ]]; then
  [[ "$SIGN" != "-" ]] || die "公证需要 Developer ID 签名，请设置 WOWTYPE_SIGN_IDENTITY"
  echo "==> 公证（这一步要几分钟）"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  RESULT=$(spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 || true)
  echo "$RESULT"
  grep -q ': accepted' <<<"$RESULT" || die "Gatekeeper 不接受这个 DMG"
else
  echo "没有设置 WOWTYPE_NOTARY_PROFILE：没公证，这个 DMG 只能本机测试，不能发布。"
fi

shasum -a 256 "$DMG"
