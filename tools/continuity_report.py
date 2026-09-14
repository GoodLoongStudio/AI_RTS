# -*- coding: utf-8 -*-
"""大规模作战的**连续性验收**（取代"平均协调频率"当目标）。

## 为什么换口径（用户 2026-09-13 原话）

> 常规协调约 2Hz 只是参考节拍。大规模战场允许约 2 秒一轮协调与批量控制，
> 不要求每秒给每个单位下新命令。验收重点是多个编队和生产设施同时持续工作、
> 生产及时接续、已有任务不中断、各线路不长期饿死、关键事件及时响应。
> 只发送变化意图，不能为凑频率重复下令，也不能用"允许 2 秒"掩盖积压、断线或无故停产。

所以本模块量的是**行为连续性**，不是频率：

| 验收点 | 事实来源 | 判据 |
|---|---|---|
| 多编队 + 多设施同时工作 | 每轮 `lanes[*].tasks`（各线活跃任务）+ `fast_production_busy`（在产设施数） | 后半程 ≥60% 的轮次并行工作流 ≥3 |
| 生产及时接续 | `fast_production_busy/items` 时间序列 | 后半程在产占比 ≥60%，且最长空转 ≤20s |
| 已有任务不中断 | `intent_dropped` 决策 + `preempted_by_emergency`/`player_override` 白名单 | 非白名单的"任务中途消失" = 0 |
| 各线路不长期饿死 | `lane_starved` 决策 + 各线 `idle_ticks` | 饿死事件 = 0，且单线最长无服务 ≤ 上限 |
| 关键事件及时响应 | `fast_events_consumed.lag_max`（事件发生→本轮处理）+ 扫描层 `event_latency_*` | p95 ≤ 3s、max ≤ 10s |
| 只发变化意图 | 每轮 `accepted` 序列 | **重复下发 = 0**（重复被仲裁层挡掉是好事，单独报） |

并且**不许用"允许 2 秒"掩盖问题**：单轮静默（`gap_max`）、平均节拍（`hz_avg`）、
在途未结算（`pending_authority_unresolved`）、批量截断（`batch_limit_exceeded`）、
降级轮占比，全部单列并设上限。

用法：

    python tools/continuity_report.py <runner.out> [--samples short_x.json] [--gate]
"""

import argparse
import io
import json
import os
import re
import sys

#: 允许的**最慢**节拍：约 2 秒一轮是战场规模下的正常值，2.5 秒是"还没坏"的下限。
MIN_COORD_HZ = 0.4
#: 单轮静默上限（秒）：协调线程**不许**出现比它更长的空档（断线/卡死/被阻塞）。
MAX_ROUND_GAP_S = 3.0
#: 后半程并行工作流下限（经济/建造/侦察/军事/生产设施 里同时有活的数量）。
MIN_PARALLEL_WORKSTREAMS = 3
MIN_PARALLEL_RATIO = 0.6
#: 后半程"有设施在产"的轮次占比下限 + 单设施最长空转（秒）。
MIN_PRODUCTION_BUSY_RATIO = 0.6
MAX_PRODUCTION_IDLE_S = 20.0
#: 关键事件响应：事件发生 → 被某轮处理（秒）。
MAX_EVENT_LAG_P95_S = 3.0
MAX_EVENT_LAG_MAX_S = 10.0
#: 扫描层事件时延（游戏 → runner 10Hz 扫描）上限（秒）。
MAX_SCAN_EVENT_LATENCY_P95_S = 0.5
#: 任一线路"有活却长期没被服务"的上限（tick，900 = 15s，与 `lanes.STARVE_TICKS` 同口径）。
MAX_LANE_IDLE_TICKS = 900
#: 后半程"这条线有活在干"的轮次占比下限（经济/建造/军事三条线各自都要达到）。
MIN_LANE_ACTIVE_RATIO = 0.7
#: 降级轮占比上限（降级本身合法，但大面积降级说明依赖在恶化）。
MAX_DEGRADED_RATIO = 0.25

TICK_HZ = 60.0

#: 任务中途消失的**合法**原因（其余一律算"无故中断"，要报出来）。
LEGIT_DROP_PREFIXES = (
    "lease_owner_player",          # 玩家接管：本来就该停
    "player_override",             # 同上（意图级）
    "preempted_by_emergency",      # 紧急事件抢占：计划 §5 明确允许
    "expired",                     # TTL 到期：任务已经跑满，不算中断
    "completed", "arrived",        # 干完了
    "duplicate_of", "intent_already_tracked",   # 重复下令被挡（这是**纪律生效**的证据）
)
#: 明确算**积压**的原因（不是"任务中断"，是"排队排不下/在途没结算"）。
BACKLOG_REASONS = ("batch_limit_exceeded", "pending_authority_unresolved")


def _percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(float(v) for v in values)
    index = min(len(ordered) - 1, max(0, int(round(q * (len(ordered) - 1)))))
    return ordered[index]


def read_records(path):
    """读 runner 的结构化日志（一行一条 JSON，允许前缀噪声）。"""
    out = []
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            index = line.find("{")
            if index < 0:
                continue
            try:
                out.append(json.loads(line[index:]))
            except ValueError:
                continue
    return out


