#!/usr/bin/env python3
"""用 OpenCC 生成简繁映射表（TSV：简体<TAB>繁体）。

先输出字符映射；给了 OpenCC 的 STPhrases.txt 时，再输出词组映射，
引擎转换时词组按最长匹配优先，「头发 -> 頭髮」「干净 -> 乾淨」这类一对多的字就能转对。

词组整张照收，不挑「逐字转会转错」的那些：OpenCC 自己也是拿整张词组表从左到右
最长匹配，逐字就能转对的词组在整句里还负责挡住别的词组（「为了」挡住「为了解决」
里的「了解 -> 瞭解」，「控制」挡住「控制面板」里的「制面 -> 製麪」）。少收一个，
整句就可能和 OpenCC 转得不一样；整张照收，引擎的结果和 OpenCC 一致。

OpenCC 是 Apache-2.0。STPhrases.txt 要和 pip 装的 opencc 是同一个版本（版本号会写进表头），
在 OpenCC 源码的 data/dictionary/ 下，例如：
    https://raw.githubusercontent.com/BYVoid/OpenCC/ver.1.1.9/data/dictionary/STPhrases.txt
pip 包里转换器实际用的是 clib/share/opencc/STPhrases.ocd2（同目录 dictionary/ 下的 txt
可能是旧的），也可以直接导出：
    opencc_dict -i .../clib/share/opencc/STPhrases.ocd2 -o STPhrases.txt -f ocd2 -t text

用法：
    python3 tools/opencc2tsv.py STPhrases.txt > core/data/s2t.tsv
    python3 tools/opencc2tsv.py > core/data/s2t.tsv      # 只要字符映射
"""

import sys


def read_phrases(path):
    """STPhrases.txt：简体词组 -> 文件里的第一个繁体写法，去重、保持顺序。"""
    seen = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            key = cols[0].strip()
            if len(key) > 1 and len(cols) > 1:
                seen.setdefault(key, cols[1].split(" ")[0])
    return seen


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
    version = getattr(opencc, "__version__", "?")
    out = sys.stdout
    out.write(f"# 由 tools/opencc2tsv.py 生成，数据来源 OpenCC {version} (Apache-2.0)\n")
    out.write("# 简体<TAB>繁体；左边多于一个字的是词组，转换时最长匹配优先\n")

    chars = 0
    ranges = [(0x4E00, 0x9FFF), (0x3400, 0x4DBF)]
    for lo, hi in ranges:
        for code in range(lo, hi + 1):
            ch = chr(code)
            t = conv.convert(ch)
            if t != ch and len(t) == 1:
                out.write(f"{ch}\t{t}\n")
                chars += 1
    print(f"生成 {chars} 条字符映射", file=sys.stderr)

    if len(sys.argv) == 2:
        phrases = read_phrases(sys.argv[1])
        stale = 0
        for p, listed in phrases.items():
            t = conv.convert(p)
            stale += t != listed
            out.write(f"{p}\t{t}\n")
        print(f"生成 {len(phrases)} 条词组映射", file=sys.stderr)
        if stale:
            # 词组表和 pip 的 opencc 不是同一个版本：字和词会来自两个版本
            print(f"警告：{stale} 个词组 OpenCC {version} 转出来和 {sys.argv[1]} 写的不一样，"
                  "检查两边版本是否一致", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
