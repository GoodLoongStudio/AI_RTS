#!/usr/bin/env python3
"""世界尺寸重平衡（2026-09-30 用户口径）。

对给定场景按系数 k 缩放"四口径"全部尺寸，保持视觉/碰撞/逻辑/carve 一致：
  - Geometry 节点：basis x k、origin x k（美术缩放挂在这里）
  - CollisionShape3D：origin x k；其引用的 CylinderShape3D 的 height/radius x k
  - MovementObstacle：origin x k、radius x k
  - Highlight / Selection / Targetability：origin x k、radius x k
  - HealthBar：origin x k、size x k
  - RallyPoint / ProductionQueue / 其它 Marker：origin x k
根节点 scale 不动（必须保持 1）。

用法：python tools/rebalance_unit_scale.py <scene.tscn> <k>
"""
import re
import sys
from pathlib import Path

ORIGIN_ONLY = {"RallyPoint", "ProductionQueue", "Movement", "SpawnPoint", "ExitPoint", "GroundFootprint", "AirToTerrainMarker"}
RING_NODES = {"Highlight", "Selection", "Targetability"}


def scale_transform(line: str, k: float) -> str:
    m = re.match(r"^(\s*transform = Transform3D\()([^)]*)(\)\s*)$", line)
    if not m:
        return line
    parts = [p.strip() for p in m.group(2).split(",")]
    vals = [float(p) for p in parts]
    out = vals[:9] + [v * k for v in vals[9:12]]
    txt = ", ".join(("%.6g" % v) for v in out)
    return f"{m.group(1)}{txt}{m.group(3)}"


def scale_basis_and_origin(line: str, k: float) -> str:
    m = re.match(r"^(\s*transform = Transform3D\()([^)]*)(\)\s*)$", line)
    if not m:
        return line
    vals = [float(p.strip()) for p in m.group(2).split(",")]
    out = [v * k for v in vals[:9]] + [v * k for v in vals[9:12]]
    return f"{m.group(1)}" + ", ".join(("%.6g" % v) for v in out) + m.group(3)


def scale_scalar(line: str, key: str, k: float) -> str:
    m = re.match(r"^(\s*%s = )(-?[\d.]+)(\s*)$" % key, line)
    if not m:
        return line
    return f"{m.group(1)}%.6g{m.group(3)}" % (float(m.group(2)) * k)


def scale_vector2(line: str, key: str, k: float) -> str:
    m = re.match(r"^(\s*%s = Vector2\()([^)]*)(\)\s*)$" % key, line)
    if not m:
        return line
    vals = [float(p.strip()) * k for p in m.group(2).split(",")]
    return f"{m.group(1)}" + ", ".join("%.6g" % v for v in vals) + m.group(3)


def main() -> int:
    scene = Path(sys.argv[1])
    k = float(sys.argv[2])
    text = scene.read_text(encoding="utf-8")
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(eol)
    changed = {"geometry": 0, "shape": 0, "origin": 0, "radius": 0, "size": 0}
    current = ""
    in_shape = False
    for i, line in enumerate(lines):
        node = re.match(r'^\[node name="([^"]+)"', line)
        if node:
            current = node.group(1)
            in_shape = False
            continue
        if line.startswith("[sub_resource"):
            in_shape = 'type="CylinderShape3D"' in line
            continue
        if line.startswith("["):
            in_shape = False
            continue
        if in_shape:
            if re.match(r"^\s*height = ", line) or re.match(r"^\s*radius = ", line):
                new = scale_scalar(line, "height" if "height" in line else "radius", k)
                if new != line:
                    changed["shape"] += 1
                    lines[i] = new
            continue
        if line.strip().startswith("transform = Transform3D("):
            if current == "Geometry" or current.startswith("Geometry"):
                new = scale_basis_and_origin(line, k)
                if new != line:
                    changed["geometry"] += 1
                    lines[i] = new
            elif current in ORIGIN_ONLY or current in RING_NODES or current in {"CollisionShape3D", "MovementObstacle", "HealthBar"}:
                new = scale_transform(line, k)
                if new != line:
                    changed["origin"] += 1
                    lines[i] = new
            continue
        if current in RING_NODES or current == "MovementObstacle":
            new = scale_scalar(line, "radius", k)
            if new != line:
                changed["radius"] += 1
                lines[i] = new
            continue
        if current == "HealthBar":
            new = scale_vector2(line, "size", k)
            if new != line:
                changed["size"] += 1
                lines[i] = new
            continue
    scene.write_text(eol.join(lines), encoding="utf-8")
    print(f"{scene.name}  x{k:g}  →  几何 {changed['geometry']} / 形状 {changed['shape']} / 原点 {changed['origin']} / 半径 {changed['radius']} / 血条 {changed['size']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