def _intent_key(intent):
    """命令指纹：动作 + 单位集合 + **具体对象**（生产项/工地/位置）——"同一条命令"的唯一口径。

    【为什么要带"具体对象"（2026-09-13 实测踩到两类假警报）】
    只看"动作+单位+场景"会把下面两件事误判成重复下令：
    ① **新建工地 vs 续建同一工地**：`rule-build-barracks-Unit_3`（新建）与
       `rule-finish-site-Unit_13`（续建已有工地）在同一批出现 —— 目标不同（一个是落点、
       一个是已存在的实体），是**两件不同的事**；
    ② **生产接续**：同一座兵营产完一个兵再产下一个，动作/单位/场景全一样，但**生产项 id 不同**
       （`production.item_id`）—— 这是本职接续，不是"为凑频率重下"。
    所以指纹里必须带上 `production.item_id`（有则用）或目标的 `entity_id`/落点。
    """
    target = intent.get("target") if isinstance(intent.get("target"), dict) else {}
    production = intent.get("production") if isinstance(intent.get("production"), dict) else {}
    # 两种形状都要认：活意图（`production.item_id`）与**归档压缩后的**（扁平 `item_id`）。
    item_id = str(production.get("item_id", "")) or str(intent.get("item_id", ""))
    pos = target.get("pos") or []
    if item_id:
        where = "item:%s" % item_id
    elif len(pos) >= 2:
        where = "%.1f,%.1f" % (float(pos[0]), float(pos[1]))
    else:
        where = str(target.get("entity_id") or target.get("site")
                    or target.get("producer") or target.get("scene") or "")
    return "%s|%s|%s" % (str(intent.get("action", "")),
                         ",".join(sorted(str(u) for u in (intent.get("unit_ids") or []))),
                         where)


def _rounds(records):
    return [record for record in records if str(record.get("kind")) == "tick"]


def _decisions(records, kind):
    return [record["decision"] for record in records
            if str(record.get("kind")) == "decision"
            and isinstance(record.get("decision"), dict)
            and str(record["decision"].get("kind", "")) == kind]


