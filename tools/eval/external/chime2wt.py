#!/usr/bin/env python3
"""把 chime（https://github.com/tyrchen/chime，MIT OR Apache-2.0）的 benchmarks/*.tsv 转成 wowtype-eval 的用例格式，
按 category 拆成一组一个文件：

    python3 tools/eval/external/chime2wt.py <chime>/benchmarks/test_holdout.tsv tools/eval/external/chime-holdout

chime 的列：category、scheme、app、left_ctx、keys、expected。转出来是「输入<TAB>期望<TAB>上文[<TAB>sp=方案]」，
双拼用例的组名后面带上方案。只用标准库。
"""
import collections
import os
import sys

HEADER = (
    "# 外部盲测集：从 chime 的 benchmarks/{name} 转来（https://github.com/tyrchen/chime，{commit}），分类 {group}。\n"
    "# Copyright (c) 2026 Tian Chen，MIT OR Apache-2.0。只用来量，不拿它调参、不照着它加词，见 tools/eval/external/README.md。\n"
)


def main() -> None:
    src, outdir = sys.argv[1], sys.argv[2]
    commit = sys.argv[3] if len(sys.argv) > 3 else "提交未记"
    os.makedirs(outdir, exist_ok=True)
    groups: dict[str, list[str]] = collections.defaultdict(list)
    for line in open(src, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#") or line.startswith("category\t"):
            continue
        cols = line.split("\t")
        if len(cols) < 6:
            continue
        cat, scheme, _app, ctx, keys, expected = cols[:6]
        if scheme == "full":
            groups[cat].append(f"{keys}\t{expected}\t{ctx}".rstrip("\t"))
        else:
            groups[f"{cat}_{scheme}"].append(f"{keys}\t{expected}\t{ctx}\tsp={scheme}")
    for group, rows in sorted(groups.items()):
        with open(os.path.join(outdir, group + ".tsv"), "w", encoding="utf-8") as f:
            f.write(HEADER.format(name=os.path.basename(src), commit=commit, group=group))
            f.write("\n".join(rows) + "\n")
    print(f"{sum(len(r) for r in groups.values())} 条，{len(groups)} 组 -> {outdir}")


if __name__ == "__main__":
    main()
