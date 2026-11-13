#!/usr/bin/env python3
"""解析微信输入法的 VAD（语音端点检测）资源目录 Resources/vad/ 的结构。

    python3 tools/wetype-assets/vad.py [vad 目录] [--json]

目录里三份文件：
- configure.16k.*.offline：文本配置（帧长、起止确认时长、静音超时、阈值）——这些是行为参数，照样打印；
- CMS_*.bin：fbank 特征的 CMS 参数——只报维度和大小，不输出数值；
- model_16k_*.bin：帧分类 DNN——只报头部 5 个 u32 和 float 个数，拿几种层结构去比对数量，不读权重。
"""

import argparse
import os
import sys

from _common import VAD_DIR, FormatError, need_dir, print_json, read_bytes, run, unpack

CONFIG_KEYS = (
    "output_data_ms", "sample_rate", "begin_win_ms", "begin_confirm_ms",
    "begin_padding_ms", "end_padding_ms", "sil_timeout",
    "frame_classifier.type", "frame_classifier.feature.name",
    "frame_classifier.net_input_win", "frame_classifier.frame_mtm",
    "frame_classifier.sil_thresh",
)


def parse_config(path):
    """INI 风格：[section] 下 key = value。"""
    sections, current = {}, None
    text = read_bytes(path).decode("utf-8", "replace")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = sections.setdefault(line[1:-1], {})
        elif current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip()
    return sections


def parse_cms(path):
    data = read_bytes(path)
    dim = unpack("<I", data, 0, "CMS 维度")[0]
    if not 0 < dim <= 1024:
        raise FormatError(f"{path}：CMS 维度 {dim} 不像真的")
    unpack(f"<{dim}f", data, 4, "CMS 数值")  # 只检查长度够不够
    return {"size": len(data), "dim": dim, "rest_bytes": len(data) - 4 - 4 * dim}


def parse_model(path):
    data = read_bytes(path)
    header = list(unpack("<5I", data, 0, "模型头"))
    floats = (len(data) - 20) // 4
    inp, hidden = header[3], header[4]
    shapes = {
        "4 层": [inp, hidden, hidden, hidden, 1],
        "3 层": [inp, hidden, hidden, 1],
    }
    candidates = []
    for name, shape in shapes.items():
        count = sum(a * b + b for a, b in zip(shape, shape[1:]))  # 权重 + 偏置
        candidates.append({"name": name, "shape": shape, "floats": count, "match": count == floats})
    return {"size": len(data), "header": header, "floats_after_header": floats, "candidates": candidates}


def main():
    ap = argparse.ArgumentParser(description="解析 VAD 资源的结构")
    ap.add_argument("dir", nargs="?", default=VAD_DIR)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    need_dir(args.dir)

    report = {"config": None, "cms": None, "model": None, "files": []}
    for name in sorted(os.listdir(args.dir)):
        path = os.path.join(args.dir, name)
        if not os.path.isfile(path):
            continue
        if name.startswith("configure"):
            report["config"] = parse_config(path)
        elif name.startswith("CMS"):
            report["cms"] = parse_cms(path)
        elif name.startswith("model"):
            report["model"] = parse_model(path)
        else:
            continue
        report["files"].append(name)
    if not report["files"]:
        sys.exit(f"{args.dir} 里没有 configure*/CMS*/model* 文件：目录不对或版本变了")

    if args.json:
        print_json(report)
        return
    print("文件：", "、".join(report["files"]))
    if report["config"]:
        section = report["config"].get("wx_asr_vad") or next(iter(report["config"].values()), {})
        print("配置：")
        for key in CONFIG_KEYS:
            if key in section:
                print(f"  {key:<36}{section[key]}")
    if report["cms"]:
        c = report["cms"]
        print(f"CMS：{c['dim']} 维，{c['size']} 字节（维度之后还剩 {c['rest_bytes']} 字节未解）")
    if report["model"]:
        m = report["model"]
        print(f"模型：{m['size']:,} 字节，头 {m['header']}，头后 {m['floats_after_header']:,} 个 float")
        for c in m["candidates"]:
            mark = "  <== 数量吻合" if c["match"] else ""
            print(f"  {c['name']} {c['shape']}：{c['floats']:,} 个 float{mark}")
        if not any(c["match"] for c in m["candidates"]):
            print("  （没有完全吻合的层结构，文件里还有别的段）")


if __name__ == "__main__":
    run(main)
