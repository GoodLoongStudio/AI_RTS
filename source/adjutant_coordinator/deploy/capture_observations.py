#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""采集**真实对局观测**为 JSONL（供短决策接口 A/B 与规模测试离线回放）。

依据（计划 §7.A）："取至少 50 个不同的真实观测或标注回放，覆盖战斗、经济、
撤退、侦察和玩家介入"。本工具只做**只读**采集：

- 起本地 Demo（专用服 ENET 24569 / DBG 24572 + 可见客户端 DBG 24570），
  与 `e2e_dual_layer` 完全同一条链路；也可 `--reuse` 直接采已跑着的对局；
- 每轮只发 `op=tactical` / `op=strategic` / `op=status`（**只读通道**，
  绝不动玩家相机、不发命令）；
- 采集结果按行落盘，包含 `rules`（首行）与每轮的 header/tactical/strategic，
  离线回放时用同一份数据重建 `DecisionFrame`，保证"模型看到的就是当时看到的"。

用法：
    python -m adjutant_coordinator.deploy.capture_observations \
        --out tests/data/observations/real_YYYYMMDD.jsonl --samples 60 --with-ai
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from typing import Any, Dict, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # source/
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.dirname(HERE))

from adjutant_coordinator import e2e_dual_layer as base  # noqa: E402

#: 只读采集用到的 op（任何写操作都不出现在这里）。
READ_OPS = ("status", "rules", "tactical", "strategic")


def tcp(port: int, payload: Dict[str, Any], timeout: float = 20.0) -> Dict[str, Any]:
    try:
        return base.tcp_call(port, payload, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc)}


def spawn(args, log_path: str, cwd: Optional[str] = None):
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    return subprocess.Popen(args, stdout=open(log_path, "wb"),
                            stderr=subprocess.STDOUT, cwd=cwd or None,
                            creationflags=subprocess.CREATE_NO_WINDOW)


def start_match(args) -> None:
    """清理旧实例 → 起专用服 → 起客户端 → 开局（与 e2e_dual_layer 同链路）。"""
    for port in (base.SERVER_PORT, base.SERVER_DBG, base.CLIENT_DBG):
        for pid in base.pids_on_port(port):
            base.kill_tree(pid)
    time.sleep(3)
    spawn([base.GODOT, "--headless", "--path", base.AI_RTS, "--",
           "--server", "--port", str(base.SERVER_PORT),
           "--debugport", str(base.SERVER_DBG)],
          os.path.join(args.log_dir, "server.log"))
    base.wait_port(base.SERVER_DBG, 90)
    spawn([base.GODOT, "--path", base.AI_RTS, "--",
           "--debugport", str(base.CLIENT_DBG),
           "--autojoin", "--autojoin-lobby",
           "--smokehost", "127.0.0.1", "--smokeport", str(base.SERVER_PORT)],
          os.path.join(args.log_dir, "client.log"))
    base.wait_port(base.CLIENT_DBG, 180)
    for _ in range(40):
        time.sleep(3)
        lobby = tcp(base.CLIENT_DBG, {"op": "lobby"}, timeout=15)
        if lobby.get("slots"):
            break
    for port in (base.SERVER_DBG, base.CLIENT_DBG):
        result = tcp(port, {"op": "start", "with_ai": bool(args.with_ai)}, timeout=30)
        if not result.get("error"):
            break
    for _ in range(40):
        time.sleep(3)
        status = tcp(base.CLIENT_DBG, {"op": "status"}, timeout=15)
        if status.get("match"):
            return


def pick_player(port: int) -> str:
    status = tcp(port, {"op": "status"})
    for player in status.get("players") or []:
        if player.get("human"):
            return str(player.get("name", ""))
    return ""


