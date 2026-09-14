# -*- coding: utf-8 -*-
"""把**一局的四层证据收进同一个档案目录**，供后续（高级模型）分析。

用户 2026-09-13："现在开始，每个对局都有意义，要尽可能把数据留档，我要给高级模型分析。"

跑起来后得到：

    <archive_root>/archive_<match8>/
      MANIFEST.json      # 身份/配置/计数/文件清单（含 sha1）/截断/缺口
      digest.md          # 给分析模型的第一读物
      events.jsonl rounds.jsonl commands.jsonl decisions.jsonl model.jsonl   # runner 写的明细
      raw/               # 原始证据副本（可点开复核）
        runner.out  agent_runner_events_*.jsonl  graph_checkpoint.json
        server_campaign.out  client_campaign.out  *.err
        short_<tag>.json  shot_<tag>_t*.png

设计要点：

- **不猜**：缺什么就在 MANIFEST 的 `missing` 里写出来（例如老局没有逐条事件，
  只能从 runner.out 还原"计数版"），绝不假装完整。
- **幂等**：同一局重复跑不会重复堆积；同 sha1 的文件跳过复制。
- **给历史局补档**：`--from-runner-log` 能把只有 `runner.out` 的老局收成
  "计数级"档案（receipt/decision/round 可还原，逐条事件无法还原 —— 显式标注）。

用法：

    python tools/archive_match.py --state-dir <state_<tag>> [--report short_<tag>.json]
                                  [--game-logs <Godot 日志目录>] [--shots <截图目录>]
                                  [--log-dir <runner 的 --log-dir>] [--tag <名字>]
"""

import argparse
import glob
import hashlib
import io
import json
import os
import shutil
import sys
from typing import Any, Dict

sys.stdout.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "source"))

from adjutant_coordinator.deploy import match_archive as ma  # noqa: E402

GAME_LOGS = ("server_campaign.out", "client_campaign.out", "server.err", "client.err")


def _read_jsonl(path, limit=200000):
    """读一份 JSONL（坏行跳过）：用于把图内 `command_timing` 合并进命令生命周期。"""
    out = []
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line or not line.startswith("{"):
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
                if len(out) >= limit:
                    break
    except OSError:
        return []
    return out


def sha1_of(path, chunk=1 << 20):
    digest = hashlib.sha1()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def find_match_id(state_dir):
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


def find_file(log_dirs, prefix, match8="", suffix=".jsonl"):
    """按 match 尾号找文件（**对不上就不返回**：拿别局的证据是复盘最忌讳的错误）。"""
    for folder in log_dirs:
        if not folder or not os.path.isdir(folder):
            continue
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            if not (name.startswith(prefix) and name.endswith(suffix)):
                continue
            if match8 and match8 not in name:
                continue
            return os.path.join(folder, name)
    return ""


def copy_into(archive_dir, source, *, subdir="raw", manifest_files=None):
    """把原始文件复制进档案（同 sha1 跳过），返回相对路径与元信息。"""
    if not source or not os.path.isfile(source):
        return None
    target_dir = os.path.join(archive_dir, subdir)
    os.makedirs(target_dir, exist_ok=True)
    name = os.path.basename(source)
    target = os.path.join(target_dir, name)
    digest = sha1_of(source)
    size = os.path.getsize(source)
    if os.path.isfile(target) and sha1_of(target) == digest:
        return {"file": os.path.join(subdir, name), "size": size, "sha1": digest,
                "source": source, "copied": False}
    try:
        shutil.copy2(source, target)
    except OSError as exc:
        print("   ⚠ 复制失败 %s：%s" % (name, exc))
        return None
    if manifest_files is not None:
        manifest_files.append(os.path.join(subdir, name))
    return {"file": os.path.join(subdir, name), "size": size, "sha1": digest,
            "source": source, "copied": True}


