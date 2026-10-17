# -*- coding: utf-8 -*-
"""DBGCTL 客户端：连接游戏内调试控制端点（--debugport），发送 JSON 指令操控对局。

协议（2026-09-29 实测，与 source/net/DebugControlServer.gd 对齐）：
- 服务端：游戏以 `-- --debugport 24568` 启动后监听 tcp://127.0.0.1:24568（注意
  `--debugport=24568` 等号形式**不解析**，必须空格分隔；不带 --debugport 时只开
  受限副官白名单 op，端口 24579）。
- 请求：裸 JSON + '\n'。**不要**自己加 4 字节长度前缀 —— 服务端按
  get_utf8_string(available) 收包，多余前缀会把缓冲搞挂，之后所有 op 永久无响应。
- 响应：4 字节小端长度 + UTF-8 JSON。

用法：
    python tools/dbgctl.py status
    python tools/dbgctl.py build --scene res://source/match/units/Barracks.tscn
    python tools/dbgctl.py click --x 883 --y 408
    python tools/dbgctl.py '{"op":"build","scene":"...","pos":[10,20]}'   # 透传原始 JSON

也可 import：from dbgctl import send

已知坑（2026-09-29）：
- `screenshot` op 会触发 Vulkan 回读，可能把游戏 _process 永久卡死 —— 想看画面用
  桌面窗口截图（ZCode CUA / 其它截屏手段），别用这个 op。
- 游戏必须用 run_in_background（或独立终端）方式启动；随 Bash 调用结束会被窗口
  关闭信号带走（[EXIT-TRACE] WM_CLOSE_REQUEST）。
"""
from __future__ import annotations

import json
import socket
import struct
import sys

HOST = "127.0.0.1"
PORT = 24568
DEFAULT_TIMEOUT = 30.0


def send(command: dict, port: int = PORT, timeout: float = DEFAULT_TIMEOUT) -> dict:
    """发送一条 op 指令并返回解析后的 JSON 响应。"""
    s = socket.create_connection((HOST, port), timeout=timeout)
    try:
        s.sendall((json.dumps(command, ensure_ascii=False) + "\n").encode("utf-8"))
        s.settimeout(timeout)
        header = b""
        while len(header) < 4:
            chunk = s.recv(4 - len(header))
            if not chunk:
                raise IOError("DBGCTL 连接被关闭")
            header += chunk
        size = struct.unpack("<I", header)[0]
        body = b""
        while len(body) < size:
            chunk = s.recv(min(1048576, size - len(body)))
            if not chunk:
                raise IOError("DBGCTL 响应不完整")
            body += chunk
        return json.loads(body.decode("utf-8", "replace"))
    finally:
        s.close()


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1].startswith("{"):
        command = json.loads(argv[1])
    elif len(argv) >= 2:
        command = {"op": argv[1]}
        for index in range(2, len(argv) - 1, 2):
            key = argv[index].lstrip("-").replace("-", "_")
            value = argv[index + 1]
            try:
                value = json.loads(value)
            except json.JSONDecodeError:
                pass
            command[key] = value
    else:
        command = {"op": "status"}
    print(json.dumps(send(command), ensure_ascii=False, indent=1)[:6000])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
