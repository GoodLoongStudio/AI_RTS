#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""无头真实 Match AI 性能探针驱动（2026-10-11 阶段一）。

在一个只属于本轮的 headless Godot 进程里跑真实 Match（1/3 个电脑玩家、
PlainAndSimple、相同 difficulty），采集帧时间分布、模拟时钟、实体量与
AIRTS_AI_PERF_STATS=1 插桩计数，输出 JSON 到指定目录。

所有权与清理完全走 tools/dev/match_instance.py 的 Instance（端口动态分配、
登记发现、按 pid 树清理），不按进程名/端口杀别人。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[0]
sys.path.insert(0, str(HERE))

from match_instance import Instance, allocate_ports, godot_exe  # noqa: E402

ERROR_RE = re.compile(r"SCRIPT ERROR:|Parse Error:|^ERROR:", re.MULTILINE)
MARKER_RE = re.compile(r"AI_PERF_PROBE completed reason=(\S+) frames=(\d+)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="输出目录（本轮证据目录）")
    parser.add_argument("--ai-count", type=int, default=1, choices=[1, 2, 3])
    parser.add_argument("--frames", type=int, default=5400,
                        help="预热后采样的物理帧数")
    parser.add_argument("--warmup-frames", type=int, default=300)
    parser.add_argument("--difficulty", type=int, default=1)
    parser.add_argument("--extra-units", type=int, default=0,
                        help="每名玩家额外脚本单位数（仅负载对齐）")
    parser.add_argument("--watchdog-s", type=float, default=900.0)
    parser.add_argument("--perf-stats", action="store_true", default=True,
                        help="默认开启 AIRTS_AI_PERF_STATS 插桩")
    parser.add_argument("--no-perf-stats", dest="perf_stats", action="store_false")
    parser.add_argument("--run-id", default="probe")
    args = parser.parse_args()

    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=True)
    result_json = output / ("ai_perf_%s_%d.json" % (
        args.run_id, int(time.time() * 1000) % 1000000))

    class ProbeInstance(Instance):
        def argv(self):
            # 本探针自带 JSON 输出、runner 内看门狗和 finally 按进程树清理；
            # 不带 --debugport（无 DCS）。注册/看门狗一并禁用（见下方环境覆盖）。
            return [godot_exe(), "--headless", "--path", str(PROJECT),
                    "res://tools/ai_perf_probe.tscn", "--",
                    "--perf-out=" + result_json.as_posix(),
                    "--ai-count=" + str(args.ai_count),
                    "--frames=" + str(args.frames),
                    "--warmup-frames=" + str(args.warmup_frames),
                    "--difficulty=" + str(args.difficulty),
                    "--extra-units=" + str(args.extra_units),
                    "--watchdog-s=" + str(args.watchdog_s),
                    "--run-id=" + args.run_id]

    instance = ProbeInstance("client", "ai-perf-" + str(os.getpid()),
                             allocate_ports(), log_dir=str(output))
    if args.perf_stats:
        instance.env_extra["AIRTS_AI_PERF_STATS"] = "1"
    # 2026-10-11 实测：完整 Instance 注册环境（AIRTS_INSTANCE_DIR/PARENT_PID/租约 +
    # --debugport + GODOT_BRIDGE_PORT 组合）会让探针进程停在 autoload 之前（仅输出
    # 版本头、CPU≈0，复现 2 次）。单项二分均不复现；本探针不依赖登记与调试口，
    # 按"已验证可行的最小调用"禁用注册（AIRTS_INSTANCE_DIR 清空 → 游戏侧惰性），
    # 所有权仍由本驱动的 Popen pid + finally stop() 保证。
    instance.env_extra["AIRTS_INSTANCE_DIR"] = ""

    started = time.time()
    try:
        instance.launch()
        deadline = time.monotonic() + args.watchdog_s + 240.0
        while instance.process.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("探针超过看门狗 %.0fs" % (args.watchdog_s + 240.0))
            time.sleep(0.5)
        rc = instance.process.returncode
        logs = "\n".join(
            path.read_text(encoding="utf-8", errors="replace")
            for path in sorted(output.glob("*.log"))
            if path.stat().st_mtime >= started)
        errors = ERROR_RE.findall(logs)
        marker = MARKER_RE.search(logs)
        if rc != 0 or not marker or errors:
            raise RuntimeError(
                "探针失败: rc=%s marker=%s errors=%s"
                % (rc, bool(marker), errors[:5]))
        if not result_json.exists() or result_json.stat().st_mtime < started:
            raise RuntimeError("缺少新鲜 JSON: %s" % result_json)
        data = json.loads(result_json.read_text(encoding="utf-8"))
        frame = data.get("frame_ms", {})
        print(json_dumps({
            "run_id": data.get("run_id"),
            "ai_count": data.get("ai_count"),
            "difficulty": data.get("difficulty"),
            "sampled_frames": data.get("sampled_frames"),
            "wall_s": round(data.get("wall_s", 0.0), 1),
            "sim_s": data.get("sim_s"),
            "units_final": data.get("units_final"),
            "resources_final": data.get("resources_final"),
            "frame_ms": {key: round(value, 2) for key, value in frame.items()},
            "json": str(result_json),
        }, ensure_ascii=False))
        return 0
    finally:
        instance.stop()


def json_dumps(payload, ensure_ascii=True):
    return json.dumps(payload, ensure_ascii=ensure_ascii, indent=2)


if __name__ == "__main__":
    sys.exit(main())