def analyze(records, *, samples=None, warmup_ratio=0.5, archive=""):
    """把一次运行的日志压成"连续性六项 + 不许掩盖的四项 + 命令纪律"。纯函数，可单测。

    `archive` = 该局的命令档案目录（含 `commands.jsonl`/`rounds.jsonl`）。
    不给就跳过命令纪律段（旧日志/单测场景），**不编 0**。
    """
    rounds = _rounds(records)
    scans = [record for record in records if str(record.get("kind")) == "fast_scan"]
    problems = []
    #: 事实缺失（旧 runner / 旧日志）→ **单列并计入判定**，不许静默当通过。
    unknowns = []
    if not rounds:
        return {"problems": ["没有协调轮次记录（runner 没跑起来？）"], "rounds": 0}

    # ---------------- ① 节拍：只做参考，抓"静默/断线" ----------------
    stamps = [float(record.get("ts", 0) or 0) for record in rounds if record.get("ts")]
    gaps = [b - a for a, b in zip(stamps, stamps[1:])]
    span = (stamps[-1] - stamps[0]) if len(stamps) >= 2 else 0.0
    hz_avg = (len(stamps) - 1) / span if span > 0 else 0.0
    worst_index = gaps.index(max(gaps)) if gaps else 0
    cadence = {
        "rounds": len(rounds), "span_s": round(span, 2), "hz_avg": round(hz_avg, 2),
        "gap_p50_s": round(_percentile(gaps, 0.5), 3),
        "gap_p95_s": round(_percentile(gaps, 0.95), 3),
        "gap_max_s": round(max(gaps), 3) if gaps else 0.0,
        "gap_max_server_tick": int(rounds[worst_index + 1].get("server_tick", 0) or 0)
        if gaps else 0,
    }
    if hz_avg < MIN_COORD_HZ:
        problems.append("协调平均 %.2fHz < %.1fHz（≈%.1f 秒一轮，超过'允许 2 秒'的下限）"
                        % (hz_avg, MIN_COORD_HZ, 1.0 / max(0.01, MIN_COORD_HZ)))
    if gaps and max(gaps) > MAX_ROUND_GAP_S:
        problems.append("单轮静默 %.2fs > %.1fs（tick=%s）：协调线程断线/被阻塞"
                        % (max(gaps), MAX_ROUND_GAP_S, cadence["gap_max_server_tick"]))

    # ---------------- ② 并行工作流（多编队 + 多设施） ----------------
    lane_rows = []
    for record in rounds:
        lanes = record.get("lanes") if isinstance(record.get("lanes"), dict) else {}
        active = [str(lane) for lane, entry in lanes.items()
                  if isinstance(entry, dict) and int(entry.get("tasks", 0) or 0) > 0]
        lane_rows.append({"tick": int(record.get("server_tick", 0) or 0), "lanes": active})
    busy_by_scan = {}
    for record in scans:
        busy_by_scan[int(record.get("server_tick", 0) or 0)] = record
    # "编队"口径：一条活跃意图覆盖 ≥2 个单位 = 一个编队在干活（不是散兵各自为战）。
    squad_counts = []
    for record in rounds:
        live = [item for item in (record.get("live_intents") or []) if isinstance(item, dict)]
        squad_counts.append(sum(1 for item in live
                                if len(item.get("unit_ids") or []) >= 2))
    parallel_counts = []
    for row in lane_rows:
        scan = busy_by_scan.get(row["tick"])
        producers_busy = int((scan or {}).get("fast_production_busy", 0) or 0)
        parallel_counts.append(len(row["lanes"]) + (1 if producers_busy > 0 else 0))
    half = int(len(parallel_counts) * warmup_ratio)
    tail_parallel = parallel_counts[half:] or parallel_counts
    tail_squads = (squad_counts[half:] or squad_counts) if squad_counts else []
    ratio_parallel = round(
        sum(1 for value in tail_parallel
            if value >= MIN_PARALLEL_WORKSTREAMS) / max(1, len(tail_parallel)), 3)
    parallel = {
        "lanes_active_p50": _percentile(
            [len(row["lanes"]) for row in lane_rows[half:] or lane_rows], 0.5),
        "workstreams_p50": _percentile(tail_parallel, 0.5),
        "workstreams_max": max(parallel_counts) if parallel_counts else 0,
        #: 后半程同时存在的**编队**数（覆盖 ≥2 单位的一条意图算一个编队）。
        "squad_intents_p50": _percentile(tail_squads, 0.5),
        "squad_intents_max": max(squad_counts) if squad_counts else 0,
        # 稳定别名（报告脚本按它读）+ 描述性别名（人看得懂"至少几条"）。
        "ratio_at_least_min": ratio_parallel,
        "min_workstreams": MIN_PARALLEL_WORKSTREAMS,
        "ratio_at_least_%d" % MIN_PARALLEL_WORKSTREAMS: ratio_parallel,
    }
    if ratio_parallel < MIN_PARALLEL_RATIO:
        problems.append("后半程只有 %.0f%% 的轮次有 ≥%d 条并行工作流（多编队/多设施没同时动）"
                        % (100.0 * ratio_parallel, MIN_PARALLEL_WORKSTREAMS))

    # ---------------- ③ 生产接续（有设施就必须持续在产） ----------------
    prod_series = [(int(record.get("server_tick", 0) or 0),
                    int(record.get("fast_production_units", 0) or 0),
                    int(record.get("fast_production_busy", 0) or 0),
                    int(record.get("fast_production_items", 0) or 0)) for record in scans]
    production = {"samples": len(prod_series)}
    # 【缺失即未知，不许当"没问题"】日志里根本没有这个字段时（旧版本 runner），
    # "0 个在产设施"和"没上报"是两件完全不同的事；把后者当通过就等于用数据缺失掩盖停产。
    if scans and not any("fast_production_busy" in record for record in scans):
        unknowns.append("production:fast_production_busy")
        production["note"] = "未上报在产设施数（旧日志/旧 runner）→ 生产接续**无法判定**"
    if prod_series:
        tail_prod = prod_series[int(len(prod_series) * warmup_ratio):] or prod_series
        producers_max = max((row[1] for row in prod_series), default=0)
        steps = [b[0] - a[0] for a, b in zip(tail_prod, tail_prod[1:])]
        step_ticks = _percentile(steps, 0.5) or 1.0
        idle_runs, run = [], 0
        for tick, producers, busy, items in tail_prod:
            if producers > 0 and busy == 0:
                run += 1
            else:
                if run:
                    idle_runs.append(run)
                run = 0
        if run:
            idle_runs.append(run)
        production.update({
            "producers_max": producers_max,
            "busy_ratio_tail": round(sum(1 for row in tail_prod if row[2] > 0)
                                     / max(1, len(tail_prod)), 3),
            "items_p50": _percentile([row[3] for row in tail_prod], 0.5),
            "max_idle_s": round(max(idle_runs, default=0) * step_ticks / TICK_HZ, 2),
            "idle_windows": len(idle_runs),
            "note": "空转 = 有生产设施但**没有任何在产项**的连续采样（无故停产）"
                    if producers_max else "本局没有可生产设施（无厂房/指挥中心）",
        })
        # 事实缺失时不判这两条（只留"无法判定"）：旧日志里 `busy` 恒 0 是**没上报**，
        # 拿它当"0% 时间在产"就是数据缺失冒充结论。
        digest_known = "production:fast_production_busy" not in unknowns
        if digest_known and producers_max and production["busy_ratio_tail"] < MIN_PRODUCTION_BUSY_RATIO:
            problems.append("后半程只有 %.0f%% 时间有设施在产（<%.0f%%）：生产没接上"
                            % (100.0 * production["busy_ratio_tail"],
                               100.0 * MIN_PRODUCTION_BUSY_RATIO))
        if digest_known and producers_max and production["max_idle_s"] > MAX_PRODUCTION_IDLE_S:
            problems.append("生产设施最长空转 %.1fs > %.0fs（有设施、无故停产）"
                            % (production["max_idle_s"], MAX_PRODUCTION_IDLE_S))

    # ---------------- ④ 已有任务不中断 / 积压 ----------------
    drops = {}
    for record in records:
        if str(record.get("kind")) == "decision":
            decision = record.get("decision") if isinstance(record.get("decision"), dict) else {}
            if str(decision.get("kind", "")) == "intent_dropped":
                reason = str(decision.get("reason", ""))
                drops[reason] = drops.get(reason, 0) + 1
        elif str(record.get("kind")) == "tick":
            for item in record.get("dropped") or []:
                if isinstance(item, dict):
                    reason = str(item.get("reason", ""))
                    drops[reason] = drops.get(reason, 0) + 1
    unjustified, backlog, blocked_repeats = 0, 0, 0
    for reason, count in drops.items():
        if any(reason.startswith(prefix) for prefix in LEGIT_DROP_PREFIXES):
            if reason.startswith(("duplicate_of", "intent_already_tracked")):
                blocked_repeats += count
            continue
        if reason in BACKLOG_REASONS:
            backlog += count
            continue
        unjustified += count
    interruptions = {"drops_by_reason": drops, "unjustified": unjustified,
                     "backlog": backlog, "repeat_blocked": blocked_repeats,
                     "legit_prefixes": list(LEGIT_DROP_PREFIXES)}
    if unjustified:
        problems.append("有 %d 条任务**无故中断**（原因不在白名单）：%s"
                        % (unjustified, [key for key in drops
                                         if not any(key.startswith(p)
                                                    for p in LEGIT_DROP_PREFIXES)
                                         and key not in BACKLOG_REASONS][:4]))
    if backlog:
        problems.append("有 %d 次**积压**（%s）：批量截断/在途未结算不许被'2 秒一轮'掩盖"
                        % (backlog, list(BACKLOG_REASONS)))

    # ---------------- ⑤ 线路不长期饿死 ----------------
    #
    # 【口径修正 2026-09-13】"饿死"必须按**这条线还有没有活在干**判，不能按"多久没下新命令"判：
    # 新纪律是"只发送变化意图"，一条正在跑的采集/建造任务本来就不该每轮重下 ——
    # 用 `lane_starved`（它量的是"距上次**接受**新意图多久"）当违规会得出假警报：
    # 实测 180 秒局 economy 报到 idle 1141 tick（19 秒没新意图），而那一轮它的 `tasks=2`
    # （两个采集工在干活）。所以：
    #   ① **违规**：该线有候选、且**这条线没有活跃任务**、又长时间没被服务（真有活没人干）；
    #   ② 常态：该线没有新命令但有活跃任务（"只发变化"的正常结果）→ 只当观察项报出来。
    starved = _decisions(records, "lane_starved")
    last_lanes = (rounds[-1].get("lanes") or {}) if rounds else {}
    idle_by_lane = {str(lane): int((entry or {}).get("idle_ticks", 0) or 0)
                    for lane, entry in last_lanes.items() if isinstance(entry, dict)}
    lane_active = {}
    tail_rows = lane_rows[half:] or lane_rows
    for lane in ("economy", "build", "scout", "military"):
        # `lane_rows` 里的 `lanes` 已经是"该轮有活跃任务(tasks>0)的线路名" → 直接看成员。
        active = sum(1 for row in tail_rows if lane in (row.get("lanes") or []))
        lane_active[lane] = round(active / max(1, len(tail_rows)), 3)
    starve_events, genuine = {}, {}
    for decision in starved:
        for item in decision.get("starved") or []:
            lane = str(item.get("lane", ""))
            starve_events[lane] = starve_events.get(lane, 0) + 1
            if int(item.get("tasks", 0) or 0) <= 0:
                genuine[lane] = genuine.get(lane, 0) + 1
    lanes_report = {
        "starve_events": starve_events,
        "genuine_starvation": genuine,
        "idle_ticks_last": idle_by_lane,
        "max_idle_ticks": max(idle_by_lane.values(), default=0),
        "active_ratio_tail": lane_active,
        "note": "starve_events 是「距上次接受新意图」的观察项；只有 tasks=0 的那些才算真饿死"
                "（有活没人干）。各线有没有活在干看 active_ratio_tail。",
    }
    if genuine:
        problems.append("有线路真的被饿死（有候选、但该线没有活跃任务）：%s" % genuine)
    for lane in ("economy", "build", "military"):
        if lane in lane_active and lane_active[lane] < MIN_LANE_ACTIVE_RATIO:
            problems.append("%s 线后半程只有 %.0f%% 的轮次有活在干（<%.0f%%）：这条线在空转"
                            % (lane, 100.0 * lane_active[lane], 100.0 * MIN_LANE_ACTIVE_RATIO))

    # ---------------- ⑥ 关键事件及时响应 ----------------
    lags = []
    for decision in _decisions(records, "fast_events_consumed"):
        lag = int(decision.get("lag_max", 0) or 0)
        if lag > 0:
            lags.append(lag / TICK_HZ)
    # 扫描层时延（游戏 → runner 的 10Hz 扫描）：用**各轮 p95 的中位数**当"常态"，
    # `max` 单列看最坏瞬时（开局/卡顿时的尖峰不该把常态判成超标：实测首轮 3.17s、
    # 之后 p95 稳定在 0.17s —— 拿 max 当门槛就是每天都在误报）。
    scan_p95 = [float((record.get("event_latency_p95") or 0.0)) for record in scans]
    scan_worst = [float((record.get("event_latency_max") or 0.0)) for record in scans]
    events = {
        "event_to_round_p95_s": round(_percentile(lags, 0.95), 3),
        "event_to_round_max_s": round(max(lags) if lags else 0.0, 3),
        "round_samples": len(lags),
        "scan_event_latency_p95_s": round(_percentile(scan_p95, 0.5), 3),
        "scan_event_latency_worst_s": round(max(scan_worst) if scan_worst else 0.0, 3),
    }
    if lags and events["event_to_round_p95_s"] > MAX_EVENT_LAG_P95_S:
        problems.append("关键事件处理延迟 p95 %.2fs > %.1fs（事件在队列里等太久）"
                        % (events["event_to_round_p95_s"], MAX_EVENT_LAG_P95_S))
    if lags and events["event_to_round_max_s"] > MAX_EVENT_LAG_MAX_S:
        problems.append("关键事件处理最坏 %.2fs > %.1fs" % (events["event_to_round_max_s"],
                                                          MAX_EVENT_LAG_MAX_S))
    if not lags:
        unknowns.append("events:lag_max")
        events["note"] = "本局没有可测的关键事件，或 runner 未上报 `lag_max`（旧日志）→ 无法判定"
    if events["scan_event_latency_p95_s"] > MAX_SCAN_EVENT_LATENCY_P95_S:
        problems.append("扫描层事件时延 p95 %.2fs > %.1fs（游戏→runner 就慢）"
                        % (events["scan_event_latency_p95_s"],
                           MAX_SCAN_EVENT_LATENCY_P95_S))

    # ---------------- ⑦ 只发变化意图（不许为凑频率重复下令） ----------------
    #
    # 判据（唯一口径）：把"本轮下发的命令"（tick 日志里是 intent_id 列表）按
    # **动作+单位集合+目标** 算出指纹，与**上一轮仍然活跃**的意图指纹比对 ——
    # 撞上就是"同一条命令还在跑又重新下发"（为凑频率下令）。
    # 注意：合法的"重发"（上一条已经生效/完成/被紧急抢占后重下）不会误报 ——
    # 那时上一条已经不在活跃表里了。
    live_keys = {}
    issued, repeats, renewals, per_round, unresolved = 0, 0, 0, [], 0
    repeat_samples = []
    for record in rounds:
        tick = int(record.get("server_tick", 0) or 0)
        live = {str(item.get("intent_id")): item
                for item in (record.get("live_intents") or []) if isinstance(item, dict)}
        accepted_ids = [str(item) for item in (record.get("accepted") or [])
                        if not isinstance(item, dict)]
        round_repeats = 0
        for intent_id in accepted_ids:
            intent = live.get(intent_id)
            if intent is None:
                # 本轮已结算/不在活跃表 → 内容无法比对（记账，不猜）。
                unresolved += 1
                continue
            old = live_keys.get(_intent_key(intent))
            if old is None:
                continue
            # 【区分"凑频率"与"续期"】上一条**还在有效窗口内**（且状态仍活着）时又下发同一条
            # = 重复下令；上一条已经过期/被丢弃再下发 = **续期**（生产接续、长任务续命本来就靠它）。
            # 不做这层区分会把"每 300 tick 给同一个哨兵续一次 hold"这类正常续期全判成违规
            # （实测首版 83 条里绝大多数是续期）。
            still_valid = int(old.get("expires_tick", 0) or 0) > tick
            alive = str(old.get("state", "")) in ("active", "pending_authority",
                                                 "active_unknown", "retry_wait")
            if still_valid and alive:
                round_repeats += 1
                if len(repeat_samples) < 6:
                    repeat_samples.append({
                        "tick": tick, "new": intent_id, "old": str(old.get("intent_id")),
                        "action": str(intent.get("action")),
                        "units": list(intent.get("unit_ids") or []),
                        "old_issued": int(old.get("issued_tick", 0) or 0),
                        "old_expires": int(old.get("expires_tick", 0) or 0)})
            else:
                renewals += 1
        repeats += round_repeats
        issued += len(accepted_ids)
        per_round.append(len(accepted_ids))
        live_keys = {_intent_key(item): item for item in live.values()} or live_keys
    units_last = len([u for u in (rounds[-1].get("ai_controlled_units") or [])]) if rounds else 0
    issuance = {
        "issued_total": issued,
        "issued_per_round_p50": _percentile(per_round, 0.5),
        "issued_per_round_max": max(per_round) if per_round else 0,
        "repeat_issued": repeats,
        "renewals": renewals,
        "repeat_samples": repeat_samples,
        "repeat_unresolved": unresolved,
        "reissue_blocked": blocked_repeats,
    }
    if repeats:
        problems.append("有 %d 条**重复下发**（同一单位同动作同目标还在跑又下发）：为凑频率下命令"
                        % repeats)
    if issuance["issued_per_round_p50"] > 0 and units_last:
        issuance["issued_per_unit_per_round"] = round(
            sum(per_round) / max(1, len(per_round)) / units_last, 3)

    # ---------------- ⑧ 不许掩盖：降级轮占比 ----------------
    degraded = sum(1 for record in rounds if str(record.get("degraded_reason", "")))
    observe_p50 = _percentile([float(record.get("observe_ms", 0) or 0) for record in rounds], 0.5)
    guard = {"degraded_rounds": degraded,
             "degraded_ratio": round(degraded / max(1, len(rounds)), 3),
             "observe_ms_p50": observe_p50,
             "round_elapsed_ms_p50": _percentile(
                 [float(record.get("elapsed_ms", 0) or 0) for record in rounds], 0.5)}
    if guard["degraded_ratio"] > MAX_DEGRADED_RATIO:
        problems.append("降级轮占比 %.0f%% > %.0f%%（规则顶得太多，不是'节奏慢'）"
                        % (100.0 * guard["degraded_ratio"], 100.0 * MAX_DEGRADED_RATIO))

    # 未知项同样进判定：验收不许"没数据 = 通过"（用户的"不能用允许 2 秒掩盖"同一条纪律）。
    for item in unknowns:
        problems.append("无法判定：%s（事实缺失，不算通过）" % item)
    # ---------------- 命令纪律（用户 2026-09-13："不能瞎下达"）----------------
    # 这一段是**硬判据**（不是观察项）：同一单位同一 tick 收到两条互相打架的移动命令，
    # 单位必然"走两步退一步"——那正是玩家看到的"部队跟不上"。
    # 被拒比例与重试浪费是**观察项**（学习期天然会有拒绝），单列出来让复盘看得见。
    commands = command_discipline(archive) if archive else None
    if archive and not commands:
        # 事实缺失不许当通过（同文件纪律）：档案在、命令流读不到 → 明说。
        unknowns.append("命令纪律无法判定（档案 %s 里没有 commands.jsonl）" % archive)
    if commands:
        if commands["same_tick_dual_live"]:
            problems.append("命令纪律：同一 tick 同一单位有 %d 组**两条都被采纳**的移动命令"
                            "（单位会同时被指挥去/停）：%s"
                            % (commands["same_tick_dual_live"], commands["same_tick_examples"]))
        if commands["accepted_ratio"] < 0.5:
            problems.append("命令纪律：命令接受率仅 %.0f%%（<50%%）= 指挥带宽大半在发无效命令：%s"
                            % (100.0 * commands["accepted_ratio"],
                               commands["reject_reasons"][:1]))
        if commands["repeat_reject_commands"] >= 20:
            problems.append("命令纪律：有 %d 条命令属于「(单位,动作) 已被拒≥3 次」的重试浪费"
                            "（同一条注定被拒的命令在刷屏）：%s"
                            % (commands["repeat_reject_commands"],
                               commands["repeated_pairs"][:2]))

    # 观测通道对游戏的开销（**观察项，不设门槛**）：玩家在意"副官有没有吃帧率"，
    # 所以把游戏自报的 FPS 与 10Hz 采样耗时一起算出来 —— 掉帧时先看这两个数，
    # 才能分清是"部队规模/渲染"还是"副官通道"（实测踩过：`is_target_reachable`
    # 每单位每 100ms 一次真寻路，曾把帧率拖到 20~30）。
    fps_series = [int(record.get("fps")) for record in scans
                  if isinstance(record.get("fps"), int) and int(record.get("fps")) > 0]
    sample_series = [float(record.get("sample_ms_p50")) for record in scans
                     if isinstance(record.get("sample_ms_p50"), (int, float))]
    # 帧率治理（游戏侧 PerformanceGovernor）：单位多时画质降了几档、缩放降到多少。
    # 与 FPS 放在同一段，才能回答用户那个问题——"部队涨上来，帧率守住没有、画质降了没"。
    tier_series = [int(record.get("quality_tier_max")) for record in scans
                   if isinstance(record.get("quality_tier_max"), int)]
    scale_series = [float(record.get("quality_scale")) for record in scans
                    if isinstance(record.get("quality_scale"), (int, float))
                    and float(record.get("quality_scale")) > 0]
    # 我方单位数（`fast_units`）：和画质档放一起，才能看出"降档是不是跟着部队规模"。
    # 口径说明：这是我方单位数，不是全图单位数（治理器数的是 `units` 组 = 全图）。
    unit_series = [int(record.get("fast_units")) for record in scans
                   if isinstance(record.get("fast_units"), int)]
    perf = {
        "fps_p50": _percentile(fps_series, 0.5) if fps_series else None,
        "fps_min": min(fps_series) if fps_series else None,
        "sample_ms_p50": _percentile(sample_series, 0.5) if sample_series else None,
        "sample_ms_max": max(sample_series) if sample_series else None,
        "quality_tier_max": max(tier_series) if tier_series else None,
        "quality_tier_last": (int(scans[-1].get("quality_tier"))
                              if scans and isinstance(scans[-1].get("quality_tier"), int)
                              else None),
        "quality_scale_min": min(scale_series) if scale_series else None,
        "units_max": max(unit_series) if unit_series else None,
        "note": "游戏自报（只读观察项，不设门槛）；缺这些数说明游戏侧未上报",
    }
    return {
        "rounds": len(rounds), "cadence": cadence, "parallel": parallel,
        "production": production, "interruptions": interruptions, "lanes": lanes_report,
        "events": events, "issuance": issuance, "guard": guard, "perf": perf,
        "commands": commands, "unknowns": unknowns, "problems": problems,
    }


