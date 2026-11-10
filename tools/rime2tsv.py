#!/usr/bin/env python3
"""把 Rime 词库（.dict.yaml）转成 WowType 的 lexicon TSV。

用法：
    python3 tools/rime2tsv.py rime_ice.dict.yaml > lexicon.tsv
    python3 tools/rime2tsv.py --min-weight 0 rime_ice.dict.yaml > lexicon.tsv

输出格式（core/src/lexicon.rs 读取）：
    拼音<TAB>词<TAB>频次
拼音用空格分隔音节。

会顺着 import_tables 递归合并被引用的词库——rime-ice 的主词库本身几乎不含词条，
条目都在 rime_ice.base / rime_ice.8105 等被引用的文件里，不处理 import 会漏掉大部分。
"""

import argparse
import os
import sys
import unicodedata

# 导出：被多个文件引用的词条只保留最大权重
Entry = dict


def normalize_syllable(s: str) -> str:
    """小写、去声调、ü 写成 v。

    万象拼音（rime_wanxiang）的拼音带声调（ā bà、lǜ），雾凇不带，同一套处理两边都适用：
    NFD 分解后 ü 是 u + 分音符（U+0308），声调是其余的组合符号。
    """
    s = s.strip().lower().replace("u:", "v")
    out = []
    for ch in unicodedata.normalize("NFD", s):
        if ch == "\u0308":
            if out and out[-1] == "u":
                out[-1] = "v"
            continue
        if unicodedata.combining(ch):
            continue
        out.append(ch)
    return "".join(out)


def normalize_code(code: str) -> str:
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


def parse_header(lines):
    """返回 (columns, imports, 条目起始行)。"""
    col = {"text": 0, "code": 1, "weight": 2}
    imports = []
    i = 0
    in_imports = False
    while i < len(lines):
        raw = lines[i].rstrip("\n")
        stripped = raw.strip()
        if stripped == "...":
            return col, imports, i + 1
        if raw.startswith("columns:"):
            order = []
            i += 1
            while i < len(lines) and lines[i].lstrip().startswith("- "):
                order.append(lines[i].strip()[2:].strip())
                i += 1
            if order:
                col = {name: idx for idx, name in enumerate(order)}
            continue
        if raw.startswith("import_tables:"):
            in_imports = True
            i += 1
            continue
        if in_imports:
            # 空行和注释行不结束 import 块（rime-ice 里就有注释掉的条目）
            if not stripped or stripped.startswith("#"):
                i += 1
                continue
            if stripped.startswith("- "):
                # 真实词库里 import 行常常带行内注释：- cn_dicts/8105     # 字表
                name = stripped[2:].split("#", 1)[0].strip()
                if name:
                    imports.append(name)
                i += 1
                continue
            in_imports = False
        i += 1
    return col, imports, 0


def resolve_import(name: str, base_dir: str) -> str:
    if not name.endswith(".yaml") and not name.endswith(".yml"):
        name += ".dict.yaml"
    return os.path.join(base_dir, name)


def load_entries(path, seen, use_imports=True, skip=()):
    """递归加载一个 .dict.yaml，返回 {(code, text): weight}。

    skip：不合并的被引用词库（import_tables 里写的名字，如 dicts/cuoyin）。"""
    abs_path = os.path.abspath(path)
    if abs_path in seen:
        print("跳过循环引用: %s" % abs_path, file=sys.stderr)
        return {}
    seen.add(abs_path)

    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as exc:
        print("读取失败 %s: %s" % (path, exc), file=sys.stderr)
        return {}

    col, imports, body_start = parse_header(lines)
    merged = Entry()
    base_dir = os.path.dirname(abs_path)

    if use_imports:
        for name in imports:
            if name in skip:
                print("跳过被引用词库: %s" % name, file=sys.stderr)
                continue
            imported = resolve_import(name, base_dir)
            if not os.path.exists(imported):
                print("找不到被引用词库: %s" % imported, file=sys.stderr)
                continue
            for key, weight in load_entries(imported, seen, use_imports, skip).items():
                if key not in merged or weight > merged[key]:
                    merged[key] = weight

    ti = col.get("text", 0)
    ci = col.get("code", 1)
    wi = col.get("weight", 2)
    for line in lines[body_start:]:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) <= max(ti, ci):
            continue
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
        key = (code, text)
        if key not in merged or weight > merged[key]:
            merged[key] = weight
    return merged


