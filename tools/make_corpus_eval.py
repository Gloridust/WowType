#!/usr/bin/env python3
"""从公开句子语料生成训练/评测用例：输入拼音<TAB>句子。

用法：
    python3 tools/make_corpus_eval.py --tatoeba cmn_sentences.tsv.bz2 --split out/train.tsv:3000 out/test.tsv:500
    python3 tools/make_corpus_eval.py --text sentences.txt --out cases.tsv --count 2000

支持：
- Tatoeba 导出（id<TAB>lang<TAB>句子，可 .bz2）
- 纯文本，一行一句

处理：繁转简（有 opencc 就转）、去掉标点、pypinyin 注音（ü 写成 v）、按固定种子打乱。
许可证跟着语料走：Tatoeba 是 CC BY 2.0，生成的文件只用于本地训练/评测时不必提交。
"""

import argparse
import bz2
import random
import re
import sys

CJK = re.compile(r'[\u4e00-\u9fff]')


def open_text(path):
    if path.endswith('.bz2'):
        return bz2.open(path, 'rt', encoding='utf-8')
    return open(path, encoding='utf-8')


def main():
    ap = argparse.ArgumentParser(description='语料 -> 拼音用例')
    ap.add_argument('--tatoeba', help='Tatoeba 的 *_sentences.tsv(.bz2)')
    ap.add_argument('--text', help='一行一句的纯文本')
    ap.add_argument('--out', help='单文件输出')
    ap.add_argument('--count', type=int, default=0)
    ap.add_argument('--split', nargs='*', default=[], help='输出文件:条数 …')
    ap.add_argument('--min-chars', type=int, default=3)
    ap.add_argument('--max-chars', type=int, default=20)
    ap.add_argument('--seed', type=int, default=20261114)
    args = ap.parse_args()

    try:
        import opencc
        cc = opencc.OpenCC('t2s')
    except Exception:
        cc = None
    from pypinyin import Style, lazy_pinyin

    rows = []
    seen = set()
    source = open_text(args.tatoeba) if args.tatoeba else open_text(args.text)
    for line in source:
        line = line.rstrip()
        if not line or line.startswith('#'):
            continue
        text = line.split(chr(9))[-1] if args.tatoeba else line
        if cc is not None:
            text = cc.convert(text)
        chars = ''.join(CJK.findall(text))
        if not (args.min_chars <= len(chars) <= args.max_chars) or chars in seen:
            continue
        pinyin = ''.join(lazy_pinyin(chars, style=Style.NORMAL, errors='ignore', v_to_u=False))
        if not pinyin.isascii() or not pinyin.isalpha():
            continue
        seen.add(chars)
        rows.append((pinyin, chars))

    random.seed(args.seed)
    random.shuffle(rows)
    if args.count:
        rows = rows[:args.count]

    if args.split:
        start = 0
        for spec in args.split:
            path, _, count = spec.rpartition(':')
            n = int(count) if count else 0
            part = rows[start:start + n] if n else rows[start:]
            start += len(part)
            with open(path, 'w', encoding='utf-8') as out:
                for pinyin, text in part:
                    out.write(pinyin + chr(9) + text + chr(10))
            print(f'{path}: {len(part)} 条', file=sys.stderr)
        return

    out = open(args.out, 'w', encoding='utf-8') if args.out else sys.stdout
    for pinyin, text in rows:
        out.write(pinyin + chr(9) + text + chr(10))
    if args.out:
        out.close()
    print(f'共 {len(rows)} 条', file=sys.stderr)


if __name__ == '__main__':
    main()