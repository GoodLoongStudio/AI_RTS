"""把各图家里 ResourceA 拉近出生点（指挥中心）。

单侧主矿整簇平移，质心约 7.5 m；矿分列基地两侧时沿各自射线拉到 7.5 m。
单矿不低于 6 m。扩张/侧翼矿不动。
用法：
  python tools/pull_home_minerals.py           # 只打印
  python tools/pull_home_minerals.py --apply   # 写回 tscn
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

TARGET_CENTROID = 7.5
MIN_DIST = 6.0
HOME_RADIUS = 22.0
MIN_HOME_COUNT = 2
MAP_MARGIN = 2.0
SKIP_IF_WITHIN = 0.35
ONE_SIDED_RATIO = 0.55
OUTLIER_DIST = 8.5
OUTLIER_TARGET = 8.0

MAPS_DIR = Path(__file__).resolve().parents[1] / "source" / "match" / "maps"
NODE_RE = re.compile(r'^\[node name="([^"]+)"([^\]]*)\]\s*$')
TRANSFORM_RE = re.compile(r"^transform = Transform3D\((.+)\)\s*$")
SIZE_RE = re.compile(r"size = Vector2(?:i)?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)")
MAP_SIZE_RE = re.compile(
    r'\[node name="Map"[^\]]*\][^\[]*?size = Vector2(?:i)?\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)',
    re.S,
)
PARENT_RE = re.compile(r'parent="([^"]+)"')
NUM_RE = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")


def parse_floats(blob: str) -> list[float]:
    return [float(m.group(0)) for m in NUM_RE.finditer(blob)]


def fmt_num(value: float, sample: str) -> str:
    sample = sample.strip()
    if re.search(r"[eE]", sample):
        if abs(value) < 1e-4:
            return sample
        return f"{value:.6g}"
    if "." in sample:
        decimals = len(sample.split(".", 1)[1])
    else:
        decimals = 0
    decimals = max(3, min(decimals, 6))
    text = f"{value:.{decimals}f}"
    if text.startswith("-") and float(text) == 0.0:
        text = text[1:]
    return text


def replace_origin(line: str, nx: float, nz: float) -> str:
    match = TRANSFORM_RE.match(line.rstrip("\n"))
    if not match:
        raise ValueError(f"not a transform line: {line!r}")
    raw_parts = [p.strip() for p in match.group(1).split(",")]
    if len(raw_parts) != 12:
        raise ValueError(f"expected 12 components: {line!r}")
    raw_parts[9] = fmt_num(nx, raw_parts[9])
    raw_parts[11] = fmt_num(nz, raw_parts[11])
    newline = f"transform = Transform3D({', '.join(raw_parts)})"
    if line.endswith("\n"):
        newline += "\n"
    return newline


def basis_mul(basis: list[float], vec: tuple[float, float, float]) -> tuple[float, float, float]:
    x = basis[0] * vec[0] + basis[3] * vec[1] + basis[6] * vec[2]
    y = basis[1] * vec[0] + basis[4] * vec[1] + basis[7] * vec[2]
    z = basis[2] * vec[0] + basis[5] * vec[1] + basis[8] * vec[2]
    return (x, y, z)


def compose(parent: tuple[list[float], tuple[float, float, float]] | None,
            local_basis: list[float],
            local_origin: tuple[float, float, float]) -> tuple[list[float], tuple[float, float, float]]:
    if parent is None:
        return (local_basis[:], local_origin)
    p_basis, p_origin = parent
    child = (
        p_origin[0] + basis_mul(p_basis, local_origin)[0],
        p_origin[1] + basis_mul(p_basis, local_origin)[1],
        p_origin[2] + basis_mul(p_basis, local_origin)[2],
    )
    return (local_basis[:], child)


class NodeRec:
    def __init__(self, name: str, parent: str, header_line: int):
        self.name = name
        self.parent = parent
        self.header_line = header_line
        self.transform_line: int | None = None
        self.basis = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        self.origin = (0.0, 0.0, 0.0)

    @property
    def path(self) -> str:
        return f"{self.parent}/{self.name}" if self.parent else self.name


def parse_map_size(text: str) -> tuple[float, float]:
    match = MAP_SIZE_RE.search(text)
    if match:
        return float(match.group(1)), float(match.group(2))
    matches = list(SIZE_RE.finditer(text))
    if matches:
        last = matches[-1]
        return float(last.group(1)), float(last.group(2))
    return (256.0, 256.0)


def parse_map(path: Path) -> tuple[float, float, list[NodeRec], list[str]]:
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    map_size = parse_map_size(text)

    nodes: list[NodeRec] = []
    current: NodeRec | None = None
    for i, line in enumerate(lines):
        header = NODE_RE.match(line.rstrip("\n"))
        if header:
            parent_m = PARENT_RE.search(header.group(2))
            current = NodeRec(header.group(1), parent_m.group(1) if parent_m else "", i)
            nodes.append(current)
            continue
        if current is None:
            continue
        tr = TRANSFORM_RE.match(line.rstrip("\n"))
        if tr:
            nums = parse_floats(tr.group(1))
            if len(nums) == 12:
                current.basis = nums[:9]
                current.origin = (nums[9], nums[10], nums[11])
                current.transform_line = i

    return map_size[0], map_size[1], nodes, lines


def world_of(node: NodeRec, by_path: dict[str, NodeRec]) -> tuple[float, float, float]:
    chain: list[NodeRec] = []
    seen: set[str] = set()
    cur: NodeRec | None = node
    while cur is not None and cur.path not in seen:
        chain.append(cur)
        seen.add(cur.path)
        cur = by_path.get(cur.parent) if cur.parent else None
    wx = wy = wz = 0.0
    basis = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    for rec in reversed(chain):
        composed = compose((basis, (wx, wy, wz)), rec.basis, rec.origin)
        basis, (wx, wy, wz) = composed
    return (wx, wy, wz)


def hypot2(ax: float, az: float, bx: float, bz: float) -> float:
    return math.hypot(ax - bx, az - bz)


def process_map(path: Path, apply: bool) -> dict:
    width, depth, nodes, lines = parse_map(path)
    by_path = {n.path: n for n in nodes}

    spawns = [n for n in nodes if n.parent == "SpawnPoints" and "Marker3D" in n.name]
    resources = [n for n in nodes if n.name.startswith("ResourceA")]
    spawn_world = [world_of(n, by_path) for n in spawns]
    res_world = [world_of(n, by_path) for n in resources]
    orig_world = list(res_world)
    orig_local = [n.origin for n in resources]

    assigned: list[list[int]] = [[] for _ in spawns]
    for ri, (rx, _ry, rz) in enumerate(res_world):
        if not spawn_world:
            continue
        best_s = min(
            range(len(spawn_world)),
            key=lambda si: hypot2(rx, rz, spawn_world[si][0], spawn_world[si][2]),
        )
        assigned[best_s].append(ri)

    def clamp_xz(nx: float, nz: float) -> tuple[float, float]:
        return (
            min(max(nx, MAP_MARGIN), width - MAP_MARGIN),
            min(max(nz, MAP_MARGIN), depth - MAP_MARGIN),
        )

    def push_min(sx: float, sz: float, nx: float, nz: float) -> tuple[float, float]:
        dist = hypot2(nx, nz, sx, sz)
        if dist < 1e-6:
            return (sx + MIN_DIST, sz)
        if dist < MIN_DIST:
            push = MIN_DIST / dist
            return (sx + (nx - sx) * push, sz + (nz - sz) * push)
        return (nx, nz)

    updates: dict[int, tuple[float, float]] = {}

    def commit_world(ri: int, nx: float, nz: float) -> None:
        rec = resources[ri]
        if rec.transform_line is None:
            return
        ox, oy, oz = orig_world[ri]
        updates[rec.transform_line] = (
            orig_local[ri][0] + (nx - ox),
            orig_local[ri][2] + (nz - oz),
        )
        res_world[ri] = (nx, oy, nz)

    def radial_to(ri: int, sx: float, sz: float, target: float) -> None:
        rx, _ry, rz = res_world[ri]
        dist = hypot2(rx, rz, sx, sz)
        if dist < 1e-6:
            nx, nz = clamp_xz(*push_min(sx, sz, sx + target, sz))
        else:
            scale = target / dist
            nx, nz = clamp_xz(*push_min(
                sx, sz, sx + (rx - sx) * scale, sz + (rz - sz) * scale
            ))
        commit_world(ri, nx, nz)

    report = []
    for si, spawn in enumerate(spawn_world):
        sx, _sy, sz = spawn
        members = assigned[si]
        if not members:
            report.append((si, sx, sz, [], [], [], "none"))
            continue
        members = sorted(
            members,
            key=lambda ri: hypot2(res_world[ri][0], res_world[ri][2], sx, sz),
        )
        home = [
            ri for ri in members
            if hypot2(res_world[ri][0], res_world[ri][2], sx, sz) <= HOME_RADIUS
        ]
        if len(home) < min(MIN_HOME_COUNT, len(members)):
            home = members[: min(MIN_HOME_COUNT, len(members))]
        before_ds = [hypot2(res_world[ri][0], res_world[ri][2], sx, sz) for ri in home]
        mean_d = sum(before_ds) / len(before_ds)
        cx = sum(res_world[ri][0] for ri in home) / len(home)
        cz = sum(res_world[ri][2] for ri in home) / len(home)
        centroid_d = hypot2(cx, cz, sx, sz)
        one_sided = centroid_d >= ONE_SIDED_RATIO * mean_d
        note = "skip"
        if max(before_ds) <= OUTLIER_DIST:
            after_ds = before_ds
            report.append((si, sx, sz, home, before_ds, after_ds, note))
            continue
        if one_sided and centroid_d > TARGET_CENTROID + SKIP_IF_WITHIN and centroid_d > 1e-6:
            scale = TARGET_CENTROID / centroid_d
            dx = (cx - sx) * (scale - 1.0)
            dz = (cz - sz) * (scale - 1.0)
            for ri in home:
                rx, _ry, rz = res_world[ri]
                nx, nz = clamp_xz(*push_min(sx, sz, rx + dx, rz + dz))
                commit_world(ri, nx, nz)
            note = "cluster"
        elif not one_sided:
            pulled = False
            for ri, dist in zip(home, before_ds):
                if dist > TARGET_CENTROID + SKIP_IF_WITHIN:
                    radial_to(ri, sx, sz, TARGET_CENTROID)
                    pulled = True
            note = "radial" if pulled else "skip"
        for ri in home:
            dist = hypot2(res_world[ri][0], res_world[ri][2], sx, sz)
            if dist > OUTLIER_DIST:
                radial_to(ri, sx, sz, OUTLIER_TARGET)
                if note == "skip":
                    note = "outlier"
                elif "outlier" not in note:
                    note += "+outlier"
        after_ds = [hypot2(res_world[ri][0], res_world[ri][2], sx, sz) for ri in home]
        report.append((si, sx, sz, home, before_ds, after_ds, note))

    if apply and updates:
        new_lines = list(lines)
        for line_i, (lx, lz) in updates.items():
            new_lines[line_i] = replace_origin(new_lines[line_i], lx, lz)
        path.write_text("".join(new_lines), encoding="utf-8")

    return {
        "path": path,
        "size": (width, depth),
        "spawns": len(spawns),
        "resources": len(resources),
        "moved": len(updates),
        "report": report,
        "resources_nodes": resources,
    }


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    maps = sorted(MAPS_DIR.rglob("*.tscn"))
    maps = [p for p in maps if p.name != "GeneratedTerrain.tscn"]
    print(f"{'apply' if args.apply else 'dry-run'}  {len(maps)} maps  "
          f"target={TARGET_CENTROID} min={MIN_DIST}")
    for path in maps:
        info = process_map(path, args.apply)
        rel = path.relative_to(MAPS_DIR)
        print(f"\n== {rel}  {info['size'][0]:.0f}x{info['size'][1]:.0f}  "
              f"spawns={info['spawns']} ores={info['resources']} moved={info['moved']}")
        for si, sx, sz, home, before_ds, after_ds, note in info["report"]:
            if not home:
                print(f"  P{si} ({sx:.1f},{sz:.1f})  {note}")
                continue
            b = sum(before_ds) / len(before_ds)
            a = sum(after_ds) / len(after_ds)
            names = ",".join(info["resources_nodes"][ri].name for ri in home)
            bd = ", ".join(f"{d:.1f}" for d in before_ds)
            ad = ", ".join(f"{d:.1f}" for d in after_ds)
            print(f"  P{si} ({sx:.1f},{sz:.1f})  {note}  mean {b:.1f}->{a:.1f}  "
                  f"ores[{names}]  {bd} => {ad}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
