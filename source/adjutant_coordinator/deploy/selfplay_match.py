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
import math
import os
import shutil
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RECON = r"G:\AIRTS\tmp_logs\langgraph_recon"
sys.path.insert(0, RECON)

import dev_ports as PORTS  # noqa: E402

# 【端口必须在 import restart_local 之前定死】2026-09-27 实测事故：
# 原顺序是先 `import restart_local`（它按 `AIRTS_TEST_BASE` 的默认值 24569 固化
# GAME/CLIENT/SERVER 三个常量），之后才把 BASE 设成验收段 24589。
# 后果是"检查的是 24589 专用段、实际起游戏用的是 24569 面板默认段"，
# 而 `kill_our_game()` 又按端口匹配进程 ⇒ 两路并行会话会互相杀对方的局
# （dev_ports 顶部 2026-09-13 血案注释写的正是这件事）。
# 今天 3 个筛查种子报 rc=2「对局未开始」也是这个根因：客户端连上的是别人的服务器。
BASE = int(os.environ.get("AIRTS_TEST_BASE") or PORTS.acceptance_base())
os.environ["AIRTS_TEST_BASE"] = str(BASE)
_ok, _why = PORTS.check_acceptance_base(BASE)
if not _ok:
    raise SystemExit("[selfplay] " + _why)
print("[selfplay] %s" % _why, flush=True)

import restart_local as _rl  # noqa: E402
from restart_local import AI, LOGS, dcs, kill_our_game, spawn, tcp_listening  # noqa: E402
from runner_ctl import start as start_runner, stop as stop_runner  # noqa: E402

# 端口口径与 restart_local 完全一致（GAME/CLIENT/SERVER = base/+1/+3）。
GAME_PORT = _rl.GAME_PORT
CLIENT_PORT = _rl.CLIENT_PORT
SERVER_PORT = _rl.SERVER_PORT
# 自检：这三个常量必须真的是验收段的端口。若哪天 import 顺序又被改回去，
# 这里直接响，而不是安静地去连别人那一局的服务器。
if (GAME_PORT, CLIENT_PORT, SERVER_PORT) != (BASE, BASE + 1, BASE + 3):
    raise SystemExit("[selfplay] 端口段与 BASE 不一致：base=%d，实际 %d/%d/%d"
                     % (BASE, GAME_PORT, CLIENT_PORT, SERVER_PORT))
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
    """副官视角的战术观测（己方单位 + 余额 + 可见敌人 + 矿点存量）。

    【为什么要显式 `limit`】游戏侧实体窗口默认 128 条。200×200 图上光矿点就可能
    上百，默认窗口会让"全图矿量"只统计到前 128 个实体——把**截断当耗尽**是本次
    最容易造出假证据的一条路（提示词第五节明令禁止）。所以取数一律要大窗口，
    并把 `truncated` 原样记进样本，分析层据此判"这局的矿量账可不可信"。
    """
    try:
        snap = dcs(SERVER_PORT, {"op": "tactical", "as_player": "Player_0",
                                 "limit": 4096}, timeout=15)
    except Exception as exc:  # noqa: BLE001
        return {"__error": str(exc)}
    return snap or {}


def _pick_scout(snap: dict):
    """挑一个己方可移动单位去探（无人机优先）。

    【为什么不是工人】实测 fs_ref9：改派工人当侦察后，它连续三次采样都钉在
    (24.7, 29.0) 一动不动——规则副官每一拍都在给它下采集令，把玩家的移动令顶掉了。
    无人机没有经济任务，实测 100 秒内从基地走了 ~170 米到达远端矿点（fs_ref5/6/8）。
    """
    candidates = [e for e in (snap.get("entities") or [])
                  if str(e.get("kind", "")) == "unit_self"
                  and e.get("movement") or str(e.get("unit_type", "")) in ("drone", "worker")]
    for want in ("drone", "worker"):
        for entity in candidates:
            if str(entity.get("unit_type", "")) == want:
                return str(entity.get("name", ""))
    return None


