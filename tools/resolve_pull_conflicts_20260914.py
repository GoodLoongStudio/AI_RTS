# -*- coding: utf-8 -*-
"""解 `git stash pop` 造成的两个冲突（只做一件事：**双方内容都保留**）。

冲突 1 `project.godot`：上游删掉了 max_fps 的注释块、本地把注释改写并锁 60 + 新增
`PerformanceGovernor` autoload → 取"上游的全部 autoload/设置 + 本地的锁 60 与 governor"。
冲突 2 `config/full_regression_suite.json`：两边各自往 `godot_tests` 追加测试套件
（上游 6 个、本地 1 个 `performance-governor`）→ **按 id 取并集**。

只读三个版本（`:2:` = 上游/合并后，`:3:` = 本地在途，`stash@{0}` = 本地版本），
写回工作区文件；不动 git 状态（add/reset 由外层命令做）。
"""
import io
import json
import subprocess
import sys

ROOT = r"G:\AIRTS\AI_RTS"
project_rel = "project.godot"
json_rel = "config/full_regression_suite.json"


def show(spec):
    return subprocess.check_output(["git", "show", spec], cwd=ROOT).decode("utf-8")


def resolve_project_godot():
    upstream = show(":2:" + project_rel)
    lines = upstream.splitlines()
    out = []
    inserted_governor = False
    removed_upstream_fps = False
    for line in lines:
        if line.strip() == "run/max_fps=120":
            # 上游在这里的 120 与本地"锁 60"是同一项设置：保留本地口径（用户 2026-09-14 明确要求锁 60）。
            out.append("; 帧率上限：不设时 max_fps=0（不限帧），低多边形场景会被渲染到 GPU 物理极限")
            out.append("; 【2026-09-14 用户要求】改为 **锁 60 帧**：目标是\"尽可能稳住 60\"而不是追高帧率；")
            out.append("; 单位多时由 `PerformanceGovernor`（autoload）**动态降画质**保帧率，")
            out.append("; 上限可在 `user://performance.cfg` 的 `max_fps` 覆盖。")
            out.append("run/max_fps=60")
            removed_upstream_fps = True
            continue
        out.append(line)
        if line.strip() == 'Globals="*res://source/Globals.gd"':
            # 本地新增的 autoload：必须放在 Globals 之后、MatchSignals 之前（与在途版本一致）。
            out.append("; 帧率治理（默认锁 60 + 单位多自动降画质）：必须早于对局加载，故放这里；")
            out.append("; headless 专用服会自行禁用（没有渲染可调，也不该占 CPU）。")
            out.append('PerformanceGovernor="*res://source/PerformanceGovernor.gd"')
            inserted_governor = True
    assert removed_upstream_fps, "没找到上游的 run/max_fps=120（模板变了，先看再改）"
    assert inserted_governor, "没找到 Globals autoload 行（模板变了，先看再改）"
    text = "\n".join(out) + "\n"
    assert "<<<<<<<" not in text and ">>>>>>>" not in text
    io.open(ROOT + "\\" + project_rel, "w", encoding="utf-8", newline="\n").write(text)
    return {"max_fps_60": "run/max_fps=60" in text,
            "governor_autoload": 'PerformanceGovernor="*res://source/PerformanceGovernor.gd"' in text,
            "upstream_autoloads_kept": all(
                token in text for token in ("MatchSignals=", "MenuMusic=", "MCPRuntimeProbe="))}


def resolve_suite_json():
    merged = json.loads(show(":2:" + json_rel))
    local = json.loads(show(":3:" + json_rel))
    have = {str(item.get("id")) for item in merged.get("godot_tests", [])
            if isinstance(item, dict)}
    added = []
    for item in local.get("godot_tests", []):
        if not isinstance(item, dict):
            continue
        key = str(item.get("id"))
        if key in have:
            continue
        merged["godot_tests"].append(item)
        have.add(key)
        added.append(key)
    text = json.dumps(merged, indent=1, ensure_ascii=False) + "\n"
    io.open(ROOT + "\\" + json_rel, "w", encoding="utf-8", newline="\n").write(text)
    check = json.loads(io.open(ROOT + "\\" + json_rel, encoding="utf-8").read())
    return {"added_from_local": added, "total_suites": len(check["godot_tests"]),
            "upstream_ids_kept": all(
                any(str(i.get("id")) == token for i in check["godot_tests"])
                for token in ("apc-smoke", "presentation-sync", "repair-sell-targeting"))}


report = {"project_godot": resolve_project_godot(), "full_regression_suite": resolve_suite_json()}
print(json.dumps(report, ensure_ascii=False, indent=1))
sys.exit(0)
