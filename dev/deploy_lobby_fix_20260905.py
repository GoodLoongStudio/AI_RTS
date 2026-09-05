# -*- coding: utf-8 -*-
"""联机大厅修复一键部署脚本（2026-09-05）

用法：
  1. 把本脚本和 yyp_test_incr_20260905.bundle 放同一目录
  2. 改下方 SERVER_IP / SERVER_USER / SERVER_PASSWORD（凭据见 服务器信息.md）
  3. python deploy_lobby_fix_20260905.py

流程：上传增量 bundle → 服务器 git pull → systemd 重启 airts 服务 → 状态确认。
前提：云服当前 HEAD 为 51f8f92f（若不确定，先用全量 bundle yyp_test_20260905_lobby_fix.bundle）。
注意：本增量不含新增 LFS 资产（51f8f92f 后只改了 .gd/.md/.uid），模型无需补传。
"""
import paramiko
import sys
import time

SERVER_IP = "101.43.121.102"          # TODO: 核对 服务器信息.md
SERVER_USER = "root"                  # TODO: 核对
SERVER_PASSWORD = ""                  # TODO: 必填
BUNDLE = "yyp_test_incr_20260905.bundle"
REMOTE_DIR = "/opt/airts"             # TODO: 核对服务器上仓库路径
SERVICE = "airts-game"                # TODO: 核对 systemd 服务名


def run(ssh: paramiko.SSHClient, cmd: str, title: str) -> bool:
    print(f"==> {title}\n    $ {cmd}")
    _, stdout, stderr = ssh.exec_command(cmd, timeout=120)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    if out.strip():
        print(out.strip()[-1500:])
    if err.strip():
        print("[stderr]", err.strip()[-800:])
    if code != 0:
        print(f"!! 命令失败（exit {code}）：{title}")
        return False
    return True


def main() -> int:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(SERVER_IP, username=SERVER_USER, password=SERVER_PASSWORD, timeout=20)
    print("SSH 已连接", SERVER_IP)

    sftp = ssh.open_sftp()
    print("==> 上传增量 bundle（10KB）")
    sftp.put(BUNDLE, f"/tmp/{BUNDLE}")
    sftp.close()

    steps = [
        (f"cd {REMOTE_DIR} && git bundle verify /tmp/{BUNDLE}", "校验 bundle"),
        (f"cd {REMOTE_DIR} && git pull /tmp/{BUNDLE} yyp_test", "服务器拉取增量"),
        (f"cd {REMOTE_DIR} && git log --oneline -3", "确认服务器 HEAD"),
        (f"systemctl restart {SERVICE}", "重启对局服务"),
        ("sleep 5", "等待 5 秒"),
        (f"systemctl is-active {SERVICE}", "确认服务存活"),
    ]
    for cmd, title in steps:
        if not run(ssh, cmd, title):
            return 1
    ssh.close()
    print("\n部署完成：云服已含「点准备后开局 + 房主判定 v3」修复。")
    print("验证：客户端加入局服 → 点准备（或房主点立即开局）→ 应直接开局。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
