#!/usr/bin/env python3
"""修复炮塔场景的过度迁移：Geometry 与几何内部 Marker 必须保持原样。

炮塔的 Visual 挂在 DetachTransform 下、且 PositionSynchronizer 是 update_scale=false，
实测（2026-09-30 快照 + 第 5 轮探针）**不吃根缩放**，因此迁移时不得给它乘 root scale。
本脚本：从 git 取回原文件，只重放"该改"的部分。
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(r"G:\AIRTS\AI_RTS")
TURRETS = ["AntiGroundTurret", "AntiAirTurret", "MachineGunTurret"]
WORLD = ("CollisionShape3D", "Highlight", "Selection", "Targetability")
APPEAR = ("HealthBar", "RallyPoint")


def scale_transform(tokens, n, basis=True):
    vals = [float(t) for t in tokens]
    if basis:
        for i in range(9):
            vals[i] *= n
    for i in range(9, 12):
        vals[i] *= n
    return ", ".join("%g" % v for v in vals)


for name in TURRETS:
    rel = f"source/match/units/{name}.tscn"
    orig = subprocess.run(["git", "-C", str(REPO), "show", f"HEAD:{rel}"],
                          capture_output=True, text=True, encoding="utf-8").stdout
    # 根缩放：只取第一个 [node ...] 块内的 scale（块内扫描，避免被块收集逻辑吃掉）
    root_block = re.search(r'^\[node name="[^"]+"[^\]]*\]\r?\n((?:(?!\[node ).)*)', orig, re.M | re.S)
    n = float(re.search(r"scale = Vector3\(([-\d.]+)", root_block.group(1)).group(1))
    # 从文本里摘掉根节点的 scale 行（后续不再处理它）
    orig = orig.replace("scale = Vector3(%g, %g, %g)\n" % (n, n, n), "", 1)
    orig = orig.replace("scale = Vector3(%g, %g, %g)\r\n" % (n, n, n), "", 1)
    lines = orig.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^\[node name="([^"]+)"(.*)\]$', line)
        if not m:
            out.append(line)
            i += 1
            continue
        node, rest = m.group(1), m.group(2)
        block = [line]
        j = i + 1
        while j < len(lines) and not lines[j].startswith("[node "):
            block.append(lines[j])
            j += 1
        body = block[1:]
        in_detached = "DetachTransform" in rest or "Geometry/" in rest
        t_idx = next((k for k, b in enumerate(body) if b.startswith("transform = ")), None)
        if node in WORLD and not in_detached:
            if t_idx is not None:
                toks = re.match(r"^transform = Transform3D\(([^)]*)\)$", body[t_idx].strip()).group(1)
                body[t_idx] = "transform = Transform3D(%s)" % scale_transform([t.strip() for t in toks.split(",")], n, basis=False)
            for k, b in enumerate(body):
                mm = re.match(r"^radius = ([-\d.]+)$", b)
                if mm:
                    body[k] = "radius = %g" % (float(mm.group(1)) * n)
        elif node in APPEAR and not in_detached:
            if t_idx is not None:
                toks = re.match(r"^transform = Transform3D\(([^)]*)\)$", body[t_idx].strip()).group(1)
                body[t_idx] = "transform = Transform3D(%s)" % scale_transform([t.strip() for t in toks.split(",")], n)
        out.append("\n".join(block[:1] + body))
        i = j
    text = "\n".join(out)
    # shape 子资源 ×n
    for sid in set(re.findall(r'^shape = SubResource\("([^"]+)"\)$', text, re.M)):
        blk = re.search(r'\[sub_resource type="CylinderShape3D" id="%s"\](.*?)(?=\n\[|\Z)' % re.escape(sid), text, re.S)
        if not blk:
            continue
        seg = blk.group(0)
        new = seg
        for prop in ("radius", "height"):
            mm = re.search(r"^%s = ([-\d.]+)$" % prop, seg, re.M)
            if mm:
                new = new.replace(mm.group(0), "%s = %g" % (prop, float(mm.group(1)) * n))
        if new != seg:
            text = text.replace(seg, new)
    (REPO / rel).write_text(text, encoding="utf-8")
    print(f"{name}: 已按原文件重放（root {n:g}->1，Geometry/Marker 保持原样）")
