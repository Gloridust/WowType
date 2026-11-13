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
#
# 可选数据源（默认一个都不开，不开时产出和以前逐字节相同）：
#   WOWTYPE_DATA_EXTRAS="corpus jieba cedict"   空格或逗号分隔，顺序无关；写错名字直接报错
#     corpus  从语料挖词频融进已有词（只改词频，不加词）。默认语料是钉死版本的 Tatoeba 中文句子
#             （CC BY 2.0 FR）；WOWTYPE_CORPUS="a.txt b.txt.bz2" 换成本机语料，这时必须
#             用 WOWTYPE_CORPUS_LICENSE 写清来源和许可证（写进 SOURCE.txt）
#     jieba   jieba 词典（MIT）的词频融进已有词，再补一批读音可靠的新词（pypinyin 注音，MIT）
#     cedict  CC-CEDICT（CC BY-SA 4.0）补词库里没有的词（人名地名、专业词），频次统一给很低的值
# 每个数据源的下载地址和 sha256 都钉在下面，对不上就退出；也可以给本机文件（同样校验 sha256）：
#   WOWTYPE_TATOEBA_FILE / WOWTYPE_JIEBA_DICT / WOWTYPE_CEDICT_FILE
# 要的 Python 包（版本钉死）：python3 -m pip install --require-hashes -r tools/requirements-data.txt
# 许可证说明只在用到时写进 SOURCE.txt（所有安装包都带 SOURCE.txt），评测数字见 docs/DATA.md。
set -euo pipefail
cd "$(dirname "$0")/.."

RIME=${1:-}
OUT=${2:-dist/data}
mkdir -p "$OUT"

# 不用 sha256sum -c：macOS 的 sha256sum 是 BSD 版，不认 -c --quiet；python3 两边都有
sha256() {
  python3 -c 'import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        h.update(block)
print(h.hexdigest())' "$1"
}

# fetch_pinned <名字> <URL> <sha256> <输出文件> [本机文件]：下载（或复制本机文件）并核对 sha256
fetch_pinned() {
  local name=$1 url=$2 want=$3 out=$4 local_file=${5:-} got
  if [[ -n "$local_file" ]]; then
    cp "$local_file" "$out"
  else
    curl -fsSL --retry 3 -o "$out" "$url"
  fi
  got=$(sha256 "$out")
  if [[ "$got" != "$want" ]]; then
    echo "${name} 的 sha256 对不上（应为 ${want}，实际 ${got}）" >&2
    exit 1
  fi
}

# require_py <模块> <版本>：可选数据源要的 Python 包必须是钉死的版本
require_py() {
  local have
  have=$(python3 -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' "$1" 2>/dev/null || true)
  if [[ "$have" != "$2" ]]; then
    echo "可选数据源要 Python 包 ${1}==${2}（现在是 ${have:-没装}）：" >&2
    echo "  python3 -m pip install --require-hashes -r tools/requirements-data.txt" >&2
    exit 1
  fi
}

EXTRAS=" $(printf '%s' "${WOWTYPE_DATA_EXTRAS:-}" | tr ',' ' ') "
for x in $EXTRAS; do
  case $x in
    corpus|jieba|cedict) ;;
    *) echo "WOWTYPE_DATA_EXTRAS 里的「${x}」不认识，可选：corpus jieba cedict" >&2; exit 1 ;;
  esac
done
want() { [[ "$EXTRAS" == *" $1 "* ]]; }

if [[ -z "$RIME" ]]; then
  RIME=$(mktemp -d)/rime-ice
  git clone --depth 1 https://github.com/iDvel/rime-ice.git "$RIME"
fi

# 大字表 41448 只补缺的单字（频次小于 1：不参与组句，只排在翻页的最后）：一个音节的字要列全
EXTRA=()
[[ -f "$RIME/cn_dicts/41448.dict.yaml" ]] && EXTRA=(--extra-chars "$RIME/cn_dicts/41448.dict.yaml")
python3 tools/rime2tsv.py ${EXTRA[@]+"${EXTRA[@]}"} "$RIME/rime_ice.dict.yaml" > "$OUT/lexicon.rime.tsv"

