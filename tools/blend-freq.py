#!/usr/bin/env python3
"""把语料词频按比例融进词库：新频次 = 词库频次*(1-w) + 语料频次*换算系数*w。

用法：
    python3 tools/blend-freq.py lexicon.tsv freq.tsv out.tsv --weight 0.2

换算系数用两边都有的词来估（总频次之比），避免两套语料量级不同。
"""

import argparse
import sys


def main():
    ap = argparse.ArgumentParser(description='词库 + 语料词频')
    ap.add_argument('lexicon')
    ap.add_argument('counts')
    ap.add_argument('output')
    ap.add_argument('--weight', type=float, default=0.2)
    args = ap.parse_args()
    w = min(max(args.weight, 0.0), 1.0)

    rows = []
    for line in open(args.lexicon, encoding='utf-8'):
        parts = line.rstrip().split(chr(9))
        if len(parts) >= 3:
            rows.append([parts[0], parts[1], float(parts[2])])

    counts = {}
    for line in open(args.counts, encoding='utf-8'):
        parts = line.rstrip().split(chr(9))
        if len(parts) >= 2:
            counts[parts[0]] = float(parts[1])

    shared_base = sum(f for _, word, f in rows if word in counts)
    shared_counts = sum(counts[word] for _, word, f in rows if word in counts)
    scale = shared_base / shared_counts if shared_counts else 0.0

    blended = 0
    with open(args.output, 'w', encoding='utf-8') as out:
        for pinyin, word, freq in rows:
            count = counts.get(word)
            if count is not None:
                freq = freq * (1.0 - w) + count * scale * w
                blended += 1
            out.write(f'{pinyin}\t{word}\t{freq:.0f}\n')
    print(f'融合 {blended} 个词，换算系数 {scale:.2f}', file=sys.stderr)


if __name__ == '__main__':
    main()