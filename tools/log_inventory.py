# -*- coding: utf-8 -*-
"""**一局能复盘到什么** —— 四层证据的清单器（用户 2026-09-13 点名："这种东西对于复盘非常重要"）。

四层证据（缺哪层就点出来，**不许让人以为都记了**）：

| 层 | 文件 | 里面有什么 |
|---|---|---|
| A 协调器 | `<state_dir>/runner.out`、`<log_dir>/agent_runner_*.jsonl` | 每轮 tick（节拍/耗时/各线账/accepted/dropped/live_intents）、fast_scan（扫描频率/快照年龄/事件时延/在产设施）、**decision**（每条内部决策带 tick+原因）、receipt（每条命令的权威回执） |
| A2 图内打点 | `<log_dir>/agent_runner_events_*.jsonl` | `ctx.services.log` 的落点：`hud_status`（面板"思考"原文）、行为树/微观/落点等打点 |
| A3 状态快照 | `<state_dir>/<match_id>/<player>_<n>/graph_checkpoint.json` | 整份协调器状态（active_intents/campaign_state/decision_log/lanes/routes/movement_stats/task_progress/…） |
| B 游戏侧 | `tmp_logs/dcs/server_campaign.out`、`client_campaign.out`、`*.err` | Godot stdout/stderr：`[GATHER]`/`[COLLECT]`（单位**有没有在听从**的逐 tick 遥测）/`[DAMAGE]`/`[VIS]`/`[ECO]`/脚本错误 |
| C 验收报告 | `short_<tag>.json`、`shot_<tag>_t*.png`、`result_*.json` | 节拍、**连续性六项**、安全移动账、问题清单、画面截图 |

用法：
    python tools/log_inventory.py <state_dir 或 runner.out> [--report short_x.json]
                                  [--log-dir <runner 的 --log-dir>] [--game-logs <Godot 日志目录>]
"""

import argparse
import io
import json
import os
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8")

#: 复盘必须有的记录种类（缺哪个就点出来）。
EXPECTED_KINDS = ("tick", "fast_scan", "receipt", "decision")
#: 打点标签：只统计"有意义的那几类"，不把普通行掩盖掉。
GAME_TAG_RE = re.compile(r"^\s*\[([A-Za-z_0-9]{2,20})\]")


def read_records(path):
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


def find_match_id(state_dir):
    """从 checkpoint 里取 match_id（用来把 A/A2/A3 三层对上同一局）。"""
    if not state_dir or not os.path.isdir(state_dir):
        return ""
    for name in os.listdir(state_dir):
        inner = os.path.join(state_dir, name)
        if not os.path.isdir(inner):
            continue
        for player in os.listdir(inner):
            path = os.path.join(inner, player, "graph_checkpoint.json")
            if os.path.isfile(path):
                try:
                    data = json.load(io.open(path, encoding="utf-8", errors="replace"))
                except (OSError, ValueError):
                    continue
                match_id = str((data.get("state") or {}).get("match_id", ""))
                if match_id:
                    return match_id
    return ""


def _find_events_file(explicit, state_dir, match8, max_up=3):
    """找图内打点文件：显式目录优先，否则沿 state_dir 的祖先逐层找 `hud/` 与目录本身。"""
    dirs = []
    if explicit:
        dirs.append(explicit)
    base = os.path.abspath(state_dir)
    for _ in range(max_up + 1):
        dirs.append(base)
        try:
            dirs.extend(os.path.join(base, name) for name in os.listdir(base)
                        if os.path.isdir(os.path.join(base, name)))
        except OSError:
            pass
        base = os.path.dirname(base)
    # 每个候选目录再扇一层 `hud/`（验收局把 `--log-dir` 指到 `.../campaign_accept/hud`）。
    for folder in list(dirs):
        dirs.append(os.path.join(folder, "hud"))
    for folder in dirs:
        if not os.path.isdir(folder):
            continue
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            if not name.startswith("agent_runner_events_"):
                continue
            # 【不许猜】match 尾号对不上就不是本局的产物：宁可报"没找到"，
            # 也不能拿别的局的文件充当本局证据（复盘最忌讳串了局）。
            if match8 and match8 in name:
                return os.path.join(folder, name)
    return ""