#: "指挥同一个单位去哪/停哪"的动作族（与 `rules_fallback`/`nodes` 侧同口径）。
MOVE_FAMILY = {"attack", "attack_move", "move", "scout", "retreat", "hold",
               "regroup", "defend", "stop"}
UNIT_IN_INTENT = re.compile(r"(Unit_\d+)")


def _read_jsonl(path):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with io.open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            index = line.find("{")
            if index < 0:
                continue
            try:
                rows.append(json.loads(line[index:]))
            except ValueError:
                continue
    return rows


def find_archive(records, explicit="", root=""):
    """定位本局的**命令档案**目录（`commands.jsonl` 所在处）。

    为什么按 `match_id` 找：档案目录名 `archive_<match_id 前 8 位>` 与 runner 日志
    （`state_<tag>/runner.out`）不同路径，但 `start` 记录里有 match_id —— 这是唯一稳定钥匙。
    """
    if explicit:
        return explicit if os.path.isdir(explicit) else ""
    match_id = ""
    for record in records:
        if str(record.get("kind")) == "start" and record.get("match_id"):
            match_id = str(record["match_id"])
            break
    if not match_id:
        return ""
    short = match_id.split("-")[0][:8]
    roots = [root] if root else []
    roots += [r"G:\AIRTS\tmp_logs\campaign_accept\hud"]
    log_dir = ""
    for record in records:
        if record.get("__source"):
            log_dir = os.path.dirname(str(record["__source"]))
            break
    if log_dir:
        roots.append(os.path.abspath(os.path.join(log_dir, "..", "..", "..",
                                                  "campaign_accept", "hud")))
    for base in roots:
        if not base:
            continue
        candidate = os.path.join(base, "archive_%s" % short)
        if os.path.isdir(candidate):
            return candidate
    return ""


