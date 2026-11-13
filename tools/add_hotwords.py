#!/usr/bin/env python3
"""把热词表合进词库。

    python3 tools/add_hotwords.py lexicon.tsv data/hotwords.tsv [--freq 30000] [--block data/blocklist.tsv] > lexicon.new.tsv

热词表每行「拼音<TAB>词[<TAB>词频]」，没写词频的用 --freq。
词库里已有的词：每个读音的词频提到不低于这个词频（已经更高的不动）。热词表里写了、词库里没有的读音
（没有的词、多音的另一种读法，比如「弃车保帅」的 qi ju 和 qi che）按热词表的拼音加在末尾。
同一个词可以写几行，每行一个读音。
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
        pinyin, word = " ".join(cols[0].split()), cols[1]
        freq = int(cols[2]) if len(cols) > 2 and cols[2].strip() else args.freq
        # 同一个词写了几行：每个读音都记下，词频取最大的
        readings, old = hot.get(word, ([], 0))
        if pinyin not in readings:
            readings.append(pinyin)
        hot[word] = (readings, max(old, freq))

    blocked = set()
    if args.block:
        for line in open(args.block, encoding="utf-8"):
            line = line.rstrip("\n")
            if line and not line.startswith("#"):
                blocked.add(line.split("\t")[-1].strip())

    # 词库里每个热词已有的读音
    seen = {}
    raised = 0
    removed = 0
    out = sys.stdout
    for line in open(args.lexicon, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        if len(cols) >= 3 and not line.startswith("#") and cols[1] in blocked:
            removed += 1
            continue
        if len(cols) >= 3 and not line.startswith("#") and cols[1] in hot:
            seen.setdefault(cols[1], set()).add(" ".join(cols[0].split()))
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
    for word, (readings, freq) in hot.items():
        if word in blocked:
            continue
        for pinyin in readings:
            if pinyin not in seen.get(word, ()):
                out.write(f"{pinyin}\t{word}\t{freq}\n")
                added += 1
                if word in seen:
                    # 词库里有这个词、没有这个读音：打出来，换词库时好查有没有加进错读音
                    print(f"热词：给 {word} 加读音 {pinyin}（词库里是 {'、'.join(sorted(seen[word]))}）",
                          file=sys.stderr)
    print(f"热词：提高词频 {raised} 条，新增 {added} 个；去掉 {removed} 条", file=sys.stderr)


if __name__ == "__main__":
    main()
