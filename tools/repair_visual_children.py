#!/usr/bin/env python3
"""修复：Visual 分支**内部**的节点被误乘了 root scale。

规则：只有 UnitRoot 的直接子节点承担了"根缩放继承"，迁移时需要补偿；
Geometry 内部的后代已经继承 Geometry 自己的缩放，必须保持原样。
本脚本用 tests/automated/_premigration/<Name>.tscn（git HEAD 副本）把
Visual 内部节点的 transform 还原。
"""
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = Path(r"G:\AIRTS\AI_RTS")
SCENES = ["Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Drone", "Scout",
          "Infantry", "Helicopter", "Rocketeer", "Sniper"]

def blocks(text):
    """返回 [(header, name, parent, body_lines, start, end)]"""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        m = re.match(r'^\[node name="([^"]+)"(.*)\]$', lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and not lines[j].startswith("[node "):
            j += 1
        parent = ""
        pm = re.search(r'parent="([^"]*)"', m.group(2))
        if pm:
            parent = pm.group(1)
        out.append((lines[i], m.group(1), parent, lines[i + 1:j]))
        i = j
    return out

for name in SCENES:
    cur_path = REPO / "source/match/units" / f"{name}.tscn"
    pre_path = REPO / "tests/automated/_premigration" / f"{name}.tscn"
    cur = cur_path.read_text(encoding="utf-8")
    pre = pre_path.read_text(encoding="utf-8")
    pre_tf = {}
    for header, node, parent, body in blocks(pre):
        tf = next((b for b in body if b.startswith("transform = ")), None)
        pre_tf[node] = tf
    fixed = 0
    for header, node, parent, body in blocks(cur):
        if "Geometry" not in parent:
            continue          # 只看 Visual 内部
        tm = re.search(r'^transform = (.*)$', "\n".join(body), re.M)
        if not tm:
            continue
        original = pre_tf.get(node)
        want = original if original else None
        seg = header + "\n" + "\n".join(body)
        if want is None:
            new_seg = seg.replace("transform = " + tm.group(1) + "\n", "", 1)
            if not new_seg.endswith("\n"):
                pass
        else:
            new_seg = seg.replace("transform = " + tm.group(1), want, 1)
        if new_seg != seg:
            cur = cur.replace(seg, new_seg, 1)
            fixed += 1
    cur_path.write_text(cur, encoding="utf-8")
    print(f"{name}: 还原 Visual 内部节点 {fixed} 处")