def _send_move(port: int, unit_name: str, site, as_player: str = "") -> dict:
    """把单位派到给定平面坐标；回执原样返回，不解读。

    键名是 **`dest`**（`_op_move` 读 `parsed.get("dest", …)`）。这里写成 `pos`
    不会报错——服务端会拿默认值把单位派到 (0,0)，于是"侦察已就位"变成假事实，
    后面矿场被拒的原因也就全错了。调试端口的接口是弱类型字典，这类键名必须核对。

    `port` 决定走哪条命令链：客户端 = 真人玩家的转发链（回执 PendingAuthority），
    专用服 = 权威端直执行链（带 as_player 才认得出人类槽位）。
    """
    payload = {"op": "move", "units": [unit_name], "dest": [site[0], site[1]]}
    if as_player:
        payload["as_player"] = as_player
    try:
        return dict(dcs(port, payload, timeout=20) or {})
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}


def _remote_ore_site(snap: dict, footprint: float = 7.0):
    """从当前观测里挑"离自家指挥中心最远、还有矿"的矿点，给出它外侧的落点。

    只在脚本化触发**自动放置被 fog 拒掉之后**当兜底用（见调用处的注释）。
    没有可见矿点返回 None——不臆造坐标。
    """
    entities = snap.get("entities") or []
    home = None
    for entity in entities:
        if str(entity.get("kind", "")) == "unit_self" \
                and str(entity.get("unit_type", "")) == "command_center":
            pos = entity.get("pos") or []
            if len(pos) >= 2:
                home = (float(pos[0]), float(pos[1]))
                break
    best = None
    best_distance = -1.0
    for entity in entities:
        if str(entity.get("kind", "")) != "resource":
            continue
        if int(entity.get("ore_remaining") or 0) <= 0:
            continue
        pos = entity.get("pos") or []
        if len(pos) < 3:
            continue
        x, z = float(pos[0]), float(pos[2])
        distance = math.dist((x, z), home) if home else math.hypot(x, z)
        if distance > best_distance:
            best_distance = distance
            best = (x, z)
    if best is None:
        return None
    # 落在矿点**背向基地**的一侧：既贴近可采区，又避开矿场自己的避让圈。
    if home and best_distance > 1.0:
        dx = (best[0] - home[0]) / best_distance
        dz = (best[1] - home[1]) / best_distance
    else:
        dx, dz = 1.0, 0.0
    return [round(best[0] + dx * footprint, 2), round(best[1] + dz * footprint, 2)]


#: 侦察"到位"的容差（米）。落点判据是 `NotVisible`，单位站在矿点 14 米环带内即生效。
SCOUT_TOLERANCE_M = 14.0


def _entity_pos(snap: dict, unit_name: str):
    """从权威战术观测里取**己方**实体的平面坐标 (x, z)；取不到返回 None（不臆造）。

    【两个必须对准的口径】
    1. 战术观测里的 `pos` 是 `[x, y, z]`（见 `DebugControlServer._fast_diff_units`），
       而 `_remote_ore_site` 给的落点是平面的 `[x, z]`。取错下标会把高度 y 当成 z，
       于是"距离"算出 178 米这种地图对角色都没有的数字——阶段 6 第一次实测就踩到了。
    2. 只匹配 `kind == "unit_self"`：单位名会回收复用，不按阵营过滤会撞上同名敌人，
       把"侦察未到位"记成"侦察跑到 1046 米外"。
    """
    for entity in snap.get("entities") or []:
        if str(entity.get("kind", "")) != "unit_self":
            continue
        if str(entity.get("name", "")) == unit_name:
            pos = entity.get("pos") or []
            if len(pos) >= 3:
                return (float(pos[0]), float(pos[2]))
            return None
    return None


def _scout_arrival(snap: dict, unit_name: str, site) -> dict:
    """侦察是否真的到位——用**坐标**判定，不用回执。

    【为什么不能用回执】`op=move` 走客户端转发时状态恒为 `PendingAuthority`，
    把它当"已就位"会让后面每一次矿场被拒都归错因（阶段 6 实测踩过两次）。
    """
    if not unit_name or not site:
        return {"arrived": False, "reason": "no_scout"}
    pos = _entity_pos(snap, unit_name)
    if pos is None:
        return {"arrived": False, "reason": "unit_not_observed"}
    dist = math.dist(pos, (float(site[0]), float(site[1])))
    return {"arrived": dist <= SCOUT_TOLERANCE_M, "distance_m": round(dist, 1),
            "unit_xz": [round(pos[0], 1), round(pos[1], 1)]}


