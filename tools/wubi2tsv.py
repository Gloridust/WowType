#!/usr/bin/env python3
"""把 Rime 五笔词库（wubi86.dict.yaml）转成 WowType 的五笔表。

用法：
    python3 tools/wubi2tsv.py wubi86.dict.yaml > wubi86.tsv

输出格式：
    code<TAB>词<TAB>频次

Rime 五笔的词条长这样：
    工<TAB>a<TAB>99454797<TAB>aa
即 词、主码、权重、若干备用码（简码/全码）。所有码都会输出，备用码权重打一折，
让主码的候选排在前面。
"""

import argparse
import sys


def parse(path):
    entries = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or "\t" not in line:
                continue
            fields = line.split("\t")
            if len(fields) < 3:
                continue
            text, code, weight = fields[0], fields[1], fields[2]
            try:
                weight = float(weight)
            except ValueError:
                continue
            if not text or not code or weight <= 0:
                continue
            key = (code, text)
            if weight > entries.get(key, 0.0):
                entries[key] = weight
            # 备用码：同一行后面的列
            for extra in fields[3:]:
                extra = extra.strip()
                if not extra:
                    continue
                key = (extra, text)
                value = weight / 10.0
                if value > entries.get(key, 0.0):
                    entries[key] = value
    return entries


def main():
    ap = argparse.ArgumentParser(description="Rime 五笔词库 -> WowType 五笔表")
    ap.add_argument("path")
    args = ap.parse_args()

    entries = parse(args.path)
    rows = sorted(entries.items(), key=lambda kv: (kv[0][0], -kv[1]))
    for (code, text), weight in rows:
        print(f"{code}\t{text}\t{weight:.0f}")
    print(f"# {len(rows)} 条，{len({c for c, _ in entries})} 个码", file=sys.stderr)


if __name__ == "__main__":
    main()