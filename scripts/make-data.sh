#!/usr/bin/env bash
# 从雾凇拼音（rime-ice）生成 Wowtype 用的词库和英文词表。
#
#   scripts/make-data.sh [rime-ice 目录] [输出目录]
#
# 不给 rime-ice 目录时自动 git clone 一份（--depth 1）。输出：
#   lexicon.tsv   中文词库（约 55 万条）
#   english.txt   英文词表
#   LICENSE       rime-ice 的许可证（GPL-3.0），随数据一起分发
#   SOURCE.txt    数据来源与版本
set -euo pipefail
cd "$(dirname "$0")/.."

RIME=${1:-}
OUT=${2:-dist/data}
mkdir -p "$OUT"

if [[ -z "$RIME" ]]; then
  RIME=$(mktemp -d)/rime-ice
  git clone --depth 1 https://github.com/iDvel/rime-ice.git "$RIME"
fi

python3 tools/rime2tsv.py "$RIME/rime_ice.dict.yaml" > "$OUT/lexicon.tsv"
cat "$RIME/en_dicts/en.dict.yaml" "$RIME/en_dicts/en_ext.dict.yaml" > "$OUT/english.txt"
cp "$RIME/LICENSE" "$OUT/LICENSE"

COMMIT=$(git -C "$RIME" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$RIME" log -1 --format=%cs 2>/dev/null || date +%F)
cat > "$OUT/SOURCE.txt" <<EOF
数据来源：雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），许可证 GPL-3.0，见 LICENSE。
版本：$COMMIT（$DATE）
lexicon.tsv 由 Wowtype 的 tools/rime2tsv.py 转换自 rime_ice.dict.yaml 及其 import_tables；
english.txt 是 en_dicts/en.dict.yaml 与 en_dicts/en_ext.dict.yaml 原样拼接。
EOF
echo "$DATE" > "$OUT/VERSION"

LINES=$(grep -vc '^#' "$OUT/lexicon.tsv" || true)
echo "词库 $LINES 条 -> $OUT/lexicon.tsv（rime-ice $DATE）"
if (( LINES < 100000 )); then
  echo "词库条数太少，rime-ice 的目录结构可能变了" >&2
  exit 1
fi
