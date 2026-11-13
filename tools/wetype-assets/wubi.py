#!/usr/bin/env python3
"""分析微信输入法的五笔词典（swbd86/98/nc.bin）。

    python3 tools/wetype-assets/wubi.py "/Library/Input Methods/WeType.app/Contents/Resources/imeData.bundle/swbd86.bin"

已确认的结构（来自符号和字节分析）：

- 文件由 `wxime::data::dict::LoudsTrieHashMapReader<SVDeserializer, ...>` 读取
  （反汇编 StaticWubiDict::Impl 构造函数可见），即 LOUDS 压缩 trie + 哈希表
- 值区里有 UTF-16LE 的中文词；大量记录以 `50 01` 开头，后跟字符数（u8）和 UTF-16 字符
- 文件尾部 33 字节是单独的尾部结构（构造时用 `size - 0x21` 排除）

还没解出来的：

- LOUDS 位序列/标签/哈希表的具体分段
- 每条值记录和五笔码的对应关系（码在文件前半部分的 ASCII 区）
"""

import argparse
import json
import struct
import sys


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def scan_words(data):
    """扫值区里 `50 01 <n> <UTF-16LE 字符>` 形式的记录。"""
    words = []
    i = 0
    n = len(data)
    while i + 3 < n:
        if data[i] == 0x50 and data[i + 1] == 0x01:
            count = data[i + 2]
            if 1 <= count <= 16 and i + 3 + 2 * count <= n:
                chars = [data[i + 3 + 2 * k] | (data[i + 4 + 2 * k] << 8) for k in range(count)]
                if all(0x3400 <= c <= 0x9FFF or 0x3000 <= c <= 0x303F for c in chars):
                    words.append({"offset": i, "text": "".join(map(chr, chars))})
                    i += 3 + 2 * count
                    continue
        i += 1
    return words


def main():
    ap = argparse.ArgumentParser(description="分析五笔词典容器")
    ap.add_argument("path")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    data = open(args.path, "rb").read()
    header = list(struct.unpack_from("<4I", data, 0))
    words = scan_words(data)
    report = {
        "path": args.path,
        "size": len(data),
        "header": header,
        "header_hex": data[:16].hex(),
        "words": len(words),
        "first": words[:5],
        "last": words[-3:],
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return
    print(f"文件：{args.path}（{len(data):,} 字节）")
    print(f"头部：{report['header_hex']}（u32 {header}）")
    print(f"`50 01` 词条：{len(words):,} 条")
    print("前几条：", "、".join(w["text"] for w in words[:8]))
    if words:
        print("最后几条：", "、".join(w["text"] for w in words[-5:]))
    print("（五笔码 ↔ 词条的对应还没解出来，码在文件前半部分的 ASCII 区）")


if __name__ == "__main__":
    main()