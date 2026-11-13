#!/usr/bin/env python3
"""从纯文本语料挖词频：词<TAB>次数。

用法：
    python3 tools/mine_corpus_freq.py corpus.txt > freq.tsv
    python3 tools/mine_corpus_freq.py --tatoeba cmn_sentences.tsv corpus.txt

分词用 jieba；只保留 1-8 个汉字的词。语料许可证跟着语料走
（Tatoeba 是 CC BY 2.0），挖出来的词频只用于本地/构建时融合词库。
"""

import argparse
import bz2
import re
import sys
from collections import Counter

CJK = re.compile(r'^[\u4e00-\u9fff]{1,8}$')


def main():
    ap = argparse.ArgumentParser(description='语料 -> 词频')
    ap.add_argument('corpus', nargs='+')
    ap.add_argument('--tatoeba', action='store_true', help='每行是 Tatoeba 的 id<TAB>lang<TAB>句子')
    ap.add_argument('--min-count', type=int, default=2)
    ap.add_argument('--t2s', action='store_true', help='繁转简（需要 opencc）')
    args = ap.parse_args()

    import jieba
    converter = None
    if args.t2s:
        import opencc
        converter = opencc.OpenCC('t2s')
    counts = Counter()
    for path in args.corpus:
        source = bz2.open(path, 'rt', encoding='utf-8') if path.endswith('.bz2') else open(path, encoding='utf-8')
        for line in source:
            line = line.rstrip()
            if not line or line.startswith('#'):
                continue
            if converter is not None:
                line = converter.convert(line)
            columns = line.split(chr(9))
            text = columns[-1] if (args.tatoeba or len(columns) == 3) else line
            for word in jieba.cut(text):
                if CJK.match(word):
                    counts[word] += 1

    kept = [(w, c) for w, c in counts.items() if c >= args.min_count]
    kept.sort(key=lambda kv: -kv[1])
    for word, count in kept:
        print(f'{word}\t{count}')
    print(f'# {len(kept)} 个词（原始 {len(counts)}）', file=sys.stderr)


if __name__ == '__main__':
    main()