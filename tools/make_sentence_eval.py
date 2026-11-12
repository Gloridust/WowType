#!/usr/bin/env python3
"""生成整句评测用例：拼音<TAB>句子。

两种来源：

    # 手写的句子（一行一句，# 开头是注释）
    python3 tools/make_sentence_eval.py --text tools/eval/daily_sentences.txt > daily.tsv

    # 从中文维基百科的 parquet 里抽句子（只抽训练语言模型时留出不用的分片）
    python3 tools/make_sentence_eval.py --wiki train-5.parquet --count 600 > wiki.tsv

依赖 pypinyin；--wiki 还要 pyarrow 和 opencc-python-reimplemented（转简体）。
拼音按 pypinyin 的词组读音给，ü 写成 v，和打字时一致。多音字偶尔会标错，
所以手写句子尽量挑没有歧义读音的说法。

维基百科的文本是 CC BY-SA 4.0，抽出的用例只在本地评测用，不提交。

--context 改成逐词的用例：把每句切成词，第 2 个词起每个词一条「拼音<TAB>词<TAB>前面的文字」，
测接着前文打的时候排序对不对（wowtype-eval 的第三列）。切词要 jieba：

    python3 tools/make_sentence_eval.py --text tools/eval/daily_sentences.txt --context > tools/eval/context.tsv
"""

import argparse
import random
import re
import sys

CJK = re.compile(r"^[一-鿿]+$")


def to_pinyin(text):
    from pypinyin import Style, lazy_pinyin

    syllables = lazy_pinyin(text, style=Style.NORMAL, errors="ignore", v_to_u=False)
    if len(syllables) != len(text):
        return None
    out = []
    for s in syllables:
        s = s.replace("ü", "v")
        if not re.fullmatch(r"[a-z]+", s):
            return None
        out.append(s)
    return "".join(out)


def syllables_of(text):
    """整句一起标音（多音字按词组读），返回每个字的拼音；有标不出的字时 None。"""
    from pypinyin import Style, lazy_pinyin

    syllables = lazy_pinyin(text, style=Style.NORMAL, errors="ignore", v_to_u=False)
    if len(syllables) != len(text):
        return None
    out = [s.replace("ü", "v") for s in syllables]
    if not all(re.fullmatch(r"[a-z]+", s) for s in out):
        return None
    return out


def context_cases(sentence):
    """一句切成词，第 2 个词起：(拼音, 词, 前面的文字)。"""
    import jieba

    syllables = syllables_of(sentence)
    if syllables is None:
        return
    words = list(jieba.cut(sentence, HMM=False))
    pos = len(words[0]) if words else 0
    for word in words[1:]:
        yield "".join(syllables[pos : pos + len(word)]), word, sentence[:pos]
        pos += len(word)


def from_text(path):
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        yield line


def from_wiki(path, count, min_len, max_len, seed):
    import opencc
    import pyarrow.parquet as pq

    t2s = opencc.OpenCC("t2s")
    rng = random.Random(seed)
    table = pq.read_table(path, columns=["text"])
    texts = table.column("text").to_pylist()
    rng.shuffle(texts)
    picked = []
    seen = set()
    for article in texts:
        # 每篇最多取两句，避免集中在少数文章
        took = 0
        for clause in re.split(r"[，。！？；：、（）《》「」『』“”\n]", t2s.convert(article)):
            clause = clause.strip()
            if not (min_len <= len(clause) <= max_len) or not CJK.match(clause):
                continue
            if clause in seen:
                continue
            seen.add(clause)
            picked.append(clause)
            took += 1
            if took >= 2:
                break
        if len(picked) >= count:
            break
    return picked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text")
    ap.add_argument("--wiki")
    ap.add_argument("--count", type=int, default=600)
    ap.add_argument("--min-len", type=int, default=4)
    ap.add_argument("--max-len", type=int, default=12)
    ap.add_argument("--seed", type=int, default=20261109)
    ap.add_argument("--context", action="store_true", help="逐词、带前文的用例（要 jieba）")
    args = ap.parse_args()
    if bool(args.text) == bool(args.wiki):
        sys.exit("--text 和 --wiki 二选一")
    if args.text:
        sentences = list(from_text(args.text))
    else:
        sentences = from_wiki(args.wiki, args.count, args.min_len, args.max_len, args.seed)
    if args.context:
        import logging

        import jieba

        jieba.setLogLevel(logging.ERROR)
        print("# 由 tools/make_sentence_eval.py --context 生成：拼音<TAB>词<TAB>前面已经上屏的文字")
        for s in sentences:
            for py, word, before in context_cases(s):
                print(f"{py}\t{word}\t{before}")
        return
    for s in sentences:
        py = to_pinyin(s)
        if py:
            print(f"{py}\t{s}")


if __name__ == "__main__":
    main()
