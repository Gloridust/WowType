#!/usr/bin/env python3
"""把 jieba 的词典（MIT）转成 WowType 的拼音词表。

用法：
    python3 tools/jieba2tsv.py --min-freq 100 > jieba.tsv

输出：拼音<TAB>词<TAB>频次，拼音用空格分隔音节。
jieba 只给词和频次，读音用 pypinyin（MIT）补；多音字按 pypinyin 的词组读音。
"""

import argparse
import os
import re
import sys

CJK = re.compile(r"^[\u4e00-\u9fff]{1,8}$")


def main():
    ap = argparse.ArgumentParser(description="jieba 词典 -> 拼音词表")
    ap.add_argument("--dict", default=None, help="dict.txt 路径，默认用已安装的 jieba")
    ap.add_argument("--min-freq", type=int, default=10)
    ap.add_argument("--max-words", type=int, default=0, help="最多输出多少条，0 表示不限")
    args = ap.parse_args()

    path = args.dict
    if not path:
        import jieba
        path = os.path.join(os.path.dirname(jieba.__file__), "dict.txt")
    from pypinyin import Style, lazy_pinyin

    seen = set()
    count = 0
    for line in open(path, encoding="utf-8"):
        parts = line.split()
        if len(parts) < 2:
            continue
        word = parts[0]
        try:
            freq = int(parts[1])
        except ValueError:
            continue
        if freq < args.min_freq or not CJK.match(word) or word in seen:
            continue
        seen.add(word)
        pinyin = " ".join(
            lazy_pinyin(word, style=Style.NORMAL, errors="ignore", v_to_u=False))
        if not pinyin:
            continue
        print(f"{pinyin}\t{word}\t{freq}")
        count += 1
        if args.max_words and count >= args.max_words:
            break
    print(f"# {count} 条", file=sys.stderr)


if __name__ == "__main__":
    main()