"""规则 AI 对局批跑与验收工具（COMPUTER_AI_PLAN S4）。

用户确认的"分阶段扩样"落在这里：

  --stage smoke    **短局筛选**：跑全部 RuleAi* 冒烟测试，汇总通过/失败。
                   这是"先用短局/少量种子筛出明显失败"的第一阶段。
  --stage match    **真实对局**：生成指定难度的临时场景，headless 起局跑 N 帧，
                   采集 AI 埋点（难度配置 / 首波出击 / 再次出击），输出 JSON。

埋点来源（AI 侧 print，格式化稳定）：
  - `规则 AI 难度=<D> 首波=<a>s 再派=<b>s 情报复查=<c>s`   （SimpleClairvoyantAI 启动日志）
  - `规则 AI 首波出击 @<t>s 人数=<n>`                       （AutoAttackingBattlegroup）
  - `规则 AI 再次出击 @<t>s 人数=<n>`                       （AutoAttackingBattlegroup）

用法：
  python tools/rule_ai_match_batch.py --stage smoke
  python tools/rule_ai_match_batch.py --stage match --difficulty EASY  --frames 10800
  python tools/rule_ai_match_batch.py --stage match --difficulty HARD  --frames 10800

输出：review/computer_ai_plan_20260917/rule_ai_batch_<stage>_<时间戳>.json
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

GODOT = (
    r"G:\AIRTS\godot_mono_471\Godot_v4.7.1-stable_mono_win64"
    r"\Godot_v4.7.1-stable_mono_win64_console.exe"
)
PROJECT = Path(r"G:\AIRTS\AI_RTS")
REPORT_DIR = Path(r"G:\AIRTS\review\computer_ai_plan_20260917")

SMOKES = [
    "RuleAiAggressionSmokeTest",
    "RuleAiBattlegroupSmokeTest",
    "RuleAiDefenseSmokeTest",
    "RuleAiEconomyQuerySmokeTest",
    "RuleAiExpansionSmokeTest",
    "RuleAiIntelligenceSmokeTest",
    "RuleAiOffenseLogisticsSmokeTest",
]

DIFFICULTY_VALUE = {"EASY": 0, "NORMAL": 1, "HARD": 2}
AI_NODE_LINE = (
    '[node name="SimpleClairvoyantAI" parent="Players" index="1" '
    'instance=ExtResource("15_6w32d")]'
)
FALLBACK_AI_NODE_RE = re.compile(
    r'\[node name="SimpleClairvoyantAI"[^\]]*instance=[^\]]+\]'
)

DIFF_BANNER_RE = re.compile(
    r"规则 AI 难度=(\S+) 首波=([\d.]+)s 再派=([\d.]+)s 情报复查=([\d.]+)s"
)
FIRST_WAVE_RE = re.compile(r"规则 AI 首波出击 @([\d.]+)s 人数=(\d+)")
RE_WAVE_RE = re.compile(r"规则 AI 再次出击 @([\d.]+)s 人数=(\d+)")


def run_godot(args: list[str], timeout_s: float) -> tuple[int, str]:
    proc = subprocess.run(
        [GODOT, "--headless", "--path", str(PROJECT), *args],
        capture_output=True,
        text=True,
        # ⚠ Godot 输出是 UTF-8；Windows 默认 GBK 解码会把中文埋点变成乱码，
        # 导致"规则 AI 首波出击"等正则全部匹配失败（曾据此误判为"没出击"）。
        encoding="utf-8",
        errors="replace",
        timeout=timeout_s,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def parse_smoke(output: str) -> int | None:
    match = re.search(r"completed: (\d+) failure", output)
    return int(match.group(1)) if match else None


def stage_smoke() -> dict:
    results = []
    for name in SMOKES:
        started = time.time()
        try:
            code, out = run_godot(
                [f"res://tests/automated/{name}.tscn"], timeout_s=900
            )
            failures = parse_smoke(out)
            results.append(
                {
                    "test": name,
                    "exit_code": code,
                    "failures": failures,
                    "seconds": round(time.time() - started, 1),
                    "ok": code == 0 and failures == 0,
                }
            )
        except subprocess.TimeoutExpired:
            results.append(
                {
                    "test": name,
                    "exit_code": None,
                    "failures": None,
                    "seconds": round(time.time() - started, 1),
                    "ok": False,
                    "error": "timeout",
                }
            )
        print(f"  {results[-1]['test']}: {'OK' if results[-1]['ok'] else 'FAIL'}"
              f" (failures={results[-1]['failures']})")
    summary = {
        "stage": "smoke",
        "total": len(results),
        "passed": sum(1 for item in results if item["ok"]),
        "results": results,
    }
    return summary


def stage_match(difficulty: str, frames: int, timeout_s: float) -> dict:
    source = PROJECT / "tests/manual/TestPlayerVsAI.tscn"
    content = source.read_text(encoding="utf-8")
    if AI_NODE_LINE in content:
        marker = AI_NODE_LINE
    else:
        match = FALLBACK_AI_NODE_RE.search(content)
        if not match:
            raise SystemExit("TestPlayerVsAI.tscn 中找不到 SimpleClairvoyantAI 节点行")
        marker = match.group(0)
    patched = content.replace(
        marker, f"{marker}\ndifficulty = {DIFFICULTY_VALUE[difficulty]}", 1
    )
    temp_scene = PROJECT / f"tests/automated/_BatchMatch_{difficulty}.tscn"
    temp_scene.write_text(patched, encoding="utf-8")
    print(f"  临时场景: {temp_scene.name}  难度={difficulty}  帧数={frames}")
    try:
        code, out = run_godot(
            ["--quit-after", str(frames), f"res://tests/automated/_BatchMatch_{difficulty}.tscn"],
            timeout_s=timeout_s,
        )
    finally:
        temp_scene.unlink(missing_ok=True)

    difficulty_banner = DIFF_BANNER_RE.search(out)
    first_wave = FIRST_WAVE_RE.search(out)
    re_waves = [(float(t), int(n)) for t, n in RE_WAVE_RE.findall(out)]
    return {
        "stage": "match",
        "difficulty": difficulty,
        "frames": frames,
        "exit_code": code,
        "sim_seconds_budget": round(frames / 60.0, 1),
        "difficulty_banner": difficulty_banner.group(0) if difficulty_banner else None,
        "first_wave_s": round(float(first_wave.group(1)), 1) if first_wave else None,
        "first_wave_size": int(first_wave.group(2)) if first_wave else None,
        "re_waves": [{"at_s": t, "size": n} for t, n in re_waves],
        "wave_count": (1 if first_wave else 0) + len(re_waves),
        "raw_log_tail": out[-8000:],
        "full_log_available": True,
        "full_log": out,
        "production_denials": len(re.findall(r"被拒绝", out)),
        "gather_started": len(re.findall(r"\[GATHER\] 进入 MOVING_TO_RESOURCE", out)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", choices=["smoke", "match"], required=True)
    parser.add_argument("--difficulty", choices=list(DIFFICULTY_VALUE), default="NORMAL")
    parser.add_argument("--frames", type=int, default=10800, help="60fps × 秒数")
    parser.add_argument("--timeout", type=float, default=1800.0)
    args = parser.parse_args()

    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    if args.stage == "smoke":
        summary = stage_smoke()
    else:
        summary = stage_match(args.difficulty, args.frames, args.timeout)

    stamp = time.strftime("%Y%m%d_%H%M%S")
    if args.stage == "match" and summary.get("full_log_available"):
        log_path = REPORT_DIR / f"rule_ai_batch_match_{stamp}.log"
        log_path.write_text(summary.pop("full_log"), encoding="utf-8")
        summary["log_file"] = str(log_path)
    out_path = REPORT_DIR / f"rule_ai_batch_{args.stage}_{stamp}.json"
    out_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"\n报告: {out_path}")
    if args.stage == "smoke":
        print(f"通过 {summary['passed']}/{summary['total']}")
        return 0 if summary["passed"] == summary["total"] else 1
    print(
        f"难度={summary['difficulty']} 首波={summary['first_wave_s']}s "
        f"再派次数={len(summary['re_waves'])}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
