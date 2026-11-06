#!/usr/bin/env python3
"""从词库反推「字二元」统计，生成语言模型 TSV。

词库里的词本身不是上下文语料，但多字词内部的相邻字对能反映常见搭配
（例如「事情」贡献 事->情）。对单字候选的上下文排序有帮助，
比完全没有 LM 强，但不能替代真实语料训练出来的词级 LM。

用法：
    python3 tools/make_bigram.py lexicon.tsv --min-count 200 > lm.tsv
"""

import argparse
import sys
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lexicon")
    ap.add_argument("--min-count", type=float, default=100.0)
    ap.add_argument("--max-entries", type=int, default=200000)
    args = ap.parse_args()

    bigram = defaultdict(float)
    with open(args.lexicon, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            word, freq = parts[1], parts[2]
            try:
                freq = float(freq)
            except ValueError:
                continue
            chars = list(word)
            if len(chars) < 2:
                continue
            for a, b in zip(chars, chars[1:]):
                bigram[(a, b)] += freq

    items = sorted(bigram.items(), key=lambda kv: -kv[1])
    items = [kv for kv in items if kv[1] >= args.min_count][: args.max_entries]

    out = sys.stdout
    out.write("# 由 tools/make_bigram.py 从词库反推生成\n")
    out.write("# prev\tcur\tcount\n")
    for (a, b), count in items:
        out.write("%s\t%s\t%d\n" % (a, b, int(count)))
    print("生成 %d 条字二元" % len(items), file=sys.stderr)


if __name__ == "__main__":
    main()