def convert_from_runner_out(archive, records):
    """**给历史局补档**：把 runner.out 的记录还原成 rounds/commands/decisions。

    逐条游戏事件**无法**还原（runner.out 只记计数）→ 在 MANIFEST 的 `missing` 里写清楚。
    `tick` 与 `fast_scan` 是**同一轮**的两条记录 → 必须按 tick 合并成一行，
    否则轮数翻倍、"最后一轮的世界"只剩半张表（实测踩过：余额 None、单位 0）。
    """
    merged: Dict[int, Dict[str, Any]] = {}
    commands = decisions = 0
    for record in records:
        kind = str(record.get("kind", ""))
        if kind == "tick":
            tick = int(record.get("server_tick", 0) or 0)
            row = merged.setdefault(tick, {"server_tick": tick, "derived": "runner.out"})
            row.update({
                "ts": record.get("ts"), "route": record.get("route"),
                "degraded_reason": record.get("degraded_reason"),
                "elapsed_ms": record.get("elapsed_ms"), "coord_hz": record.get("coord_hz"),
                "observe_ms": record.get("observe_ms"),
                "lanes": record.get("lanes") or {},
                "movement": record.get("movement") or {},
                "accepted": record.get("accepted") or [],
                "dropped": record.get("dropped") or [],
                # 活跃意图压成紧凑表（原样灌进去会让档案膨胀十倍）。
                "live_intents": [
                    {"id": str(item.get("intent_id", "")),
                     "action": str(item.get("action", "")),
                     "units": list(item.get("unit_ids") or [])[:8],
                     "target": item.get("target") or {},
                     "state": str(item.get("state", ""))}
                    for item in (record.get("live_intents") or []) if isinstance(item, dict)],
            })
        elif kind == "fast_scan":
            tick = int(record.get("server_tick", 0) or 0)
            row = merged.setdefault(tick, {"server_tick": tick, "derived": "runner.out"})
            row.update({
                "scan_hz": record.get("scan_hz"),
                "snapshot_age_p95": record.get("snapshot_age_p95"),
                "event_latency_p95": record.get("event_latency_p95"),
                "fast_units": record.get("fast_units"),
                "fast_production_units": record.get("fast_production_units"),
                "fast_production_busy": record.get("fast_production_busy"),
                "fast_production_items": record.get("fast_production_items"),
                "event_seq": record.get("event_seq"),
            })
        elif kind == "receipt":
            receipt = record.get("receipt") or {}
            if isinstance(receipt, dict):
                archive.command({
                    "server_tick": int(record.get("server_tick", 0) or 0),
                    "intent_id": str(receipt.get("intent_id", "")),
                    "action": str(receipt.get("intent_action", "") or receipt.get("action", "")),
                    "status": str(receipt.get("status", "")),
                    "reason": str(receipt.get("reason", ""))[:300],
                    "generation": receipt.get("generation"),
                    "derived": "runner.out"})
                commands += 1
        elif kind == "decision":
            entry = record.get("decision") or {}
            if isinstance(entry, dict):
                archive.decision(dict(entry, derived="runner.out"))
                decisions += 1
    for tick in sorted(merged):
        archive.round_(merged[tick])
    return {"rounds": len(merged), "commands": commands, "decisions": decisions}


