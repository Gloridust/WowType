#!/usr/bin/env bash
# 从雾凇拼音（rime-ice）生成 WowType 用的词库和英文词表。
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

python3 tools/rime2tsv.py "$RIME/rime_ice.dict.yaml" > "$OUT/lexicon.rime.tsv"
# 合进 WowType 自己整理的热词（AI、工作、网络用语），见 data/hotwords.tsv
python3 tools/add_hotwords.py "$OUT/lexicon.rime.tsv" data/hotwords.tsv > "$OUT/lexicon.tsv"
rm "$OUT/lexicon.rime.tsv"
cat "$RIME/en_dicts/en.dict.yaml" "$RIME/en_dicts/en_ext.dict.yaml" > "$OUT/english.txt"
cp "$RIME/LICENSE" "$OUT/LICENSE"

COMMIT=$(git -C "$RIME" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$RIME" log -1 --format=%cs 2>/dev/null || date +%F)
cat > "$OUT/SOURCE.txt" <<EOF
数据来源：雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），许可证 GPL-3.0，见 LICENSE。
版本：$COMMIT（$DATE）
lexicon.tsv 由 WowType 的 tools/rime2tsv.py 转换自 rime_ice.dict.yaml 及其 import_tables，
再用 tools/add_hotwords.py 合进 WowType 的热词表 data/hotwords.tsv；
english.txt 是 en_dicts/en.dict.yaml 与 en_dicts/en_ext.dict.yaml 原样拼接。
EOF
# 词库包版本 = rime-ice 日期 + WowType 自己的修订号；只改了热词表等、rime-ice 没变时加 REV，
# 否则同版本号的包 apt 不会更新。rime-ice 换新日期时 REV 归 0。
REV=1
echo "$DATE.$REV" > "$OUT/VERSION"

LINES=$(grep -vc '^#' "$OUT/lexicon.tsv" || true)
echo "词库 $LINES 条 -> $OUT/lexicon.tsv（rime-ice $DATE，修订 $REV）"
if (( LINES < 100000 )); then
  echo "词库条数太少，rime-ice 的目录结构可能变了" >&2
  exit 1
fi
