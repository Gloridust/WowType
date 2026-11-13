#!/usr/bin/env python3
"""把外部词频按比例融进词库（只改已有词的频次，不加词）。

用法：
    python3 tools/blend-freq.py lexicon.tsv counts.tsv out.tsv --weight 0.3

counts.tsv 每行「词<TAB>次数」，不带读音：jieba 的词典（tools/jieba2tsv.py --counts）、
语料挖出来的词频（tools/mine_corpus_freq.py）都是这个格式。

按词融合，不按行：
    词的新总频次 = 词库里这个词各读音的频次之和 * (1 - w) + 外部次数 * 换算系数 * w
再按原来各读音的比例分回去（多音词「行」的 xing / hang 各自乘同一个系数），
所以外部次数不会给每个读音各加一遍。换算系数用两边都有的词估（按词算，见 lexdata.shared_scale）。

不碰的行：表头和注释、频次小于 1 的生僻读音、占位频次的词（见 tools/lexdata.py）。
"""

import argparse

import lexdata


def main():
    ap = argparse.ArgumentParser(description="词库 + 外部词频")
    ap.add_argument("lexicon")
    ap.add_argument("counts")
    ap.add_argument("output")
    ap.add_argument("--weight", type=float, default=0.3, help="外部词频的比重，0~1")
    ap.add_argument("--label", default="词频", help="日志里的名字")
    args = ap.parse_args()
    w = min(max(args.weight, 0.0), 1.0)

    lex = lexdata.Lexicon(args.lexicon)
    counts = lexdata.load_counts(args.counts)
    placeholder = lex.placeholder()
    scale = lexdata.shared_scale(lex, counts, placeholder)
    if scale <= 0:
        raise SystemExit(f"{args.label}：外部词频和词库没有共同的词，算不出换算系数")

    blended_words = 0
    skipped_placeholder = 0
    for word, rows in lex.readings_by_word().items():
        count = counts.get(word)
        if count is None:
            continue
        usable = lexdata.blendable(rows, placeholder)
        if not usable:
            skipped_placeholder += 1
            continue
        total = sum(r[3] for r in usable)
        factor = (total * (1.0 - w) + count * scale * w) / total
        if factor == 1.0:
            continue
        for row in usable:
            lex.set_freq(row, row[3] * factor)
        blended_words += 1

    lex.write(args.output)
    lexdata.log(
        f"{args.label}：融合 {blended_words} 个词（{len(lex.changed)} 行），"
        f"占位频次/生僻读音跳过 {skipped_placeholder} 个，换算系数 {scale:.4g}，权重 {w:g}")


if __name__ == "__main__":
    main()