# 可选数据源。放在热词表之前：data/ 下手工定的词频（只提不降）和黑名单最后套，不会被冲掉，
# 外部数据源带进来的错条目也能用 data/blocklist.tsv 去掉。
NOTICES=""
APPLIED=""
if [[ "$EXTRAS" != "  " ]]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  lex="$OUT/lexicon.rime.tsv"
  step=0

  if want corpus; then
    # Tatoeba 每周重新导出，官网文件不固定：钉 Internet Archive 存的一份（2026-11-05）
    TATOEBA_URL=https://web.archive.org/web/20261105045937id_/https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2
    TATOEBA_SHA256=d603c1b9c67fb7a5a68c56fe6df5c935025ca1f36a1f9a912c33ed6dbed91743
    CORPUS_WEIGHT=${WOWTYPE_CORPUS_WEIGHT:-0.3}
    require_py jieba 0.42.1
    corpus_args=()
    if [[ -n "${WOWTYPE_CORPUS:-}" ]]; then
      if [[ -z "${WOWTYPE_CORPUS_LICENSE:-}" ]]; then
        echo "用本机语料（WOWTYPE_CORPUS）时要用 WOWTYPE_CORPUS_LICENSE 写清来源和许可证" >&2
        exit 1
      fi
      read -r -a corpus_files <<< "$WOWTYPE_CORPUS"
      corpus_args=(--column "${WOWTYPE_CORPUS_COLUMN:-0}")
      if [[ "${WOWTYPE_CORPUS_T2S:-}" == "1" ]]; then
        require_py opencc-python-reimplemented 0.1.7
        corpus_args+=(--t2s)
      fi
      corpus_license=$WOWTYPE_CORPUS_LICENSE
    else
      fetch_pinned "Tatoeba 中文句子" "$TATOEBA_URL" "$TATOEBA_SHA256" "$tmp/cmn_sentences.tsv.bz2" \
        "${WOWTYPE_TATOEBA_FILE:-}"
      require_py opencc-python-reimplemented 0.1.7
      corpus_files=("$tmp/cmn_sentences.tsv.bz2")
      corpus_args=(--column 3 --t2s)
      corpus_license="Tatoeba（https://tatoeba.org）的中文句子，2026-11-05 的导出，许可证 CC BY 2.0 FR
  （https://creativecommons.org/licenses/by/2.0/fr/），作者见 https://tatoeba.org 上各句的页面。
  下载地址：${TATOEBA_URL}"
    fi
    python3 tools/mine_corpus_freq.py "${corpus_args[@]}" "${corpus_files[@]}" > "$tmp/corpus.counts"
    step=$((step + 1)); out="$tmp/lexicon.${step}.tsv"
    python3 tools/blend-freq.py "$lex" "$tmp/corpus.counts" "$out" --weight "$CORPUS_WEIGHT" --label 语料
    lex=$out
    corpus_sums=""
    for f in "${corpus_files[@]}"; do
      corpus_sums+="
  $(basename "$f")  sha256 $(sha256 "$f")"
    done
    APPLIED+=" corpus"
    NOTICES+="
语料词频（corpus）：用 jieba 0.42.1 给下列语料分词计数，按权重 ${CORPUS_WEIGHT} 融进已有词的词频
（tools/mine_corpus_freq.py、tools/blend-freq.py），不加新词。语料：${corpus_sums}
来源与许可证：${corpus_license}
"
  fi

  if want jieba; then
    JIEBA_DICT_URL=https://raw.githubusercontent.com/fxsjy/jieba/v0.42.1/jieba/dict.txt
    JIEBA_DICT_SHA256=7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8
    require_py pypinyin 0.55.0
    fetch_pinned "jieba 词典" "$JIEBA_DICT_URL" "$JIEBA_DICT_SHA256" "$tmp/jieba.dict" "${WOWTYPE_JIEBA_DICT:-}"
    # 单字不融合（雾凇的单字频次决定 d/l/b 这些简拼的首选），只用 jieba 里频次 >= 20 的词
    python3 tools/jieba2tsv.py --dict "$tmp/jieba.dict" --counts --min-chars 2 > "$tmp/jieba.counts"
    step=$((step + 1)); out="$tmp/lexicon.${step}.tsv"
    python3 tools/blend-freq.py "$lex" "$tmp/jieba.counts" "$out" --weight 0.3 --label jieba
    lex=$out
    python3 tools/jieba2tsv.py --dict "$tmp/jieba.dict" --new --lexicon "$lex" --min-freq 50 > "$tmp/jieba.new"
    step=$((step + 1)); out="$tmp/lexicon.${step}.tsv"
    python3 tools/add-words.py "$lex" "$tmp/jieba.new" "$out" --label jieba
    lex=$out
    APPLIED+=" jieba"
    NOTICES+="