def convert(path, min_weight, out, use_imports=True, skip=(), scale_total=0.0):
    entries = load_entries(path, set(), use_imports, skip)
    items = [
        (key, weight)
        for key, weight in entries.items()
        if weight >= min_weight
    ]
    if scale_total > 0:
        # 核心里有几个按绝对词频定的值（自定义词 500 万、热词 3 万、精确匹配保护 1000），
        # 是照雾凇的词频定的；别的词库先整体缩放到同样的总词频，这些值才是一个意思
        total = sum(weight for _key, weight in items)
        if total > 0:
            factor = scale_total / total
            items = [(key, max(1.0, weight * factor)) for key, weight in items]
            print("词频整体乘 %.4f（总词频 %.0f -> %.0f）" % (factor, total, scale_total),
                  file=sys.stderr)
    items.sort(key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))

    out.write("# 由 tools/rime2tsv.py 生成，来源：%s\n" % path)
    out.write("# 拼音<TAB>词<TAB>频次\n")
    for (code, text), weight in items:
        out.write("%s\t%s\t%d\n" % (code, text, int(round(weight))))

    print(
        "合并 %d 条（import=%s）" % (len(items), "on" if use_imports else "off"),
        file=sys.stderr,
    )


SAMPLE_BASE = """---
name: sample_base
columns:
  - text
  - code
  - weight
...
的\tde\t120000
是\tshi\t70000
"""

SAMPLE_TONED = """---
name: sample_toned
...
绿色\tlǜ sè\t500\t注释列不管
女儿\tnǚ ér\t200
略\tlüè\t100
"""

SAMPLE_SKIPPED = """---
name: sample_skipped
...
秘鲁\tmì lǔ\t100\t秘(bì)鲁
"""

SAMPLE_MAIN = """---
name: sample
import_tables:
  - sample_base
  - sample_toned
  - sample_skipped
columns:
  - text
  - code
  - weight
...
你好\tni hao\t100000
西安\txi an\t3000
"""


def selftest():
    import io
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        for name, text in (("sample_base", SAMPLE_BASE), ("sample_toned", SAMPLE_TONED),
                           ("sample_skipped", SAMPLE_SKIPPED)):
            with open(os.path.join(tmp, name + ".dict.yaml"), "w", encoding="utf-8") as f:
                f.write(text)
        main = os.path.join(tmp, "sample.dict.yaml")
        with open(main, "w", encoding="utf-8") as f:
            f.write(SAMPLE_MAIN)

        buf = io.StringIO()
        convert(main, 0, buf)
        lines = [l for l in buf.getvalue().splitlines() if not l.startswith("#")]
        assert "de\t的\t120000" in lines, lines
        assert "ni hao\t你好\t100000" in lines, lines
        assert "xi an\t西安\t3000" in lines, lines
        # 万象的拼音带声调：去掉声调，ü 写成 v
        assert "lv se\t绿色\t500" in lines, lines
        assert "nv er\t女儿\t200" in lines, lines
        assert "lve\t略\t100" in lines, lines
        assert "mi lu\t秘鲁\t100" in lines, lines

        buf = io.StringIO()
        convert(main, 0, buf, skip=("sample_skipped",), scale_total=2 * 293800)
        scaled = [l for l in buf.getvalue().splitlines() if not l.startswith("#")]
        assert not any("秘鲁" in l for l in scaled), scaled
        assert "de\t的\t240000" in scaled, scaled
        assert "ni hao\t你好\t200000" in scaled, scaled
        print("selftest ok: %d 条（含 import、带声调、跳过、缩放）" % len(lines))


def main():
    ap = argparse.ArgumentParser(description="Rime 词库转 WowType TSV")
    ap.add_argument("path", nargs="?", help="rime .dict.yaml")
    ap.add_argument("--min-weight", type=float, default=0.0)
    ap.add_argument("--no-import", action="store_true", help="不处理 import_tables")
    ap.add_argument("--skip-import", action="append", default=[], metavar="NAME",
                    help="不合并这个被引用词库（import_tables 里的名字），可以写多次")
    ap.add_argument("--scale-total", type=float, default=0.0, metavar="N",
                    help="把词频整体缩放到总和为 N（0 不缩放）")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return
    if not args.path:
        ap.error("需要 rime .dict.yaml 路径")
    convert(args.path, args.min_weight, sys.stdout, not args.no_import,
            tuple(args.skip_import), args.scale_total)


if __name__ == "__main__":
    main()
