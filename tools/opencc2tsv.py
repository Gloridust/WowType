#!/usr/bin/env python3
"""用 OpenCC 生成简繁字符映射表（TSV：简体<TAB>繁体）。

OpenCC 是 Apache-2.0，本脚本只生成字符级映射；词组级别的歧义消解需要
额外的词组表，这里不做。

用法：
    python3 tools/opencc2tsv.py > core/data/s2t.tsv
"""

import sys


def main():
    try:
        import opencc
    except ImportError:
        print("需要先安装：pip install opencc", file=sys.stderr)
        return 1

    conv = opencc.OpenCC("s2t")
    out = sys.stdout
    out.write("# 由 tools/opencc2tsv.py 生成，数据来源 OpenCC (Apache-2.0)\n")
    out.write("# 简体<TAB>繁体\n")

    ranges = [(0x4E00, 0x9FFF), (0x3400, 0x4DBF)]
    count = 0
    for lo, hi in ranges:
        for code in range(lo, hi + 1):
            ch = chr(code)
            t = conv.convert(ch)
            if t != ch and len(t) == 1:
                out.write(f"{ch}\t{t}\n")
                count += 1
    print(f"生成 {count} 条映射", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())