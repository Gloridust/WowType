#!/usr/bin/env python3
"""把 jieba 词表（拼音<TAB>词<TAB>频次）合并进主词库。

用法：
    python3 tools/merge-lexicon.py base.tsv jieba.tsv merged.tsv [--min-new-freq 50]

规则：
- 同一个（拼音, 词）：两边的频次按比例混合（默认各一半）
- jieba 有、主词库没有的词：按比例换算后加入（低于 --min-new-freq 的不加）
- 词已经在主词库出现、只是读音不同（多音字）：不重复加
"""

import argparse
import sys


def load(path):
    rows = []
    index = {}
    words = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            pinyin, word = parts[0], parts[1]
            try:
                freq = float(parts[2])
            except ValueError:
                continue
            index[(pinyin, word)] = len(rows)
            words.add(word)
            rows.append([pinyin, word, freq])
    return rows, index, words


def main():
    ap = argparse.ArgumentParser(description="合并拼音词库")
    ap.add_argument("base")
    ap.add_argument("extra")
    ap.add_argument("output")
    ap.add_argument("--min-new-freq", type=float, default=50.0)
    ap.add_argument("--base-weight", type=float, default=0.5)
    args = ap.parse_args()

    base, base_index, base_words = load(args.base)
    extra, _, _ = load(args.extra)

    # 找共有词，算换算系数
    shared_base = 0.0
    shared_extra = 0.0
    for pinyin, word, freq in extra:
        i = base_index.get((pinyin, word))
        if i is not None:
            shared_base += base[i][2]
            shared_extra += freq
    scale = shared_base / shared_extra if shared_extra > 0 else 1.0

    blended = 0
    added = 0
    for pinyin, word, freq in extra:
        key = (pinyin, word)
        i = base_index.get(key)
        if i is not None:
            base[i][2] = base[i][2] * args.base_weight + freq * scale * (1.0 - args.base_weight)
            blended += 1
            continue
        if word in base_words:
            continue
        scaled = freq * scale
        if scaled < args.min_new_freq:
            continue
        base.append([pinyin, word, scaled])
        base_index[key] = len(base) - 1
        base_words.add(word)
        added += 1

    with open(args.output, "w", encoding="utf-8") as out:
        for pinyin, word, freq in base:
            out.write(f"{pinyin}\t{word}\t{freq:.0f}\n")

    print(f"主词库 {len(base) - added} 条，混合 {blended} 条，新增 {added} 条，"
          f"换算系数 {scale:.3f}", file=sys.stderr)


if __name__ == "__main__":
    main()