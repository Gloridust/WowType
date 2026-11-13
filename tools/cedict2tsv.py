#!/usr/bin/env python3
"""CC-CEDICT（CC BY-SA 4.0）-> 拼音<TAB>词，交给 tools/add-words.py 补词。

用法：
    python3 tools/cedict2tsv.py cedict_1_0_ts_utf-8_mdbg.txt.gz > cedict.tsv

CC-CEDICT 的读音是人工校过的，但没有词频，频次由 add-words.py 统一给。不要的条目：
- 只是别的词的异体（释义全是 variant of / old variant of / erhua variant of …）
- 台湾用词（每个义项都标了 (Tw)，比如 卡达 = 卡塔尔）
- 儿化（读音里有 r5）：雾凇和 WowType 的拼音里没有单独的 r 音节
- 简体一栏不全是汉字（夹了字母、数字、·、，）——add-words.py 也会再查一遍
同一个简体词、同一个不带声调的拼音只出一次（mdbg 的文件里繁体不同、简体相同的词会重复）。
"""

import argparse
import gzip
import re
import sys

LINE = re.compile(r"^(\S+) (\S+) \[([^\]]+)\] /(.*)/\s*$")
VARIANT = re.compile(
    r"^(?:old |archaic |ancient |obscure |Japanese |erhua |non-standard |nonstandard |"
    r"unofficial |Korean |Taiwan )?variant of ", re.I)


def convert_pinyin(raw):
    out = []
    for syllable in raw.split():
        s = syllable.strip().lower().replace("u:", "v").replace("ü", "v")
        s = re.sub(r"[1-5]$", "", s)
        if s == "r" or not s.isascii() or not s.isalpha():
            return None
        out.append(s)
    return " ".join(out) if out else None


def senses(definition):
    return [s.strip() for s in definition.split("/") if s.strip()]


def only_variant(definition):
    parts = senses(definition)
    return bool(parts) and all(VARIANT.match(s) for s in parts)


def only_taiwan(definition):
    """每个义项都标了 (Tw)：台湾用词（卡达 = 卡塔尔、亚塞拜然 = 阿塞拜疆），简体是转写出来的，大陆不这么写。"""
    parts = senses(definition)
    return bool(parts) and all("(Tw)" in s for s in parts)


def main():
    ap = argparse.ArgumentParser(description="CC-CEDICT -> 拼音词表")
    ap.add_argument("path", help="cedict_1_0_ts_utf-8_mdbg.txt(.gz)")
    args = ap.parse_args()

    opener = gzip.open if args.path.endswith(".gz") else open
    seen = set()
    count = 0
    skipped = {"异体": 0, "台湾用词": 0, "儿化或非拼音": 0}
    with opener(args.path, "rt", encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            m = LINE.match(line)
            if not m:
                continue
            simplified, raw, definition = m.group(2), m.group(3), m.group(4)
            if only_variant(definition):
                skipped["异体"] += 1
                continue
            if only_taiwan(definition):
                skipped["台湾用词"] += 1
                continue
            pinyin = convert_pinyin(raw)
            if not pinyin:
                skipped["儿化或非拼音"] += 1
                continue
            key = (pinyin, simplified)
            if key in seen:
                continue
            seen.add(key)
            print(f"{pinyin}\t{simplified}")
            count += 1
    detail = "，".join(f"{k} {v}" for k, v in skipped.items())
    print(f"CC-CEDICT：{count} 条（跳过 {detail}）", file=sys.stderr)


if __name__ == "__main__":
    main()
