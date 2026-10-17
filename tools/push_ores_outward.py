#!/usr/bin/env python3
"""把贴基地的矿点外推（2026-09-30 用户口径）。

用户要"矿车跑一阵去采、再运回矿场"，所以矿点不能贴在基地边上。
规则：对每个矿点，取它到**最近起始点**的距离 d：
  - d >= NEAR_KEEP(28m)  -> 不动（远端/扩张矿保持原样）
  - d <  NEAR_KEEP       -> 沿"起始点 -> 矿点"方向外推到 TARGET(32m) + 每矿确定性抖动(0~6m)
方向保持 => 矿田走向、地图对称性不变。

用法：python tools/push_ores_outward.py <map.tscn> [--dry]
"""
import re
import sys
from pathlib import Path

NEAR_KEEP = 28.0
TARGET = 32.0
JITTER = 6.0


def main() -> int:
    path = Path(sys.argv[1])
    dry = "--dry" in sys.argv
    text = path.read_text(encoding="utf-8")
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(eol)

    # 关键：Resources / SpawnPoints 不是独立节点，而是写在子节点行的 parent="..." 上。
    spawns: list[tuple[float, float]] = []
    ores: list[tuple[int, int, float, float]] = []  # line_idx, order, x, z
    kind = ""
    for i, line in enumerate(lines):
        m = re.match(r'^\[node name="([^"]+)"(.*)\]', line)
        if m:
            parent = re.search(r'parent="([^"]*)"', m.group(2))
            parent_path = parent.group(1) if parent else ""
            kind = "spawn" if parent_path == "SpawnPoints" else ("ore" if parent_path == "Resources" or parent_path.startswith("Resources/") else "")
            continue
        if line.startswith("transform = Transform3D(") and kind:
            vals = [float(v) for v in line[line.index("(") + 1:line.rindex(")")].split(",")]
            x, z = vals[9], vals[11]
            if kind == "spawn":
                spawns.append((x, z))
            else:
                ores.append((i, len(ores), x, z))

    if not spawns or not ores:
        print(f"{path.name}: 起始点 {len(spawns)} / 矿 {len(ores)} -> 跳过")
        return 0

    moved = []
    for idx, (line_no, order, x, z) in enumerate(ores):
        d = min(((x - sx) ** 2 + (z - sz) ** 2) ** 0.5 for sx, sz in spawns)
        if d >= NEAR_KEEP:
            continue
        sx, sz = min(spawns, key=lambda s: (x - s[0]) ** 2 + (z - s[1]) ** 2)
        dx, dz = x - sx, z - sz
        norm = (dx * dx + dz * dz) ** 0.5
        if norm < 0.001:
            dx, dz, norm = 1.0, 0.0, 1.0
        target = TARGET + (JITTER * ((order * 37) % 5) / 4.0)
        nx, nz = sx + dx / norm * target, sz + dz / norm * target
        line = lines[line_no]
        vals = [float(v) for v in line[line.index("(") + 1:line.rindex(")")].split(",")]
        vals[9], vals[11] = nx, nz
        lines[line_no] = "transform = Transform3D(" + ", ".join(
            ("%.6g" % v) for v in vals) + ")"
        moved.append((d, target))

    if not dry and moved:
        path.write_text(eol.join(lines), encoding="utf-8")
    print(f"{path.name}: 矿 {len(ores)} 个，外推 {len(moved)} 个（{NEAR_KEEP:g}m 以内 -> {TARGET:g}m±{JITTER:g}）"
          + ("  [dry]" if dry else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
