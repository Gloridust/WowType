#!/usr/bin/env bash
# 外部盲测：用别人写的整句用例（tools/eval/external/，现在只有 chime 的 1010 条 test_holdout）量排序。
# 只报数，不设门槛、CI 不跑：这些句子不是照着我们的词库和模型写的，拿来看自家评测集看不出的问题
# （tools/eval/daily.tsv 带模型 94%，同样的配置在这里 60% 出头）。规矩见 tools/eval/external/README.md：只量，不照着它调。
#
#   scripts/eval-external.sh <数据目录> [--nnlm <nnlm.bin>] [wowtype-eval 的其它参数，比如 --misses、--fuzzy]
#
# 配置和外壳默认设置下一样（同 scripts/eval.sh）；输入法里带着整句增强模型，所以一般加上 --nnlm。
# WOWTYPE_EVAL_BIN 指定现成的 wowtype-eval，不给就现编一个。数据目录要可写（载入词库会在旁边写缓存）。
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=${1:?用法：scripts/eval-external.sh <数据目录> [--nnlm <nnlm.bin>] [wowtype-eval 的参数]}
shift

BIN=${WOWTYPE_EVAL_BIN:-}
if [[ -z "$BIN" ]]; then
  cargo build --release --locked -p wowtype-core --no-default-features --bin wowtype-eval >&2
  BIN=${CARGO_TARGET_DIR:-target}/release/wowtype-eval
fi

status=0
for set in tools/eval/external/*/; do
  args=(--data "$DATA")
  for f in "$set"*.tsv; do
    args+=(--eval "$f")
  done
  out=$("$BIN" "${args[@]}" "$@") || status=$?
  # 要看没通过的用例（--misses）时原样打出来，否则只打每组一行的表
  if [[ " $* " == *" --misses "* ]]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$out" | grep -E '^\| ' || true
  fi
  printf '%s\n' "$out" | awk -F'|' -v name="$(basename "$set")" '
    /^\| / && $3 + 0 > 0 {
      n += $3
      split($4, a, "%"); top1 += $3 * a[1] / 100
      split($5, b, "%"); top3 += $3 * b[1] / 100
      split($6, c, "%"); top9 += $3 * c[1] / 100
    }
    END {
      if (n) printf "%s 合计 %d 条：top1 %.1f%%  top3 %.1f%%  top9 %.1f%%\n", name, n, 100 * top1 / n, 100 * top3 / n, 100 * top9 / n
    }'
done
exit "$status"
