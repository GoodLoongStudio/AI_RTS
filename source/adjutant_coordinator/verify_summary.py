# -*- coding: utf-8 -*-
"""summary.json 独立校验器：从 results 重算 PASS/FAIL/SKIP 并比对。

用法：python verify_summary.py <path/to/summary.json> [更多 summary.json ...]
- 强制 UTF-8 读取；
- 顶层 PASS/FAIL/SKIP 与 counts.* 必须与重算一致；
- SKIP 不计入 PASS；未知结果类型视为失败；
- 任何不一致以非零退出码失败（自动复核不得基于失真汇总继续）。
"""

import json
import sys


def verify(path):
    with open(path, "r", encoding="utf-8") as handle:
        summary = json.load(handle)
    recomputed = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    results = summary.get("results", [])
    for entry in results:
        kind = str(entry.get("kind", "")).upper()
        if kind not in recomputed:
            raise ValueError("%s: 未知结果类型 %r" % (path, kind))
        recomputed[kind] += 1
    problems = []
    for key in ("PASS", "FAIL", "SKIP"):
        top = summary.get(key)
        if top is None:
            problems.append("%s: 缺少顶层 %s 字段" % (path, key))
        elif int(top) != recomputed[key]:
            problems.append("%s: 顶层 %s=%s 与重算 %d 不一致" % (path, key, top, recomputed[key]))
        counts_value = summary.get("counts", {}).get(key)
        if counts_value is not None and int(counts_value) != recomputed[key]:
            problems.append("%s: counts.%s=%s 与重算 %d 不一致" % (
                path, key, counts_value, recomputed[key]))
    if recomputed["PASS"] + recomputed["FAIL"] + recomputed["SKIP"] != len(results):
        problems.append("%s: 计数总和 %d 与 results 条数 %d 不一致" % (
            path, recomputed["PASS"] + recomputed["FAIL"] + recomputed["SKIP"], len(results)))
    return recomputed, problems


def main():
    if len(sys.argv) < 2:
        print("用法: python verify_summary.py <summary.json> [...]", file=sys.stderr)
        return 2
    failures = 0
    for path in sys.argv[1:]:
        try:
            counts, problems = verify(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print("[FAIL] %s: %s" % (path, exc))
            failures += 1
            continue
        if problems:
            for problem in problems:
                print("[FAIL] %s" % problem)
            failures += 1
        else:
            print("[PASS] %s -> PASS=%d FAIL=%d SKIP=%d" % (
                path, counts["PASS"], counts["FAIL"], counts["SKIP"]))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
