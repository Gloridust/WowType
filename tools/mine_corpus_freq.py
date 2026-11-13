#!/usr/bin/env python3
"""从纯文本语料挖词频：词<TAB>次数，交给 tools/blend-freq.py 融进词库。

用法：
    python3 tools/mine_corpus_freq.py corpus.txt [more.txt.bz2 ...] > freq.tsv
    python3 tools/mine_corpus_freq.py --column 3 cmn_sentences.tsv.bz2 > freq.tsv   # Tatoeba 导出

每行一句；带 TAB 的文件用 --column 指定句子在第几列（从 1 数，Tatoeba 的导出是第 3 列，
tools/make_corpus_eval.py 生成的「拼音<TAB>句子」是第 2 列）。分词用 jieba，只留 1~8 个汉字的词。
语料是繁体时加 --t2s（要 opencc，比如 pip 的 opencc-python-reimplemented）。

做评测时别把评测句子放进语料：先按固定种子切出训练/留出两份（比如 #196 的 tools/make_corpus_eval.py），
只挖训练那份。docs/DATA.md 的评测就是这么做的。
语料的许可证跟着语料走（Tatoeba 是 CC BY 2.0 FR），make-data.sh 会把署名写进 SOURCE.txt。
"""

import argparse
import bz2
import re
import sys
from collections import Counter

CJK = re.compile(r"^[一-鿿]{1,8}$")


def open_text(path):
    if path.endswith(".bz2"):
        return bz2.open(path, "rt", encoding="utf-8")
    return open(path, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description="语料 -> 词频")
    ap.add_argument("corpus", nargs="+")
    ap.add_argument("--column", type=int, default=0,
                    help="句子在 TAB 分隔的第几列（从 1 数）；0 表示整行")
    ap.add_argument("--min-count", type=int, default=1)
    ap.add_argument("--min-chars", type=int, default=1,
                    help="只数至少这么多字的词（2 = 不数单字：单字的频次决定 d/l/b 这类简拼的首页）")
    ap.add_argument("--t2s", action="store_true", help="繁转简（需要 opencc）")
    args = ap.parse_args()

    import jieba
    jieba.setLogLevel(60)
    converter = None
    if args.t2s:
        import opencc
        converter = opencc.OpenCC("t2s")

    counts = Counter()
    sentences = 0
    for path in args.corpus:
        with open_text(path) as source:
            for line in source:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                if args.column:
                    cols = line.split("\t")
                    if len(cols) < args.column:
                        continue
                    line = cols[args.column - 1]
                if converter is not None:
                    line = converter.convert(line)
                sentences += 1
                for word in jieba.cut(line):
                    if len(word) >= args.min_chars and CJK.match(word):
                        counts[word] += 1

    kept = sorted(((w, c) for w, c in counts.items() if c >= args.min_count),
                  key=lambda kv: (-kv[1], kv[0]))
    for word, count in kept:
        print(f"{word}\t{count}")
    print(f"语料：{sentences} 句，{len(kept)} 个词（去重前 {len(counts)}）", file=sys.stderr)


if __name__ == "__main__":
    main()