def command_discipline(archive_dir):
    """**命令纪律**（用户 2026-09-13："你下达命令不能瞎下达啊，部队还没跟上"）。

    纯函数：读一局的 `commands.jsonl`（真正下发的命令流）与 `rounds.jsonl`（每轮摘要），
    算出"命令是否在瞎下"的四个硬事实：

    - `accepted_ratio`：命令接受率（被拒的**都是**浪费的指挥带宽）；
    - `reject_reasons`：拒因 Top3（单一拒因刷屏 = 我们在反复发注定被拒的命令）；
    - `same_tick_dual_live`：**同一 tick 同一单位两条都被采纳**的移动命令数
      （真冲突：单位会同时收到"去"和"停"，这是"部队跟不上"的直接来源）；
    - `repeat_reject_commands`：属于"(单位,动作) 被拒 ≥3 次"的命令数（重试浪费的规模）；
    - `target_memory_peak / last`：`unattackable_targets`/`enemy_types` 的峰值与末值
      （**按域拉黑到底有没有生效**，看它就够 —— 恒 0 说明记忆没落进状态）。

    口径坑（已踩）：`commands.jsonl` 里同一个 `intent_id` 会有**两条**记录
    （意图级 + 收尾合并进来的权威命令级，如 `retreat → BadReceipt` 与 `move → Accepted`）——
    那是同一件事的两面，**不是**冲突；所以"双发"必须按 `intent_id` 去重后再判。
    """
    if not archive_dir or not os.path.isdir(archive_dir):
        return None
    rows = _read_jsonl(os.path.join(archive_dir, "commands.jsonl"))
    if not rows:
        return None
    status = {}
    reasons = {}
    repeated = {}
    order = []                      # 保持出现顺序，便于复现
    live = {}
    for record in rows:
        state_value = str(record.get("status", ""))
        status[state_value] = status.get(state_value, 0) + 1
        intent_id = str(record.get("intent_id", ""))
        action = str(record.get("action", ""))
        unit_match = UNIT_IN_INTENT.search(intent_id) or UNIT_IN_INTENT.search(
            str(record.get("unit_ids")))
        unit = unit_match.group(1) if unit_match else ""
        key = (unit, action)
        if state_value != "Accepted":
            text = str(record.get("reason") or record.get("error_code") or "")[:60]
            reasons[text] = reasons.get(text, 0) + 1
            if unit:
                repeated[key] = repeated.get(key, 0) + 1
        if action in MOVE_FAMILY and unit and state_value == "Accepted":
            bucket = live.setdefault((record.get("server_tick"), unit), set())
            bucket.add(intent_id)
    dual = {key: ids for key, ids in live.items() if len(ids) > 1}
    repeat_total = sum(count for count in repeated.values() if count >= 3)
    rounds = _read_jsonl(os.path.join(archive_dir, "rounds.jsonl"))
    memory = [record.get("target_memory") or {} for record in rounds]
    peak = max((int(item.get("bans", 0) or 0) for item in memory), default=0)
    total = sum(status.values())
    accepted = int(status.get("Accepted", 0))
    return {
        "archive": os.path.basename(archive_dir),
        "commands": total,
        "accepted": accepted,
        "accepted_ratio": round(accepted / total, 3) if total else 0.0,
        "reject_reasons": sorted(reasons.items(), key=lambda item: -item[1])[:3],
        "same_tick_dual_live": len(dual),
        "same_tick_examples": [{"unit": key[1], "tick": key[0], "intents": sorted(ids)}
                               for key, ids in sorted(dual.items())[:3]],
        "repeat_reject_commands": repeat_total,
        "repeated_pairs": sorted(repeated.items(), key=lambda item: -item[1])[:3],
        "target_memory_peak": {"bans": peak,
                               "enemy_types": max((int(item.get("enemy_types", 0) or 0)
                                                   for item in memory), default=0)},
        "target_memory_last": dict(memory[-1]) if memory else {},
    }


