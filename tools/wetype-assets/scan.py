#!/usr/bin/env python3
"""列出微信输入法词典目录里每份文件的大小、dict_type、头部魔数和可打印字节比例。

    python3 tools/wetype-assets/scan.py [imeData.bundle 目录] [--json]

不给目录时用本机安装位置。只看结构（大小、头 16 字节、前 64KB 的可打印比例），
不输出文件内容。配合 index.json 可以知道每份文件在微信输入法里的 dict_type。
"""

import argparse
import json
import os
import sys

from _common import IME_DATA, need_dir, print_json, read_bytes, run

SAMPLE = 64 * 1024


def stats(path):
    head = read_bytes(path, SAMPLE)
    printable = sum(1 for b in head if 32 <= b < 127)
    return {
        "size": os.path.getsize(path),
        "magic": head[:8].hex(),
        "head_ascii": "".join(chr(b) if 32 <= b < 127 else "." for b in head[:16]),
        "printable_pct": round(printable * 100 / max(1, len(head))),
    }


def load_index(directory):
    """index.json：[{name, dict_type, is_cell, …}]；没有或格式不对就返回空表并提示。"""
    path = os.path.join(directory, "index.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            items = json.load(f)
    except (OSError, ValueError) as e:
        print(f"index.json 读不了，忽略：{e}", file=sys.stderr)
        return {}
    if isinstance(items, dict):  # 兼容可能的 {"list": [...]} 形式
        items = next((v for v in items.values() if isinstance(v, list)), [])
    return {i["name"]: i for i in items if isinstance(i, dict) and "name" in i}


def main():
    ap = argparse.ArgumentParser(description="扫描微信输入法词典目录（只看结构）")
    ap.add_argument("dir", nargs="?", default=IME_DATA)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    need_dir(args.dir)
    meta = load_index(args.dir)

    rows = []
    for name in sorted(os.listdir(args.dir)):
        path = os.path.join(args.dir, name)
        if name == "index.json" or not os.path.isfile(path):
            continue
        info = meta.get(name, {})
        rows.append({"name": name, **stats(path),
                     "dict_type": info.get("dict_type"), "is_cell": info.get("is_cell")})

    if args.json:
        print_json(rows)
        return
    print(f"{'文件':<32}{'大小':>13}  {'dict_type':<10}{'头部':<18}可打印%")
    for r in rows:
        print(f"{r['name']:<32}{r['size']:>13,}  {str(r['dict_type']):<10}{r['head_ascii']:<18}{r['printable_pct']}")
    print(f"共 {len(rows)} 个文件，index.json 记了 {len(meta)} 个")


if __name__ == "__main__":
    run(main)
