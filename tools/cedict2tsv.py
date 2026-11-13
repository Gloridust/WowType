#!/usr/bin/env python3
"""把 CC-CEDICT 转成拼音词表：拼音<TAB>词<TAB>频次。

CC-CEDICT 只有词和读音、没有词频，所以频次统一给一个很小的值；
合并时只补主词库没有的词。许可证 CC BY-SA 4.0。
"""

import argparse
import re
import sys

LINE = re.compile(r'^(\S+) (\S+) \[([^\]]+)\]')


def convert_pinyin(raw):
    out = []
    for syllable in raw.split():
        syllable = syllable.strip().lower().replace('u:', 'v')
        syllable = re.sub(r'[0-9]', '', syllable)
        if syllable == 'r':
            out.append('er')
            continue
        if not syllable.isalpha() or not syllable.isascii():
            return None
        out.append(syllable)
    return ' '.join(out) if out else None


def main():
    ap = argparse.ArgumentParser(description='CC-CEDICT -> 拼音词表')
    ap.add_argument('path')
    ap.add_argument("--freq", type=float, default=10.0)
    args = ap.parse_args()

    seen = set()
    count = 0
    for line in open(args.path, encoding='utf-8'):
        if line.startswith('#'):
            continue
        m = LINE.match(line)
        if not m:
            continue
        simplified = m.group(2)
        pinyin = convert_pinyin(m.group(3))
        if not pinyin or len(simplified) > 8:
            continue
        key = (pinyin, simplified)
        if key in seen:
            continue
        seen.add(key)
        print(f'{pinyin}\t{simplified}\t{args.freq:g}')
        count += 1
    print(f'# {count} 条', file=sys.stderr)


if __name__ == '__main__':
    main()