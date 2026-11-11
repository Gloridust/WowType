#!/usr/bin/env bash
# macOS 前端的守卫：把「不许这样写」的约定变成检查。
#
#   macos/scripts/guards.sh          检查 macos/，再证明每条守卫真的会报错
#   macos/scripts/guards.sh DIR      只检查 DIR（一份 macos/ 目录），不做自测
#
# 守卫：
#   kit-ui        WowTypeKit 不 import InputMethodKit / AppKit / Cocoa / SwiftUI（它要能直接 swift test）
#   core-import   只有 WowTypeEngine 能 import CWowTypeCore
#   print         源码里不用 print / debugPrint / NSLog，只用 os.Logger
#   public-text   日志里打的字（编辑区、候选、上屏文字）不能标 privacy: .public：
#                 标了 .public 的插值只能是下面 PUBLIC_OK 里列出的表达式（插值拆成几行也查）
#   identity      macos/ 里不写死签名身份、团队 ID、公证配置，也不出现个人或公司名
#   plist-keys    Info.plist 模板里输入法要的键都在
#
# 自测：把 macos/ 复制到临时目录，每次埋一个违规，确认对应的守卫报错。
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# 拼出来的字符串，免得这个脚本自己被 identity 守卫查到。
DEVID="Developer ID"
BADNAME="P""anor"

# 可以标 privacy: .public 的插值表达式（空白压成一个空格后完全一样才算）。
# 只放错误、路径、数量、状态这类不含用户打的字的值。加新的之前先确认它带不出编辑区、候选、上屏文字。
PUBLIC_OK='error.localizedDescription
String(describing: error)
Self.lastError
lastError
failure.name.rawValue
target.path
url.path
modeID(id)
status
removed
others.count
ms
bad
lm != nil'

# import 语句的开头：可以带 @testable、@preconcurrency 这类属性，也可以是 import struct M.X 这种只导入一个名字的写法。
IMPORT='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?'

# 打印 FILE 里每个标了 privacy: .public、但表达式不在 PUBLIC_OK 里的插值（「文件:行: 表达式」）。
# 整个文件一起看，所以插值拆成几行也查得到；表达式从 .public 往前最近的一个 \( 算起。
public_interpolations() {
  PUBLIC_OK="$PUBLIC_OK" awk -v file="$1" '
    { text = text $0 "\n" }
    END {
      n = split(ENVIRON["PUBLIC_OK"], list, "\n")
      for (i = 1; i <= n; i++) ok[list[i]] = 1
      done = 0
      while (match(substr(text, done + 1), /privacy:[[:space:]]*\.public/)) {
        at = done + RSTART
        before = substr(text, 1, at - 1)
        start = 0
        rest = before
        while ((k = index(rest, "\\(")) > 0) { start += k + 1; rest = substr(rest, k + 2) }
        expr = start > 0 ? substr(before, start + 1) : "（找不到插值开头）"
        gsub(/[[:space:]]+/, " ", expr)
        sub(/^ /, "", expr)
        sub(/ ?, ?$/, "", expr)
        if (!(expr in ok)) {
          line = gsub(/\n/, "\n", before) + 1
          print file ":" line ": \\(" expr ", privacy: .public)"
        }
        done = at + RLENGTH - 1
      }
    }' "$1"
}

