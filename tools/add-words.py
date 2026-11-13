#!/usr/bin/env python3
"""把补充词表里、主词库没有的词追加进去（同词不同读音不重复加）。

用法：
    python3 tools/add-words.py base.tsv extra.tsv out.tsv
"""

import argparse
import sys


def main():
    ap = argparse.ArgumentParser(description='追加缺失的词')
    ap.add_argument('base')
    ap.add_argument('extra')
    ap.add_argument('output')
    args = ap.parse_args()

    words = set()
    rows = []
    for line in open(args.base, encoding='utf-8'):
        parts = line.rstrip().split(chr(9))
        if len(parts) < 3:
            continue
        rows.append(parts)
        words.add(parts[1])

    added = 0
    for line in open(args.extra, encoding='utf-8'):
        parts = line.rstrip().split(chr(9))
        if len(parts) < 3 or parts[1] in words:
            continue
        words.add(parts[1])
        rows.append(parts)
        added += 1

    with open(args.output, 'w', encoding='utf-8') as out:
        for parts in rows:
            out.write(chr(9).join(parts) + chr(10))
    print(f'新增 {added} 条，总共 {len(rows)} 条', file=sys.stderr)


if __name__ == '__main__':
    main()