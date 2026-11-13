#!/usr/bin/env python3
"""解析微信输入法的大模型容器（XLLM）。

    python3 tools/wetype-assets/dump_xllm.py <decgnr.bin>

微信输入法的模型不在公开格式里：外层是 XLLM 容器，里面依次是
配置 JSON、分词器 JSON、张量蓝图表和权重区。这个脚本把前四部分读出来，
方便判断某个模型能不能自己推理；权重区的布局只做到"定位 + 尺寸"，还没逐张量解。

模型是腾讯的资产：脚本只读本机文件，不分发任何权重。
"""

import argparse
import json
import re
import struct
import sys


def uvarint(buf, i):
    value = 0
    shift = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, i
        shift += 7


def parse_fields(buf, i):
    """读取一段 protobuf 风格字段，返回 {字段号: [值]}。"""
    out = {}
    while i < len(buf):
        tag = buf[i]
        if tag == 0:
            break
        field, wire = tag >> 3, tag & 7
        i += 1
        if wire == 0:
            value, i = uvarint(buf, i)
        elif wire == 2:
            length, i = uvarint(buf, i)
            value = buf[i:i + length]
            i += length
        elif wire == 5:
            value = struct.unpack_from("<f", buf, i)[0]
            i += 4
        elif wire == 1:
            value = buf[i:i + 8]
            i += 8
        else:
            break
        out.setdefault(field, []).append(value)
    return out, i


def read_json_at(data, offset):
    """从 offset 读一个 JSON 对象，返回 (对象, 结束偏移)。"""
    depth = 0
    in_string = False
    escaped = False
    i = offset
    while i < len(data):
        c = chr(data[i])
        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
        else:
            if c == '"':
                in_string = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return json.loads(data[offset:i + 1].decode("utf-8")), i + 1
        i += 1
    raise ValueError("JSON 没有闭合")


def parse_tensors(data):
    """张量蓝图表：记录被包在 field 3 里，内容是 0a<名字> 12<形状> …"""
    pos = data.find(b"tok_embeddings.weight")
    if pos < 0:
        return [], 0
    i = pos - 4
    tensors = []
    while i < len(data) and data[i] == 0x1A:
        length, j = uvarint(data, i + 1)
        record = data[j:j + length]
        fields, _ = parse_fields(record, 0)
        name = fields[1][0].decode("utf-8")
        raw_dims = fields.get(2, [b""])[0]
        dims = []
        k = 0
        while k < len(raw_dims):
            value, k = uvarint(raw_dims, k)
            dims.append(value)
        tensors.append({
            "name": name,
            "shape": dims,
            "dtype": fields.get(4, [None])[0],
            "extra": [len(v) if isinstance(v, bytes) else v for v in fields.get(3, [])],
        })
        i = j + length
    return tensors, i


def main():
    ap = argparse.ArgumentParser(description="解析 XLLM 模型容器")
    ap.add_argument("path")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--tokens", metavar="PATH", help="把词表写成 id<TAB>token 的文本")
    args = ap.parse_args()

    data = open(args.path, "rb").read()
    if data[:4] != b"XLLM":
        sys.exit("不是 XLLM 容器")
    config_len = struct.unpack_from("<Q", data, 0x20)[0]
    config, config_end = read_json_at(data, 0x28)
    tensors, table_end = parse_tensors(data)

    tokenizer = None
    tokenizer_size = 0
    marker = data.find(b'{\n  "version"', table_end)
    if marker >= 0:
        try:
            tokenizer, tokenizer_end = read_json_at(data, marker)
            tokenizer_size = tokenizer_end - marker
        except (ValueError, json.JSONDecodeError):
            tokenizer = None

    total = sum(1 for _ in range(1))  # 占位，保持脚本简单
    params = 0
    for t in tensors:
        n = 1
        for d in t["shape"]:
            n *= d
        params += n

    report = {
        "file": args.path,
        "size": len(data),
        "version": struct.unpack_from("<I", data, 4)[0],
        "config": config,
        "config_bytes": config_len,
        "tokenizer_bytes": tokenizer_size,
        "tokenizer_vocab": len(tokenizer["model"]["vocab"]) if tokenizer and "model" in tokenizer and "vocab" in tokenizer["model"] else None,
        "tensors": tensors,
        "tensor_table_end": table_end,
        "blueprint_params": params,
    }
    if args.tokens and tokenizer:
        vocab = tokenizer.get("model", {}).get("vocab", {})
        with open(args.tokens, "w", encoding="utf-8") as out:
            for token, index in sorted(vocab.items(), key=lambda kv: kv[1]):
                out.write(f"{index}\t{token}\n")
        print(f"词表已写出：{args.tokens}（{len(vocab)} 个 token）", file=sys.stderr)

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return

    print(f"文件：{args.path}（{len(data):,} 字节）")
    print(f"配置：{json.dumps(config, ensure_ascii=False)}")
    if tokenizer:
        print(f"分词器：{tokenizer_size:,} 字节，词表 {report['tokenizer_vocab']} 个 token")
    print(f"张量蓝图 {len(tensors)} 条（合计 {params:,} 参数）：")
    for t in tensors:
        print(f"  {t['name']:<36} {str(t['shape']):<18} dtype={t['dtype']}")
    print(f"蓝图表结束于 0x{table_end:x}；之后是权重区（布局未逐张量解码）")


if __name__ == "__main__":
    main()