def load_samples(path):
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            payload = json.load(handle)
    except (IOError, OSError, ValueError):
        return None
    return payload.get("samples") if isinstance(payload, dict) else None


def main():
    parser = argparse.ArgumentParser(description="大规模作战连续性验收")
    parser.add_argument("runner_log")
    parser.add_argument("--samples", default="")
    parser.add_argument("--gate", action="store_true", help="有问题时返回退出码 1")
    parser.add_argument("--json", default="", help="把结果写到该文件")
    parser.add_argument("--archive", default="",
                        help="该局的命令档案目录（含 commands.jsonl）；不给则按 match_id 自动找")
    parser.add_argument("--archive-root", default="",
                        help="档案根目录（默认 G:\\AIRTS\\tmp_logs\\campaign_accept\\hud）")
    args = parser.parse_args()

    records = read_records(args.runner_log)
    archive = find_archive(records, explicit=args.archive, root=args.archive_root)
    report = analyze(records,
                     samples=load_samples(args.samples) if args.samples else None,
                     archive=archive)
    print("== 节拍（参考，不是目标）==")
    for key, value in report["cadence"].items():
        print("   %-24s %s" % (key, value))
    print("== 并行工作流（多编队 + 多设施同时工作）==")
    for key, value in report["parallel"].items():
        print("   %-24s %s" % (key, value))
    print("== 生产接续 ==")
    for key, value in report["production"].items():
        print("   %-24s %s" % (key, value))
    print("== 任务中断 / 积压 / 重复下发 ==")
    for key, value in report["interruptions"].items():
        if key != "legit_prefixes":
            print("   %-24s %s" % (key, value))
    print("== 线路饿死 ==")
    for key, value in report["lanes"].items():
        print("   %-24s %s" % (key, value))
    print("== 关键事件响应 ==")
    for key, value in report["events"].items():
        print("   %-24s %s" % (key, value))
    print("== 只发变化意图 ==")
    for key, value in report["issuance"].items():
        print("   %-24s %s" % (key, value))
    if report.get("commands"):
        item = report["commands"]
        print("== 命令纪律（不能瞎下达）==")
        print("   %-24s %s（Accepted %d/%d）" % ("接受率", item["accepted_ratio"],
                                                 item["accepted"], item["commands"]))
        print("   %-24s %s" % ("同tick双发（都被采纳）", item["same_tick_dual_live"]))
        for one in item["same_tick_examples"]:
            print("        ⛔ %s tick=%s %s" % (one["unit"], one["tick"], one["intents"]))
        print("   %-24s %s" % ("重试浪费命令数", item["repeat_reject_commands"]))
        for pair, count in item["repeated_pairs"]:
            print("        %s 被拒 %d 次" % (list(pair), count))
        for reason, count in item["reject_reasons"]:
            print("   %-24s %s x%d" % ("拒因", reason[:36], count))
        print("   %-24s %s" % ("目标记忆峰值/末值", "%s / %s" % (item["target_memory_peak"],
                                                             item["target_memory_last"])))
    if (report.get("perf") or {}).get("quality_tier_max") is not None:
        print("== 帧率治理（锁 60 + 单位多自动降画质）==")
        print("   %-24s %s" % ("画质档（峰值/末值）",
                                "%s / %s" % (report["perf"].get("quality_tier_max"),
                                             report["perf"].get("quality_tier_last"))))
        print("   %-24s %s" % ("最低渲染缩放", report["perf"].get("quality_scale_min")))
    print("== 不许掩盖（降级/观测开销）==")
    for key, value in report["guard"].items():
        print("   %-24s %s" % (key, value))
    if report.get("unknowns"):
        print("== 无法判定（事实缺失，不算通过）==")
        for item in report["unknowns"]:
            print("   ? %s" % item)
    print("== 判定 ==")
    if report["problems"]:
        for problem in report["problems"]:
            print("   ⛔ %s" % problem)
    else:
        print("   通过（连续性六项全达标）")
    if args.json:
        with io.open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=1)
    return 1 if (report["problems"] and args.gate) else 0


if __name__ == "__main__":
    sys.exit(main())