def summarize_events_file(path):
    """统计图内打点：**按 `event` 字段**（不是按 'phase' 在不在 —— `campaign` 也带 phase，
    用它当判据会把 740 条主线事件的账算到 hud_status 头上，实测踩过）。"""
    kinds, events = Counter(), Counter()
    lines = 0
    for record in read_records(path):
        lines += 1
        kinds[str(record.get("kind", "") or "(无 kind)")] += 1
        events[str(record.get("event", "") or "(无 event)")] += 1
    return {"lines": lines, "kinds": dict(kinds), "events": dict(events)}


def summarize_game_log(path):
    tags, errors = Counter(), Counter()
    lines = 0
    if not os.path.isfile(path):
        return None
    for line in io.open(path, encoding="utf-8", errors="replace"):
        lines += 1
        match = GAME_TAG_RE.match(line)
        if match:
            tags[match.group(1)] += 1
        if "SCRIPT ERROR" in line or "Parse Error" in line:
            errors["脚本错误"] += 1
        elif "ERROR" in line:
            errors["ERROR"] += 1
    return {"lines": lines, "tags": dict(tags), "errors": dict(errors),
            "size_kb": int(os.path.getsize(path) / 1024)}


def inventory(records, *, report=None, events=None, checkpoint=None, game=None):
    kinds = Counter(str(record.get("kind", "")) for record in records)
    decisions = Counter(str((record.get("decision") or {}).get("kind", ""))
                        for record in records if str(record.get("kind")) == "decision")
    receipts = Counter()
    receipt_actions = Counter()
    for record in records:
        receipt = record.get("receipt")
        if isinstance(receipt, dict):
            receipts[str(receipt.get("status"))] += 1
            receipt_actions[str(receipt.get("action"))] += 1
    ticks = [record for record in records if str(record.get("kind")) == "tick"]
    scans = [record for record in records if str(record.get("kind")) == "fast_scan"]
    last = ticks[-1] if ticks else {}
    present = {}
    if ticks:
        present = {
            "节拍/耗时": all(key in last for key in ("elapsed_ms", "coord_hz", "observe_ms")),
            "线路账(各线任务/饿死)": isinstance(last.get("lanes"), dict),
            "安全移动账": isinstance(last.get("movement"), dict),
            "下发/丢弃清单": "accepted" in last and "dropped" in last,
            "活跃意图快照(含目标与状态)": "live_intents" in last,
            "批量提交计数": isinstance(last.get("batch"), dict),
        }
    if scans:
        present.update({
            "生产在产设施数": any("fast_production_busy" in record for record in scans),
            "事件时延(游戏→扫描)": any("event_latency_p95" in record for record in scans),
            "快照年龄(现在→刚才)": any("snapshot_age_p95" in record for record in scans),
            "扫描频率": any("scan_hz" in record for record in scans),
        })
    present["事件→本轮处理延迟"] = any(
        "lag_max" in (record.get("decision") or {})
        for record in records if str(record.get("kind")) == "decision")
    present["主线推进(里程碑/阶段/中断)"] = any(kind.startswith("campaign")
                                              for kind in decisions)
    present["行为树/微观打点"] = any(kind.startswith(("micro", "behavior", "bt_"))
                                    for kind in decisions)
    present["玩家接管/交回"] = any("player" in kind for kind in decisions) or any(
        "player" in str(record.get("kind", "")) for record in records)
    return {
        "records": len(records), "kinds": dict(kinds), "decisions": dict(decisions),
        "receipts": dict(receipts), "receipt_actions": dict(receipt_actions),
        "missing_kinds": [kind for kind in EXPECTED_KINDS if kind not in kinds],
        "present": present, "report": report, "events": events,
        "checkpoint": checkpoint, "game": game,
    }