# 在 DIR 里跑所有守卫；每条失败打印一行「FAIL 守卫名: 原因」，有失败返回 1。
check() {
  local dir=$1 failed=0
  local src="$dir/Sources"

  fail() { echo "FAIL $1: $2"; failed=1; }

  local hits
  hits=$(grep -rnE "${IMPORT}(InputMethodKit|AppKit|Cocoa|SwiftUI)([.[:space:]]|\$)" \
    "$src/WowTypeKit" 2>/dev/null || true)
  [[ -z "$hits" ]] || fail kit-ui "WowTypeKit 里有界面框架：$hits"

  hits=$(grep -rnE "${IMPORT}CWowTypeCore([.[:space:]]|\$)" "$src" "$dir/Tests" 2>/dev/null \
    | grep -v "^$src/WowTypeEngine/" || true)
  [[ -z "$hits" ]] || fail core-import "WowTypeEngine 以外 import 了 CWowTypeCore：$hits"

  hits=$(grep -rnE '(^|[^A-Za-z0-9_.])((Swift|Foundation)\.)?(print|debugPrint|NSLog)[[:space:]]*\(' \
    --include='*.swift' --include='*.m' --include='*.h' "$src" 2>/dev/null || true)
  [[ -z "$hits" ]] || fail print "源码里有 print/NSLog（用 os.Logger）：$hits"

  hits=""
  local f out
  while IFS= read -r f; do
    out=$(public_interpolations "$f")
    [[ -z "$out" ]] || hits+="$out"$'\n'
  done < <(grep -rlE 'privacy:[[:space:]]*\.public' --include='*.swift' "$src" 2>/dev/null || true)
  [[ -z "$hits" ]] || fail public-text "用户打的字标了 privacy: .public：$hits"

  hits=$(grep -rnIE \
      -e "${DEVID} (Application|Installer):" \
      -e '(TeamIdentifier|DEVELOPMENT_TEAM|[Tt][Ee][Aa][Mm][-_ ]?[Ii][Dd])[^A-Za-z0-9]{1,6}[A-Z0-9]{10}([^A-Za-z0-9]|$)' \
      -e '--keychain-profile[[:space:]]+[^"$[:space:]]' \
      --exclude-dir=.build --exclude-dir=build --exclude-dir=.swiftpm "$dir" 2>/dev/null \
    | grep -v "^$dir/scripts/guards.sh:" || true)
  hits+=$(grep -rnIi -e "$BADNAME" \
      --exclude-dir=.build --exclude-dir=build --exclude-dir=.swiftpm "$dir" 2>/dev/null \
    | grep -v "^$dir/scripts/guards.sh:" || true)
  [[ -z "$hits" ]] || fail identity "写死了签名身份、团队 ID、公证配置或名字：$hits"

  local plist="$dir/Resources/Info.plist.template"
  if [[ ! -f "$plist" ]]; then
    fail plist-keys "没有 Resources/Info.plist.template"
  else
    local key
    for key in LSUIElement CFBundleIdentifier InputMethodConnectionName InputMethodServerControllerClass \
               InputMethodServerDelegateClass ComponentInputModeDict tsInputModeListKey \
               tsVisibleInputModeOrderedArrayKey TISInputSourceID TISIntendedLanguage tsInputModeScriptKey \
               tsInputMethodIconFileKey tsInputMethodCharacterRepertoireKey LSMinimumSystemVersion; do
      grep -q "<key>$key</key>" "$plist" || fail plist-keys "Info.plist 模板缺少 $key"
    done
    grep -q '<string>@BUNDLE_ID@_Connection</string>' "$plist" || fail plist-keys "连接名不是 @BUNDLE_ID@_Connection"
    grep -q '<string>WowTypeIME\.WowTypeInputController</string>' "$plist" \
      || fail plist-keys "控制器类名要带模块前缀 WowTypeIME."
    grep -q '<string>@BUNDLE_ID@\.pinyin</string>' "$plist" || fail plist-keys "输入模式 id 不是 @BUNDLE_ID@.pinyin"
    grep -q '<string>13\.0</string>' "$plist" || fail plist-keys "LSMinimumSystemVersion 不是 13.0"
  fi

  return $failed
}