def _await_authority_terminal(command_id: str, timeout_s: float = 15.0,
                              scene_hint: str = "") -> dict:
    """到**专用服**复核命令终态。客户端只说 PendingAuthority，那不算权威结论。

    专用服的 `op=commands` 查的是权威端 `_command_log`（NetSync 落账），
    因此这里拿到的是 Accepted/Rejected，不是转发话术。

    【为什么要按场景回扫】客户端转发链会自己生成 `command_id`，
    服务器落账时用的键不一定还是它（实测：按 id 查 15 秒 `still_pending`，
    而矿场实体随后就出现在观测里）。查不到 id 时退一步按
    `op + scene` 找最近的终态记录，并把扫到的条数一起留痕——
    "查不到"与"根本没落账"必须是两回事。
    """
    stop = time.time() + timeout_s
    last_scan = -1
    while time.time() < stop:
        try:
            reply = dcs(SERVER_PORT, {"op": "commands",
                                      "command_id": command_id}, timeout=8) or {}
        except Exception as exc:  # noqa: BLE001
            return {"found": False, "reason": "query_failed", "error": str(exc)}
        entries = reply.get("commands") or []
        for entry in entries:
            if str(entry.get("command_id", "")) != command_id:
                continue
            status = str(entry.get("status", ""))
            if status and status != "PendingAuthority":
                return {"found": True, "status": status, "match": "command_id",
                        "reason": str(entry.get("reason", "")),
                        "subject": str(entry.get("subject", ""))}
        if scene_hint:
            # 【为什么整段包 try】这是**诊断**，不是判据。它出任何错都不许把整局取证带崩：
            # 实测 `op=commands` 不带 command_id 时返回体很大，按行读 JSON 会截断，
            # `json.loads` 直接抛 JSONDecodeError ⇒ 这一局的 result 根本没写出来。
            try:
                all_reply = dcs(SERVER_PORT, {"op": "commands"}, timeout=8) or {}
            except Exception as exc:  # noqa: BLE001
                return {"found": False, "reason": "scan_failed",
                        "error": str(exc)[:160], "scanned": last_scan}
            all_entries = all_reply.get("commands") if isinstance(all_reply, dict) else None
            if not isinstance(all_entries, list):
                return {"found": False, "reason": "scan_not_a_list", "scanned": last_scan}
            last_scan = len(all_entries)
            for entry in reversed(all_entries):
                if not isinstance(entry, dict):
                    continue
                if str(entry.get("op", "")) != "build":
                    continue
                if scene_hint not in str(entry.get("scene", "")):
                    continue
                status = str(entry.get("status", ""))
                if status and status != "PendingAuthority":
                    return {"found": True, "status": status, "match": "scene_scan",
                            "reason": str(entry.get("reason", "")),
                            "command_id": str(entry.get("command_id", "")),
                            "scanned": last_scan}
        time.sleep(1.5)
    return {"found": False, "reason": "still_pending", "scanned": last_scan}


def _refinery_entities(snap: dict) -> list:
    """权威观测里已存在的矿场实体（建成与否看 `constructed`，不看下单回执）。"""
    out = []
    for entity in snap.get("entities") or []:
        if str(entity.get("unit_type", "")) == "ore_refinery":
            out.append({"name": str(entity.get("name", "")),
                        "constructed": bool(entity.get("constructed")),
                        "refinery": entity.get("refinery") or {}})
    return out


