#!/usr/bin/env python3
"""把热词表合进词库。

    python3 tools/add_hotwords.py lexicon.tsv data/hotwords.tsv [--freq 30000] [--block data/blocklist.tsv] > lexicon.new.tsv

热词表每行「拼音<TAB>词[<TAB>词频]」，没写词频的用 --freq。
词库里已有的词：每个读音的词频提到不低于这个词频（已经更高的不动）；没有的词按热词表的拼音加在末尾。
--block 给的表里的词（每行「拼音<TAB>词」或只有「词」）从词库里整个去掉，所有读音都去。
"""

import argparse
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lexicon")
    ap.add_argument("hotwords")
    ap.add_argument("--freq", type=int, default=30000)
    ap.add_argument("--block", help="要从词库里去掉的词")
    args = ap.parse_args()

    hot = {}
    for line in open(args.hotwords, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        pinyin, word = cols[:2]
        freq = int(cols[2]) if len(cols) > 2 and cols[2].strip() else args.freq
        # 同一个词写了几行（热词一行、词频修正又一行）：读音取第一行的，词频取最大的
        if word in hot:
            hot[word] = (hot[word][0], max(hot[word][1], freq))
        else:
            hot[word] = (pinyin, freq)

    blocked = set()
    if args.block:
        for line in open(args.block, encoding="utf-8"):
            line = line.rstrip("\n")
            if line and not line.startswith("#"):
                blocked.add(line.split("\t")[-1].strip())

    seen = set()
    raised = 0
    removed = 0
    out = sys.stdout
    for line in open(args.lexicon, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if len(cols) >= 3 and not line.startswith("#") and cols[1] in blocked:
            removed += 1
            continue
        if len(cols) >= 3 and not line.startswith("#") and cols[1] in hot:
            seen.add(cols[1])
            target = hot[cols[1]][1]
            try:
                freq = float(cols[2])
            except ValueError:
                freq = 0.0
            if freq < target:
                cols[2] = str(target)
                raised += 1
            out.write("\t".join(cols) + "\n")
        else:
            out.write(line)
    added = 0
    for word, (pinyin, freq) in hot.items():
        if word not in seen and word not in blocked:
            out.write(f"{pinyin}\t{word}\t{freq}\n")
            added += 1
    print(f"热词：提高词频 {raised} 条，新增 {added} 个；去掉 {removed} 条", file=sys.stderr)


if __name__ == "__main__":
    main()
