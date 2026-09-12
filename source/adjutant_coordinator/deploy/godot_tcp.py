# -*- coding: utf-8 -*-
"""服务器侧 Godot 调试端点帮助函数（只读/受控开局；端口白名单硬约束）。

铁律：本模块只允许连本机隔离测试端口（24569/24570/24572），
任何写操作都拒绝玩家局服端口（24567/24568/24571）。
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from typing import Any, Dict, List, Optional

#: 玩家局服 / Hermes 客户端调试端口：永不允许连接。
FORBIDDEN_PORTS = {24567, 24568, 24571}
#: 允许的隔离测试端口（局服 UDP 24569、测试客户端 24570、测试局服调试 24572）。
ALLOWED_PORTS = {24569, 24570, 24572}

DEFAULT_REPO = "/home/ubuntu/AI_RTS"
DEFAULT_GODOT = ("/home/ubuntu/godot/Godot_v4.7.1-stable_mono_linux_x86_64/"
                 "Godot_v4.7.1-stable_mono_linux.x86_64")


class PortNotAllowed(RuntimeError):
    """端口不在隔离测试白名单内。"""


def assert_allowed(port: int) -> None:
    if port in FORBIDDEN_PORTS:
        raise PortNotAllowed("拒绝：%d 属于玩家局服/Hermes 链路，禁止连接。" % port)
    if port not in ALLOWED_PORTS:
        raise PortNotAllowed("拒绝：%d 不在隔离测试端口白名单 %s 内。" % (
            port, sorted(ALLOWED_PORTS)))


def tcp_json(port: int, payload: Dict[str, Any], timeout: float = 20.0) -> Dict[str, Any]:
    """与游戏调试端点同协议：发一行 JSON，读一行 JSON。

    注意：端点在响应后不一定关闭连接（StreamPeer 语义），因此必须按
    “第一个 '{' 到其后第一个换行”截取，而不能读到 EOF。
    """
    assert_allowed(port)
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        buffer = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            buffer += chunk
            start = buffer.find(b"{")
            end = buffer.find(b"\n", start)
            if start >= 0 and end > start:
                line = buffer[start:end].decode("utf-8", errors="replace")
                try:
                    return json.loads(line)
                except ValueError:
                    return {"error": "non-json", "raw": line[:500]}
    return {"error": "timeout", "raw": buffer.decode("utf-8", "replace")[:500]}


def port_listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2.0):
            return True
    except OSError:
        return False


def run(cmd: str, timeout: float = 60.0) -> str:
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=timeout)
    return (result.stdout or "") + (result.stderr or "")


def ensure_test_client(client_dbg: int = 24570, match_port: int = 24569,
                       repo: str = DEFAULT_REPO, godot: str = DEFAULT_GODOT,
                       log_path: str = "/opt/airts-agent/logs/test_client.log",
                       start: bool = True) -> Dict[str, Any]:
    """确保隔离测试客户端在跑（不启动局服本身，局服由 systemd 管理）。"""
    assert_allowed(client_dbg)
    assert_allowed(match_port)
    if start and not port_listening(client_dbg):
        os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
        client_args = ["--headless", "--path", repo, "--", "--debugport", str(client_dbg),
                       "--autojoin", "--autojoin-lobby", "--smokehost", "127.0.0.1",
                       "--smokeport", str(match_port)]
        if os.name == "nt":  # 本地 Windows 冒烟（服务器侧走 nohup 分支）
            with open(log_path, "wb") as handle:
                subprocess.Popen([godot] + client_args, stdout=handle,
                                 stderr=subprocess.STDOUT,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        else:
            cmd = ("nohup %s %s > %s 2>&1 & echo started" % (
                godot, " ".join(client_args), log_path))
            run(cmd)
    deadline = time.time() + 45
    networked = False
    while time.time() < deadline:
        time.sleep(2)
        try:
            status = tcp_json(client_dbg, {"op": "status", "lite": True}, timeout=6)
        except OSError:
            continue
        if status.get("networked") is True:
            networked = True
            break
    return {"networked": networked, "client_dbg": client_dbg}


def start_match(client_dbg: int = 24570, with_ai: bool = True) -> Dict[str, Any]:
    return tcp_json(client_dbg, {"op": "start", "with_ai": with_ai,
                                 "passive_ai_test": True}, timeout=30)


def wait_match(authority_dbg: int = 24572, timeout_s: float = 60.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        time.sleep(2)
        try:
            if tcp_json(authority_dbg, {"op": "status", "lite": True}, timeout=6).get("match") is True:
                return True
        except OSError:
            continue
    return False


def fetch_views(authority_dbg: int, as_player: str,
                timeout: float = 25.0) -> Dict[str, Any]:
    """读取规则/战术/战略视图（只读 op）。"""
    return {
        "rules": tcp_json(authority_dbg, {"op": "rules"}, timeout=timeout),
        "tactical": tcp_json(authority_dbg, {"op": "tactical", "as_player": as_player},
                             timeout=timeout),
        "strategic": tcp_json(authority_dbg, {"op": "strategic", "as_player": as_player},
                              timeout=timeout),
    }


def pick_player(status: Dict[str, Any]) -> Optional[str]:
    for player in status.get("players", []) or []:
        if player.get("human") is True:
            return str(player.get("name", ""))
    players = status.get("players", []) or []
    return str(players[0].get("name", "")) if players else None