def _economy(snap: dict) -> dict:

    """施工/矿场/矿点三张经济账（提示词第六节逐局报告项的原始事实）。



    只做透传与求和，不做推断；`truncated` 必须带上——窗口截断时矿量合计不可信。

    """

    entities = snap.get("entities") or []

    constructing = 0

    workers = 0

    refineries = []

    for entity in entities:

        if str(entity.get("kind", "")) != "unit_self":

            continue

        if entity.get("constructing"):

            constructing += 1

        if str(entity.get("unit_type", "")) == "worker":

            workers += 1

        stats = entity.get("refinery")

        if isinstance(stats, dict) and str(entity.get("unit_type", "")) == "ore_refinery":

            refineries.append({"name": str(entity.get("name", "")),

                               "constructed": bool(entity.get("constructed")),

                               "assigned": int(stats.get("assigned") or 0),

                               "takeovers": int(stats.get("takeovers") or 0),

                               "delivered": int(stats.get("delivered_count") or 0),

                               "delivered_amount": int(stats.get("delivered_amount") or 0),
                               # §6：每座矿场实际服务的矿点数（不只是"有没有矿"）。
                               "served_nodes": int(stats.get("served_nodes") or 0)})

    ore_nodes = [e for e in entities if str(e.get("kind", "")) == "resource"]
    # 再生证据（§6）：出现过耗尽的矿点数 + 全图已结算的再生轮数 + 正在等待再生的毫秒。
    ore_depleted_seen = sum(1 for e in ore_nodes if e.get("ore_depleted"))
    ore_regen_cycles = sum(int(e.get("ore_regen_cycles") or 0) for e in ore_nodes)
    ore_regen_waiting = sum(1 for e in ore_nodes
                            if int(e.get("regen_remaining_ms") or 0) > 0)
    # 玩家账户余额。`op=tactical` header 里 **`resources` 与 `balance` 两个键都在**
    # （`resources` 是副官资源白名单视图，`balance` 是完整视图；实测同一局两处读数
    # 一致：resources 路径拿到 34400、balance 路径拿到 37600，是不同时刻不是不同口径）。
    # 这里取 `balance`，与 `_forces()` 终局打印同口径，避免两处报告用两种数。
    # 【原先真正的错】旧 `peak_balance` 读的是 `forces_log` 条目里的 `balance`，
    # 而 `forces_log` 只存 `{"ts","forces"}`——余额在采样时就被丢掉了，所以恒为 0。
    # 这不是"矿被采出"的同义词：§7 要的是钱到账。
    balance = snap.get("balance") or {}
    return {
        "balance_a": int(balance.get("a") or 0),
        "constructing": constructing,

        "workers": workers,

        "refineries": refineries,

        "ore_nodes": len(ore_nodes),

        "ore_depleted": sum(1 for e in ore_nodes if e.get("ore_depleted")),

        "ore_depleted_seen": ore_depleted_seen,

        "ore_regen_cycles": ore_regen_cycles,

        "ore_regen_waiting": ore_regen_waiting,

        "ore_remaining": sum(int(e.get("ore_remaining") or 0) for e in ore_nodes),

        "ore_capacity": sum(int(e.get("ore_capacity") or 0) for e in ore_nodes),

        "truncated": bool(snap.get("truncated")),

        "cw_seconds": snap.get("construction_worker_seconds") or {},

    }





