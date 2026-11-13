#!/usr/bin/env python3
"""jieba 的词典（MIT）-> 词频表，或带读音的候补新词。

    # 词<TAB>频次：给 tools/blend-freq.py 融合已有词的词频，不需要读音
    python3 tools/jieba2tsv.py --dict dict.txt --counts > jieba.counts

    # 拼音<TAB>词<TAB>频次：词库里没有的词，读音用 pypinyin（MIT）注，再交给 tools/add-words.py
    python3 tools/jieba2tsv.py --dict dict.txt --new --lexicon lexicon.tsv --min-freq 50 > jieba.new.tsv

jieba 只有词和频次，读音是 pypinyin 猜的。多音字猜错是实打实的风险（#172「弃车保帅」读成 qi che），
所以 --new 只收读音靠得住的词：每个字要么在雾凇里只有一个常用读音（频次 >= 1 的单字读音只有一个），
要么落在 pypinyin 词组表（phrases_dict）里整词查到的那一段；单字按默认读音猜的多音字，整个词不要。
注出来的读音还要每个字都是雾凇里这个字有的读音，字数和音节数对得上。

--new 的频次按两边都有的词换算到词库的尺度（同 tools/blend-freq.py），--min-freq 按换算后的值卡。
"""

import argparse
import sys

import lexdata


def read_dict(path, min_chars, min_count):
    """jieba dict.txt：词 频次 [词性]。同一个词只取第一次；频次低于 min_count 的不要。"""
    counts = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            word = parts[0]
            freq = lexdata.parse_freq(parts[1])
            if not freq or freq < min_count or word in counts:
                continue
            if len(word) < min_chars or not lexdata.CJK_WORD.match(word):
                continue
            counts[word] = freq
    return counts


class Reader:
    """pypinyin 注音，并判断每个字的读音是不是靠得住。"""

    def __init__(self, char_readings, all_readings):
        from pypinyin import Style, lazy_pinyin
        from pypinyin.constants import PHRASES_DICT
        from pypinyin.seg.simpleseg import seg

        self.lazy_pinyin = lazy_pinyin
        self.style = Style.NORMAL
        self.phrases = PHRASES_DICT
        self.seg = seg
        self.char_readings = char_readings  # 常用读音（频次 >= 1）
        self.all_readings = all_readings    # 含大字表的生僻读音

    def reading(self, word):
        """返回 (拼音, 原因)；读音不可靠时拼音是 None，原因说明为什么。"""
        syllables = self.lazy_pinyin(word, style=self.style, errors="ignore", v_to_u=False)
        if len(syllables) != len(word):
            return None, "字数和音节数对不上"
        # 哪些字的读音来自词组表（整段查到）
        from_phrase = [False] * len(word)
        pos = 0
        for part in self.seg(word):
            if len(part) > 1 and part in self.phrases:
                for i in range(pos, pos + len(part)):
                    from_phrase[i] = True
            pos += len(part)
        for i, (ch, syl) in enumerate(zip(word, syllables)):
            # 词组表给的读音可以是雾凇里的生僻读音；按单字猜的必须是常用读音
            # （郭嵩焘：pypinyin 单字默认 焘 dao，雾凇里 dao 只是大字表的生僻读音，常用的是 tao）
            allowed = self.all_readings if from_phrase[i] else self.char_readings
            if syl not in allowed.get(ch, ()):
                return None, f"读音雾凇里没有：{ch} {syl}"
            if not from_phrase[i] and len(self.char_readings.get(ch, ())) > 1:
                return None, f"多音字按单字猜：{ch}"
        return " ".join(syllables), ""


def main():
    ap = argparse.ArgumentParser(description="jieba 词典 -> 词频表 / 候补新词")
    ap.add_argument("--dict", required=True, help="jieba 的 dict.txt")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--counts", action="store_true", help="输出 词<TAB>频次")
    mode.add_argument("--new", action="store_true", help="输出词库里没有的词：拼音<TAB>词<TAB>频次")
    ap.add_argument("--lexicon", help="--new 要：现有词库（判断有没有、取单字读音、算换算系数）")
    ap.add_argument("--min-chars", type=int, default=1, help="只要至少这么多字的词")
    ap.add_argument("--min-count", type=float, default=20,
                    help="只要 jieba 词典里频次不低于这个数的词（太低的计数噪声大）")
    ap.add_argument("--min-freq", type=float, default=50, help="--new：换算到词库尺度后的最低频次")
    ap.add_argument("--rejects", help="--new：把没收的词和原因写到这个文件（检查用）")
    args = ap.parse_args()

    counts = read_dict(args.dict, args.min_chars, max(args.min_count, 1e-9))
    if args.counts:
        for word, freq in counts.items():
            print(f"{word}\t{freq:g}")
        lexdata.log(f"jieba：{len(counts)} 个词")
        return

    if not args.lexicon:
        ap.error("--new 需要 --lexicon")
    lex = lexdata.Lexicon(args.lexicon)
    placeholder = lex.placeholder()
    scale = lexdata.shared_scale(lex, counts, placeholder)
    if scale <= 0:
        raise SystemExit("jieba：和词库没有共同的词，算不出换算系数")
    known = lex.words()
    reader = Reader(lex.char_readings(), lex.char_readings(include_rare=True))

    rejects = open(args.rejects, "w", encoding="utf-8") if args.rejects else None
    kept = 0
    skipped = {}
    for word, freq in counts.items():
        if word in known or len(word) < 2:
            continue
        scaled = freq * scale
        if scaled < args.min_freq:
            continue
        pinyin, why = reader.reading(word)
        if pinyin is None:
            key = why.split("：")[0]
            skipped[key] = skipped.get(key, 0) + 1
            if rejects:
                rejects.write(f"{word}\t{why}\n")
            continue
        print(f"{pinyin}\t{word}\t{scaled:.6g}")
        kept += 1
    if rejects:
        rejects.close()
    detail = "，".join(f"{k} {v}" for k, v in sorted(skipped.items(), key=lambda kv: -kv[1]))
    lexdata.log(f"jieba：候补新词 {kept} 个（换算系数 {scale:.4g}）；读音不可靠没收 {sum(skipped.values())} 个"
                + (f"（{detail}）" if detail else ""))


if __name__ == "__main__":
    sys.exit(main())
