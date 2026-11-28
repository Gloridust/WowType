#!/usr/bin/env python3
"""看开发者模式的打字记录（docs/DEVLOG.md），或者把它转成排序评测的用例。

    tools/devlog.py summary [devlog.jsonl ...]     汇总：首选命中率、选的位置分布、放弃和退格
    tools/devlog.py misses  [devlog.jsonl ...]     没选第一个的（还有上屏后马上退格的），按次数排
    tools/devlog.py eval    [devlog.jsonl ...]     转成 wowtype-eval 的用例（输入、期望、上文），写到标准输出

不给文件时读 Linux 上输入法写的那份：~/.local/share/wowtype/devlog.jsonl（旧的 devlog.jsonl.1 在前）；
macOS、Windows 上把设置里「导出…」存的文件名写在后面。记录是明文的打字内容，转出来的用例也是，别提交进仓库。

只用标准库。
"""

import collections
import json
import os
import sys


def default_files():
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    path = os.path.join(base, "wowtype", "devlog.jsonl")
    return [name for name in (path + ".1", path) if os.path.isfile(name)]


def read(files):
    """按顺序读出每一行；坏行跳过。"""
    events = []
    for name in files:
        with open(name, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if isinstance(event, dict) and "e" in event:
                    events.append(event)
    return events


def commits(events):
    """每次上屏，连同「上屏后是不是马上退格了」（下一条是同一段字的 backspace）。"""
    out = []
    for at, event in enumerate(events):
        if event["e"] != "commit":
            continue
        after = events[at + 1] if at + 1 < len(events) else {}
        undone = after.get("e") == "backspace" and after.get("text") == event.get("text")
        out.append((event, undone))
    return out


def pinyin_steps(event):
    """这次上屏是不是全靠选引擎的词拼出来的（没有原样上屏、表情、联想、以词定字）。"""
    steps = event.get("steps") or []
    return bool(steps) and all(step.get("kind") == "word" and "char" not in step for step in steps)


def first_try(event):
    """一步、选的就是第一个：首选命中。"""
    steps = event.get("steps") or []
    return len(steps) == 1 and steps[0].get("pick") == 1


def summary(events):
    done = commits(events)
    typed = [(event, undone) for event, undone in done if pinyin_steps(event)]
    lines = []
    add = lines.append
    add(f"记录 {len(events)} 条：上屏 {len(done)}，放弃 {sum(e['e'] == 'abandon' for e in events)}，"
        f"上屏后马上退格 {sum(e['e'] == 'backspace' for e in events)}")
    if not typed:
        add("没有选词上屏的记录")
        return "\n".join(lines)
    total = len(typed)
    hit = sum(first_try(event) for event, _ in typed)
    add(f"选词上屏 {total} 次：一步选第一个 {hit} 次（{hit / total:.1%}），"
        f"分几步选的 {sum(len(e['steps']) > 1 for e, _ in typed)} 次，"
        f"上屏后马上退格 {sum(undone for _, undone in typed)} 次")
    positions = collections.Counter()
    for event, _ in typed:
        for step in event["steps"]:
            pick = step.get("pick", 0)
            positions["10+" if pick >= 10 else str(pick)] += 1
    steps = sum(positions.values())
    add("每一步选的位置：" + "  ".join(
        f"第{key}个 {positions[key]}（{positions[key] / steps:.0%}）"
        for key in [*map(str, range(1, 10)), "10+"] if positions[key]))
    how = collections.Counter(step.get("via", "?") for event, _ in typed for step in event["steps"])
    add("怎么选的：" + "  ".join(f"{via} {count}" for via, count in how.most_common(8)))
    raw = sum(1 for event, _ in done if any(step.get("kind") == "raw" for step in event.get("steps") or []))
    add(f"原样上屏输入（回车、切走）{raw} 次")
    apps = collections.Counter(event.get("app", "") or "（不知道）" for event, _ in done)
    add("应用：" + "  ".join(f"{app} {count}" for app, count in apps.most_common(8)))
    return "\n".join(lines)


def misses(events):
    """没选第一个的每一步：那时的输入、选的、它排第几、当时的第一个。上屏后马上退格的另列。"""
    counts = collections.Counter()
    for event, _ in commits(events):
        if not pinyin_steps(event):
            continue
        for step in event["steps"]:
            if step.get("pick", 0) > 1:
                top = (step.get("cands") or [{}])[0].get("t", "")
                counts[(step.get("rest", ""), step.get("text", ""), step["pick"], top)] += 1
    lines = ["# 次数\t输入\t选的\t排第几\t当时的第一个"]
    for (rest, text, pick, top), count in counts.most_common():
        lines.append(f"{count}\t{rest}\t{text}\t{pick}\t{top}")
    undone = collections.Counter(
        (event.get("input", ""), event.get("text", "")) for event, gone in commits(events) if gone)
    if undone:
        lines.append("# 上屏后马上退格的：次数\t输入\t上屏的字")
        for (typed, text), count in undone.most_common():
            lines.append(f"{count}\t{typed}\t{text}")
    return "\n".join(lines)


def eval_cases(events):
    """转成 wowtype-eval 的用例：`输入<TAB>期望<TAB>上文[<TAB>属性]`。

    只收全靠选引擎的词拼出来、上屏后没有马上退格的；期望是整段上屏的字（分几步选的也是整句）。
    繁体、五笔、互译里打的不收。同一条（输入、期望、上文）只留一次。
    """
    seen = set()
    lines = ["# 从开发者模式的打字记录转的（tools/devlog.py eval）。输入\t期望\t上文\t属性"]
    for event, undone in commits(events):
        scheme = event.get("scheme", "")
        if undone or not pinyin_steps(event) or event.get("mode") != "zh":
            continue
        if (event.get("cfg") or {}).get("traditional"):
            continue
        if scheme == "pinyin":
            attrs = ""
        elif scheme.startswith("shuangpin:"):
            attrs = "sp=" + scheme.split(":", 1)[1]
        else:
            continue
        typed, text, context = event.get("input", ""), event.get("text", ""), event.get("context", "")
        if not typed or not text or any(c in typed + text + context for c in "\t\n\r") or typed.startswith("#"):
            continue
        key = (typed, text, context, attrs)
        if key in seen:
            continue
        seen.add(key)
        lines.append("\t".join([typed, text, context, attrs]).rstrip("\t"))
    return "\n".join(lines)


def self_test():
    step = lambda pick, rest, text, kind="word", **more: {  # noqa: E731
        "via": "space", "pick": pick, "rest": rest, "text": text, "kind": kind,
        "cands": [{"t": "你好"}, {"t": "拟好"}], **more}
    commit = lambda typed, text, steps, **more: {  # noqa: E731
        "e": "commit", "mode": "zh", "scheme": "pinyin", "input": typed, "text": text, "context": "",
        "steps": steps, **more}
    events = [
        commit("nihao", "你好", [step(1, "nihao", "你好")], app="kitty"),
        commit("nihao", "拟好", [step(2, "nihao", "拟好")], context="我"),
        commit("nihao", "拟好", [step(2, "nihao", "拟好")], context="我"),
        commit("shijie", "视界", [step(3, "shijie", "视界")]),
        {"e": "backspace", "text": "视界"},
        commit("nihaoshijie", "你好世界", [step(1, "nihaoshijie", "你好"), step(1, "shijie", "世界")]),
        commit("sudo", "sudo", [step(0, "sudo", "sudo", kind="raw")]),
        commit("uijx", "世界", [step(1, "uijx", "世界")], scheme="shuangpin:xiaohe"),
        commit("ggtt", "五笔", [step(1, "ggtt", "五笔")], scheme="wubi"),
        commit("fanti", "繁體", [step(1, "fanti", "繁體")], cfg={"traditional": True}),
        commit("nihao", "你", [step(1, "nihao", "你好", char="first")]),
        {"e": "abandon", "input": "nih", "keys": "nih<esc>"},
    ]
    text = summary(events)
    assert "上屏 10，放弃 1，上屏后马上退格 1" in text, text
    # 选词上屏的 8 次（原样上屏、以词定字的不算），一步选第一个的 4 次
    assert "选词上屏 8 次：一步选第一个 4 次（50.0%），分几步选的 1 次，上屏后马上退格 1 次" in text, text
    assert "第1个 6" in text and "第2个 2" in text and "第3个 1" in text, text
    assert "原样上屏输入（回车、切走）1 次" in text and "kitty 1" in text, text
    rows = misses(events).splitlines()
    assert rows[1] == "2\tnihao\t拟好\t2\t你好", rows
    assert rows[-1] == "1\tshijie\t视界", rows
    cases = eval_cases(events).splitlines()[1:]
    assert cases == ["nihao\t你好", "nihao\t拟好\t我", "nihaoshijie\t你好世界", "uijx\t世界\t\tsp=xiaohe"], cases
    assert summary([]).startswith("记录 0 条")
    print("devlog self-test ok")


def main(argv):
    if len(argv) >= 2 and argv[1] == "--self-test":
        self_test()
        return 0
    if len(argv) < 2 or argv[1] not in ("summary", "misses", "eval"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    files = argv[2:] or default_files()
    if not files:
        print("没有记录文件：在设置里打开开发者模式打一会儿字，或者把导出的文件名写在后面", file=sys.stderr)
        return 1
    events = read(files)
    print({"summary": summary, "misses": misses, "eval": eval_cases}[argv[1]](events))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
