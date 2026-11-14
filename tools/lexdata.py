"""lexicon.tsv 的读写和几条共用规则，给 tools/blend-freq.py（语料词频融合）用。

几条规则（改之前先看 core/src/lexicon.rs）：

- 「#」开头的行（表头）和没改动的行原样写回，词库只在真改了的行上变。
- 频次小于 1 的单字是大字表补的生僻读音（LexEntry::is_rare），不参与组句；
  它们的频次一律不动，改出来的频次也不会低于 1（否则常用词会掉进生僻字的长尾）。
- 多音节词里占比最大的那个频次是「占位频次」（雾凇的 ext / tencent 词表都是 100），
  引擎加载时按组成部分重新估（estimate_placeholder_freqs）。融合时不碰这些行，
  也不拿它们算换算系数：改成别的数它们就不再被估了。
"""

import sys
from collections import Counter

# 和 core/src/lexicon.rs 的 PLACEHOLDER_MIN_WORDS 一致
PLACEHOLDER_MIN_WORDS = 1000


def parse_freq(text):
    try:
        return float(text)
    except ValueError:
        return None


def format_freq(value):
    """改过的频次：取整，但不低于 1（低于 1 的单字会被当成生僻字）。"""
    return str(max(1, int(round(value))))


class Lexicon:
    """按行读进 lexicon.tsv，记住每行原文；只有 set_freq 过的行写回时才重新格式化。"""

    def __init__(self, path):
        self.lines = []
        self.rows = []  # [行号, 拼音, 词, 频次]
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                self.lines.append(line)
                if not line or line.startswith("#"):
                    continue
                cols = line.split("\t")
                if len(cols) != 3:
                    continue
                freq = parse_freq(cols[2])
                if freq is None:
                    continue
                self.rows.append([len(self.lines) - 1, cols[0], cols[1], freq])
        self.changed = set()

    def readings_by_word(self):
        """词 -> 这个词的所有行（多音词有几行）。"""
        out = {}
        for row in self.rows:
            out.setdefault(row[2], []).append(row)
        return out

    def placeholder(self):
        """占位频次：多音节词里最常见的频次，规则同 estimate_placeholder_freqs；没有就是 None。"""
        hist = Counter()
        multi = 0
        for _, pinyin, _, freq in self.rows:
            if len(pinyin.split()) >= 2:
                multi += 1
                hist[freq] += 1
        if not hist:
            return None
        value, count = hist.most_common(1)[0]
        if count < PLACEHOLDER_MIN_WORDS or count * 4 < multi:
            return None
        return value

    def set_freq(self, row, value):
        row[3] = value
        self.changed.add(row[0])

    def write(self, path):
        changed = {row[0]: row for row in self.rows if row[0] in self.changed}
        with open(path, "w", encoding="utf-8") as out:
            for i, line in enumerate(self.lines):
                row = changed.get(i)
                if row is None:
                    out.write(line + "\n")
                else:
                    out.write(f"{row[1]}\t{row[2]}\t{format_freq(row[3])}\n")


def load_counts(path):
    """词<TAB>次数（# 开头是注释）。同一个词出现几次取第一次。"""
    counts = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) < 2:
                continue
            value = parse_freq(cols[1])
            if value is None or value <= 0 or cols[0] in counts:
                continue
            counts[cols[0]] = value
    return counts


def blendable(rows, placeholder):
    """一个词里能融合的行；整个词都不该碰时返回空表。

    生僻读音（频次小于 1）不碰，其余读音照常融合；有一行是占位频次就整个词不碰
    （多音词一半估、一半融合，两边尺度对不上）。
    """
    if placeholder is not None and any(r[3] == placeholder for r in rows):
        return []
    return [r for r in rows if r[3] >= 1]


def shared_scale(lex, counts, placeholder):
    """换算系数：两边都有的词上，词库频次总和 / 外部计数总和。

    一个词按词算一次（多音词的几行加起来），不按行算——按行算多音词的计数会被重复加。
    """
    base_total = 0.0
    extra_total = 0.0
    for word, rows in lex.readings_by_word().items():
        count = counts.get(word)
        if count is None:
            continue
        rows = blendable(rows, placeholder)
        if not rows:
            continue
        base_total += sum(r[3] for r in rows)
        extra_total += count
    return base_total / extra_total if extra_total > 0 else 0.0


def log(msg):
    print(msg, file=sys.stderr)
