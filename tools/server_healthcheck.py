#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI_RTS 服务器一键健康自检（防止版本漂移/协议不兼容再次溜到玩家手上）。

背景：2026-09-10 两次玩家可见故障同属一个模式——
  1) 服务器专用服代码落后于客户端 -> RPC checksum 失败 -> 大厅槽位全"空位"；
  2) daemon 探测协议与新版服务器不兼容（sendall 字面 \\n 笔误）-> 连通测试
     "游戏端点未响应"。
任何一侧改动协议文件（NetSession/Online/DebugControlServer/adjutant_daemon）
后必须跑一次本脚本，全部 PASS 才算交付。

用法：python tools/server_healthcheck.py     （自动读根目录服务器信息.md）
退出码：0 = 全 PASS；1 = 任一 FAIL。凭证不打印、不落日志。
"""
import hashlib
import re
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

REPO = Path(__file__).resolve().parents[1]
INFO_FILE = Path(r"G:\AIRTS\服务器信息.md")
HOST = "101.43.121.102"
USER = "ubuntu"
REMOTE = "/home/ubuntu/AI_RTS"
WATCH_FILES = ("source/net/NetSession.gd", "source/main-menu/Online.gd",
               "source/net/DebugControlServer.gd")
OLD_TOKEN = "AIRTS-ADJ-7c91f2x9"


def local_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    import paramiko
    info = INFO_FILE.read_text(encoding="utf-8")
    password = re.search(r"登录密码[:：]\s*(\S+)", info).group(1).replace("\\", "")
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=password, timeout=15)

    def run(cmd, timeout=30):
        _, out, _ = cli.exec_command(cmd, timeout=timeout)
        return out.read().decode("utf-8", "replace").strip()

    results = []

    def check(name, ok, detail=""):
        results.append(bool(ok))
        print("[%s] %s %s" % ("PASS" if ok else "FAIL", name, detail))

    check("airts-game active",
          run("systemctl is-active airts-game") == "active")

    check("24567 listening",
          "24567" in run("ss -ulnp 2>/dev/null | grep 24567 | head -1"))

    for rel in WATCH_FILES:
        remote_hash = run("sha256sum %s/%s | cut -d' ' -f1" % (REMOTE, rel))
        local_hash = local_sha256(str(REPO / rel))
        check("%s == local HEAD" % Path(rel).name,
              bool(remote_hash) and remote_hash == local_hash,
              "sha %s" % (remote_hash[:12] or "missing"))

    leak = run("grep -rl '%s' %s/source 2>/dev/null | head -3" % (OLD_TOKEN, REMOTE))
    check("no retired token on server", leak == "", leak[:80] or "clean")

    dproc = run("pgrep -af 'adjutant_daemon.py' | grep -v grep | head -1")
    dlisten = run("ss -tlnp 2>/dev/null | grep 24580 | head -1")
    check("daemon running on 24580",
          bool(dproc) and "24580" in dlisten, dproc[:60] or "not found")

    ping = run(
        "TOKEN=$(cat /home/ubuntu/ai-adjutant/config/adjutant_token); "
        "curl -s -m 15 -X POST http://127.0.0.1:24580/adjutant/control "
        "-H 'Content-Type: application/json' "
        "-d '{\"token\":\"'\"$TOKEN\"'\",\"action\":\"ping\"}'")
    check("daemon ping game_alive", '"game_alive": true' in ping, ping[:120])

    # takeover 分支回归检查：对无对局端口应干净返回 409（NameError/502 即 FAIL）。
    dry = run(
        "TOKEN=$(cat /home/ubuntu/ai-adjutant/config/adjutant_token); "
        "printf '%s' \"{\\\"token\\\":\\\"$TOKEN\\\",\\\"action\\\":\\\"takeover\\\",\\\"port\\\":24568}\" "
        "> /tmp/healthcheck_dry.json; "
        "curl -s -m 15 -w 'HTTP_%{http_code}' -X POST "
        "http://127.0.0.1:24580/adjutant/control "
        "-H 'Content-Type: application/json' -d @/tmp/healthcheck_dry.json")
    check("takeover branch sane (409 on empty port)",
          "HTTP_409" in dry and "no active match" in dry, dry[:100])

    bad_sendall = run(
        "grep -cE \"sendall\\(b'.*\\\\\\\\\\\\\\\\n'\\)\" "
        "/home/ubuntu/adjutant_daemon.py")
    check("daemon ping newline literal clean", bad_sendall == "0",
          "literal-newline hits=%s" % bad_sendall)

    cli.close()
    failed = [i for i, ok in enumerate(results) if not ok]
    print("=== %d/%d PASS ===" % (len(results) - len(failed), len(results)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
