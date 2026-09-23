"""G2 保底地形烘焙（2026-09-20 从 tools/regen_large_lake_256.py 搬入 rtsmap 包）。

## 为什么需要它
工作台 pipeline 的 G2 一旦质检不过，G3/G4/引擎会被整条 skipped ⇒ 任务"done"
却没有场景产出 ⇒ 大厅「随机地图」失败。而在 `regen_large_lake_256.py` 里，
G2 失败时会**先轮询若干参数变体，最后用 `bake_playable()` 保底**——这是大湖
（16-0-1ca6e21aa1）能稳定生成的原因。本模块把这段保底能力搬进来，供 pipeline 使用，
让随机地图"永远出得了图"。

## 契约
- 输入：G1 的 `starts`（出生点）、`runs_root`、`seed`、`params`（G2 参数）；
- 产出：写 `runs/<seed>/G2/` 与 `runs/<seed>/G3/` 两个门的产物
  （mapgrid.npz / mapspec.json / lanes.json / resources.json / objects.json）；
- 返回：G2 的 mapspec dict，其中 `all_pass=True`、`baked=True`。

## 诚实说明
保底图**布局固定**（湖、河、桥的位置不随 seed 变化，只有出生点来自 G1 的随机），
所以它保证的是"能玩"，不是"每张都不同"。真正多变的图依赖 G2 正常通过质检。
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ..contract import ALGO_VERSION, H, W
from ..gate import new_manifest, run_dir
from ..grid import MapGrid, write_json, sha256_file
from ..pathing import compute_passable
from ..rng import gate_seed_int


def _disc(cx: float, cz: float, radius: float):
    yy, xx = np.ogrid[:int(H), :int(W)]
    return (xx + 0.5 - cx) ** 2 + (yy + 0.5 - cz) ** 2 <= radius ** 2


def _erode(mask, n=1):
    from ..pathing import dilate8

    out = mask.copy()
    for _ in range(n):
        out = ~dilate8(~out)
    return out & mask


def bake_playable(starts, runs_root, seed, params) -> dict:
    """程序化构造一张**确定可玩**的湖图，作为 G2 无法过检时的保底。

    与 `tools/regen_large_lake_256.py` 的原实现一致（湖 r=28 于 (118,142)、
    横河 z∈[98,108] 带 3 座桥 @x=48/128/208 宽 10、6 处台地、出生点整平）。
    """
    gw, gh = int(W), int(H)
    ground, water_y, top = 0.6, -2.4, 8.1
    ramp_h = (ground + top) / 2.0
    height = np.full((gh, gw), ground, dtype=np.float32)
    blocking = np.zeros((gh, gw), dtype=np.uint8)
    water = np.zeros((gh, gw), dtype=bool)

    lake_c = (118.0, 142.0)
    lake = _disc(*lake_c, 28.0)
    water |= lake

    river_z0, river_z1 = 98, 108
    river = np.zeros((gh, gw), dtype=bool)
    river[river_z0:river_z1, :] = True
    river &= ~_disc(*lake_c, 34.0)
    water |= river
    bridges = []
    for x in (48.0, 128.0, 208.0):
        xi = int(x)
        river[river_z0:river_z1, xi - 5:xi + 5] = False
        water[river_z0:river_z1, xi - 5:xi + 5] = False
        bridges.append({"a": [x, float(river_z0 - 2)], "b": [x, float(river_z1 + 2)], "width": 10.0})

    raw_centers = [
        (starts[0][0], starts[0][1] - 22.0),
        (starts[1][0] + 22.0, starts[1][1]),
        (starts[2][0] - 22.0, starts[2][1]),
        (starts[3][0], starts[3][1] + 22.0),
        (72.0, 72.0),
        (184.0, 200.0),
    ]
    plateaus = []
    yy_idx, xx_idx = np.ogrid[:gh, :gw]
    for i, (cx, cz) in enumerate(raw_centers):
        cx = float(np.clip(cx, 24.0, W - 24.0))
        cz = float(np.clip(cz, 24.0, H - 24.0))
        region = _disc(cx, cz, 12.0) & ~water
        if int(region.sum()) < 80:
            continue
        ring = region & ~_erode(region, 2)
        ramps = np.zeros_like(region)
        for dx in (1.0, -1.0):
            band = _disc(cx + dx * 12.0, cz, 8.0) & region
            slit = (np.abs(yy_idx + 0.5 - cz) <= 6.0) & ring & (
                np.sign(xx_idx + 0.5 - cx) == np.sign(dx)
            )
            ramps |= band | slit
        cliff = ring & ~ramps
        blocking[cliff] = 1
        height[region & ~ramps] = top
        height[ramps] = ramp_h
        yy, xx = np.nonzero(region)
        outline = [
            [float(xx.min()), float(yy.min())],
            [float(xx.max()), float(yy.min())],
            [float(xx.max()), float(yy.max())],
            [float(xx.min()), float(yy.max())],
        ]
        kind = "home" if i < 2 else ("central" if i == 4 else "route")
        plateaus.append({
            "center": [cx, cz],
            "footprint_area_m2": int(region.sum()),
            "walkable_top_area_m2": int((region & ~cliff).sum()),
            "lobes": 1,
            "outline": outline,
            "landform_angle": 0.0,
            "kind": kind,
            "owner": i if kind == "home" else None,
            "controlled_routes": [],
            "ramp_centers": [[cx + 12.0, cz], [cx - 12.0, cz]],
            "ramp_dirs": [[-1.0, 0.0], [1.0, 0.0]],
        })

    height[water] = water_y
    blocking[water] = 1
    for br in bridges:
        x = int(br["a"][0])
        blocking[river_z0:river_z1, x - 5:x + 5] = 0
        height[river_z0:river_z1, x - 5:x + 5] = ground

    for sx, sz in starts:
        home = _disc(sx, sz, 12.0)
        blocking[home] = 0
        height[home & ~water] = ground

    g1_dir = Path(run_dir(runs_root, seed, "G1"))
    parent = MapGrid.load(g1_dir / "mapgrid.npz")
    grid = MapGrid.from_parent(parent)
    terrain = np.zeros((gh, gw), dtype=np.uint8)
    terrain[water] = 5
    terrain[blocking.astype(bool) & ~water] = 1
    grid.set("terrain", terrain)
    grid.set("water_footprint", water.astype(np.uint8))
    grid.set("height", height)
    grid.set("blocking", blocking)
    grid.set("blocking_g2", blocking.copy())
    grid.set("passable", compute_passable(blocking).astype(np.uint8))
    grid.set("overlay", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("lane_core", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("role", np.zeros((gh, gw), dtype=np.uint8))
    grid.set("region", np.zeros((gh, gw), dtype=np.uint16))

    g2_spec = {
        "gate": "G2", "master_seed": seed, "algo_version": "7.11.0",
        "params": params, "all_pass": True, "starts": starts,
        "plateaus": plateaus, "bridges": bridges,
        "rivers": [{"polyline": [[0.0, 103.0], [256.0, 103.0]], "width": 10.0,
                    "widths": [10.0, 10.0], "kind": "main",
                    "endpoints": [[0.0, 103.0], [256.0, 103.0]], "tributaries": []}],
        "lakes": [{"center": list(lake_c),
                   "outline": [[90, 114], [146, 114], [146, 170], [90, 170]],
                   "area_m2": int(lake.sum())}],
        "expansion_anchors": [], "flank_anchors": [],
        "baked": True,
        # pipeline 的 `_g2_summary()` 会读这两个字段（原本由 G2 正式流程产出），
        # 保底图也必须提供，否则汇总时 KeyError。
        "solid_frac": float(1.0 - float(water.mean())),
        "strategy_metrics": {"crossings": len(bridges)},
    }
    g2_dir = Path(run_dir(runs_root, seed, "G2"))
    g3_dir = Path(run_dir(runs_root, seed, "G3"))
    g2_dir.mkdir(parents=True, exist_ok=True)
    g3_dir.mkdir(parents=True, exist_ok=True)
    grid.save(g2_dir / "mapgrid.npz")
    grid.save(g3_dir / "mapgrid.npz")
    write_json(g2_dir / "mapspec.json", g2_spec)
    write_json(g2_dir / "lanes.json", {})
    write_json(g3_dir / "mapspec.json", {"gate": "G3", "master_seed": seed, "all_pass": True})
    resources = []
    for i, (sx, sz) in enumerate(starts):
        resources.append({"type": "A", "x": sx + 8.0, "z": sz + 6.0, "player": i})
        resources.append({"type": "A", "x": sx - 7.0, "z": sz - 5.0, "player": i})
    write_json(g3_dir / "resources.json", {"resources": resources})
    write_json(g3_dir / "objects.json", {"instances": []})

    # ---- manifest：G3 的 auto 模式会校验它 ----
    # 【2026-09-20】初版漏写 manifest.json，导致 G3 报
    # "G2 产物 mapgrid.npz 与 manifest 哈希不一致或缺失"（g3_content._ensure_g2_valid_auto）。
    # 保底图必须像正式 G2 一样留下 input/output 哈希，下游才能自动继续。
    algo = ALGO_VERSION["G2"]
    input_hash = sha256_file(g1_dir / "mapgrid.npz")
    manifest = new_manifest(
        seed, "G2", gate_seed_int(seed, "G2", algo), algo, params,
        input_hash=input_hash,
        output_hash={
            "mapgrid.npz": sha256_file(g2_dir / "mapgrid.npz"),
            "mapspec.json": sha256_file(g2_dir / "mapspec.json"),
        },
    )
    manifest["execution_mode"] = "workbench_bake"
    write_json(g2_dir / "manifest.json", manifest)
    return g2_spec
