#!/usr/bin/env bash
# 重新生成 data/tatoeba-freq.tsv（Tatoeba 中文句子的词频，scripts/make-data.sh 默认融进词库）。
#
#   scripts/make-tatoeba-freq.sh            重新生成并覆盖 data/tatoeba-freq.tsv
#   scripts/make-tatoeba-freq.sh --check    重新生成，和仓库里的逐字节比较，不一样就失败（不进默认构建）
#
# 语料钉死在 Internet Archive 存的一份导出上（Tatoeba 官网的文件每周重新导出），核对 sha256；
# 本机已有这份文件时 WOWTYPE_TATOEBA_FILE=<路径>（同样校验）。分词、繁转简要钉死版本的包：
#   python3 -m pip install --require-hashes -r tools/requirements-data.txt
# 换语料版本时同时改 URL、sha256、DATE、SENTENCES。
set -euo pipefail
cd "$(dirname "$0")/.."

TATOEBA_URL=https://web.archive.org/web/20261105045937id_/https://downloads.tatoeba.org/exports/per_language/cmn/cmn_sentences.tsv.bz2
TATOEBA_SHA256=d603c1b9c67fb7a5a68c56fe6df5c935025ca1f36a1f9a912c33ed6dbed91743
DATE=2026-11-05
TABLE=data/tatoeba-freq.tsv

check=
[[ "${1:-}" == "--check" ]] && check=1

for pkg in jieba==0.42.1 opencc-python-reimplemented==0.1.7; do
  have=$(python3 -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' "${pkg%%==*}" 2>/dev/null || true)
  if [[ "$have" != "${pkg##*==}" ]]; then
    echo "要 Python 包 ${pkg}（现在是 ${have:-没装}）：python3 -m pip install --require-hashes -r tools/requirements-data.txt" >&2
    exit 1
  fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
corpus=$tmp/cmn_sentences.tsv.bz2
if [[ -n "${WOWTYPE_TATOEBA_FILE:-}" ]]; then
  cp "$WOWTYPE_TATOEBA_FILE" "$corpus"
else
  curl -fsSL --retry 5 --retry-delay 10 -o "$corpus" "$TATOEBA_URL"
fi
got=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$corpus")
if [[ "$got" != "$TATOEBA_SHA256" ]]; then
  echo "Tatoeba 语料的 sha256 对不上（应为 ${TATOEBA_SHA256}，实际 ${got}）" >&2
  exit 1
fi

{
  cat <<EOF
# Tatoeba 中文句子的词频（只数两个字以上的词），scripts/make-data.sh 默认按权重 0.3 融进词库的已有词。
# 来源：Tatoeba（https://tatoeba.org）中文句子 ${DATE} 的导出 cmn_sentences.tsv.bz2，全部句子（繁体先转简体）
# 下载：${TATOEBA_URL}
# sha256：${TATOEBA_SHA256}
# 许可证：CC BY 2.0 FR，Tatoeba contributors（https://creativecommons.org/licenses/by/2.0/fr/）。
#   这里只有统计出来的词频，不含句子。
# 生成：scripts/make-tatoeba-freq.sh（jieba 0.42.1 分词，opencc-python-reimplemented 0.1.7 繁转简，
#   tools/mine_corpus_freq.py --column 3 --t2s --min-chars 2）；--check 核对能逐字节重新生成。
# 词<TAB>次数，按次数从多到少、同次数按词排
EOF
  python3 tools/mine_corpus_freq.py --column 3 --t2s --min-chars 2 "$corpus"
} > "$tmp/table.tsv"

if [[ -n "$check" ]]; then
  if cmp -s "$tmp/table.tsv" "$TABLE"; then
    echo "${TABLE} 和重新生成的逐字节相同"
  else
    echo "${TABLE} 和重新生成的不一样（jieba、opencc 版本或语料不对？）" >&2
    diff "$TABLE" "$tmp/table.tsv" | head -20 >&2 || true
    exit 1
  fi
else
  cp "$tmp/table.tsv" "$TABLE"
  echo "已生成 ${TABLE}（$(grep -vc '^#' "$TABLE") 个词）"
fi
