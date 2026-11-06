#!/usr/bin/env bash
# 在 Ubuntu 上构建。
#   scripts/build-linux.sh          只构建 Rust 核心
#   scripts/build-linux.sh --addon  连 fcitx5 插件一起构建
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== 依赖（需要 sudo）=="
cat <<'PKG'
sudo apt install -y build-essential pkg-config \
  libasound2-dev libx11-dev libxkbcommon-dev \
  extra-cmake-modules libfcitx5core-dev libfcitx5config-dev libfcitx5utils-dev
PKG

echo "== Rust 核心 =="
cargo build --release -p wowtype-core
cargo test -p wowtype-core

echo "== C ABI 冒烟测试 =="
./scripts/abi-smoke.sh

echo "== 语音核心 =="
cargo build --release -p wowtype-voice
cargo test -p wowtype-voice

echo "== 语音守护 =="
cargo build --release -p wowtype-voiced

if [[ "${1:-}" == "--addon" ]]; then
  echo "== fcitx5 插件 =="
  cmake -S fcitx5-addon -B fcitx5-addon/build -DCMAKE_BUILD_TYPE=Release
  cmake --build fcitx5-addon/build -j
fi

echo "完成"
