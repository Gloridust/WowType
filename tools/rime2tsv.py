#!/usr/bin/env python3
"""把 Rime 词库（.dict.yaml）转成 Wowtype 的 lexicon TSV。

用法：
    python3 tools/rime2tsv.py rime_ice.dict.yaml > lexicon.tsv
    python3 tools/rime2tsv.py --min-weight 0 rime_ice.dict.yaml > lexicon.tsv

输出格式（core/src/lexicon.rs 读取）：
    拼音<TAB>词<TAB>频次
拼音用空格分隔音节。

为什么要它：WeType 自己的词库还在逆向，先用雾凇拼音（rime-ice）这类开源词库
把整条输入链路跑起来，等二进制格式解完再替换。
"""

import argparse
import sys

# Rime 里 ü 的写法不统一：nv / nü / nu: 都可能出现
_UMLAUT = {
    "\u00fc": "v",
    "u:": "v",
    "v": "v",
}


def normalize_syllable(s: str) -> str:
    s = s.strip().lower()
    s = s.replace("\u00fc", "v").replace("u:", "v")
    return s


def normalize_code(code: str) -> str:
    """把 rime 的 code 字段规范成空格分隔的音节串。"""
    parts = []
    for raw in code.replace("'", " ").split():
        syl = normalize_syllable(raw)
        if not syl:
            continue
        # 只接受纯字母，避免把英文/符号条目混进来
        if not syl.isalpha():
            return ""
        parts.append(syl)
    return " ".join(parts)


def parse_columns(lines, start):
    """读取 YAML 头里的 columns 顺序，返回 (col_index, 条目起始行)。"""
    col = {"text": 0, "code": 1, "weight": 2}
    i = start
    while i < len(lines):
        line = lines[i].rstrip("\n")
        if line.startswith("columns:"):
            order = []
            i += 1
            while i < len(lines) and lines[i].lstrip().startswith("- "):
                order.append(lines[i].strip()[2:].strip())
                i += 1
            if order:
                col = {name: idx for idx, name in enumerate(order)}
            continue
        if line.strip() == "...":
            return col, i + 1
        i += 1
    return col, start


def convert(path, min_weight, out):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    col, body_start = parse_columns(lines, 0)
    ti = col.get("text", 0)
    ci = col.get("code", 1)
    wi = col.get("weight", 2)

    seen = {}
    total = 0
    kept = 0
    for line in lines[body_start:]:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) <= max(ti, ci):
            continue
        total += 1
        text = fields[ti].strip()
        code = normalize_code(fields[ci])
        if not text or not code:
            continue
        weight = 1.0
        if len(fields) > wi:
            try:
                weight = float(fields[wi])
            except ValueError:
                weight = 1.0
        if weight < min_weight:
            continue
        key = (code, text)
        # 同音同词取最大权重，避免重复条目稀释
        if key in seen:
            seen[key] = max(seen[key], weight)
            continue
        seen[key] = weight
        kept += 1

    items = sorted(seen.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))
    out.write("# 由 tools/rime2tsv.py 生成，来源：%s\n" % path)
    out.write("# 拼音<TAB>词<TAB>频次\n")
    for (code, text), weight in items:
        out.write("%s\t%s\t%d\n" % (code, text, int(round(weight))))

    print(
        "解析 %d 行，保留 %d 条，缺失 code 或非法音节的行被跳过" % (total, kept),
        file=sys.stderr,
    )


SAMPLE = """\
---
name: sample
version: "1"
sort: by_weight
columns:
  - text
  - code
  - weight
...

的\tde\t120000
是\tshi\t70000
你好\tni hao\t100000
西安\txi an\t3000
女\tnv\t2000
绿\tlv\t1500
花儿\thua r\t800
"""


def selftest():
    import subprocess
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write(SAMPLE)
        path = f.name
    import io

    buf = io.StringIO()
    convert(path, 0, buf)
    lines = [l for l in buf.getvalue().splitlines() if not l.startswith("#")]
    assert "ni hao\t你好\t100000" in lines, lines
    assert "xi an\t西安\t3000" in lines, lines
    assert "nv\t女\t2000" in lines, lines
    print("selftest ok: %d 条" % len(lines))


def main():
    ap = argparse.ArgumentParser(description="Rime 词库转 Wowtype TSV")
    ap.add_argument("path", nargs="?", help="rime .dict.yaml")
    ap.add_argument("--min-weight", type=float, default=0.0)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return
    if not args.path:
        ap.error("需要 rime .dict.yaml 路径")
    convert(args.path, args.min_weight, sys.stdout)


if __name__ == "__main__":
    main()
