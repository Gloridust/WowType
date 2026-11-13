#!/usr/bin/env python3
"""用 OpenCC 生成简繁映射表（TSV：简体<TAB>繁体）。

先输出字符映射；给了 OpenCC 的 STPhrases.txt 时，再输出词组映射，
引擎转换时词组按最长匹配优先，「头发 -> 頭髮」「干净 -> 乾淨」这类一对多的字就能转对。
词组只留逐字转换会转错的那些，其余的逐字映射已经够用，不必重复。

OpenCC 是 Apache-2.0。STPhrases.txt 在 OpenCC 源码的 data/dictionary/ 下，
取和 pip 装的 opencc 同一个版本，例如：
    https://raw.githubusercontent.com/BYVoid/OpenCC/ver.1.4.1/data/dictionary/STPhrases.txt

用法：
    python3 tools/opencc2tsv.py STPhrases.txt > core/data/s2t.tsv
    python3 tools/opencc2tsv.py > core/data/s2t.tsv      # 只要字符映射
"""

import sys


def read_phrases(path):
    """STPhrases.txt 的左列（简体词组），去重、保持顺序。"""
    seen = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            key = line.split("\t", 1)[0].strip()
            if len(key) > 1:
                seen.setdefault(key, None)
    return list(seen)


def main():
    if len(sys.argv) > 2 or sys.argv[1:2] in (["-h"], ["--help"]):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        import opencc
    except ImportError:
        print("需要先安装：pip install opencc", file=sys.stderr)
        return 1

    conv = opencc.OpenCC("s2t")
    out = sys.stdout
    out.write("# 由 tools/opencc2tsv.py 生成，数据来源 OpenCC (Apache-2.0)\n")
    out.write("# 简体<TAB>繁体；左边多于一个字的是词组，转换时最长匹配优先\n")

    chars = {}
    ranges = [(0x4E00, 0x9FFF), (0x3400, 0x4DBF)]
    for lo, hi in ranges:
        for code in range(lo, hi + 1):
            ch = chr(code)
            t = conv.convert(ch)
            if t != ch and len(t) == 1:
                out.write(f"{ch}\t{t}\n")
                chars[ch] = t
    print(f"生成 {len(chars)} 条字符映射", file=sys.stderr)

    if len(sys.argv) == 2:
        want = {p: conv.convert(p) for p in read_phrases(sys.argv[1])}
        table = {}
        # 按引擎的最长匹配试转每个词组，转得和 OpenCC 不一样就收进表。收进来的词组
        # 会改变别的词组的切分（断发 会吃掉「不断发展」里的「发」），所以反复做到不再变。
        while True:
            longest = max(map(len, table), default=0)
            added = {p: t for p, t in want.items()
                     if p not in table and greedy(p, chars, table, longest) != t}
            if not added:
                break
            table.update(added)
        for p in want:
            if p in table:
                out.write(f"{p}\t{table[p]}\n")
        print(f"生成 {len(table)} 条词组映射", file=sys.stderr)
    return 0


def greedy(text, chars, phrases, longest):
    """和 core/src/convert.rs 一样：从左到右，词组最长匹配优先，其余逐字转换。"""
    out, i = [], 0
    while i < len(text):
        for n in range(min(longest, len(text) - i), 1, -1):
            if text[i:i + n] in phrases:
                out.append(phrases[text[i:i + n]])
                i += n
                break
        else:
            out.append(chars.get(text[i], text[i]))
            i += 1
    return "".join(out)


if __name__ == "__main__":
    sys.exit(main())
