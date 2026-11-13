#!/usr/bin/env bash
# 从 rime-wubi 生成五笔码表（wubi86.tsv）。
#
#   scripts/make-wubi.sh [rime-wubi 目录] [输出目录]
#
# 不给目录时自动 clone 一份（--depth 1）。输出：
#   wubi86.tsv    code<TAB>词<TAB>频次
#   LICENSE       码表的许可证（LGPL-3.0）
#   SOURCE.txt    来源与版本
set -euo pipefail
cd "$(dirname "$0")/.."

RIME=${1:-}
OUT=${2:-dist/data}
mkdir -p "$OUT"

if [[ -z "$RIME" ]]; then
  RIME=$(mktemp -d)/rime-wubi
  git clone --depth 1 https://github.com/rime/rime-wubi.git "$RIME"
fi

DICT="$RIME/wubi86.dict.yaml"
[[ -f "$DICT" ]] || { echo "没有 $DICT" >&2; exit 1; }

python3 tools/wubi2tsv.py "$DICT" > "$OUT/wubi86.tsv"
[[ -s "$OUT/wubi86.tsv" ]] || { echo "wubi86.tsv 是空的" >&2; exit 1; }

cp "$RIME/LICENSE" "$OUT/WUBI-LICENSE"
COMMIT=$(git -C "$RIME" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$RIME" log -1 --format=%cs 2>/dev/null || date +%F)
cat > "$OUT/WUBI-SOURCE.txt" <<EOF
数据来源：Rime 五笔字型 rime-wubi（https://github.com/rime/rime-wubi），许可证 LGPL-3.0，见 WUBI-LICENSE。
版本：$COMMIT（$DATE）
wubi86.tsv 由 tools/wubi2tsv.py 转换自 wubi86.dict.yaml：
每行是 code、词、频次；原文一行里的备用码会拆成单独条目，权重打一折。
EOF

echo "wubi86.tsv: $(wc -l < "$OUT/wubi86.tsv") 条"
echo "输出目录: $OUT"