jieba 词频（jieba）：jieba 0.42.1 的词典（${JIEBA_DICT_URL}，sha256 ${JIEBA_DICT_SHA256}）
里频次 >= 20 的多字词按权重 0.3 融进已有词的词频，并补了一批词库里没有的词，读音由 pypinyin 0.55.0 生成，
只收读音可靠的词（tools/jieba2tsv.py）。两者都是 MIT 许可证：

  jieba：Copyright (c) 2013 Sun Junyi
  pypinyin：Copyright (c) 2016 mozillazg, 闲耘 <hotoo.cn@gmail.com>

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the \"Software\"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
"
  fi

  if want cedict; then
    # mdbg 上的文件每天更新，不固定：钉 Internet Archive 存的一份（2026-11-04 版，125365 条）
    CEDICT_URL=https://web.archive.org/web/20261105062842id_/https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz
    CEDICT_SHA256=68f54ba4159aa8234326c881482705e81277b4a84e8e67e090a1318068e5e0aa
    fetch_pinned "CC-CEDICT" "$CEDICT_URL" "$CEDICT_SHA256" "$tmp/cedict.txt.gz" "${WOWTYPE_CEDICT_FILE:-}"
    python3 tools/cedict2tsv.py "$tmp/cedict.txt.gz" > "$tmp/cedict.tsv"
    # 没有词频：统一给 10，比雾凇里几乎所有词都低，只在整串拼音只对得上它时出来；最多 4 个字
    step=$((step + 1)); out="$tmp/lexicon.${step}.tsv"
    python3 tools/add-words.py "$lex" "$tmp/cedict.tsv" "$out" --freq 10 --max-chars 4 --label CC-CEDICT
    lex=$out
    APPLIED+=" cedict"
    NOTICES+="
CC-CEDICT 补词（cedict）：词库里没有的词（最多 4 个字，去掉异体和儿化）从 CC-CEDICT 补进来，
频次是统一给的 10，不是 CC-CEDICT 的数据（tools/cedict2tsv.py、tools/add-words.py）。
  CC-CEDICT（https://cc-cedict.org/），2026-11-04 版，下载地址：${CEDICT_URL}
  sha256 ${CEDICT_SHA256}
  CC-CEDICT is licensed under the Creative Commons Attribution-ShareAlike 4.0
  International License: https://creativecommons.org/licenses/by-sa/4.0/
"
  fi
  mv "$lex" "$OUT/lexicon.rime.tsv"
fi

# 合进 WowType 自己整理的热词（AI、工作、网络用语），见 data/hotwords.tsv；
# 再按 data/rime-ice-freq.tsv 修正几个常用词的词频，去掉 data/blocklist.tsv 里的错条目（去次）
python3 tools/add_hotwords.py "$OUT/lexicon.rime.tsv" data/hotwords.tsv > "$OUT/lexicon.hot.tsv"
python3 tools/add_hotwords.py "$OUT/lexicon.hot.tsv" data/rime-ice-freq.tsv --block data/blocklist.tsv > "$OUT/lexicon.tsv"
rm "$OUT/lexicon.rime.tsv" "$OUT/lexicon.hot.tsv"
cat "$RIME/en_dicts/en.dict.yaml" "$RIME/en_dicts/en_ext.dict.yaml" > "$OUT/english.txt"
cp "$RIME/LICENSE" "$OUT/LICENSE"

