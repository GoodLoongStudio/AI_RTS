#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本机回环 LLM 代理：密钥留在服务器，客户端经 SSH 隧道使用真实 Provider。

设计（安全边界）：
- 只绑定 127.0.0.1（公网不可达；本机需经 SSH 端口转发才能使用）；
- 上游与密钥全部来自 /opt/airts-agent/.env（LLM_BASE_URL / LLM_API_KEY），
  转发时注入 Authorization；调用方不需要也不接触密钥；
- 只转发 OpenAI 兼容的 POST /chat/completions（其余路径一律 404）；
- 日志只记录方法/路径/状态/耗时/字节数：不记录 prompt、不记录响应正文、不记录密钥。

用法（服务器）：
  .venv/bin/python -m adjutant_coordinator.deploy.llm_proxy --port 8899 \
      --log /opt/airts-agent/logs/llm_proxy.log
本机隧道（SSH 端口转发 8899 -> 服务器 127.0.0.1:8899）后：
  LLM_BASE_URL=http://127.0.0.1:8899 LLM_API_KEY=<任意非空占位> python ... --provider real
"""

from __future__ import annotations

import argparse
import http.client
import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlsplit

HERE = __import__("os").path.dirname(__import__("os").path.abspath(__file__))
sys.path.insert(0, HERE)

from env_file import load_env_file  # noqa: E402

ALLOWED_PATH = "/chat/completions"


def upstream_parts(base_url: str) -> Tuple[str, str, int, str]:
    """把 base_url 解析成 (host, base_path, port, scheme)。"""
    parts = urlsplit(base_url)
    scheme = parts.scheme or "https"
    host = parts.hostname or "api.stepfun.com"
    port = parts.port or (443 if scheme == "https" else 80)
    base_path = parts.path.rstrip("/")
    return host, base_path, port, scheme


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "airts-llm-proxy/1.0"

    def log_message(self, fmt, *args):  # noqa: D102 —— 关掉默认 stderr 噪声
        return

    def _log(self, **fields: Any) -> None:
        record = {"ts": time.strftime("%Y-%m-%d %H:%M:%S"), **fields}
        line = json.dumps(record, ensure_ascii=False)
        path = self.server.log_path  # type: ignore[attr-defined]
        try:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass
        print(line, flush=True)

    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") in ("/health", ""):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok": true, "upstream": "configured"}')
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):  # noqa: N802
        started = time.time()
        path = urlsplit(self.path).path
        if path != ALLOWED_PATH:
            self.send_response(404)
            self.end_headers()
            self._log(method="POST", path=path, status=404, reason="path_not_allowed")
            return
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length else b""
        host, base_path, port, scheme = self.server.upstream  # type: ignore[attr-defined]
        target = base_path + ALLOWED_PATH
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": "Bearer %s" % self.server.api_key,  # type: ignore[attr-defined]
            "Content-Length": str(len(body)),
        }
        connection: Optional[http.client.HTTPConnection] = None
        try:
            if scheme == "https":
                connection = http.client.HTTPSConnection(
                    host, port, timeout=300, context=ssl.create_default_context())
            else:
                connection = http.client.HTTPConnection(host, port, timeout=300)
            connection.request("POST", target, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type",
                             response.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self._log(method="POST", path=path, status=response.status,
                      latency_s=round(time.time() - started, 3),
                      request_bytes=len(body), response_bytes=len(payload))
        except Exception as exc:  # noqa: BLE001 —— 上游异常结构化回执，不泄露细节
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(
                    {"error": {"type": "proxy_upstream_error",
                               "message": type(exc).__name__}}).encode("utf-8"))
            except Exception:
                pass
            self._log(method="POST", path=path, status=502,
                      latency_s=round(time.time() - started, 3),
                      error=type(exc).__name__)
        finally:
            if connection is not None:
                connection.close()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="本机回环 LLM 代理（密钥留服务器）")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--log", default="/opt/airts-agent/logs/llm_proxy.log")
    parser.add_argument("--env-file", default="")
    args = parser.parse_args(argv)

    loaded = load_env_file(args.env_file)
    import os
    base_url = os.environ.get("LLM_BASE_URL", "")
    api_key = os.environ.get("LLM_API_KEY", "")
    if not base_url or not api_key:
        print("缺少 LLM_BASE_URL / LLM_API_KEY（已加载键名：%s）" % sorted(loaded))
        return 2
    server = ThreadingHTTPServer((args.host, args.port), ProxyHandler)
    server.upstream = upstream_parts(base_url)  # type: ignore[attr-defined]
    server.api_key = api_key  # type: ignore[attr-defined]
    server.log_path = args.log  # type: ignore[attr-defined]
    host, base_path, port, scheme = server.upstream  # type: ignore[attr-defined]
    print("proxy listening on %s:%d -> %s://%s%s (只允许 POST %s)"
          % (args.host, args.port, scheme, host, base_path, ALLOWED_PATH), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
