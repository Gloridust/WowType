#!/usr/bin/env python3
"""把 Rime 五笔 86 词库（rime-wubi 的 wubi86.dict.yaml）转成 WowType 的五笔表。

用法：
    python3 tools/wubi2tsv.py wubi86.dict.yaml > wubi86.tsv
    python3 tools/wubi2tsv.py wubi86.dict.yaml -o wubi86.tsv

输出：每行 code<TAB>词<TAB>频次（整数），按 码 升序、频次降序排；没有注释行和表头。
同样的输入，输出逐字节相同（不含日期、路径）。

源文件的列是 text、code、weight、stem（见文件头 columns:）：
- 一个字的每个码（一级/二级/三级简码、全码）各占一行，各有各的权重，所以不需要「备用码」；
- 第 4 列 stem 是 Rime 造词用的「构词码」（字全码的前两码），**不是能敲的码**，不输出。
  （早先把它当备用码输出，结果 gg 下「一」排到了二级简码「五」前面。）

取舍：
- 注释掉的行（# 开头，如键名字的重复条目）不要；
- z 开头的码不要：那是符号表（zzbd、zzd……），z 键留给拼音反查/万能键；
- 权重为 0 的行不要：约 4.3 万个扩展区生僻字和 14 个部首，Rime 也只在「增廣」字集下才出；
- 没有权重列的行（2023 年补进的《通用规范汉字表》字，163 个）要，频次记 1，排在同码最后；
- 私用区字符、空码、非 a-y 的码直接报错退出（源文件变了要人看）。
"""

import argparse
import sys

MIN_WEIGHT = 1  # 规范字没有权重时用的保底频次
CODE_CHARS = set("abcdefghijklmnopqrstuvwxy")


def is_private_use(text):
    return any(0xE000 <= ord(ch) <= 0xF8FF or ord(ch) >= 0xF0000 for ch in text)


def parse(path):
    """返回 {(code, 词): (频次, 行号)}；同一 (码, 词) 出现多次取最大频次。"""
    entries = {}
    stats = {"rows": 0, "comment": 0, "z": 0, "zero": 0, "noweight": 0, "dup": 0}
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    try:
        start = lines.index("...") + 1  # YAML 头之后才是词条
    except ValueError:
        sys.exit(f"{path}：找不到 YAML 头的结束行「...」，不像 Rime 词库")
    for lineno, line in enumerate(lines[start:], start + 1):
        line = line.rstrip("\r")
        if not line:
            continue
        if line.startswith("#"):
            stats["comment"] += 1
            continue
        fields = line.split("\t")
        if len(fields) < 2 or len(fields) > 4:
            sys.exit(f"{path}:{lineno}：列数不对（{len(fields)}）：{line!r}")
        stats["rows"] += 1
        text, code = fields[0], fields[1]
        if not text or not code:
            sys.exit(f"{path}:{lineno}：空的词或码：{line!r}")
        if code.startswith("z"):
            stats["z"] += 1
            continue
        if len(code) > 4 or not set(code) <= CODE_CHARS:
            sys.exit(f"{path}:{lineno}：码不是 1~4 个 a-y：{line!r}")
        if is_private_use(text):
            sys.exit(f"{path}:{lineno}：词里有私用区字符：{line!r}")
        if len(fields) == 2 or not fields[2]:
            weight = MIN_WEIGHT
            stats["noweight"] += 1
        else:
            try:
                weight = int(fields[2])
            except ValueError:
                sys.exit(f"{path}:{lineno}：权重不是整数：{line!r}")
            if weight <= 0:
                stats["zero"] += 1
                continue
        key = (code, text)
        if key in entries:
            stats["dup"] += 1
            if weight <= entries[key][0]:
                continue
        entries[key] = (weight, lineno)
    return entries, stats


def main():
    ap = argparse.ArgumentParser(description="Rime 五笔 86 词库 -> WowType 五笔表")
    ap.add_argument("path", help="wubi86.dict.yaml")
    ap.add_argument("-o", "--output", help="输出文件（默认标准输出）")
    args = ap.parse_args()

    entries, stats = parse(args.path)
    # 码升序、频次降序；同码同频按源文件行号，保证稳定
    rows = sorted(entries.items(), key=lambda kv: (kv[0][0], -kv[1][0], kv[1][1]))
    out = "".join(f"{code}\t{text}\t{weight}\n" for (code, text), (weight, _) in rows)
    if args.output:
        with open(args.output, "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
    else:
        sys.stdout.buffer.write(out.encode("utf-8"))
    codes = len({code for code, _ in entries})
    print(
        f"# 输出 {len(rows)} 条，{codes} 个码；源 {stats['rows']} 行，"
        f"跳过 z 码 {stats['z']}、零权重 {stats['zero']}、注释 {stats['comment']}，"
        f"无权重补 1：{stats['noweight']}，重复 {stats['dup']}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
