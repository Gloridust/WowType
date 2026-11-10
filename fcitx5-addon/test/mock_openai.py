#!/usr/bin/env python3
"""假的 OpenAI chat/completions 服务（流式），给插件按键测试用，也可以手动试互译。

    python3 fcitx5-addon/test/mock_openai.py        # 第一行打印端口

每种译法是「T<n>:原文」，一次给三种，几个字一块慢慢流出来；
原文里有「错误」或者 Key 不是 sk-harness 时回 401。
"""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        source = body["messages"][-1]["content"]
        if self.headers.get("Authorization") != "Bearer sk-harness" or "错误" in source:
            data = json.dumps({"error": {"message": "Incorrect API key provided"}}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        text = "\n".join(f"T{i}:{source}" for i in (1, 2, 3))
        for i in range(0, len(text), 4):
            chunk = {"choices": [{"delta": {"content": text[i : i + 4]}}]}
            self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()
            time.sleep(0.02)
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
