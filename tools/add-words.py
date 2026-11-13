#!/usr/bin/env python3
"""把补充词表里、词库还没有的词加到词库末尾。

用法：
    python3 tools/add-words.py lexicon.tsv extra.tsv out.tsv [--freq 10] [--max-chars 4]

extra.tsv 每行「拼音<TAB>词[<TAB>频次]」；没写频次、或给了 --freq 时用 --freq。
只加词库里一个读音都没有的词（已有的词不加新读音：多音词的读音交给 data/hotwords.tsv 手工补）。

每条都要过这几关，过不了的不加（--rejects 可以把原因写出来）：
- 只含汉字（基本区和扩展 A），不超过 --max-chars 个字
- 音节数等于字数，每个字的读音都是词库里这个字有的读音（含大字表的生僻读音）
- 同一个词、同一个拼音只加一次
表头和原有的行原样写回。
"""

import argparse

import lexdata


def main():
    ap = argparse.ArgumentParser(description="追加词库里没有的词")
    ap.add_argument("lexicon")
    ap.add_argument("extra")
    ap.add_argument("output")
    ap.add_argument("--freq", type=float, help="统一给的频次（覆盖 extra.tsv 的第三列）")
    ap.add_argument("--max-chars", type=int, default=8)
    ap.add_argument("--label", default="补词", help="日志里的名字")
    ap.add_argument("--rejects", help="把没加的词和原因写到这个文件")
    args = ap.parse_args()

    lex = lexdata.Lexicon(args.lexicon)
    known = lex.words()
    readings = lex.char_readings(include_rare=True)

    rejects = open(args.rejects, "w", encoding="utf-8") if args.rejects else None
    skipped = {}

    def reject(word, why):
        skipped[why] = skipped.get(why, 0) + 1
        if rejects:
            rejects.write(f"{word}\t{why}\n")

    seen = set()
    for line in open(args.extra, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2:
            continue
        pinyin, word = " ".join(cols[0].split()), cols[1]
        if word in known:
            continue
        if (pinyin, word) in seen:
            continue
        if not lexdata.CJK_WORD.match(word):
            reject(word, "不全是汉字")
            continue
        if len(word) > args.max_chars:
            reject(word, f"超过 {args.max_chars} 个字")
            continue
        syllables = pinyin.split()
        if len(syllables) != len(word):
            reject(word, "字数和音节数对不上")
            continue
        if any(s not in readings.get(ch, ()) for ch, s in zip(word, syllables)):
            reject(word, "有字的读音词库里没有")
            continue
        if args.freq is not None:
            freq = args.freq
        else:
            freq = lexdata.parse_freq(cols[2]) if len(cols) > 2 else None
            if freq is None:
                reject(word, "没有频次")
                continue
        seen.add((pinyin, word))
        lex.append(pinyin, word, freq)

    if rejects:
        rejects.close()
    lex.write(args.output)
    new_words = len({w for _, w in seen})
    detail = "，".join(f"{k} {v}" for k, v in sorted(skipped.items(), key=lambda kv: -kv[1]))
    lexdata.log(f"{args.label}：新增 {new_words} 个词（{len(seen)} 行）"
                + (f"；没加 {sum(skipped.values())} 个（{detail}）" if detail else ""))


if __name__ == "__main__":
    main()
