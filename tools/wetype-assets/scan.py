#!/usr/bin/env python3
"""扫描一个词典目录，列出文件大小、头部魔数和可打印字符串概况。

    python3 tools/wetype-assets/scan.py "/Library/Input Methods/WeType.app/Contents/Resources/imeData.bundle"

配合 index.json 可以知道每份文件在微信输入法里的 dict_type，便于决定先解哪一个。
"""

import argparse
import json
import os
import sys


def stats(path):
    data = open(path, "rb").read()
    head = data[:16]
    printable = sum(1 for b in data[:65536] if 32 <= b < 127)
    return {
        "size": len(data),
        "magic": head[:8].hex(),
        "head_ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in head),
        "printable_pct": round(printable * 100 / max(1, len(data[:65536]))),
    }


def main():
    ap = argparse.ArgumentParser(description="扫描词典目录")
    ap.add_argument("dir")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(args.dir):
        sys.exit(f"不是目录：{args.dir}")

    meta = {}
    index = os.path.join(args.dir, "index.json")
    if os.path.isfile(index):
        for item in json.load(open(index, encoding="utf-8")):
            meta[item["name"]] = item

    rows = []
    for name in sorted(os.listdir(args.dir)):
        path = os.path.join(args.dir, name)
        if not os.path.isfile(path) or name == "index.json":
            continue
        row = {"name": name, **stats(path)}
        info = meta.get(name, {})
        row["dict_type"] = info.get("dict_type")
        row["is_cell"] = info.get("is_cell")
        rows.append(row)

    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return

    print(f"{'文件':<32}{'大小':>12}  {'dict_type':<10}{'头部':<18}{'可打印%'}")
    for r in rows:
        print(f"{r['name']:<32}{r['size']:>12,}  {str(r['dict_type']):<10}{r['head_ascii']:<18}{r['printable_pct']}")


if __name__ == "__main__":
    main()