def capture(args) -> int:
    out_path = os.path.abspath(args.out)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    port = int(args.client_debug_port)
    if not args.reuse:
        start_match(args)
    player = args.player or pick_player(port)
    if not player:
        print("[capture] 找不到真人玩家，拒绝采集（避免采到错误视角）", file=sys.stderr)
        return 3
    rules = tcp(port, {"op": "rules"}, timeout=30)
    if rules.get("error"):
        print("[capture] op=rules 失败：%s" % rules.get("error"), file=sys.stderr)
        return 3
    print("[capture] player=%s 端口=%d 采样 %d 次 / 间隔 %.1fs -> %s"
          % (player, port, args.samples, args.interval, out_path))
    written = 0
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"kind": "rules", "rules": rules},
                                ensure_ascii=False) + "\n")
        for seq in range(int(args.samples)):
            tactical = tcp(port, {"op": "tactical", "as_player": player,
                                  "limit": int(args.entity_limit)}, timeout=30)
            strategic = tcp(port, {"op": "strategic", "as_player": player}, timeout=30)
            status = tcp(port, {"op": "status", "lite": True}, timeout=20)
            if tactical.get("error"):
                print("[capture] 第 %d 次 op=tactical 失败：%s" % (seq, tactical["error"]))
            else:
                header = {
                    "schema_version": 1,
                    "match_id": str(rules.get("match_id", "") or ""),
                    "player_id": player,
                    "rules_version": str((rules.get("rules_version") or {}).get(
                        "content_hash", "") or ""),
                    "snapshot_id": int(tactical.get("snapshot_id",
                                                    tactical.get("server_tick", 0)) or 0),
                    "server_tick": int(tactical.get("server_tick", 0) or 0),
                }
                handle.write(json.dumps({
                    "kind": "observation", "seq": seq, "ts": time.time(),
                    "header": header, "tactical": tactical, "strategic": strategic,
                    "match": status.get("match"), "margin": _margin(tactical),
                }, ensure_ascii=False) + "\n")
                handle.flush()
                written += 1
                print("  #%02d tick=%s 己方=%d 敌人=%d 资源=%d 余额=%s"
                      % (seq, header["server_tick"],
                         len([e for e in tactical.get("entities", []) or []
                              if str(e.get("kind")) == "unit_self"]),
                         len([e for e in tactical.get("entities", []) or []
                              if str(e.get("kind", "")).startswith("unit_enemy")]),
                         len([e for e in tactical.get("entities", []) or []
                              if str(e.get("kind")) == "resource"]),
                         (tactical.get("balance") or {})))
            if args.stop_when_ended and not status.get("match"):
                print("[capture] 对局已结束，提前停止")
                break
            time.sleep(float(args.interval))
    print("[capture] 完成：写入 %d 条观测 -> %s" % (written, out_path))
    return 0 if written else 4


def _margin(tactical: Dict[str, Any]) -> Dict[str, int]:
    own = len([e for e in tactical.get("entities", []) or []
               if str(e.get("kind")) == "unit_self"])
    enemies = len([e for e in tactical.get("entities", []) or []
                   if str(e.get("kind", "")).startswith("unit_enemy")])
    return {"own": own, "enemy": enemies}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="只读采集真实对局观测（JSONL）")
    parser.add_argument("--out", default=os.path.join(
        ROOT, "adjutant_coordinator", "tests", "data", "observations",
        time.strftime("real_%Y%m%d_%H%M%S.jsonl")))
    parser.add_argument("--samples", type=int, default=60)
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--entity-limit", type=int, default=0,
                        help="op=tactical 的实体上限（0=全部）")
    parser.add_argument("--client-debug-port", type=int, default=base.CLIENT_DBG)
    parser.add_argument("--player", default="")
    parser.add_argument("--with-ai", action="store_true", help="开 AI 对手（覆盖战斗/撤退场景）")
    parser.add_argument("--reuse", action="store_true", help="不重开局，采当前跑着的对局")
    parser.add_argument("--keep-running", action="store_true",
                        help="采完保留对局（离线 A/B 时让游戏继续占用 GPU，接近真实条件）")
    parser.add_argument("--stop-when-ended", action="store_true", default=True)
    parser.add_argument("--log-dir", default=r"G:\AIRTS\tmp_logs\observation_capture")
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    code = capture(args)
    if not args.keep_running and not args.reuse:
        for port in (base.SERVER_PORT, base.SERVER_DBG, base.CLIENT_DBG):
            for pid in base.pids_on_port(port):
                base.kill_tree(pid)
    return code


if __name__ == "__main__":
    sys.exit(main())
