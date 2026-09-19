# -*- coding: utf-8 -*-
"""跨语言 parity 校验：Godot 规则地板 vs Python 规则地板必须**逐字节同序**。

为什么需要它：`source/match/augments/AugmentRanker.gd` 与
`source/adjutant_coordinator/graph/augment_rank.py` 是同一套规则地板的两份实现。
副官超时/无 LLM 时用 Python 那份，Godot 侧自带兜底 —— 两份不一致时，同一个兵局
会出现「副官推荐 A、兜底选 B」，而且**不会报任何错**。

用法（在本目录或任意位置）：
    python tools/check_augment_rank_parity.py
    GODOT_BIN=<godot 可执行文件> python tools/check_augment_rank_parity.py

退出码：0 = 一致；1 = 分叉（会打印第一处不同的行）；2 = 环境不可用（找不到 Godot 等）。

纪律：
- 用**真实牌库** `config/match_augments.json` 全量牌，不用手搓的假牌，否则测不到真实数据。
- 探针是临时生成的（`_rank_parity_probe.gd`），跑完在 finally 里删掉，仓库零残留。
- 事实集在两侧各写一份，探针会把用到的事实一起打出来 ⇒ 事实漂移会直接表现为 diff，
  不会出现「两边用不同输入所以看起来一致」的假绿。
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
PROBE_REL = "tools/_rank_parity_probe.gd"
PROBE_ABS = REPO_ROOT / PROBE_REL

DEFAULT_GODOT = (r"G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64"
                 r"/Godot_v4.7.1-stable_mono_win64_console.exe")

# 事实集：两侧各写一份，探针会把事实回显 ⇒ 漂移会变成 diff。
CASES = [
    {"army_count": 1, "balance_a": 80, "enemy_count": 0, "structure_count": 1},
    {"army_count": 8, "balance_a": 9000, "enemy_count": 3, "structure_count": 4},
    {"army_count": 0, "balance_a": 3000, "enemy_count": 0, "structure_count": 0},
    {"army_count": 4, "balance_a": 600, "enemy_count": 5, "structure_count": 2},
]

PROBE_SOURCE = '''extends SceneTree

## 本文件由 tools/check_augment_rank_parity.py 临时生成，跑完即删。不要提交。

const Ranker = preload("res://source/match/augments/AugmentRanker.gd")

const CASES := {cases}


func _initialize() -> void:
	var raw := FileAccess.get_file_as_string("res://config/match_augments.json")
	var data = JSON.parse_string(raw)
	if not data is Dictionary:
		print("PARITY_ERR|cannot read catalog")
		quit(1)
		return
	var cards: Array = data.get("cards", [])
	print("PARITY_CARDS|", cards.size())
	for facts in CASES:
		var out: Dictionary = Ranker.rank(cards, facts, {{}})
		print("PARITY|", JSON.stringify(facts), "|", JSON.stringify(out.get("order", [])))
	quit(0)
'''


def _json_compact(value) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def _run_godot_side() -> list[str]:
    godot = os.environ.get("GODOT_BIN") or DEFAULT_GODOT
    if not Path(godot).is_file():
        raise RuntimeError(f"找不到 Godot 可执行文件：{godot}（用 GODOT_BIN 覆盖）")
    PROBE_ABS.write_text(PROBE_SOURCE.format(cases=_gd_const(CASES)), encoding="utf-8")
    try:
        proc = subprocess.run(
            [godot, "--headless", "--path", str(REPO_ROOT), "--script", f"res://{PROBE_REL}"],
            cwd=str(REPO_ROOT), capture_output=True, text=True, errors="replace", timeout=300,
        )
        lines = [ln for ln in proc.stdout.splitlines() if ln.startswith("PARITY")]
        if not lines:
            raise RuntimeError(
                "Godot 侧没有任何 PARITY 输出；"
                f"exit={proc.returncode}\nstdout tail:\n" + "\n".join(proc.stdout.splitlines()[-20:]))
        return lines
    finally:
        for path in (PROBE_ABS, PROBE_ABS.with_suffix(".gd.uid")):
            if path.exists():
                path.unlink()


def _gd_const(cases) -> str:
    """GDScript 侧的事实集字面量，与 CASES 同序同值。"""
    rows = []
    for case in cases:
        inner = ", ".join(f'"{k}": {int(v)}' for k, v in sorted(case.items()))
        rows.append("\t{" + inner + "},")
    return "[\n" + "\n".join(rows) + "\n]"


def _run_python_side() -> list[str]:
    # 与 `source/adjutant_coordinator/tests/test_augment_rank.py` 同口径：把 `source/`
    # 放进 sys.path，再按 `adjutant_coordinator.graph` 导入。
    sys.path.insert(0, str(REPO_ROOT / "source"))
    from adjutant_coordinator.graph import augment_rank as ar  # noqa: PLC0415

    cards = json.loads((REPO_ROOT / "config" / "match_augments.json").read_text(encoding="utf-8"))["cards"]
    lines = [f"PARITY_CARDS|{len(cards)}"]
    for facts in CASES:
        out = ar.rank_offer({"offer": cards, "facts": dict(facts), "profile": {}}, live=None)
        lines.append(f"PARITY|{_json_compact(facts)}|{_json_compact(out['order'])}")
    return lines


def _normalize(line: str) -> str:
    """只对齐 JSON 键序，不动顺序本身（顺序正是被测对象）。"""
    if not line.startswith("PARITY|"):
        return line
    _, facts, order = line.split("|", 2)
    return f"PARITY|{json.dumps(json.loads(facts), separators=(',', ':'), sort_keys=True)}|{order}"


def main() -> int:
    try:
        godot_lines = [_normalize(ln) for ln in _run_godot_side()]
    except Exception as exc:  # noqa: BLE001
        print(f"[PARITY] 环境不可用：{exc}")
        return 2
    try:
        py_lines = [_normalize(ln) for ln in _run_python_side()]
    except Exception as exc:  # noqa: BLE001
        print(f"[PARITY] Python 侧失败：{exc}")
        return 2

    if len(godot_lines) != len(py_lines):
        print(f"[PARITY] 行数不同：Godot {len(godot_lines)} vs Python {len(py_lines)}")
        return 1
    for i, (gd, py) in enumerate(zip(godot_lines, py_lines)):
        if gd != py:
            print(f"[PARITY] 第 {i} 行分叉：")
            print(f"  Godot : {gd}")
            print(f"  Python: {py}")
            return 1
    print(f"[PARITY] OK —— {len(godot_lines)} 行逐字节一致"
          f"（真实牌库 {godot_lines[0].split('|')[1]} 张 × {len(CASES)} 组事实）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
