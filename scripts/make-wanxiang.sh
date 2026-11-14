#!/usr/bin/env bash
# 从万象拼音（rime_wanxiang）生成可选词库包。默认词库仍是雾凇（scripts/make-data.sh），
# 这个包不进安装包，用户在「WowType 设置 → 词库」里下载切换。
#
#   scripts/make-wanxiang.sh [rime_wanxiang 目录] [输出目录] [打包目录]
#
# 不给 rime_wanxiang 目录时自动 git clone 一份（--depth 1）。输出目录里：
#   lexicon.tsv   中文词库（条数生成时打出来）
#   LICENSE       万象的许可证（CC BY 4.0），随数据一起分发
#   SOURCE.txt    数据来源、版本和 WowType 做了哪些改动（CC BY 要求注明）
#   VERSION       词库包版本
# 给了打包目录时再打成 wowtype-data-wanxiang-<版本>.tar.gz。
#
# 只用万象的词条。它的 .gram 语法模型是 librime 的 octagram 格式，WowType 用不了，
# 语言模型和英文词表还是默认数据里的 words.lm、english.txt。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=${1:-}
OUT=${2:-dist/wanxiang}
PKG=${3:-}
mkdir -p "$OUT"

if [[ -z "$SRC" ]]; then
  SRC=$(mktemp -d)/rime_wanxiang
  git clone --depth 1 https://github.com/amzxyz/rime_wanxiang.git "$SRC"
fi

# 万象的总词频约 12 亿，雾凇约 75 亿；核心里自定义词、热词等几个绝对词频是照雾凇定的，
# 所以先整体缩放到同样的总词频
SCALE_TOTAL=7500000000
# dicts/cuoyin 是故意收的错音错字（秘鲁 mì lǔ、炽热 zhì rè），万象靠 lua 在候选旁提示正确读音，
# WowType 没有这个提示，收进来只会让人照错的读音打出字却不知道，所以不要
SKIP=(dicts/cuoyin)

skip_args=()
for name in "${SKIP[@]}"; do skip_args+=(--skip-import "$name"); done
python3 tools/rime2tsv.py "${skip_args[@]}" --scale-total "$SCALE_TOTAL" \
  "$SRC/wanxiang.dict.yaml" > "$OUT/lexicon.wanxiang.tsv"
python3 tools/add_hotwords.py "$OUT/lexicon.wanxiang.tsv" data/hotwords.tsv > "$OUT/lexicon.tsv"
rm "$OUT/lexicon.wanxiang.tsv"
cp "$SRC/LICENSE" "$OUT/LICENSE"

COMMIT=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$SRC" log -1 --format=%cs 2>/dev/null || date +%F)
IMPORTS=$(sed -n '/^import_tables:/,/^[^ ]/p' "$SRC/wanxiang.dict.yaml" |
  sed -n 's/^ *- *\([^ #]*\).*/\1/p' | grep -vxF -f <(printf '%s\n' "${SKIP[@]}") | paste -sd' ')
cat > "$OUT/SOURCE.txt" <<EOF
数据来源：万象拼音 rime_wanxiang（https://github.com/amzxyz/rime_wanxiang，作者 amzxyz），
许可证 CC BY 4.0，见 LICENSE。
版本：${COMMIT}（${DATE}）

WowType 做的改动（tools/rime2tsv.py、tools/add_hotwords.py，脚本 scripts/make-wanxiang.sh）：
- 只取 wanxiang.dict.yaml 引用的这些词库：$IMPORTS
  没有收 ${SKIP[*]}（错音错字，WowType 没有读音提示）。
- 拼音去掉声调，ü 写成 v（ā bà -> a ba，lǜ -> lv），只留文字、拼音、词频三列。
- 同一个词同一个读音出现多次时取最大词频。
- 词频整体乘同一个系数，让总和为 ${SCALE_TOTAL}（和默认的雾凇词库同一个量级），
  排序不变。
- 合进 WowType 的热词表 data/hotwords.tsv（AI、工作、网络用语）。
没有用万象的 .gram 语法模型。
EOF
# 词库包版本 = 万象提交日期 + WowType 的修订号（只改了转换方式时加 REV，万象换新日期时归 0）
REV=0
VERSION="${DATE//-/.}.$REV"
echo "$VERSION" > "$OUT/VERSION"

LINES=$(grep -vc '^#' "$OUT/lexicon.tsv" || true)
echo "词库 $LINES 条 -> $OUT/lexicon.tsv（万象 ${DATE}，修订 ${REV}）"
if (( LINES < 500000 )); then
  echo "词库条数太少，rime_wanxiang 的目录结构可能变了" >&2
  exit 1
fi
for word in 你好 中国 输入法; do
  grep -qP "\t$word\t" "$OUT/lexicon.tsv" || { echo "词库里没有「${word}」，转换有问题" >&2; exit 1; }
done

if [[ -n "$PKG" ]]; then
  mkdir -p "$PKG"
  tarball="$PKG/wowtype-data-wanxiang-$VERSION.tar.gz"
  tar -C "$OUT" -czf "$tarball" lexicon.tsv LICENSE SOURCE.txt VERSION
  echo "$tarball"
fi
