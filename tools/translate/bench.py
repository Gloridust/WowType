#!/usr/bin/env python3
"""本地翻译模型的基准：载入时间、首个字、整句耗时、内存，以及空闲释放后的内存。

用法：
    tools/translate/bench.py --server llama-server --model ~/.local/share/wowtype/models/HY-MT1.5-1.8B-Q4_K_M.gguf
    [--sentences tools/translate/sentences.tsv] [--threads N]

和输入法用的是同一套启动参数与提示词（core/src/llama.rs、core/src/translate.rs）。
只用标准库；llama-server 只监听 127.0.0.1 的随机端口，跑完就停。
译文打印出来供人工检查（issue #53 的验收：每个方向 20 句里至少 17 句正确）。
"""

import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def rss_mb(pid):
    """进程常驻内存（MB）；llama-server 会 mmap 模型，所以同时报告匿名内存。"""
    rss = anon = 0
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1])
            elif line.startswith("RssAnon:"):
                anon = int(line.split()[1])
    return rss / 1024, anon / 1024


def health(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
            return r.status
    except Exception:
        return None


def prompt_for(direction, text):
    target = "英语" if direction == "zh" else "中文"
    return f"将以下文本翻译为{target}，注意只需要输出翻译后的结果，不要额外解释：\n\n{text}"


def translate(port, direction, text):
    body = json.dumps({
        "model": "hy-mt",
        "stream": True,
        "messages": [{"role": "user", "content": prompt_for(direction, text)}],
        "temperature": 0.7, "top_k": 20, "top_p": 0.6, "repeat_penalty": 1.05,
        "max_tokens": 64 + len(text) * 4,
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    start = time.monotonic()
    first = None
    out = []
    with urllib.request.urlopen(req, timeout=120) as r:
        for raw in r:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            delta = json.loads(line[5:])["choices"][0]["delta"].get("content") or ""
            if delta and first is None:
                first = time.monotonic() - start
            out.append(delta)
    return "".join(out).strip(), first or 0.0, time.monotonic() - start


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--server", default="llama-server")
    ap.add_argument("--model", required=True)
    ap.add_argument("--sentences", default=os.path.join(HERE, "sentences.tsv"))
    ap.add_argument("--threads", type=int, default=0, help="传给 llama-server 的 -t（0 = 它自己定）")
    args = ap.parse_args()

    cases = []
    with open(args.sentences, encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                direction, text = line.rstrip("\n").split("\t", 1)
                cases.append((direction, text))

    port = free_port()
    cmd = [args.server, "-m", os.path.expanduser(args.model), "--host", "127.0.0.1",
           "--port", str(port), "-c", "2048", "-np", "1"]
    if args.threads:
        cmd += ["-t", str(args.threads)]
    start = time.monotonic()
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        while health(port) != 200:
            if proc.poll() is not None:
                sys.exit("llama-server 退出了：" + " ".join(cmd))
            if time.monotonic() - start > 120:
                sys.exit("载入超时")
            time.sleep(0.1)
        load = time.monotonic() - start
        print(f"载入：{load:.2f} s")

        firsts, totals, peak_rss, peak_anon = [], [], 0.0, 0.0
        for direction, text in cases:
            result, first, total = translate(port, direction, text)
            rss, anon = rss_mb(proc.pid)
            peak_rss, peak_anon = max(peak_rss, rss), max(peak_anon, anon)
            firsts.append(first)
            totals.append(total)
            print(f"[{direction}] {total:5.2f}s  {text}\n         → {result}")

        def stat(xs):
            xs = sorted(xs)
            return (f"均值 {statistics.mean(xs):.2f} s，中位 {statistics.median(xs):.2f} s，"
                    f"最慢 {xs[-1]:.2f} s")
        print(f"\n首个字：{stat(firsts)}")
        print(f"整句：{stat(totals)}")
        print(f"内存：常驻最高 {peak_rss:.0f} MB（其中匿名 {peak_anon:.0f} MB，其余是 mmap 的模型文件）")
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    print(f"停掉以后：进程{'已退出' if proc.poll() is not None else '还在'}，"
          f"端口 {port} {'已释放' if health(port) is None else '还在监听'}")


if __name__ == "__main__":
    main()
