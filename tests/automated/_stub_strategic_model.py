"""阶段1 战略聊天测试桩：本地 OpenAI 兼容模型服务（可注入故障模式）。

用法：python _stub_strategic_model.py <port> <mode>
mode：
  ok      — 正常 completion，固定中文回复（含上一问回声，用于验证上下文）
  error503 — HTTP 503
  empty   — content 为空白
  invalid — body 不是 JSON
  hang    — 接受连接后不响应（配合短超时测 timeout 路径）
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"
TURN = {"n": 0}


class Handler(BaseHTTPRequestHandler):
    # Godot 的 HTTPClient 对 HTTP/1.0 无 Content-Length 的响应读不到 body（实测空体）：
    # 必须显式 HTTP/1.1 + Content-Length。
    protocol_version = "HTTP/1.1"

    def _send(self, code: int, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802 - http.server 命名
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", "ignore")
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {}
        TURN["n"] += 1
        if MODE == "error503":
            self._send(503, b'{"error":"stub down"}')
            return
        if MODE == "hang":
            time.sleep(60)
            return
        if MODE == "empty":
            content = "   "
        elif MODE == "invalid":
            self._send(200, b"stub non-json body")
            return
        else:
            content = "（桩回复 %d）收到：%s" % (TURN["n"], payload.get("messages", [{}, {}])[-1].get("content", ""))
        self._send(200, json.dumps({
            "choices": [{"finish_reason": "stop",
                         "message": {"role": "assistant", "content": content}}],
        }, ensure_ascii=False).encode("utf-8"))

    def log_message(self, *_args):  # 静默访问日志
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18230
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
