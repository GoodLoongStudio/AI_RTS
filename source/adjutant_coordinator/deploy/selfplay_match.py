# -*- coding: utf-8 -*-
"""自对局驱动：AI 副官 vs 电脑玩家（RuleAI），用于 Laya 训练数据采集与迭代评估。

与验收 harness（campaign_accept）的差别：**with_ai=True**——真的有一个电脑对手，
副官的部队会遭遇敌人、交火、推进。验收局是 with_ai=False（无对手），只能练发展。

用法：
    python selfplay_match.py --seconds 300 --tag sp1 [--backend laya|model|off]
                            [--difficulty 0|1|2] [--dataset <path.jsonl>]

流程：起专用服+客户端 → op=start(with_ai=True) → 起 runner（默认三层全本地）
→ 采样对局 → 收尾 → 输出战绩摘要（JSON）。

结局判定（v1，够用优先）：对局结束时双方存留单位/建筑对比；
若中间一方被歼灭（观测不到对方单位且持续一段时间）也记录。
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RECON = r"G:\AIRTS\tmp_logs\langgraph_recon"
sys.path.insert(0, RECON)

import dev_ports as PORTS  # noqa: E402
import restart_local as _rl  # noqa: E402
from restart_local import AI, LOGS, dcs, kill_our_game, spawn, tcp_listening  # noqa: E402
from runner_ctl import start as start_runner, stop as stop_runner  # noqa: E402

BASE = int(os.environ.get("AIRTS_TEST_BASE") or PORTS.acceptance_base())
os.environ["AIRTS_TEST_BASE"] = str(BASE)
_ok, _why = PORTS.check_acceptance_base(BASE)
if not _ok:
    raise SystemExit("[selfplay] " + _why)
print("[selfplay] %s" % _why, flush=True)

# 端口口径与 restart_local 完全一致（GAME/CLIENT/SERVER = base/+1/+3）。
GAME_PORT = _rl.GAME_PORT
CLIENT_PORT = _rl.CLIENT_PORT
SERVER_PORT = _rl.SERVER_PORT
OUT = os.path.join(RECON, "selfplay")
HUD = os.environ.get("AIRTS_RUNNER_HUD") or os.path.join(OUT, "hud")
os.environ["AIRTS_RUNNER_HUD"] = HUD


def _wait_match(timeout_s: float = 150) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if dcs(CLIENT_PORT, {"op": "status"}, timeout=8).get("match"):
                return True
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)
    return False


def _match_forces() -> dict:
    """无迷雾的双方单位计数（op=match_forces；自对局胜负判定用）。"""
    try:
        data = dcs(SERVER_PORT, {"op": "match_forces"}, timeout=15) or {}
    except Exception as exc:  # noqa: BLE001
        return {"__error": str(exc)}
    return data


def _own_snapshot():
    """副官视角的战术观测（己方单位 + 余额 + 可见敌人）。"""
    try:
        snap = dcs(SERVER_PORT, {"op": "tactical", "as_player": "Player_0"},
                   timeout=15)
    except Exception as exc:  # noqa: BLE001
        return {"__error": str(exc)}
    return snap or {}


def _match_result_from_log() -> str:
    """从游戏日志读**权威结算字符串**（"胜利"/"失败"/"平局"）。

    专用服在广播结果后 5 秒主动 `quit()`（NetSync._on_match_finished），
    所以"连接断开"**不等于**"游戏崩了"——两种退出长得一模一样。
    2026-09-23 实测 r9_1：375s 敌军全灭、386s 日志广播"胜利"、391s 服务端退出，
    上一版 harness 把这次退出判成 aborted，白丢一场胜局。
    服务器那行是权威（`已广播结果`）；客户端那行是回执（`收到结算`），兜底用。
    """
    for name, needle in (("selfplay_server.out", "已广播结果"),
                         ("selfplay_client.out", "收到结算")):
        try:
            with open(os.path.join(LOGS, name), "r", encoding="utf-8",
                      errors="replace") as handle:
                lines = handle.read().splitlines()
        except OSError:
            continue
        for line in reversed(lines):
            if needle not in line:
                continue
            tail = line.split(needle, 1)[1]
            # 形如 "[对局] 已广播结果: 胜利, 5 秒后回收专用服" / "收到结算: 胜利，3 秒后…"
            tail = tail.lstrip(": ：,， ")
            for separator in (",", "，"):
                if separator in tail:
                    tail = tail.split(separator, 1)[0]
            result = tail.strip()
            if result:
                return result
    return ""


def _forces(snap: dict) -> dict:
    out = {"units": {}, "balance": snap.get("balance") or {},
           "visible_enemies": 0}
    for entity in snap.get("entities") or []:
        kind = str(entity.get("kind", ""))
        if kind == "unit_self":
            utype = str(entity.get("unit_type", "?"))
            out["units"][utype] = out["units"].get(utype, 0) + 1
        elif kind == "unit_enemy":
            out["visible_enemies"] += 1
    return out


def _detail(snap: dict) -> dict:
    """逐实体明细（评测指标用：建筑掉血/摧毁、战损、位置、可见性）。

    只做透传，不做推断：hp/hp_max/type 全部取观测原值。
    坐标取 **[x, z]**（观测 pos 是 [x, y(高度), z]，y 是高度不是平面坐标——
    2026-09-22 实测踩过：取 [:2] 会把高度当 z，距离/推进分析全错）。
    """
    own, enemies = [], []
    for entity in snap.get("entities") or []:
        kind = str(entity.get("kind", ""))
        raw = entity.get("pos") or []
        pos = [round(float(raw[0]), 1), round(float(raw[2]), 1)] if len(raw) >= 3 else []
        entry = {
            "name": str(entity.get("name", "")),
            "type": str(entity.get("unit_type", "")),
            "pos": pos,
            "hp": round(float(entity.get("hp") or 0.0), 2),
            "hp_max": round(float(entity.get("hp_max") or 0.0), 2),
        }
        if kind == "unit_self":
            own.append(entry)
        elif kind.startswith("unit_enemy"):
            enemies.append(entry)
    return {"own": own, "enemies": enemies}


def main() -> int:
    parser = argparse.ArgumentParser(description="副官 vs 电脑玩家 自对局")
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--tag", default="sp")
    parser.add_argument("--backend", default=os.environ.get("AIRTS_S1_BACKEND", "laya"),
                        choices=("laya", "model", "off"))
    parser.add_argument("--difficulty", type=int, default=-1,
                        help="电脑难度 0=EASY 1=NORMAL 2=HARD；-1=游戏默认")
    parser.add_argument("--dataset", default="",
                        help="Laya 训练数据集输出路径（JSONL，追加写）")
    args = parser.parse_args()

    os.makedirs(OUT, exist_ok=True)
    os.makedirs(HUD, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    os.environ["AIRTS_S1_BACKEND"] = args.backend
    if args.dataset:
        os.environ["AIRTS_LAYA_DATASET"] = args.dataset
    # 电脑难度：0/1/2 经环境变量传给游戏侧（NetSession 的默认不干预覆盖）；
    # -1 = 不设置（游戏默认 NORMAL）。
    if args.difficulty in (0, 1, 2):
        os.environ["AIRTS_SELFPLAY_DIFFICULTY"] = str(args.difficulty)
    # 【2026-09-21 双 runner 事故修复】客户端加载页会按 `auto_takeover` 预热
    # **第二个** runner（连客户端 DCS）。实测（sp_ft2_branch 局）：第二个 runner
    # 的命令经客户端转发链触发 `player_override`，把 112 个机动单位全部踢出
    # 副官托管（只剩建筑），军事/侦察轨无执行者 → 全军在家攒兵、超时亡。
    # 这里显式关掉预热（游戏侧 `AIRTS_ADJ_AUTO_TAKEOVER` 本就是隔离测试用的
    # 覆盖开关；harness 自己起 runner，不需要客户端再起一个）。
    os.environ["AIRTS_ADJ_AUTO_TAKEOVER"] = "0"

    # 起专用服 + 客户端（与验收同口径，只按端口 PID 清理）。
    kill_our_game()
    spawn(["--headless", "--path", AI, "--",
           "--server", "--port", str(GAME_PORT), "--debugport", str(SERVER_PORT)],
          "selfplay_server.out")
    ok = False
    for _ in range(45):
        time.sleep(2)
        if tcp_listening(SERVER_PORT):
            ok = True
            break
    if not ok:
        print("[selfplay] 服务端未就绪", flush=True)
        return 2
    # 客户端参数与验收 harness 完全一致（debugport 显式指定：默认 24579 会被同时
    # 开着的游戏/demo 占用；--autojoin 系列是自动进大厅的关键，缺了会卡在主菜单）。
    # 注意**不能加 --headless**：客户端要走主菜单/大厅流程（harness 同款窗口运行）。
    spawn(["--path", AI, "--", "--debugport", str(CLIENT_PORT),
           "--autojoin", "--autojoin-lobby",
           "--smokehost", "127.0.0.1", "--smokeport", str(GAME_PORT)],
          "selfplay_client.out")
    ok = False
    for _ in range(25):
        time.sleep(2)
        if tcp_listening(CLIENT_PORT):
            ok = True
            break
    if not ok:
        print("[selfplay] 客户端未就绪", flush=True)
        kill_our_game()
        return 2

    # 等大厅就绪（客户端连上网、拿到槽位）后再开局——否则 op=start 报 not networked。
    lobby_ready = False
    for _ in range(20):
        time.sleep(2)
        try:
            lobby = dcs(CLIENT_PORT, {"op": "lobby"}, timeout=8) or {}
        except Exception:  # noqa: BLE001
            continue
        if lobby.get("slots"):
            lobby_ready = True
            print("[selfplay] 大厅就绪: %s" % str(lobby.get("local_name")), flush=True)
            break
    if not lobby_ready:
        print("[selfplay] 大厅未就绪", flush=True)
        kill_our_game()
        return 2

    # 开局：**with_ai=True**（真的电脑对手）；passive=False（它会主动进攻）。
    started = dcs(CLIENT_PORT, {"op": "start", "with_ai": True,
                                "passive_ai_test": False}, timeout=30)
    print("[selfplay] op=start -> %s" % str(started)[:160], flush=True)
    if not _wait_match():
        print("[selfplay] 对局未开始", flush=True)
        kill_our_game()
        return 2

    state_dir = os.path.join(OUT, "state_%s" % args.tag)
    # 【2026-09-23】自对局的 runner 必须写**自己的** HUD 状态目录。
    # runner 的 `--log-dir` 默认落在 `%APPDATA%\Godot\app_userdata\Open RTS\adjutant_logs`
    # （游戏面板读的那个 hud_status.json），不隔离的话自对局每一秒都在覆盖玩家
    # 自己那局的面板状态——用户开着游戏看副官，看到的却是训练局的"在想什么"，
    # 而且两边 runner 还会互相抢同一个权威端口。用 `AIRTS_RUNNER_HUD` 指到本局目录。
    os.environ["AIRTS_RUNNER_HUD"] = state_dir
    start_runner(state_dir, tactics_interval=15, event_interval=10,
                 strategy="plan", model="on")
    print("[selfplay] 对局开始，采样 %ds（backend=%s difficulty=%s）"
          % (args.seconds, args.backend, args.difficulty), flush=True)

    samples = []
    forces_log = []
    detail_log = []
    ## 采样失败留痕（2026-09-23）：旧实况失败时**静默丢弃**——long_66/67 两局
    ## 游戏进程在 289s/313s 自己死了（runner 侧 ConnectionResetError），harness
    ## 却照样把 deadline 跑满 600s，结果 JSON 里采样数/verdict 全停在死亡那一刻，
    ## 看起来像"打满 600s 没打完"。没有留痕就只能靠翻 runner.out 才知道真相。
    sampling_log = []
    ## 权威结算（从游戏日志读）：专用服广播结果后 5 秒主动退出，
    ## 所以"连接断开"可能是正常终局，也可能是真崩——只有日志能区分。
    match_result = ""
    game_died_at_s = None
    deadline = time.time() + args.seconds
    next_forces = 0.0
    consecutive_failures = 0
    while time.time() < deadline:
        snap = _own_snapshot()
        if "__error" not in snap and snap.get("server_tick"):
            consecutive_failures = 0
            sample = {"ts": time.time(), "tick": int(snap["server_tick"]),
                      **_forces(snap)}
            samples.append(sample)
            detail_log.append({"ts": sample["ts"], "tick": sample["tick"],
                               **_detail(snap)})
        else:
            consecutive_failures += 1
            sampling_log.append({"ts": time.time(),
                                 "error": str(snap.get("__error") or "no server_tick")})
            # 连续拿不到战术观测 = 游戏进程已经不在了。先分清是"正常终局回收"
            # 还是"真崩"：读日志里的权威结算，有结算就不是事故。
            if consecutive_failures >= 3 and not match_result:
                match_result = _match_result_from_log()
            if consecutive_failures >= 3 and game_died_at_s is None:
                if match_result:
                    print("[selfplay] 对局已结束（%s），服务端按设计回收"
                          % match_result, flush=True)
                else:
                    game_died_at_s = round(args.seconds - (deadline - time.time()), 1)
                    print("[selfplay] 游戏进程异常退出（连续 %d 次采样失败，约第 %ss），"
                          "提前收尾" % (consecutive_failures, game_died_at_s), flush=True)
                break
        if time.time() >= next_forces:
            next_forces = time.time() + 30
            fm = _match_forces()
            if "__error" not in fm and fm.get("forces"):
                forces_log.append({"ts": time.time(), "forces": fm["forces"]})
            else:
                sampling_log.append({"ts": time.time(),
                                     "error": "match_forces: %s"
                                     % str(fm.get("__error") or "empty")})
        time.sleep(10)

    # 收尾前取最后一帧战力（失败就用最后一次成功采样，不阻断收尾）。
    final = _own_snapshot()
    if "__error" in final or not final.get("server_tick"):
        final = samples[-1] if samples else {}
    final_forces = _forces(final) if final else {}
    try:
        dcs(CLIENT_PORT, {"op": "screenshot",
                          "path": os.path.join(OUT, "shot_%s.png" % args.tag)},
            timeout=30)
    except Exception:  # noqa: BLE001
        pass
    stop_runner(SERVER_PORT)
    time.sleep(2)
    kill_our_game()
    # 对局日志随 tag 留档（2026-09-23）：`selfplay_server.out` / `selfplay_client.out`
    # 每局被 truncate 覆盖，游戏进程中途死掉时**现场正好被下一局擦掉**，只能靠
    # runner.out 里的 ConnectionResetError 反推。复制一份到 state_<tag>/ 才能复盘。
    for log_name in ("selfplay_server.out", "selfplay_client.out"):
        source = os.path.join(LOGS, log_name)
        if os.path.exists(source):
            try:
                shutil.copyfile(source, os.path.join(state_dir, log_name))
            except OSError as exc:  # noqa: BLE001
                print("[selfplay] 日志留档失败 %s: %s" % (log_name, exc), flush=True)

    # 终局前再读一次权威结算：对局可能在最后一次采样之后、进程退出之前结束，
    # 那时日志里已经有结果但连接还没来得及断。
    if not match_result:
        match_result = _match_result_from_log()

    # 单位计数只在"没有权威结算"时才算（权威结算优先，见下）。
    own_total = 0
    enemy_total = 0
    last_forces = (forces_log[-1]["forces"] if forces_log
                   else _match_forces().get("forces") or {})
    for name, entry in last_forces.items():
        total = int((entry or {}).get("total", 0) or 0)
        if str(name) == "Player_0":
            own_total = total
        else:
            enemy_total += total

    # 胜负判定：**权威结算优先**（游戏自己广播的），其次才用单位计数推断。
    # 旧口径只认 forces_log 最后一条——它在终局前 30s 就停止更新了，
    # 于是"375s 全灭敌军、386s 广播胜利"会被记成 timeout（实测 r9_1）。
    if match_result:
        verdict = {"胜利": "win", "失败": "loss", "平局": "draw"}.get(
            match_result, "unknown:%s" % match_result)
    elif game_died_at_s is not None:
        # 游戏进程自己退了且日志里没有结算：这一局的任何结论都不成立，必须单记。
        verdict = "aborted"
    elif enemy_total == 0 and own_total > 0:
        verdict = "win"
    elif own_total == 0:
        verdict = "loss"
    else:
        verdict = "timeout"
    result = {
        "tag": args.tag, "backend": args.backend, "seconds": args.seconds,
        "difficulty": args.difficulty,
        "samples": len(samples),
        "first": samples[0] if samples else {},
        "last": samples[-1] if samples else {},
        "final_forces": final_forces,
        "peak_visible_enemies": max([s.get("visible_enemies", 0) for s in samples]
                                    or [0]),
        "forces_log": forces_log,
        "verdict": verdict,
        "match_result": match_result,
        "own_total": own_total,
        "enemy_total": enemy_total,
        "detail_log": detail_log,
        "sampling_log": sampling_log,
        "game_died_at_s": game_died_at_s,
    }
    path = os.path.join(OUT, "result_%s.json" % args.tag)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=1)
    print("[selfplay] 终局: verdict=%s own=%d enemy=%d units=%s balance=%s"
          % (verdict, own_total, enemy_total, final_forces.get("units"),
             final_forces.get("balance")), flush=True)
    print("[selfplay] written: %s" % path, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