if [[ $# -ge 1 ]]; then
  check "$1"
  exit $?
fi

MAC=$(cd "$(dirname "$0")/.." && pwd)
echo "==> 守卫：$MAC"
check "$MAC"
echo "守卫全部通过"

# ---- 自测：每条守卫遇到违规都要报错 ----
echo "==> 守卫自测"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# plant 守卫名 说明 命令（命令在复制出来的目录里执行）
plant() {
  local guard=$1 what=$2 cmd=$3 copy="$TMP/$1-$RANDOM"
  mkdir -p "$copy"
  rsync -a --exclude .build --exclude build --exclude .swiftpm "$MAC/" "$copy/"
  (cd "$copy" && eval "$cmd")
  local out
  if out=$("$SELF" "$copy" 2>&1); then
    echo "自测失败：埋了「$what」，守卫 $guard 没报错" >&2
    exit 1
  fi
  if ! grep -q "^FAIL $guard:" <<<"$out"; then
    echo "自测失败：埋了「$what」，报错的不是 $guard：" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "  ok  $guard 抓到：$what"
}

plant kit-ui "WowTypeKit 里 import AppKit" \
  'printf "import AppKit\n" > Sources/WowTypeKit/Planted.swift'
plant kit-ui "WowTypeKit 里 import InputMethodKit" \
  'printf "import Foundation\nimport InputMethodKit\n" > Sources/WowTypeKit/Planted.swift'
plant kit-ui "WowTypeKit 里 import struct AppKit.NSEvent" \
  'printf "import struct AppKit.NSEvent\n" > Sources/WowTypeKit/Planted.swift'
plant kit-ui "WowTypeKit 里 @preconcurrency import SwiftUI" \
  'printf "@preconcurrency import SwiftUI\n" > Sources/WowTypeKit/Planted.swift'
plant core-import "WowTypeIME 里 import CWowTypeCore" \
  'printf "import CWowTypeCore\n" > Sources/WowTypeIME/Planted.swift'
plant core-import "WowTypeKit 里 import CWowTypeCore" \
  'printf "import CWowTypeCore\n" > Sources/WowTypeKit/Planted.swift'
plant print "print 调试输出" \
  'printf "func planted() { print(1) }\n" > Sources/WowTypeIME/Planted.swift'
plant core-import "WowTypeIME 里 import func CWowTypeCore.x" \
  'printf "import func CWowTypeCore.wowtype_config_default_ini\n" > Sources/WowTypeIME/Planted.swift'
plant print "NSLog" \
  'printf "func planted() { NSLog(\"x\") }\n" > Sources/WowTypeIME/Planted.swift'
plant print "Swift.print" \
  'printf "func planted() { Swift.print(\"typed\") }\n" > Sources/WowTypeIME/Planted.swift'
plant public-text "上屏文字标 .public" \
  'printf "func planted(_ text: String) { Log.input.debug(\"\\\\(text, privacy: .public)\") }\n" > Sources/WowTypeIME/Planted.swift'
plant public-text "候选标 .public" \
  'printf "func planted(_ s: [String]) { Log.input.debug(\"\\\\(s.candidates.first!, privacy: .public)\") }\n" > Sources/WowTypeIME/Planted.swift'
plant public-text "名字看不出是打的字的变量标 .public" \
  'printf "func planted(_ s: String) { Log.input.debug(\"\\\\(s, privacy: .public)\") }\n" > Sources/WowTypeIME/Planted.swift'
plant public-text "插值拆成两行再标 .public" \
  'printf "func planted(_ committed: String) {\n  Log.input.debug(\"\\\\(committed,\n    privacy: .public)\")\n}\n" > Sources/WowTypeIME/Planted.swift'
plant public-text "同一行先有一个 .private 插值" \
  'printf "func planted(_ n: Int, _ s: String) { Log.input.debug(\"\\\\(n, privacy: .private) \\\\(s, privacy: .public)\") }\n" > Sources/WowTypeIME/Planted.swift'
plant identity "写死签名身份" \
  "printf 'SIGN=\"%s Application: Someone (ABCDE12345)\"\n' \"$DEVID\" >> scripts/build.sh"
plant identity "写死团队 ID" \
  "printf 'TEAM_ID=ABCDE12345\n' >> scripts/package.sh"
plant identity "写死公证配置" \
  "printf 'xcrun notarytool submit x --keychain-profile myprofile\n' >> scripts/package.sh"
plant identity "出现公司名" \
  "printf '%s\n' \"$BADNAME\" >> README.md"
plant plist-keys "Info.plist 模板少了连接名" \
  "sed -i '' '/InputMethodConnectionName/d' Resources/Info.plist.template"
plant plist-keys "控制器类名没有模块前缀" \
  "sed -i '' 's/WowTypeIME\\.WowTypeInputController/WowTypeInputController/' Resources/Info.plist.template"
plant plist-keys "没有输入模式列表" \
  "sed -i '' 's/tsInputModeListKey/tsInputModeList/' Resources/Info.plist.template"

echo "守卫自测全部通过"