def main():
    parser = argparse.ArgumentParser(description="把一局的四层证据收进同一个档案目录")
    parser.add_argument("--state-dir", default="", help="state_<tag> 目录（runner 的 --state-dir）")
    parser.add_argument("--runner-log", default="", help="直接给 runner.out 路径")
    parser.add_argument("--log-dir", default="", help="runner 的 --log-dir（放 archive_*/events）")
    parser.add_argument("--report", default="", help="short_<tag>.json")
    parser.add_argument("--game-logs", default=r"G:\AIRTS\tmp_logs\dcs")
    parser.add_argument("--shots", default="", help="截图目录（默认取 report 所在目录）")
    parser.add_argument("--tag", default="", help="档案名后缀（默认用报告里的 tag）")
    parser.add_argument("--from-runner-log", action="store_true",
                        help="只从 runner.out 还原（历史局补档；逐条事件无法还原，会显式标注）")
    args = parser.parse_args()

    runner_log = args.runner_log or (os.path.join(args.state_dir, "runner.out")
                                     if args.state_dir else "")
    if not runner_log or not os.path.isfile(runner_log):
        print("找不到 runner.out：%s" % runner_log, file=sys.stderr)
        return 2
    state_dir = args.state_dir or os.path.dirname(runner_log)
    match_id = find_match_id(state_dir)
    match8 = match_id[:8]
    report = None
    if args.report and os.path.isfile(args.report):
        report = json.load(io.open(args.report, encoding="utf-8", errors="replace"))
    tag = args.tag or str((report or {}).get("tag", "")) or os.path.basename(state_dir)

    # 档案根目录：runner 写档在 `--log-dir`；没指定就取 state_dir 的祖先里第一个含 archive_ 的。
    roots = [args.log_dir] if args.log_dir else []
    roots += [state_dir, os.path.dirname(state_dir), os.path.dirname(os.path.dirname(state_dir))]
    archive_dir = ""
    for root in roots:
        if root and os.path.isdir(os.path.join(root, "archive_%s" % (match8 or "nomatch"))):
            archive_dir = os.path.join(root, "archive_%s" % (match8 or "nomatch"))
            break
    archive_root = os.path.dirname(archive_dir) if archive_dir else (args.log_dir or state_dir)
    # 身份从 runner.out 的 `start` 记录里取（报告里没有 player/rules_version；
    # `start` 是每局必写的一条，比猜可靠）。
    runner_records = ma_load(runner_log)
    start = next((item for item in runner_records if str(item.get("kind")) == "start"), {})
    archive = ma.MatchArchive(
        archive_root, match_id=str(start.get("match_id") or match_id or tag),
        player=str(start.get("player") or (report or {}).get("player", "")),
        rules_version=str(start.get("rules_version", "")),
        config={key: start.get(key) for key in
                ("provider", "engine", "port", "interface") if start.get(key) is not None})
    print("[archive] 档案目录：%s" % archive.dir)

    # 【合并而不是覆盖】runner 可能已经写过 MANIFEST（计数/截断/异常/时间线在它那里）：
    # 收档只允许**追加**原始副本信息与验收结论，绝不许把它的计数抹成空
    # （实测踩过：`counts={}` `files={}` 一覆盖，连"为什么 0 字节"都查不出来）。
    # 注意：`_progress.json` 里是**被杀之前**的最后进度，runner 若被 taskkill 就是唯一活口。
    for candidate in {os.path.join(archive_dir, "MANIFEST.json") if archive_dir else "",
                      os.path.join(archive.dir, "MANIFEST.json")}:
        if candidate and os.path.isfile(candidate):
            try:
                archive.hydrate(json.load(io.open(candidate, encoding="utf-8",
                                                 errors="replace")))
                print("[archive] 已合并既有 MANIFEST：%s" % candidate)
            except (OSError, ValueError):
                pass
    progress_path = os.path.join(archive.dir, "_progress.json")
    if os.path.isfile(progress_path):
        try:
            progress = json.load(io.open(progress_path, encoding="utf-8", errors="replace"))
            archive.counts.update(progress.get("counts") or {})
            archive._bytes.update(progress.get("bytes") or {})
            for item in progress.get("truncated") or []:
                if item not in archive.truncated:
                    archive.truncated.append(item)
            for item in progress.get("errors") or []:
                if len(archive.errors) < 8:
                    archive.errors.append(item)
            if isinstance(progress.get("rounds"), int):
                archive._rounds = max(archive._rounds, int(progress["rounds"]))
            for key in ("first_tick", "last_tick"):
                if isinstance(progress.get(key), int):
                    setattr(archive, key, progress[key])
            for item in progress.get("timeline") or []:
                if isinstance(item, dict) and item not in archive._timeline:
                    archive._timeline.append(item)
            print("[archive] 已合并进程进度：rounds=%s bytes=%s"
                  % (progress.get("rounds"), progress.get("bytes")))
        except (OSError, ValueError):
            pass
    # 【命令生命周期】runner 常被验收脚本强杀（不会跑收尾）→ 合并放在这里做：
    # 原始副本里有图内打点（`command_timing` = 决定→下发），与回执按 `intent_id` 拼一条生命周期。
    try:
        timing_events = []
        for path in sorted(glob.glob(os.path.join(archive.dir, "raw",
                                                 "agent_runner_events_*.jsonl"))):
            timing_events.extend(_read_jsonl(path))
        if timing_events:
            merged = archive.command_lifecycle(timing_events)
            print("[archive] 命令生命周期合并：%s（来自 %d 条图内事件）"
                  % (merged, len(timing_events)))
    except Exception as exc:  # noqa: BLE001 —— 合并失败不影响收档
        print("[archive] ⚠ 命令生命周期合并失败：%r" % exc)
    # 【摘要以磁盘为准】明细文件才是事实：从文件反推计数/榜单/最后一轮，
    # 避免"进度文件 + 文件"两份数字相加、或摘要与实际内容自相矛盾。
    try:
        rebuilt = archive.rebuild_from_files()
        print("[archive] 从明细反推摘要：%s" % rebuilt)
    except Exception as exc:  # noqa: BLE001 —— 反推失败不影响收档
        print("[archive] ⚠ 反推摘要失败：%r" % exc)

    missing, raw = [], []
    if args.from_runner_log:
        stats = convert_from_runner_out(archive, runner_records)
        print("[archive] 从 runner.out 还原：%s" % stats)
        missing.append("events.jsonl（逐条游戏事件：runner.out 只记计数，无法还原；"
                       "需要新版本 runner 的留档层）")
    elif not os.path.isfile(os.path.join(archive.dir, "rounds.jsonl")):
        missing.append("rounds.jsonl（runner 未写留档：该局可能跑的是旧版 runner）")

    # 原始证据副本
    log_dirs = [d for d in [args.log_dir, os.path.dirname(state_dir),
                            os.path.dirname(os.path.dirname(state_dir)),
                            os.path.dirname(os.path.dirname(os.path.dirname(state_dir))),
                            os.path.join(os.path.dirname(os.path.dirname(
                                os.path.dirname(state_dir))), "campaign_accept", "hud")]
                if d]
    sources = [runner_log,
               find_file(log_dirs, "agent_runner_events_", match8),
               find_file(log_dirs, "agent_runner_", match8),
               args.report,
               os.path.join(args.game_logs, "server_campaign.out"),
               os.path.join(args.game_logs, "client_campaign.out"),
               os.path.join(args.game_logs, "server.err"),
               os.path.join(args.game_logs, "client.err")]
    for name in os.listdir(state_dir) if os.path.isdir(state_dir) else []:
        inner = os.path.join(state_dir, name)
        if os.path.isdir(inner):
            for player in os.listdir(inner):
                candidate = os.path.join(inner, player, "graph_checkpoint.json")
                if os.path.isfile(candidate):
                    sources.append(candidate)
    shots_dir = args.shots or (os.path.dirname(args.report) if args.report else "")
    if shots_dir and os.path.isdir(shots_dir):
        for name in sorted(os.listdir(shots_dir)):
            if name.startswith("shot_%s" % tag) and name.endswith(".png"):
                sources.append(os.path.join(shots_dir, name))
    for source in sources:
        info = copy_into(archive.dir, source)
        if info:
            raw.append(info)
    for name in GAME_LOGS:
        if not os.path.isfile(os.path.join(args.game_logs, name)):
            missing.append("raw/%s（游戏侧日志缺失）" % name)
    payload = archive.close(status="assembled", extra={
        "tag": tag, "report_passed": (report or {}).get("passed"),
        "report_problems": (report or {}).get("problems"),
        "continuity": (report or {}).get("continuity"),
        "assembly": {"raw_files": raw, "missing": sorted(set(missing)),
                     "from_runner_log": bool(args.from_runner_log)}})
    # 把 raw 清单与缺口也写进 MANIFEST（合并而不是覆盖）。
    manifest_path = os.path.join(archive.dir, "MANIFEST.json")
    try:
        data = json.load(io.open(manifest_path, encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        data = payload
    data.setdefault("extra", {})["assembly"] = {
        "raw_files": [item["file"] for item in raw],
        "raw_bytes": sum(item["size"] for item in raw),
        "missing": sorted(set(missing)),
        "from_runner_log": bool(args.from_runner_log),
    }
    with io.open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=1)
    print("[archive] 收档完成：明细 %s 条、原始副本 %d 个、缺口 %d 项"
          % (json.dumps(data.get("counts") or {}, ensure_ascii=False), len(raw),
             len(set(missing))))
    print("[archive] 给分析模型的第一读物：%s" % os.path.join(archive.dir, "digest.md"))
    return 0


def ma_load(path):
    """读 runner.out（复用留档层的记录读取口径）。"""
    out = []
    for line in io.open(path, encoding="utf-8", errors="replace"):
        index = line.find("{")
        if index < 0:
            continue
        try:
            out.append(json.loads(line[index:]))
        except ValueError:
            continue
    return out


if __name__ == "__main__":
    sys.exit(main())
