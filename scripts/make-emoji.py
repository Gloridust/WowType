#!/usr/bin/env python3
"""从 Unicode CLDR 生成 emoji 表 core/src/emoji/cldr.tsv（编进核心库）。

用法：scripts/make-emoji.py <下载目录> [输出文件]

下载目录里要有（都是 Unicode 官方数据，Unicode License v3）：
  emoji-test.txt                             https://unicode.org/Public/emoji/latest/emoji-test.txt
  cldr-annotations-full-{zh,en}.json         cldr-json 仓库 cldr-annotations-full/annotations/<语言>/annotations.json
  cldr-annotations-derived-full-{zh,en}.json cldr-json 仓库 cldr-annotations-derived-full/annotationsDerived/<语言>/annotations.json

只收 emoji 15.0 及以前的（新的系统字体可能还画不出来），不收肤色变体。
每行：emoji <TAB> 中文关键词（| 分隔，朗读名在前） <TAB> 英文关键词。顺序就是 Unicode 的 emoji 顺序。
"""
import json
import os
import re
import sys

MAX_VERSION = (15, 0)
SKIN_TONES = {chr(c) for c in range(0x1F3FB, 0x1F400)}


def load_annotations(path, key):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)[key]["annotations"]
    out = {}
    for emoji, entry in data.items():
        words = list(entry.get("tts", [])) + list(entry.get("default", []))
        out[emoji.replace("️", "")] = words
    return out


def keywords(emoji, *tables):
    words = []
    for table in tables:
        words += table.get(emoji.replace("️", ""), [])
    seen, out = set(), []
    for word in words:
        # 「旗: 中国」这种派生名拆开
        for part in re.split(r"[:：]\s*", word):
            part = part.strip().replace("|", " ").replace("\t", " ")
            if part and part not in seen:
                seen.add(part)
                out.append(part)
    return out


def main():
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(__file__), "..", "core", "src", "emoji", "cldr.tsv")
    zh = load_annotations(os.path.join(src, "cldr-annotations-full-zh.json"), "annotations")
    zh_d = load_annotations(os.path.join(src, "cldr-annotations-derived-full-zh.json"), "annotationsDerived")
    en = load_annotations(os.path.join(src, "cldr-annotations-full-en.json"), "annotations")
    en_d = load_annotations(os.path.join(src, "cldr-annotations-derived-full-en.json"), "annotationsDerived")

    version = "?"
    rows = []
    with open(os.path.join(src, "emoji-test.txt"), encoding="utf-8") as f:
        for line in f:
            if line.startswith("# Version:"):
                version = line.split(":", 1)[1].strip()
            m = re.match(r"^[0-9A-F ]+;\s*fully-qualified\s*#\s*(\S+)\s+E(\d+)\.(\d+)\s", line)
            if not m:
                continue
            emoji = m.group(1)
            if (int(m.group(2)), int(m.group(3))) > MAX_VERSION or SKIN_TONES & set(emoji):
                continue
            words_zh = keywords(emoji, zh, zh_d)
            words_en = keywords(emoji, en, en_d)
            # 中文表里的 lol 这类英文词归到英文那列
            words_en += [w for w in words_zh if w.isascii() and w not in words_en]
            words_zh = [w for w in words_zh if not w.isascii()]
            if not words_zh and not words_en:
                continue
            rows.append(f"{emoji}\t{'|'.join(words_zh)}\t{'|'.join(w.lower() for w in words_en)}")

    with open(dst, "w", encoding="utf-8") as f:
        f.write("# WowType emoji 表，由 scripts/make-emoji.py 生成，别手改。\n")
        f.write(f"# 来源：Unicode emoji-test.txt {version}、Unicode CLDR 注释（zh、en），只收 emoji 15.0 及以前。\n")
        f.write("# Copyright © 1991-2026 Unicode, Inc. Unicode License v3: https://www.unicode.org/license.txt\n")
        f.write("\n".join(rows) + "\n")
    print(f"{len(rows)} 个 emoji -> {dst}")


if __name__ == "__main__":
    main()
