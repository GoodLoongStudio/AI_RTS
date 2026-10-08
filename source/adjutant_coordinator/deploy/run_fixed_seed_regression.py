# -*- coding: utf-8 -*-
"""固定地图 / 固定种子的对局扫描与回归驱动器（执行提示词 §6「逐局报告」入口）。

## 为什么要有这个文件

阶段 0 核查报告记的硬断点之一是**今天没有固定种子对局入口**：
`selfplay_match.py` 能跑一局，但既不能钉图、也不能钉种子，跑 10 局只能得到
10 个互不可比的样本。提示词 §6 要的恰恰是"同一张图、指定种子、逐局一张表"，
所以缺的不是分析能力，是**可重复的采集入口**。

## 与"假证据"的三条硬规矩

1. **种子必须落在权威进程**。`selfplay_match.py` 把 `--map/--seed` 同时传给专用服
   与客户端；真正生效的是服务器侧 `_launch_match()`（全局 RNG 只在权威模拟一侧决定
   结果）。所以本脚本绝不调用 `op=start` 的 seed 字段——客户端那条路径已被游戏侧
   直接拒绝（`FixedMatchOnServerOnly`），不静默接受。
2. **表里的缺失写 None，不写 0**。"没有矿场"与"矿场没被统计到"必须是两回事。
3. **实体窗口被截断的局要单独标出来**（`entities_truncated`）。截断时全图矿量只是
   部分和，拿它当"矿已耗尽"的证据就是伪造。

用法：
    # 5 个筛选种子，每个 180 秒，纯规则后端（不需要模型，先确认闭环活着）
    python -m adjutant_coordinator.deploy.run_fixed_seed_regression \\
        --map res://source/match/maps/PlainAndSimple.tscn \\
        --seeds 11,22,33,44,55 --seconds 180 --backend off --tag fs_screen

    # 10 局回归 + 汇总表
    python -m adjutant_coordinator.deploy.run_fixed_seed_regression \\
        --map ... --seeds ... --tag fs_reg --out G:/AIRTS/AI_RTS/build/selfplay

输出：`<out>/sweep_<tag>.json`（逐局指标）+ `<out>/sweep_<tag>.md`（§6 表）。
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

DEPLOY_DIR = os.path.dirname(os.path.abspath(__file__))
AI_ROOT = os.path.abspath(os.path.join(DEPLOY_DIR, "..", "..", ".."))

#: §6 逐局报告要求的列。顺序即表格顺序；取不到就是 None（**不补 0**）。
COLUMNS = (
    ("tag", "局标"),
    ("map", "地图"),
    ("seed", "种子"),
    ("verdict", "权威结算"),
    ("duration_s", "时长(s)"),
    ("worker_seconds_on_construction", "Worker 施工占用(s)"),
    ("constructing_workers_peak", "施工中 Worker 峰值"),
    ("first_barracks_t", "首座兵营建成(s)"),
    ("first_refinery_placed_t", "矿场放置(s)"),
    ("first_refinery_takeover_t", "首次接管 Worker(s)"),
    ("first_refinery_delivery_t", "首次交付(s)"),
    ("refinery_delivered_amount", "矿场交付矿量"),
    ("ore_nodes", "矿点数"),
    ("ore_remaining_first", "开局全图矿量"),
    ("ore_remaining_last", "终局全图矿量"),
    ("ore_depleted_nodes", "耗尽矿点数"),
    ("ore_depleted_ever_nodes", "曾耗尽矿点数"),
    ("ore_regen_cycles", "再生结算轮数"),
    ("ore_regen_waiting_nodes", "等待再生矿点数"),
    ("entities_truncated", "实体窗口截断"),
    ("refinery_trigger", "矿场触发"),
    ("balance_first", "开局余额"),
    ("balance_last", "终局余额"),
    ("balance_grew", "余额有增长"),
    ("first_attack_move_t", "首次有效出击(s)"),
)


def _run(cmd: list) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    return subprocess.run(cmd, cwd=AI_ROOT, env=env, timeout=7200,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def _selfplay_result_dir() -> str:
    """驱动脚本真正写 `result_<tag>.json` 的目录（从它自己拿，不在这里猜路径）。

    【为什么】`selfplay_match.OUT` 指向 `%TMP%\\langgraph_recon\\selfplay`，和报告输出目录
    不是一回事。硬编码一份副本，改了任一边就会出现"跑完 10 局、汇总表 10 行全是
    no result json"——看着像回归失败，其实是路径漂移。
    """
    if DEPLOY_DIR not in sys.path:
        sys.path.insert(0, DEPLOY_DIR)
    import selfplay_match  # noqa: PLC0415  只为拿 OUT 常量，main 有 __name__ 保护
    return str(selfplay_match.OUT).replace("\\", "/")


def _num(value):
    """把 None/数值原样留着，其余强转 float；失败也留 None（不造假数据）。"""
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _cell(value) -> str:
    if value is None:
        return "None"
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, float):
        return ("%g" % value)
    return str(value)


def run_one(tag: str, map_path: str, seed: int, seconds: int,
            backend: str, refinery_at: int, boot_budget: float = 240.0) -> dict:
    """跑一局并把 `result_*.json` 过一遍 `match_metrics`，返回 §6 表的一行。"""
    driver = os.path.join(DEPLOY_DIR, "selfplay_match.py")
    analyser = os.path.join(DEPLOY_DIR, "match_metrics.py")
    cmd = [sys.executable, driver, "--tag", tag, "--seconds", str(seconds),
           "--backend", backend, "--map", map_path, "--seed", str(seed),
           "--refinery-at", str(refinery_at), "--boot-budget", str(boot_budget)]
    started = time.time()
    proc = _run(cmd)
    row = {"tag": tag, "map": map_path, "seed": seed,
           "driver_returncode": proc.returncode}
    result_path = os.path.join(_selfplay_result_dir(), "result_%s.json" % tag)
    if not os.path.exists(result_path):
        # 【为什么必须带驱动输出尾部】§6 要求逐局给出"失败/拒绝/中断原因"。
        # 原先这里只写 `no result json (driver rc=2)`，而驱动的子进程输出被 PIPE 吞掉了，
        # 于是"引擎冷启动被同机会话挤爆"和"对局真的崩了"在表里长得一模一样。
        tail = (proc.stdout or b"")[-1200:].decode("utf-8", "replace").strip().splitlines()
        row["error"] = "no result json at %s (driver rc=%s)" % (result_path, proc.returncode)
        row["driver_tail"] = tail[-6:]
        return row
    with open(result_path, encoding="utf-8") as handle:
        result = json.load(handle)
    row["verdict"] = result.get("verdict")
    # 触发回执原样进表（`未触发` / `accepted` / 被拒状态列表）。没有这一列，
    # "矿场三列全是 None"就分不清是"没试"还是"试了一直被拒"。
    row["refinery_trigger"] = _trigger_label(result.get("refinery_receipt"))
    row["duration_s"] = round(max(0.0, time.time() - started), 1)
    analyse = _run([sys.executable, analyser, result_path])
    try:
        metrics = json.loads(analyse.stdout.decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        row["error"] = "metrics output not json: %s" % analyse.stdout[:200]
        return row
    economy = metrics.get("economy") or {}
    for key in ("worker_seconds_on_construction", "first_refinery_placed_t",
                "first_refinery_takeover_t", "first_refinery_delivery_t",
                "refinery_delivered_amount", "ore_nodes", "ore_remaining_first",
                "ore_remaining_last", "ore_depleted_nodes",
                "ore_depleted_ever_nodes", "ore_regen_cycles",
                "ore_regen_waiting_nodes"):
        row[key] = economy.get(key)
    row["constructing_workers_peak"] = economy.get("constructing_workers_peak")
    row["entities_truncated"] = economy.get("entities_truncated")
    row["first_attack_move_t"] = metrics.get("first_attack_move_t")
    for key in ("balance_first", "balance_last", "balance_peak", "balance_grew"):
        row[key] = economy.get(key)
    # 兵营完工时刻只从实体明细取（见 `_barracks_time`），不用下单/回执替代。
    row["first_barracks_t"] = _barracks_time(result)
    row["economy_error"] = economy.get("error")
    return row


def _trigger_label(receipt) -> str:
    if not receipt:
        return "未触发"
    if receipt.get("accepted"):
        return "accepted(%d 次)" % int(receipt.get("tries") or 0)
    return "被拒 %s" % (receipt.get("history") or [receipt.get("last")])


def _barracks_time(result: dict):
    """兵营**完工**时刻：detail_log 里第一个 type=barracks 且 hp>0 的采样点。

    取不到就返回 None。绝不用"下令时刻"或"回执 Accepted"替代——提示词明令
    禁止把一次 `Accepted` 当成完工证据。
    """
    for sample in result.get("detail_log") or []:
        for unit in sample.get("own") or []:
            if str(unit.get("type")) == "barracks":
                return round(float(sample.get("ts", 0.0))
                             - float(result.get("first", {}).get("ts", 0.0) or 0.0), 1)
    return None


def render_markdown(rows: list, notes: list) -> str:
    lines = ["# 固定种子对局逐局报告（执行提示词 §6）", ""]
    lines.append("| " + " | ".join(label for _, label in COLUMNS) + " |")
    lines.append("|" + "|".join(["---"] * len(COLUMNS)) + "|")
    for row in rows:
        lines.append("| " + " | ".join(_cell(row.get(key)) for key, _ in COLUMNS) + " |")
    lines.append("")
    lines.append("## 读表须知")
    for note in notes:
        lines.append("- %s" % note)
    return "\n".join(lines) + "\n"


def run_one_with_retry(tag: str, map_path: str, seed: int, seconds: int,
                       backend: str, refinery_at: int, boot_budget: float,
                       retries: int) -> dict:
    """跑一局，失败就原地重试。

    【为什么必须有】这台机器上同时有另一路会话在跑它自己的回归，
    而两边的收尾都**按进程树清理**——实测我的一局在 t+75s 被整棵带走
    （驱动没崩、没有 traceback，只是进程没了，`result_<tag>.json` 自然也没写出来）。
    端口段（24589/24609 两段）本身不冲突，冲突的是进程树清理。
    一次外部干扰不该让 §6 的表少一行，所以允许同种子重跑；
    但只重试 `retries` 次，避免真的坏了时无限打转。
    """
    row = run_one(tag, map_path, seed, seconds, backend, refinery_at, boot_budget)
    for attempt in range(1, retries + 1):
        if not row.get("error"):
            return row
        print("[sweep] %s 第 %d 次重试（上次：%s）"
              % (tag, attempt, str(row.get("error"))[:120]), flush=True)
        row = run_one("%s_r%d" % (tag, attempt), map_path, seed, seconds,
                      backend, refinery_at, boot_budget)
        if not row.get("error"):
            row["tag"] = tag          # 表里仍按种子记账，重试后缀只用于文件命名
            row["retried"] = attempt
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description="固定地图/固定种子对局扫描与回归")
    parser.add_argument("--map", required=True,
                        help="固定地图 res:// 路径（必须登记在 Constants.Match.ALL_MAPS）")
    parser.add_argument("--seeds", required=True, help="逗号分隔的种子列表，如 11,22,33")
    parser.add_argument("--seconds", type=int, default=180)
    parser.add_argument("--backend", default="off", choices=("laya", "model", "off"))
    parser.add_argument("--tag", default="fs")
    parser.add_argument("--refinery-at", type=int, default=-1,
                        help="开局 N 秒后脚本化触发远端矿场（-1 = 只看副官主线自己走不走）")
    parser.add_argument("--boot-budget", type=float, default=240.0,
                        help="透传给驱动的启动预算（同机并发跑回归时必需放宽）")
    parser.add_argument("--retries", type=int, default=1,
                        help="同一粒种子失败后的原地重试次数（默认 1 次）。"
                             "并行会话按进程树清理会偶发带走本局，一次干扰不该让表少一行")
    parser.add_argument("--out", default=os.path.join(AI_ROOT, "build", "selfplay"))
    args = parser.parse_args()

    seeds = [int(item) for item in args.seeds.replace(" ", "").split(",") if item]
    if not seeds:
        print("没有种子", flush=True)
        return 2
    out_dir = args.out.replace("\\", "/")
    os.makedirs(out_dir, exist_ok=True)
    # 种子 0 是"不干预"哨兵，不能当固定种子用。
    if 0 in seeds:
        print("种子列表含 0（=不干预，不是固定种子），请改用非 0 值", flush=True)
        return 2

    rows = []
    for seed in seeds:
        tag = "%s_%d" % (args.tag, seed)
        print("[sweep] 开始 %s map=%s seed=%d" % (tag, args.map, seed), flush=True)
        row = run_one_with_retry(tag, args.map, seed, args.seconds, args.backend,
                                 args.refinery_at, args.boot_budget, args.retries)
        rows.append(row)
        print("[sweep] 结束 %s -> %s" % (tag, json.dumps(
            {k: row.get(k) for k in ("verdict", "worker_seconds_on_construction",
                                     "refinery_delivered_amount", "error")},
            ensure_ascii=False)), flush=True)
        # 失败原因必须跟着行进日志，否则表里只有一行"error"，归因又要靠猜。
        if row.get("driver_tail"):
            for line in row["driver_tail"]:
                print("[sweep]   驱动输出 | %s" % line, flush=True)

    notes = [
        '`None` = 该项没测到，**不是** 0，也不是"没发生"。',
        "`Worker 施工占用(s)` 的目标值是 0.0；非 0 即本次改造回归。",
        '`实体窗口截断=是` 的局，全图矿量只是窗口内部分和，不得引用为"矿已耗尽"。',
        "`首次交付(s)` 为空只说明这一局没走到矿场交付，不等于矿场功能失效——"
        "结论要看阶段 2/3 的专项冒烟测试。",
        "种子灌的是权威进程的全局 RNG（单位出生散布/增强卡抽取/随机挑选目标）；"
        "帧调度与网络时序带来的非确定不在其覆盖范围，因此本表不宣称逐帧可复现。",
    ]
    payload = {"map": args.map, "seeds": seeds, "seconds": args.seconds,
               "backend": args.backend, "rows": rows}
    json_path = os.path.join(out_dir, "sweep_%s.json" % args.tag)
    md_path = os.path.join(out_dir, "sweep_%s.md" % args.tag)
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=1)
    with open(md_path, "w", encoding="utf-8") as handle:
        handle.write(render_markdown(rows, notes))
    print("[sweep] %d 局，表 -> %s" % (len(rows), md_path), flush=True)
    failed = [row for row in rows if row.get("error")]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