def _fixed_match_args(args) -> list:
    """把 --map/--seed 翻成游戏侧命令行参数；未指定就不加（保持旧行为逐字一致）。"""
    extra = []
    if args.map:
        extra += ["--map", args.map]
    if args.seed:
        extra += ["--seed", str(args.seed)]
    return extra


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
    # 固定地图/固定种子（阶段 6 回归入口）。种子灌的是**权威进程**的全局 RNG，
    # 所以下面会把它同时传给专用服那一条命令行——只给客户端传是无效凭据。
    parser.add_argument("--map", default="",
                        help="固定地图 res:// 路径（必须登记在 Constants.Match.ALL_MAPS）")
    parser.add_argument("--seed", type=int, default=0,
                        help="固定全局 RNG 种子，0 = 不干预（游戏默认）")
    parser.add_argument("--refinery-at", type=int, default=-1,
                        help="开局 N 秒后脚本化建一座远端矿场（-1 = 不建，纯看副官主线）")
    parser.add_argument("--boot-budget", type=float, default=240.0,
                        help="引擎冷启动/大厅/开局的等待预算（秒）。同机并发跑回归时 50 秒不够，"
                             "会把「机器忙」报成「这局没结果」（假阴性）")
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
    fixed_args = _fixed_match_args(args)
    spawn(["--headless", "--path", AI, "--",
           "--server", "--port", str(GAME_PORT), "--debugport", str(SERVER_PORT)] + fixed_args,
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
           "--smokehost", "127.0.0.1", "--smokeport", str(GAME_PORT)] + fixed_args,
          "selfplay_client.out")
    # 【就绪预算为什么要按并发环境定】2026-09-27 的 5 筛查种子里有 3 局 rc=2，
    # 原因不是产品坏了，而是同一台机器上另一路会话在跑 perfgrid/冒烟回归，
    # 引擎冷启动（含导航异步烘焙）超过了原来 25×2s=50 秒的窗口。
    # 采集入口把"机器忙"报成"这一局没结果"，就是在制造假阴性，所以预算放宽到可配、
    # 并且失败时把**等了多久、卡在哪一步**写进日志。
    boot_budget = float(args.boot_budget)
    ok = False
    waited = 0.0
    while waited < boot_budget:
        time.sleep(2)
        waited += 2
        if tcp_listening(CLIENT_PORT):
            ok = True
            break
    if not ok:
        print("[selfplay] 客户端未就绪：等 %.0fs 后端口 %d 仍未监听"
              % (waited, CLIENT_PORT), flush=True)
        kill_our_game()
        return 2

    # 等大厅就绪（客户端连上网、拿到槽位）后再开局——否则 op=start 报 not networked。
    lobby_ready = False
    waited = 0.0
    while waited < boot_budget:
        time.sleep(2)
        waited += 2
        try:
            lobby = dcs(CLIENT_PORT, {"op": "lobby"}, timeout=8) or {}
        except Exception:  # noqa: BLE001
            continue
        if lobby.get("slots"):
            lobby_ready = True
            print("[selfplay] 大厅就绪: %s（等 %.0fs）" % (str(lobby.get("local_name")), waited),
                  flush=True)
            break
    if not lobby_ready:
        print("[selfplay] 大厅未就绪：等 %.0fs 仍拿不到 slots" % waited, flush=True)
        kill_our_game()
        return 2

    # 开局：**with_ai=True**（真的电脑对手）；passive=False（它会主动进攻）。
    started = dcs(CLIENT_PORT, {"op": "start", "with_ai": True,
                                "passive_ai_test": False}, timeout=30)
    print("[selfplay] op=start -> %s" % str(started)[:160], flush=True)
    if not _wait_match(timeout_s=boot_budget):
        print("[selfplay] 对局未开始：等 %.0fs 客户端 status 里没有 match" % boot_budget, flush=True)
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
    # 验收场景「远端专门矿场」的脚本化触发（提示词 §6「远端矿场」）。
    # 之所以要这个开关：纯规则副官在 150 秒窗口里走不到 M08，于是"矿场能建、会接管
    # 工人、交货进账户"这三件事在一局真实对局里一次也没被观测到——只有冒烟夹具里有。
    #
    # 【为什么重写成状态机、并且每一步换一种判据】
    # 上一版把**客户端回执**当事实：`op=move` 与 `op=build` 经客户端转发时状态恒为
    # `PendingAuthority`，于是"侦察已就位""权威已接受"都是没有依据的推断，
    # 断点定位连着两次归错因（阶段 6 报告第四节）。现在：
    #   就位 → 权威观测里的**坐标**
    #   接受 → 专用服 `op=commands` 里的**命令终态**
    #   建成 → 权威观测里真的出现 `ore_refinery` 实体
    #   收入 → 矿场交付计数与账户余额（由 match_metrics 结算，不在这里判）
    match_started_at = time.time()
    refinery_sent = None
    refinery_scout = None
    refinery_tries = 0
    refinery_stage = "scout"
    refinery_rearm = 0
    refinery_builds: list = []
    refinery_observed = None
    refinery_next_try = float(args.refinery_at)
    while time.time() < deadline:
        elapsed = round(time.time() - match_started_at, 1)
        if args.refinery_at >= 0 and refinery_stage != "done" \
                and elapsed >= refinery_next_try:
            snap0 = _own_snapshot()
            site = _remote_ore_site(snap0)
            if refinery_stage == "scout":
                # `auto=resource` 的锚点必须是**已探明**矿点，开局头几十秒侦察还没铺出去，
                # 那时有矿点候选才有意义。只发一次会把"时机未到"记成"矿场建不起来"，
                # 那是个假阴性，所以要重试并留痕。
                scout = _pick_scout(snap0)
                if site and scout:
                    refinery_scout = {
                        "site": site, "unit": scout, "sent_at_s": elapsed,
                        "via_player_link": _send_move(CLIENT_PORT, scout, site)}
                    print("[selfplay] 矿场前置：派 %s 到 %s -> %s"
                          % (scout, site, str(refinery_scout["via_player_link"])[:120]),
                          flush=True)
                    refinery_stage = "arrive"
                else:
                    print("[selfplay] 矿场前置：可见远端矿点=%s 可动单位=%s，10s 后重试"
                          % (bool(site), scout), flush=True)
                refinery_next_try = elapsed + 10.0
            elif refinery_stage == "arrive":
                arrival = _scout_arrival(snap0, str((refinery_scout or {}).get("unit") or ""),
                                         (refinery_scout or {}).get("site"))
                refinery_scout["arrival"] = arrival
                print("[selfplay] 矿场前置：侦察 %s -> %s"
                      % (refinery_scout.get("unit"), arrival), flush=True)
                waited = elapsed - float(refinery_scout.get("sent_at_s") or 0.0)
                if arrival.get("arrived"):
                    refinery_scout["arrived_at_s"] = elapsed
                    refinery_stage = "build"
                elif arrival.get("reason") == "unit_not_observed" and refinery_rearm < 2:
                    # 侦察单位半路阵亡（实测 fs_ref7：无人机在远端矿区被击落）。
                    # 视野随单位一起没了，此时发建造只会拿到 NotVisible/SurfaceNotBuildable，
                    # 把"脚本触发脆弱"误记成"产品建不出矿场"。换人换点重来。
                    refinery_rearm += 1
                    refinery_stage = "scout"
                    print("[selfplay] 矿场前置：侦察单位丢失，重新选人重探（第 %d 次）"
                          % refinery_rearm, flush=True)
                elif waited > 60.0 and "via_authority" not in refinery_scout:
                    # 真人链路 60 秒没把单位挪到位：再问权威端直执行一次，仍然用坐标验收。
                    # 两条链都留回执，归因时才分得清是命令链断了还是产品规则如此。
                    refinery_scout["via_authority"] = _send_move(
                        SERVER_PORT, str(refinery_scout.get("unit")),
                        refinery_scout.get("site"), as_player="Player_0")
                    print("[selfplay] 矿场前置：改走权威端直执行 -> %s"
                          % str(refinery_scout["via_authority"])[:160], flush=True)
                elif waited > 150.0:
                    refinery_scout["blocked"] = "scout_never_arrived"
                    refinery_stage = "done"
                refinery_next_try = elapsed + 10.0
            elif refinery_stage == "build":
                if refinery_tries >= 8:
                    refinery_scout.setdefault("blocked", "build_never_accepted")
                    refinery_stage = "done"
                else:
                    refinery_tries += 1
                    site = _remote_ore_site(snap0) or (refinery_scout or {}).get("site")
                    payload = {"op": "build",
                               "scene": "res://source/match/units/OreRefinery.tscn",
                               # 与同局已成功的分基地同口径（14 米是调试入口写死的默认值）。
                               "max_radius_meters": 48.0}
                    # 【落点策略按实测排，不再靠推测】
                    #   fs_ref6：不带 hint 的 auto → 权威端 Accepted，真的建出 Unit_75；
                    #   fs_ref7：脚本按矿点外侧 7 米算的显式落点 → 连着 `SurfaceNotBuildable`；
                    #   fs_ref8：`auto=resource` + 最远矿点 hint → 反复 `NoValidSite`。
                    # 结论：落点交给权威端自己搜（人类玩家也是"把单位开到那儿就地右键"，
                    # 由游戏找那块合法地面），脚本只负责"先探开、再下单、逐次留原因"。
                    payload["auto"] = "resource"
                    mode = "auto"
                    try:
                        attempt = dict(dcs(CLIENT_PORT, payload, timeout=20) or {})
                    except Exception as exc:  # noqa: BLE001
                        attempt = {"ok": False, "status": "Exception", "error": str(exc)}
                    attempt["mode"] = mode
                    attempt["authority"] = _await_authority_terminal(
                        str(attempt.get("command_id") or ""), scene_hint="OreRefinery")
                    # 命令账查不到不等于没建成：矿场实体出现在权威观测里就是直接证据，
                    # 而且它比任何回执都硬（提示词禁止用 Accepted 回执替代完工事实）。
                    attempt["observed"] = _refinery_entities(snap0)
                    refinery_builds.append({
                        "try": refinery_tries, "at_s": elapsed, "mode": mode,
                        "site": site, "payload_pos": payload.get("pos"),
                        "client_status": attempt.get("status"),
                        "client_detail": str(attempt.get("detail") or attempt.get("reason") or "")[:80],
                        "authority": attempt["authority"],
                        "observed": attempt["observed"]})
                    print("[selfplay] 矿场建造第 %d 次（%s）客户端=%s 权威=%s 观测=%s"
                          % (refinery_tries, mode,
                             str(attempt)[:90],
                             json.dumps(attempt["authority"], ensure_ascii=False),
                             str(attempt["observed"])[:120]), flush=True)
                    if (attempt["authority"].get("status") == "Accepted"
                            or attempt["observed"]):
                        refinery_stage = "verify"
                    elif attempt["authority"].get("status") == "Rejected" and refinery_tries >= 6:
                        # 同一位置反复被拒就不再多试；原因已经逐条落在 refinery_builds 里。
                        refinery_stage = "done"
                    refinery_next_try = elapsed + 10.0
            elif refinery_stage == "verify":
                found = _refinery_entities(snap0)
                if found:
                    refinery_observed = {"first_seen_s": elapsed, "entities": found}
                    print("[selfplay] 矿场已出现在权威观测：%s" % str(found)[:200], flush=True)
                    refinery_stage = "done"
                elif refinery_tries >= 8:
                    refinery_stage = "done"
                refinery_next_try = elapsed + 10.0
        snap = _own_snapshot()
        if "__error" not in snap and snap.get("server_tick"):
            consecutive_failures = 0
            sample = {"ts": time.time(), "tick": int(snap["server_tick"]),
                      **_forces(snap)}
            samples.append(sample)
            detail_log.append({"ts": sample["ts"], "tick": sample["tick"],
                               **_detail(snap), **_economy(snap)})
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

    # 矿场触发小结：判据是**权威命令终态 + 权威观测里的矿场实体**，不是客户端回执。
    # `accepted` 只有在服务器把这条命令落成 Accepted 时才为真；
    # 全部被拒时 `builds` 里留着的是一手原因，供 §6 的失败归因列使用。
    refinery_sent = {
        "tries": refinery_tries,
        "stage": refinery_stage,
        "builds": refinery_builds,
        "accepted": any((item.get("authority") or {}).get("status") == "Accepted"
                        for item in refinery_builds),
        "history": [str(item.get("client_status")) for item in refinery_builds],
    }
    last_snap = _own_snapshot()
    if "__error" not in last_snap:
        refinery_observed = {"final_entities": _refinery_entities(last_snap),
                             **(refinery_observed or {})}
    # `accepted` 有两条独立依据：权威命令终态 Accepted，或观测里真的出现了矿场实体。
    # 后者更强（提示词明令不得用回执替代完工事实），前者查不到时仍要留 `still_pending` 痕。
    refinery_sent["observed_entities"] = (refinery_observed or {}).get("final_entities")
    refinery_sent["accepted"] = bool(
        refinery_sent["accepted"] or (refinery_observed or {}).get("final_entities"))

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
        "map": args.map, "seed": args.seed,
        # 脚本化矿场的**原始回执**（不解读）：拒了就照实写，报告层据此区分
        # "没尝试建矿场"与"建了但被权威端拒绝"。
        "refinery_receipt": refinery_sent,
        "refinery_at_s": args.refinery_at,
        "refinery_scout": refinery_scout,
        # 权威观测里矿场实体的出现时刻与计数——"建成"的唯一直接证据。
        "refinery_observed": refinery_observed,
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
