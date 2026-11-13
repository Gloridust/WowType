#!/usr/bin/env python3
"""解析微信输入法的大模型容器（XLLM，如 decgnr.bin）的结构。

    python3 tools/wetype-assets/dump_xllm.py [decgnr.bin] [--json]
    python3 tools/wetype-assets/dump_xllm.py decgnr.bin --tokens ~/wetype-dump/decgnr_vocab.tsv

容器依次是：头（magic `XLLM`、版本、+0x20 处 u64 配置长度）、配置 JSON、分词器 JSON、
张量蓝图表（protobuf 风格：0a 名字、12 形状、20 dtype）、权重区。
默认只打印结构：配置（层数、维度等超参数）、分词器大小与词表条数、张量名和形状；不读权重。

--tokens 会把分词器词表写成 id<TAB>token，供本机研究；那是腾讯的数据，
脚本拒绝写进 WowType 仓库，也不要把它提交、打包或上传。
"""

import argparse
import json
import os
import sys

from _common import IME_DATA, FormatError, need, open_output, print_json, read_bytes, run, unpack, uvarint

MAX_JSON = 16 << 20  # 单个 JSON 最多扫这么远，防止在坏文件上扫到底
TOKENIZER_MARKER = b'{\n  "version"'


def parse_fields(buf):
    """读一段 protobuf 风格字段，返回 {字段号: [值]}；遇到 0 或未知的 wire type 就停。"""
    out = {}
    i = 0
    while i < len(buf) and buf[i] != 0:
        tag, i = uvarint(buf, i, "字段标签")
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, i = uvarint(buf, i, "字段值")
        elif wire == 2:
            length, i = uvarint(buf, i, "字段长度")
            need(buf, i, length, f"字段 {field}")
            value = bytes(buf[i:i + length])
            i += length
        elif wire == 5:
            value = unpack("<f", buf, i, f"字段 {field}")[0]
            i += 4
        elif wire == 1:
            need(buf, i, 8, f"字段 {field}")
            value = bytes(buf[i:i + 8])
            i += 8
        else:
            break
        out.setdefault(field, []).append(value)
    return out


def read_json_at(data, offset):
    """从 offset 读一个 JSON 对象（按括号配对找结尾），返回 (对象, 结束偏移)。"""
    need(data, offset, 1, "JSON 起点")
    if data[offset] != ord("{"):
        raise FormatError(f"0x{offset:x} 处不是 JSON 对象")
    depth, in_string, escaped = 0, False, False
    end = min(len(data), offset + MAX_JSON)
    for i in range(offset, end):
        c = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif c == 0x5C:  # \
                escaped = True
            elif c == 0x22:  # "
                in_string = False
        elif c == 0x22:
            in_string = True
        elif c == 0x7B:  # {
            depth += 1
        elif c == 0x7D:  # }
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(bytes(data[offset:i + 1]).decode("utf-8")), i + 1
                except ValueError as e:
                    raise FormatError(f"0x{offset:x} 处的 JSON 解析失败：{e}")
    raise FormatError(f"0x{offset:x} 处的 JSON 在 {MAX_JSON >> 20}MB 内没有闭合")


def parse_tensors(data):
    """张量蓝图表：从 tok_embeddings.weight 往前定位，记录是一串 1a<长度><0a 名字 12 形状 …>。"""
    pos = data.find(b"tok_embeddings.weight")
    if pos < 4:
        return [], 0
    i = pos - 4
    tensors = []
    while i < len(data) and data[i] == 0x1A:
        length, j = uvarint(data, i + 1, "蓝图记录长度")
        need(data, j, length, "蓝图记录")
        fields = parse_fields(data[j:j + length])
        if 1 not in fields or not isinstance(fields[1][0], bytes):
            raise FormatError(f"0x{i:x} 处的蓝图记录没有名字")
        dims, raw, k = [], fields.get(2, [b""])[0], 0
        while k < len(raw):
            value, k = uvarint(raw, k, "形状")
            dims.append(value)
        tensors.append({
            "name": fields[1][0].decode("utf-8", "replace"),
            "shape": dims,
            "dtype": fields.get(4, [None])[0],
        })
        i = j + length
    return tensors, i


def find_tokenizer(data, start):
    marker = data.find(TOKENIZER_MARKER, start)
    if marker < 0:
        marker = data.find(TOKENIZER_MARKER)
    if marker < 0:
        return None, 0, -1
    try:
        tokenizer, end = read_json_at(data, marker)
    except FormatError as e:
        print(f"分词器 JSON 读不出来：{e}", file=sys.stderr)
        return None, 0, marker
    return tokenizer, end - marker, marker


def main():
    ap = argparse.ArgumentParser(description="解析 XLLM 模型容器的结构")
    ap.add_argument("path", nargs="?", default=os.path.join(IME_DATA, "decgnr.bin"))
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--tokens", metavar="PATH", help="把词表写成 id<TAB>token（不能写进仓库）")
    args = ap.parse_args()

    data = read_bytes(args.path)
    need(data, 0, 0x29, "XLLM 头")
    if data[:4] != b"XLLM":
        raise FormatError(f"开头是 {data[:4]!r}，不是 XLLM 容器")
    version = unpack("<I", data, 4, "版本")[0]
    config_len = unpack("<Q", data, 0x20, "配置长度")[0]
    config, config_end = read_json_at(data, 0x28)
    tensors, table_end = parse_tensors(data)
    tokenizer, tokenizer_size, tokenizer_at = find_tokenizer(data, config_end)
    model = (tokenizer or {}).get("model") or {}
    vocab = model.get("vocab") if isinstance(model.get("vocab"), dict) else {}

    params = 0
    for t in tensors:
        n = 1
        for d in t["shape"]:
            n *= d
        params += n

    report = {
        "file": args.path,
        "size": len(data),
        "version": version,
        "config_bytes_header": config_len,
        "config_bytes_parsed": config_end - 0x28,
        "config": config,
        "tokenizer_offset": tokenizer_at,
        "tokenizer_bytes": tokenizer_size,
        "tokenizer_model": model.get("type"),
        "tokenizer_vocab": len(vocab) if tokenizer else None,
        "tensors": tensors,
        "tensor_table_end": table_end,
        "blueprint_params": params,
    }

    if args.tokens:
        if not vocab:
            sys.exit("没找到分词器词表，不写 --tokens")
        with open_output(args.tokens) as out:
            for token, index in sorted(vocab.items(), key=lambda kv: kv[1]):
                out.write(f"{index}\t{token}\n")
        print(f"词表已写出：{args.tokens}（{len(vocab)} 个 token；只供本机研究，不要提交或分发）", file=sys.stderr)

    if args.json:
        print_json(report)
        return
    print(f"文件：{args.path}（{len(data):,} 字节），XLLM 版本 {version}")
    print(f"配置：头里记 {config_len} 字节，实际 JSON {report['config_bytes_parsed']} 字节")
    print(f"  {json.dumps(config, ensure_ascii=False)}")
    if tokenizer:
        print(f"分词器：0x{tokenizer_at:x} 起 {tokenizer_size:,} 字节，模型 {report['tokenizer_model']}，词表 {len(vocab)} 条")
    else:
        print("分词器：没找到")
    print(f"张量蓝图 {len(tensors)} 条（合计 {params:,} 参数）：")
    for t in tensors:
        print(f"  {t['name']:<36} {str(t['shape']):<18} dtype={t['dtype']}")
    if tensors:
        print(f"蓝图表结束于 0x{table_end:x}；之后是权重区（布局未逐张量解码）")


if __name__ == "__main__":
    run(main)
