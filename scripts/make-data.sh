#!/usr/bin/env bash
# 从雾凇拼音（rime-ice）生成 WowType 用的词库和英文词表。
#
#   scripts/make-data.sh [rime-ice 目录] [输出目录]
#
# 不给 rime-ice 目录时自动 git clone 一份（--depth 1）。输出：
#   lexicon.tsv   中文词库（约 55 万条）
#   english.txt   英文词表
#   LICENSE       rime-ice 的许可证（GPL-3.0），随数据一起分发
#   words.lm      词级语言模型（从 GitHub Release 下载，见下面 LM_URL）
#   SOURCE.txt    数据来源与版本
#
# words.lm 是用 wowtype-lmbuild 从约 5 GB 语料训练的，不在这里重新训练。
# 想用本机的文件（不下载）：WOWTYPE_LM_FILE=path/to/words.lm scripts/make-data.sh
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

# 词级语言模型，训练语料与命令见 Release 说明；换模型时同时改 URL 和 sha256
LM_URL=https://github.com/Gloridust/WowType/releases/download/lm-2026.11.09/words.lm.xz
LM_SHA256=42cb7c4a7cededa29b1a9ff105530085529fefff96535cc051341ebd51605dbe
if [[ -n "${WOWTYPE_LM_FILE:-}" ]]; then
  cp "$WOWTYPE_LM_FILE" "$OUT/words.lm"
else
  curl -fsSL --retry 3 "$LM_URL" | xz -d > "$OUT/words.lm"
fi
echo "$LM_SHA256  $OUT/words.lm" | sha256sum -c --quiet || {
  echo "words.lm 的 sha256 对不上（应为 $LM_SHA256）" >&2
  exit 1
}

COMMIT=$(git -C "$RIME" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$RIME" log -1 --format=%cs 2>/dev/null || date +%F)
cat > "$OUT/SOURCE.txt" <<EOF
数据来源：雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），许可证 GPL-3.0，见 LICENSE。
版本：$COMMIT（$DATE）
lexicon.tsv 由 WowType 的 tools/rime2tsv.py 转换自 rime_ice.dict.yaml 及其 import_tables，
再用 tools/add_hotwords.py 合进 WowType 的热词表 data/hotwords.tsv；
english.txt 是 en_dicts/en.dict.yaml 与 en_dicts/en_ext.dict.yaml 原样拼接。

words.lm 是 WowType 的词级语言模型，由 wowtype-lmbuild 从下列语料统计生成，许可证 CC BY-SA 4.0：
  LCCC（https://huggingface.co/datasets/thu-coai/lccc，清华大学 CoAI 组，MIT）
  中文维基百科（https://zh.wikipedia.org/，CC BY-SA 4.0）
下载地址：$LM_URL
sha256：$LM_SHA256
EOF
# 词库包版本 = rime-ice 日期 + WowType 自己的修订号；只改了热词表等、rime-ice 没变时加 REV，
# 否则同版本号的包 apt 不会更新。rime-ice 换新日期时 REV 归 0。
REV=2
echo "$DATE.$REV" > "$OUT/VERSION"

LINES=$(grep -vc '^#' "$OUT/lexicon.tsv" || true)
echo "词库 $LINES 条 -> $OUT/lexicon.tsv（rime-ice $DATE，修订 $REV）"
if (( LINES < 100000 )); then
  echo "词库条数太少，rime-ice 的目录结构可能变了" >&2
  exit 1
fi
