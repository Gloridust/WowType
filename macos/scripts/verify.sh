#!/usr/bin/env bash
# macOS 前端的完整检查，按顺序跑，第一个失败就停：
#   1. 守卫（含自测）和图标检查
#   2. cargo test --workspace --locked
#   3. scripts/abi-smoke.sh（C ABI 冒烟）
#   4. swift test（WowTypeKit 的单元测试）
#   5. 编译输入法程序 WowTypeIME（只编译，不链接）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "==> 1/5 守卫"
macos/scripts/guards.sh
macos/scripts/make-icons.sh --check

echo "==> 2/5 cargo test"
cargo test --workspace --locked

echo "==> 3/5 C ABI 冒烟"
scripts/abi-smoke.sh

echo "==> 4/5 swift test"
(cd macos && swift test)

# Package.swift 只有设了 WOWTYPE_CORE_LIB 才声明 WowTypeIME，上一步的 swift test 不会编它，
# 这里单独编一遍，输入法程序里写错了也能查出来。--target 只编译这个模块、不链接，
# 所以用上一步 abi-smoke.sh 编好的核心静态库就行；链接和组装 .app 由 build.sh 做。
# 编译目录放在 build/ 下，不和 swift test 的 .build 混用（两边的包声明不一样）。
echo "==> 5/5 编译输入法程序"
CORE_LIB=$PWD/target/release/libwowtype_core.a
[[ -f "$CORE_LIB" ]] || { echo "verify.sh：没有 $CORE_LIB" >&2; exit 1; }
(cd macos && WOWTYPE_CORE_LIB="$CORE_LIB" swift build --target WowTypeIME --scratch-path build/verify-ime)

echo "全部通过"