# 词级语言模型，训练语料与命令见 Release 说明；换模型时同时改 URL 和 sha256
LM_URL=https://github.com/Gloridust/WowType/releases/download/lm-2026.11.09/words.lm.xz
LM_SHA256=42cb7c4a7cededa29b1a9ff105530085529fefff96535cc051341ebd51605dbe
if [[ -n "${WOWTYPE_LM_FILE:-}" ]]; then
  cp "$WOWTYPE_LM_FILE" "$OUT/words.lm"
else
  # macOS 默认没有 xz，用 python3 自带的 lzma 解
  if command -v xz >/dev/null; then
    curl -fsSL --retry 3 "$LM_URL" | xz -d > "$OUT/words.lm"
  else
    curl -fsSL --retry 3 "$LM_URL" |
      python3 -c 'import lzma, shutil, sys; shutil.copyfileobj(lzma.open(sys.stdin.buffer), sys.stdout.buffer)' \
      > "$OUT/words.lm"
  fi
fi
actual=$(sha256 "$OUT/words.lm")
if [[ "$actual" != "$LM_SHA256" ]]; then
  echo "words.lm 的 sha256 对不上（应为 ${LM_SHA256}，实际 ${actual}）" >&2
  exit 1
fi

COMMIT=$(git -C "$RIME" rev-parse HEAD 2>/dev/null || echo unknown)
DATE=$(git -C "$RIME" log -1 --format=%cs 2>/dev/null || date +%F)
cat > "$OUT/SOURCE.txt" <<EOF
数据来源：雾凇拼音 rime-ice（https://github.com/iDvel/rime-ice），许可证 GPL-3.0，见 LICENSE。
版本：${COMMIT}（${DATE}）
lexicon.tsv 由 WowType 的 tools/rime2tsv.py 转换自 rime_ice.dict.yaml 及其 import_tables，
另从 cn_dicts/41448.dict.yaml（大字表）补了词库里没有的单字读音（频次记 0.7~0.9），
再用 tools/add_hotwords.py 合进 WowType 的热词表 data/hotwords.tsv、按 data/rime-ice-freq.tsv 修正几个常用词的词频、
去掉 data/blocklist.tsv 里的错条目；
english.txt 是 en_dicts/en.dict.yaml 与 en_dicts/en_ext.dict.yaml 原样拼接。

words.lm 是 WowType 的词级语言模型，由 wowtype-lmbuild 从下列语料统计生成，许可证 CC BY-SA 4.0：
  LCCC（https://huggingface.co/datasets/thu-coai/lccc，清华大学 CoAI 组，MIT）
  中文维基百科（https://zh.wikipedia.org/，CC BY-SA 4.0）
下载地址：$LM_URL
sha256：$LM_SHA256
EOF
# 可选数据源的来源和许可证说明（只在用到时写）。SOURCE.txt 所有安装包都带
# （deb/rpm/Arch 装成 DATA-SOURCE.txt，macOS 放进 Resources，数据压缩包和 Nix 也有），不用另加文件。
if [[ -n "$NOTICES" ]]; then
  {
    echo
    echo "额外数据源：${APPLIED# }（scripts/make-data.sh 的 WOWTYPE_DATA_EXTRAS，按这个顺序处理，都在合热词表之前）"
    printf '%s' "$NOTICES"
  } >> "$OUT/SOURCE.txt"
fi
# 词库包版本 = rime-ice 日期 + WowType 自己的修订号；只改了热词表等、rime-ice 没变时加 REV，
# 否则同版本号的包 apt 不会更新。rime-ice 换新日期时 REV 归 0。
REV=4
echo "$DATE.$REV" > "$OUT/VERSION"

LINES=$(grep -vc '^#' "$OUT/lexicon.tsv" || true)
echo "词库 $LINES 条 -> $OUT/lexicon.tsv（rime-ice ${DATE}，修订 ${REV}）"
if (( LINES < 100000 )); then
  echo "词库条数太少，rime-ice 的目录结构可能变了" >&2
  exit 1
fi