def main():
    parser = argparse.ArgumentParser(description="一局能复盘到什么（四层证据清单）")
    parser.add_argument("target", help="state_<tag> 目录或 runner.out 路径")
    parser.add_argument("--report", default="", help="对应的 short_<tag>.json")
    parser.add_argument("--log-dir", default="", help="runner 的 --log-dir（放 events jsonl/HUD 快照）")
    parser.add_argument("--game-logs", default=r"G:\AIRTS\tmp_logs\dcs",
                        help="游戏侧 stdout 日志目录")
    args = parser.parse_args()
    state_dir = args.target if os.path.isdir(args.target) else os.path.dirname(args.target)
    path = args.target if os.path.isfile(args.target) else os.path.join(args.target, "runner.out")
    if not os.path.isfile(path):
        print("找不到日志：%s" % path, file=sys.stderr)
        return 2
    match_id = find_match_id(state_dir)
    match8 = match_id[:8]
    # A2 图内打点：按 match 尾号自动找。验收局把 `--log-dir` 指到 `tmp_logs/campaign_accept/hud`，
    # 而 state_dir 在 `tmp_logs/langgraph_recon/campaign_accept/state_<tag>` —— 两者是
    # **隔层的兄弟目录**，所以必须"沿祖先逐层扇出一层"地找，而不是只看固定相对路径。
    events, events_path = None, ""
    found = _find_events_file(args.log_dir, state_dir, match8)
    if found:
        events_path = found
        events = summarize_events_file(found)
    # A3 状态快照
    checkpoint = None
    if match_id and os.path.isdir(os.path.join(state_dir, match_id)):
        inner = os.path.join(state_dir, match_id)
        for player in os.listdir(inner):
            candidate = os.path.join(inner, player, "graph_checkpoint.json")
            if os.path.isfile(candidate):
                try:
                    data = json.load(io.open(candidate, encoding="utf-8", errors="replace"))
                except (OSError, ValueError):
                    continue
                checkpoint = {"path": candidate, "saved_tick": data.get("saved_tick"),
                              "state_keys": len(data.get("state") or {})}
    # B 游戏侧
    game = {}
    for name in ("server_campaign.out", "client_campaign.out", "server.err", "client.err"):
        summary = summarize_game_log(os.path.join(args.game_logs, name))
        if summary:
            game[name] = summary
    report = None
    if args.report and os.path.isfile(args.report):
        with io.open(args.report, encoding="utf-8", errors="replace") as handle:
            report = json.load(handle)
    data = inventory(read_records(path), report=report, events=events,
                     checkpoint=checkpoint, game=game)
    print("== 本局身份 ==")
    print("   match_id=%s  日志=%s" % (match_id or "?", path))
    print("== A 协调器记录种类（都在 runner.out 里）==")
    for kind, count in sorted(data["kinds"].items(), key=lambda kv: -kv[1]):
        print("   %-22s %d" % (kind, count))
    if data["missing_kinds"]:
        print("   ⚠ 本次缺失：%s" % data["missing_kinds"])
    print("== A 决策种类（每条带 tick + 原因 = 决策地图）==")
    for kind, count in sorted(data["decisions"].items(), key=lambda kv: -kv[1])[:22]:
        print("   %-34s %d" % (kind, count))
    print("== A 回执（权威层到底收没收）==")
    print("   %s" % data["receipts"])
    for kind, count in sorted(data["receipt_actions"].items(), key=lambda kv: -kv[1])[:10]:
        print("   %-16s %d" % (kind, count))
    print("== A2 图内打点（AI 的“思考”原文在这里）==")
    if data["events"]:
        print("   %s（%d 条）" % (events_path, data["events"]["lines"]))
        for kind, count in sorted(data["events"]["kinds"].items(),
                                  key=lambda kv: -kv[1])[:8]:
            print("   kind=%-28s %d" % (kind, count))
        for kind, count in sorted(data["events"]["events"].items(),
                                  key=lambda kv: -kv[1])[:14]:
            print("   event=%-27s %d" % (kind, count))
    else:
        print("   ⚠ 没找到 `agent_runner_events_*.jsonl`（图内 _log 不落盘 → 看不到思考原文）")
    print("== A3 状态快照 ==")
    if data["checkpoint"]:
        print("   %s" % data["checkpoint"]["path"])
        print("   saved_tick=%s  状态键=%d（意图/主线/路由/任务进度/额度都在里面）"
              % (data["checkpoint"]["saved_tick"], data["checkpoint"]["state_keys"]))
    else:
        print("   ⚠ 没找到 graph_checkpoint.json")
    print("== B 游戏侧日志 ==")
    for name, summary in (data["game"] or {}).items():
        print("   %-22s %6d 行 %5dKB  错误=%s" % (name, summary["lines"], summary["size_kb"],
                                                summary["errors"] or "无"))
        if summary["tags"]:
            print("      打点：%s" % dict(sorted(summary["tags"].items(),
                                              key=lambda kv: -kv[1])[:10]))
    print("== 关键事实是否齐（缺 = 无法判定，不等于没问题）==")
    for key, ok in data["present"].items():
        print("   %-28s %s" % (key, "有" if ok else "**缺**"))
    if report:
        print("== C 验收报告 ==")
        print("   %s" % ", ".join(sorted(key for key in report if key != "samples")))
        if isinstance(report.get("continuity"), dict):
            print("   连续性六项：%s" % ", ".join(sorted(report["continuity"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
