#!/usr/bin/env python3
"""从词库 TSV 生成排序评测用例。

思路：同一个拼音往往对应多个同音词，取频次最高的那个作为期望答案，
这样用例的答案就是「这个词库里最该出现的词」。

用法：
    python3 tools/make_eval.py lexicon.tsv --count 500 > cases.tsv

默认只取最常用的 5000 个词。常用词几乎不会出错，「打全了的低频词被高频补全抢走」
（zhongdi 出「重点」不出「种地」）这类问题要用 --skip 换到中低频词才测得出来。
"""

import argparse
import sys
from collections import defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lexicon")
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--min-len", type=int, default=2, help="拼音总长度下限")
    ap.add_argument("--max-len", type=int, default=12, help="拼音总长度上限")
    ap.add_argument("--max-word", type=int, default=4, help="词的字数上限")
    ap.add_argument("--top", type=int, default=5000, help="只从频次前 N 的词里取")
    ap.add_argument(
        "--skip",
        type=int,
        default=0,
        help="跳过频次前 N 的词（只测中低频词：--skip 30000 --top 300000）。"
        "同音词排第几仍按全部词算",
    )
    ap.add_argument(
        "--jianpin",
        action="store_true",
        help="把输入换成简拼（只取每音节首字母）",
    )
    ap.add_argument(
        "--truncate",
        type=int,
        default=0,
        help="截掉末尾 N 个字母，模拟半成品输入（测补全能力）",
    )
    ap.add_argument(
        "--rank",
        type=int,
        default=1,
        help="取同音词里第几高频的作为期望（2/3 用来测候选广度）",
    )
    args = ap.parse_args()

    per_pinyin = defaultdict(list)  # pinyin -> [(freq, word)]
    rows = []
    with open(args.lexicon, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            pinyin, word, freq = parts[0], parts[1], parts[2]
            try:
                freq = float(freq)
            except ValueError:
                continue
            rows.append((freq, pinyin, word))

    rows.sort(key=lambda r: -r[0])
    rows = rows[: args.top]

    for index, (freq, pinyin, word) in enumerate(rows):
        syllables = pinyin.split()
        joined = "".join(s[0] for s in syllables) if args.jianpin else pinyin.replace(" ", "")
        if args.truncate > 0:
            if len(joined) <= args.truncate + 1:
                continue
            joined = joined[: -args.truncate]
        if not (args.min_len <= len(joined) <= args.max_len):
            continue
        if len(word) > args.max_word:
            continue
        bucket = per_pinyin[joined]
        if len(bucket) < args.rank:
            bucket.append((freq, word, index))

    # 第 rank 高频的词（同音词里第 2/3 个）
    items = [
        (joined, (bucket[args.rank - 1][1], bucket[args.rank - 1][0]))
        for joined, bucket in per_pinyin.items()
        if len(bucket) >= args.rank and bucket[args.rank - 1][2] >= args.skip
    ]
    # 均匀抽样，避免全是超高频词
    step = max(1, len(items) // args.count)
    sampled = items[::step][: args.count]

    out = sys.stdout
    out.write("# 由 tools/make_eval.py 生成\n")
    out.write("# 输入\t期望\n")
    for joined, (word, _freq) in sampled:
        out.write("%s\t%s\n" % (joined, word))
    print("生成 %d 条用例" % len(sampled), file=sys.stderr)


if __name__ == "__main__":
    main()
