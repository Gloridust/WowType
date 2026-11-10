#!/usr/bin/env bash
# 在 Linux 上构建；各发行版依赖见 docs/INSTALL.md。
#   scripts/build-linux.sh          构建并测试 Rust 工作区和 C ABI
#   scripts/build-linux.sh --addon  连 fcitx5 插件一起构建
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
  --help|-h)
    echo "用法：scripts/build-linux.sh [--addon]"
    echo "依赖见 docs/INSTALL.md；--addon 只构建，安装需另执行 sudo cmake --install fcitx5-addon/build。"
    exit 0 ;;
  ""|--addon) ;;
  *) echo "未知参数：$1；用法：scripts/build-linux.sh [--addon]" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo "最多接受一个 --addon 参数" >&2; exit 2; }

echo "依赖和安装步骤见 docs/INSTALL.md（按发行版选择）。"
for name in WOWTYPE_LEXICON WOWTYPE_ENGLISH WOWTYPE_LM WOWTYPE_S2T; do
  if [[ -n "${!name:-}" && ( ! -f "${!name}" || ! -r "${!name}" || ! -s "${!name}" ) ]]; then
    echo "$name 指定的文件不存在、为空或不可读：${!name}" >&2
    exit 1
  fi
done
lexicon=${WOWTYPE_LEXICON:-/usr/share/wowtype/lexicon.tsv}
english=${WOWTYPE_ENGLISH:-$(dirname "$lexicon")/english.txt}
lm=${WOWTYPE_LM:-$(dirname "$lexicon")/words.lm}
[[ -f "$lm" && -r "$lm" && -s "$lm" ]] || lm=""

echo "== Rust 工作区（核心、语音、守护进程）=="
cargo build --release --locked --workspace
cargo test --locked --workspace

echo "== C ABI 冒烟测试 =="
./scripts/abi-smoke.sh

echo "== 数据自检 =="
if [[ -f "$lexicon" && -r "$lexicon" && -s "$lexicon" ]]; then
  cargo run --release --locked -q -p wowtype-core --bin wowtype-check -- \
    --lexicon "$lexicon" --lm "$lm" --s2t "${WOWTYPE_S2T:-$PWD/core/data/s2t.tsv}"
else
  echo "跳过真实词库自检：没有 $lexicon；准备好词库后设置 WOWTYPE_LEXICON 再运行。"
fi

if [[ "${1:-}" == "--addon" ]]; then
  echo "== fcitx5 插件 =="
  cmake -S fcitx5-addon -B fcitx5-addon/build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build fcitx5-addon/build --parallel "$(nproc)"
  echo "== 插件按键测试（私有 fcitx5 实例，不影响正在用的输入法）=="
  if [[ -s "$lexicon" && -s "$english" && -s "$lm" ]]; then
    WOWTYPE_LM="$lm" ./scripts/addon-test.sh "$lexicon" "$english"
  elif [[ -n "${WOWTYPE_LEXICON:-}${WOWTYPE_ENGLISH:-}${WOWTYPE_LM:-}" ]]; then
    echo "按键测试需要完整词库、英文词表和语言模型；请同时提供 WOWTYPE_LEXICON、WOWTYPE_ENGLISH、WOWTYPE_LM。" >&2
    exit 1
  else
    echo "跳过真实数据按键测试：缺 lexicon.tsv、english.txt 或 words.lm，准备步骤见 docs/INSTALL.md。"
  fi
  echo "安装：sudo cmake --install fcitx5-addon/build"
fi

echo "完成"
