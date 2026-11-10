#!/usr/bin/env python3
"""把 Rime 词库（.dict.yaml）转成 WowType 的 lexicon TSV。

用法：
    python3 tools/rime2tsv.py rime_ice.dict.yaml > lexicon.tsv
    python3 tools/rime2tsv.py --min-weight 0 rime_ice.dict.yaml > lexicon.tsv
    python3 tools/rime2tsv.py --extra-chars cn_dicts/41448.dict.yaml rime_ice.dict.yaml > lexicon.tsv

输出格式（core/src/lexicon.rs 读取）：
    拼音<TAB>词<TAB>频次
拼音用空格分隔音节。

会顺着 import_tables 递归合并被引用的词库——rime-ice 的主词库本身几乎不含词条，
条目都在 rime_ice.base / rime_ice.8105 等被引用的文件里，不处理 import 会漏掉大部分。

--extra-chars 补一张大字表（rime-ice 的 cn_dicts/41448，默认没引入）：只加词库里还没有的
单字读音，频次记 0.7~0.9（小于 1）：引擎不拿它们组句，只排在翻页的最后。输入法翻到最后时字要列全。
"""

import argparse
import os
import sys

# 导出：被多个文件引用的词条只保留最大权重
Entry = dict


def normalize_syllable(s: str) -> str:
    s = s.strip().lower()
    return s.replace("\u00fc", "v").replace("u:", "v")


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


def load_entries(path, seen, use_imports=True):
    """递归加载一个 .dict.yaml，返回 {(code, text): weight}。"""
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
            imported = resolve_import(name, base_dir)
            if not os.path.exists(imported):
                print("找不到被引用词库: %s" % imported, file=sys.stderr)
                continue
            for key, weight in load_entries(imported, seen, use_imports).items():
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


def rare_char_freq(text):
    """大字表补进来的字的频次：都小于 1（引擎据此把它们只放在翻页的长尾，不参与组句），
    常用字区（基本区、兼容区）0.9 > 扩展 A 区 0.8 > 其余（扩展 B 区以后，很多字体显示不了）0.7。"""
    cp = ord(text)
    if 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF:
        return 0.9
    if 0x3400 <= cp <= 0x4DBF:
        return 0.8
    return 0.7


def add_extra_chars(entries, path):
    """把大字表里还没有的单字读音补进 entries（频次见 rare_char_freq），返回补了几条。"""
    added = 0
    for (code, text), _ in load_entries(path, set(), False).items():
        if len(text) != 1 or " " in code:
            continue
        key = (code, text)
        if key not in entries:
            entries[key] = rare_char_freq(text)
            added += 1
    return added


def convert(path, min_weight, out, use_imports=True, extra_chars=()):
    entries = load_entries(path, set(), use_imports)
    for extra in extra_chars:
        added = add_extra_chars(entries, extra)
        print("大字表 %s：补 %d 个单字读音" % (extra, added), file=sys.stderr)
    items = [
        (key, weight)
        for key, weight in entries.items()
        if weight >= min_weight
    ]
    items.sort(key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))

    out.write("# 由 tools/rime2tsv.py 生成，来源：%s\n" % path)
    out.write("# 拼音<TAB>词<TAB>频次\n")
    for (code, text), weight in items:
        if weight < 1:
            out.write("%s\t%s\t%.1f\n" % (code, text, weight))
        else:
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

SAMPLE_MAIN = """---
name: sample
import_tables:
  - sample_base
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
        with open(os.path.join(tmp, "sample_base.dict.yaml"), "w", encoding="utf-8") as f:
            f.write(SAMPLE_BASE)
        main = os.path.join(tmp, "sample.dict.yaml")
        with open(main, "w", encoding="utf-8") as f:
            f.write(SAMPLE_MAIN)

        buf = io.StringIO()
        convert(main, 0, buf)
        lines = [l for l in buf.getvalue().splitlines() if not l.startswith("#")]
        assert "de\t的\t120000" in lines, lines
        assert "ni hao\t你好\t100000" in lines, lines
        assert "xi an\t西安\t3000" in lines, lines

        big = os.path.join(tmp, "big.dict.yaml")
        with open(big, "w", encoding="utf-8") as f:
            f.write("---\nname: big\n...\n的\tde\n是\tshi\n㕈\thou\n後\thou\n𠯜\thou\n你好\tni hao\n")
        buf = io.StringIO()
        convert(main, 0, buf, extra_chars=[big])
        lines2 = [l for l in buf.getvalue().splitlines() if not l.startswith("#")]
        assert "de\t的\t120000" in lines2, "已有的字不改频次"
        assert "hou\t㕈\t0.8" in lines2, lines2
        assert "hou\t後\t0.9" in lines2, lines2
        assert "hou\t𠯜\t0.7" in lines2, lines2
        assert len(lines2) == len(lines) + 3, "只补缺的单字"
        print("selftest ok: %d 条（含 import）" % len(lines))


def main():
    ap = argparse.ArgumentParser(description="Rime 词库转 WowType TSV")
    ap.add_argument("path", nargs="?", help="rime .dict.yaml")
    ap.add_argument("--min-weight", type=float, default=0.0)
    ap.add_argument("--no-import", action="store_true", help="不处理 import_tables")
    ap.add_argument(
        "--extra-chars",
        action="append",
        default=[],
        help="补一张大字表（只加缺的单字读音，频次小于 1），可以给多次",
    )
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return
    if not args.path:
        ap.error("需要 rime .dict.yaml 路径")
    convert(args.path, args.min_weight, sys.stdout, not args.no_import, args.extra_chars)


if __name__ == "__main__":
    main()
