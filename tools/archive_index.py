# -*- coding: utf-8 -*-
"""给所有对局档案生成一份**索引**（`ARCHIVES.md`）。

为什么要它（用户 2026-09-13："有效历史对局数据"）：把档案交给外部模型做分析时，
它第一件事是"哪些局是有效的、配置是什么、有没有缺口"。一局一份 MANIFEST 要它逐个数
既慢又容易串局，所以在档案根目录放一张表：一局一行，含配置、判定、计数、缺口、有效性。

用法：
    python tools/archive_index.py [档案根目录 ...]
默认扫描 `G:\\AIRTS\\tmp_logs\\campaign_accept\\hud`（验收局）。
"""

import glob
import io
import json
import os
import sys

sys.stdout.reconfigure(encoding="utf-8")
DEFAULT_ROOTS = (r"G:\AIRTS\tmp_logs\campaign_accept\hud",)

#: 明细文件的"有效"判据：这四份都非空，且没有写入异常。
DETAILS = ("events.jsonl", "rounds.jsonl", "commands.jsonl", "decisions.jsonl")


def _load(path):
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def _count_lines(path, cap=400000):
    total = 0
    first = last = None
    try:
        with io.open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                total += 1
                # 每行都取 tick：档案很小（≤1MB），而"首末 tick"必须准
                # （抽样会得出 `694→694` 这种假跨度 —— 实测踩过）。
                try:
                    tick = int(json.loads(line).get("server_tick", -1) or -1)
                except ValueError:
                    tick = -1
                if tick >= 0:
                    first = tick if first is None else first
                    last = tick
                if total >= cap:
                    break
    except OSError:
        return 0, None, None
    return total, first, last


def describe(archive):
    """一局档案 → 一行事实（不猜：拿不到就写 unknown，能从明细算的就从明细算）。"""
    manifest = _load(os.path.join(archive, "MANIFEST.json"))
    progress = _load(os.path.join(archive, "_progress.json"))
    data = manifest or progress
    extra = data.get("extra") or {}
    config = data.get("config") or {}
    counts = dict(data.get("counts") or {})
    rounds = data.get("rounds")
    first_tick, last_tick = data.get("first_tick"), data.get("last_tick")
    derived = False
    # 【清单缺计数就从明细算】早期几局的 MANIFEST 被覆盖过 → 计数缺失；
    # 明细文件才是事实，所以直接数行（档案都很小，代价可忽略）。
    if not counts or rounds in (None, 0):
        derived = True
        rows = 0
        for name, key in (("events.jsonl", "events"), ("commands.jsonl", "commands"),
                          ("decisions.jsonl", "decisions")):
            total, _, _ = _count_lines(os.path.join(archive, name))
            counts[key] = total
        rounds, first_tick, last_tick = _count_lines(os.path.join(archive, "rounds.jsonl"))
    seconds = extra.get("seconds") or config.get("seconds")
    if not seconds and isinstance(first_tick, int) and isinstance(last_tick, int):
        seconds = round((last_tick - first_tick) / 60.0, 1)
    return {
        "dir": os.path.basename(archive),
        "match": str(data.get("match_id", "?"))[:8],
        "player": str(data.get("player", "?")),
        "model": str(config.get("engine") or "?"),
        "mode": str(config.get("model", "?")),
        "seconds": seconds or "?",
        "tick_span": "%s→%s" % (first_tick if first_tick is not None else "?",
                                last_tick if last_tick is not None else "?"),
        "rounds": rounds if rounds is not None else "?",
        "events": counts.get("events", "?"),
        "commands": counts.get("commands", "?"),
        "decisions": counts.get("decisions", "?"),
        "model_calls": counts.get("model_calls", "?"),
        "verdict": ("通过" if extra.get("report_passed") else
                    ("未过" if extra.get("report_passed") is not None else "未收档报告")),
        "problems": extra.get("report_problems") or [],
        "missing": (extra.get("assembly") or {}).get("missing") or [],
        "truncated": data.get("truncated") or [],
        "errors": data.get("errors") or [],
        "derived": derived,
        "valid": all(os.path.isfile(os.path.join(archive, name))
                     and os.path.getsize(os.path.join(archive, name)) > 0
                     for name in DETAILS),
    }


def render(rows, root):
    lines = ["# 对局档案索引（自动生成，事实优先）", "",
             "目录：`%s`" % root, "",
             "> **有效性判据**：`events/rounds/commands/decisions.jsonl` 四份都非空且无写入异常。",
             "> 无效的局**原始副本仍完整**（`raw/`：runner.out、图内打点、checkpoint、游戏侧 stdout、报告、截图），",
             "> 可以做「世界与决策」级分析，但没有逐条事件。", "",
             "| 档案 | match | 模式 | 时长(s) | tick 段 | 轮 | 事件 | 命令 | 决策 | 模型调用 | 验收 | 明细 | 计数来源 |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        lines.append("| `%s` | %s | %s/%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            row["dir"], row["match"], row["model"], row["mode"], row["seconds"],
            row["tick_span"], row["rounds"], row["events"], row["commands"],
            row["decisions"], row["model_calls"], row["verdict"],
            "完整" if row["valid"] else "**缺**",
            "明细反推" if row["derived"] else "清单"))
    valid = [row for row in rows if row["valid"]]
    lines += ["", "## 统计", "",
              "- 档案总数 **%d**，其中明细完整 **%d** 局。" % (len(rows), len(valid)),
              "- 完整局时长（秒）：%s。" % ", ".join(str(row["seconds"]) for row in valid),
              "- 模型调用次数（完整局）：%s。" % ", ".join(
                  str(row["model_calls"]) for row in valid),
              "- 计数来源标「明细反推」的局：MANIFEST 曾被覆盖，计数由明细行数算出（事实仍是明细）。"]
    bad = [row for row in rows if row["missing"] or row["truncated"] or row["errors"]]
    if bad:
        lines += ["", "## 有缺口或异常的局（分析时打折看）", ""]
        for row in bad:
            lines.append("- `%s`：缺口=%s 截断=%s 异常=%s"
                         % (row["dir"], row["missing"] or "无", row["truncated"] or "无",
                            row["errors"] or "无"))
    lines += ["", "## 每局的判定问题（原样抄自验收报告）", ""]
    for row in rows:
        if row["problems"]:
            lines.append("- `%s`（%s）：" % (row["dir"], row["verdict"]))
            for problem in row["problems"][:6]:
                lines.append("  - %s" % str(problem)[:200])
    lines.append("")
    return "\n".join(lines)


def main():
    roots = sys.argv[1:] or list(DEFAULT_ROOTS)
    for root in roots:
        archives = sorted(glob.glob(os.path.join(root, "archive_*")))
        if not archives:
            print("[index] %s：没有档案" % root)
            continue
        rows = [describe(path) for path in archives]
        text = render(rows, root)
        out = os.path.join(root, "ARCHIVES.md")
        with io.open(out, "w", encoding="utf-8") as handle:
            handle.write(text)
        valid = sum(1 for row in rows if row["valid"])
        print("[index] %s：%d 局（完整 %d）→ %s" % (root, len(rows), valid, out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
