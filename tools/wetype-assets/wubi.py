#!/usr/bin/env python3
"""分析微信输入法五笔词典（swbd86.bin / swbd98.bin / swbdnc.bin）的容器结构。

    python3 tools/wetype-assets/wubi.py [swbd86.bin …] [--json]

只报结构，不输出词条：文件头、尾部结构大小、`50 01 <字数> <UTF-16LE>` 形式的值记录有多少条、
落在哪段偏移、字数分布，以及前半部分 ASCII 码区的大致范围。

WowType 的五笔码表用的是公开的 rime-wubi（scripts/make-wubi.sh），**不用**这里的任何数据；
这个脚本只是记录格式研究的结论（读文件的是 LoudsTrieHashMapReader：LOUDS trie + 哈希表 + 值区）。
"""

import argparse
import collections
import os
import re

from _common import IME_DATA, FormatError, need, print_json, read_bytes, run

MAGIC = bytes.fromhex("029d300300130001")  # 3.0.x 的 swbd86/98/nc 开头都是这 8 字节
TAIL = 0x21  # 构造函数用 size - 0x21 切出正文，末尾 33 字节是单独的结构
CODE_RUN = re.compile(rb"[a-y]{2,4}(?=[^a-z])")


def scan_records(data):
    """数 `50 01 <n> <n 个 UTF-16LE 汉字>` 记录，返回 (条数, 首偏移, 末偏移, 字数分布)。"""
    count, first, last = 0, -1, -1
    lengths = collections.Counter()
    i, n = 0, len(data) - TAIL
    while True:
        i = data.find(b"\x50\x01", i, n)
        if i < 0 or i + 3 > n:
            break
        chars = data[i + 2]
        end = i + 3 + 2 * chars
        if 1 <= chars <= 16 and end <= n:
            units = [data[k] | (data[k + 1] << 8) for k in range(i + 3, end, 2)]
            if all(0x3400 <= u <= 0x9FFF or 0x3000 <= u <= 0x303F for u in units):
                count += 1
                lengths[chars] += 1
                first = i if first < 0 else first
                last = i
                i = end
                continue
        i += 1
    return count, first, last, lengths


def ascii_code_region(data):
    """前半部分像五笔码（2~4 个 a-y）的 ASCII 片段的分布范围（按 64KB 分桶，取命中多的桶）。"""
    buckets = collections.Counter(m.start() >> 16 for m in CODE_RUN.finditer(data))
    dense = sorted(b for b, c in buckets.items() if c >= 1000)
    if not dense:
        return None
    return {"from": dense[0] << 16, "to": (dense[-1] + 1) << 16, "runs": sum(buckets[b] for b in dense)}


def analyse(path):
    data = read_bytes(path)
    need(data, 0, 16 + TAIL, "文件头和尾部")
    if not data.startswith(MAGIC):
        raise FormatError(f"{path}：开头是 {data[:8].hex()}，不是五笔词典容器（应为 {MAGIC.hex()}）")
    count, first, last, lengths = scan_records(data)
    return {
        "path": path,
        "size": len(data),
        "header_hex": data[:16].hex(),
        "tail_bytes": TAIL,
        "records": count,
        "records_from": first,
        "records_to": last,
        "record_lengths": dict(sorted(lengths.items())),
        "ascii_codes": ascii_code_region(data),
    }


def main():
    ap = argparse.ArgumentParser(description="分析五笔词典容器的结构（不输出词条）")
    ap.add_argument("paths", nargs="*", default=[os.path.join(IME_DATA, n) for n in ("swbd86.bin", "swbd98.bin", "swbdnc.bin")])
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    reports = [analyse(p) for p in args.paths]
    if args.json:
        print_json(reports)
        return
    for r in reports:
        print(f"文件：{r['path']}（{r['size']:,} 字节）")
        print(f"  头 16 字节：{r['header_hex']}；尾部结构 {r['tail_bytes']} 字节")
        if r["records"]:
            print(f"  `50 01` 值记录：{r['records']:,} 条，偏移 0x{r['records_from']:x}–0x{r['records_to']:x}")
            print(f"  字数分布：{r['record_lengths']}")
        else:
            print("  没找到 `50 01` 值记录（版本不同？）")
        a = r["ascii_codes"]
        if a:
            print(f"  ASCII 码区：约 0x{a['from']:x}–0x{a['to']:x}（{a['runs']:,} 段 2~4 位 a-y 串）")
    print("（码 ↔ 词的对应没有解；WowType 用公开的 rime-wubi 码表，不用这里的数据）")


if __name__ == "__main__":
    run(main)
