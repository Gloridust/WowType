#!/usr/bin/env python3
"""解析微信输入法的 VAD 资源（Resources/vad/）。

    python3 tools/wetype-assets/vad.py "/Library/Input Methods/WeType.app/Contents/Resources/vad"

里面有三份文件：

- configure.16k.*.offline：文本配置（帧长、确认时长、静音超时、阈值）
- CMS_40dim_chi.bin：40 维 fbank 的 CMS 参数
- model_16k_*.bin：帧分类 DNN
"""

import argparse
import json
import os
import struct
import sys


def parse_config(path):
    sections = {}
    current = None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections[current] = {}
            continue
        if current is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        sections[current][key.strip()] = value.strip()
    return sections


def parse_cms(path):
    data = open(path, "rb").read()
    dim = struct.unpack_from("<I", data, 0)[0]
    values = struct.unpack_from("<%df" % dim, data, 4)
    return {"dim": dim, "size": len(data), "values": [round(v, 4) for v in values], "rest": len(data) - 4 - 4 * dim}


def parse_model(path):
    data = open(path, "rb").read()
    header = list(struct.unpack_from("<5I", data, 0))
    floats = (len(data) - 20) // 4
    candidates = []
    input_dim, hidden = header[3], header[4]
    # 4 层：input->hidden, hidden->hidden ×2, hidden->1
    plan = [input_dim * hidden + hidden, hidden * hidden + hidden, hidden * hidden + hidden, hidden + 1]
    candidates.append({"shape": [input_dim, hidden, hidden, hidden, 1], "floats": sum(plan)})
    # 3 层
    plan3 = [input_dim * hidden + hidden, hidden * hidden + hidden, hidden + 1]
    candidates.append({"shape": [input_dim, hidden, hidden, 1], "floats": sum(plan3)})
    return {
        "size": len(data),
        "header": header,
        "floats_after_header": floats,
        "candidates": candidates,
        "candidate_hits": [c for c in candidates if c["floats"] == floats],
    }


def main():
    ap = argparse.ArgumentParser(description="解析 VAD 资源")
    ap.add_argument("dir")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if not os.path.isdir(args.dir):
        sys.exit(f"不是目录：{args.dir}")

    report = {"config": None, "cms": None, "model": None}
    for name in sorted(os.listdir(args.dir)):
        path = os.path.join(args.dir, name)
        if name.startswith("configure"):
            report["config"] = parse_config(path)
        elif name.startswith("CMS"):
            report["cms"] = parse_cms(path)
        elif name.startswith("model"):
            report["model"] = parse_model(path)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    if report["config"]:
        section = report["config"].get("wx_asr_vad") or next(iter(report["config"].values()))
        print("配置：")
        for key in ("output_data_ms", "sample_rate", "begin_win_ms", "begin_confirm_ms",
                    "begin_padding_ms", "end_padding_ms", "sil_timeout"):
            if key in section:
                print(f"  {key:<20}{section[key]}")
        for key in ("frame_classifier.type", "frame_classifier.feature.name",
                    "frame_classifier.net_input_win", "frame_classifier.frame_mtm",
                    "frame_classifier.sil_thresh"):
            if key in section:
                print(f"  {key:<36}{section[key]}")

    if report["cms"]:
        cms = report["cms"]
        print(f"CMS：{cms['dim']} 维，{cms['size']} 字节（前几个 {cms['values'][:5]}，剩余 {cms['rest']} 字节）")

    if report["model"]:
        m = report["model"]
        print(f"模型：{m['size']} 字节，头 {m['header']}，头后 {m['floats_after_header']} 个 float")
        for c in m["candidates"]:
            mark = "  <== 数量吻合" if c in m["candidate_hits"] else ""
            print(f"  候选结构 {c['shape']}：{c['floats']} 个 float{mark}")
        if not m["candidate_hits"]:
            print("  （没有完全吻合的层结构，文件里还有别的段）")


if __name__ == "__main__":
    main()