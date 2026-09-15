"""G2 装饰语义提示层（decoration hints）——纯附加产物。

产物：``runs/<seed>/G2/decoration_hints.npz`` + ``decoration_hints.json``。

定位
----
G2 仍然是**玩法与候选提示的唯一权威**。本模块只读取 G2 已经裁决完成的几何
（geom）、权威格网通道（blocking / water_footprint）与参数，派生一张「哪里适合
放什么装饰、哪里绝对不放」的逐格提示图，供 G4 / 视觉层消费。

硬约束（用户 2026-09-12 指令，逐条对应）
--------------------------------------
1. 不写入任何权威通道；本模块**不返回**也不修改 blocking / passable / height /
   water_footprint / terrain / region / role / lane_core，不参与导航烘焙。
2. 水域与河心禁止树、草、石头（它们只能落在 clear_zone）。
3. 桥面、桥头、坡道核心、主战略通道、出生点安全圈、资源锚点安全圈 → clear_zone。
4. 山体阻挡区不出树草，只出 stone_zone / mountain_foot_zone。
5. 河湖边缘出连续 shore_zone，不向河心延伸。
6. 侧翼 / 后方 / 山脚 / 岸线用中等自然密度。
7. 出生区、资源区、桥头、坡道、主通道保持开阔。
8. 由 (master_seed, terrain_seed) 经独立随机流确定性生成。
9. 既有 G2 mask 与布局算法零改动——调用方只新增产物，不改输出哈希。

分区是**互斥**的（每格至多属于一个 zone），优先级见 ``ZONE_PRIORITY``：
clear > shore > mountain_foot > stone > tree > grass。
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from scipy import ndimage

from ..contract import GRID_H, GRID_W, H, W
from ..grid import write_json
from ..pathing import compute_passable
from ..rng import gate_rng, gate_seed_int

DECOR_ALGO_VERSION = "1.0.0"
DECOR_RNG_TAG = "decoration@1.0.0"

# ---------------------------------------------------------------- 分区与常量

ZONE_TREE = 1
ZONE_GRASS = 2
ZONE_STONE = 3
ZONE_SHORE = 4
ZONE_MOUNTAIN_FOOT = 5
ZONE_CLEAR = 6

ZONE_NAMES = {
    ZONE_TREE: "tree_zone",
    ZONE_GRASS: "grass_zone",
    ZONE_STONE: "stone_zone",
    ZONE_SHORE: "shore_zone",
    ZONE_MOUNTAIN_FOOT: "mountain_foot_zone",
    ZONE_CLEAR: "clear_zone",
}
NAME_TO_ZONE = {v: k for k, v in ZONE_NAMES.items()}
ZONE_PRIORITY = ["clear_zone", "shore_zone", "mountain_foot_zone",
                 "stone_zone", "tree_zone", "grass_zone"]

# 排除原因码（clear_zone 与「无树草」共用同一套语义）
REASONS = {
    0: "none",
    1: "water",
    2: "bridge",
    3: "ramp",
    4: "corridor",
    5: "spawn",
    6: "resource",
    7: "plateau_interior",
    8: "rock_offlimits",   # 山体/岩体阻挡面：禁树草，仅 stone / mountain_foot
    9: "impassable",       # 不在 passable 通道内（视觉上无立足点）
    11: "mountain_foot_scree",   # 该格让位给山脚沉积带
    12: "shore_band",            # 该格让位给岸线带
}
R_WATER, R_BRIDGE, R_RAMP, R_CORRIDOR = 1, 2, 3, 4
R_SPAWN, R_RESOURCE, R_INTERIOR = 5, 6, 7
R_ROCK, R_IMPASSABLE = 8, 9
R_SCREE, R_SHORE = 11, 12

# 保护距离（米；格边长 = 1m，故与格数同值）
SPAWN_SAFE_M = 26.0         # 出生点安全圈（= G2 home_radius 20 + 6）
RESOURCE_SAFE_M = 12.0      # 资源锚点安全圈
CORRIDOR_EXTRA_M = 2.0      # 主通道保护 = lane_clear_width/2 + 该值（对齐 G2 corridors 自身口径）
BRIDGEHEAD_CLEAR_M = 10.0   # 桥体带外扩（桥头保护）
RAMP_CLEAR_M = 8.0          # 坡道外扩保护
SHORE_WIDTH_M = 7.0         # 岸线带宽度（向陆一侧）
MOUNTAIN_FOOT_WIDTH_M = 9.0 # 山脚沉积带宽度
STONE_COLLAR_M = 4.0        # 山脚内侧碎石领宽（先于 mountain_foot 判定）
TREE_SHARE = 0.30           # 树区占可装饰陆地的目标比例（分位阈值，跨 seed 稳定）

# 预算上限：cap = clamp(建议密度×格数×1.5, 下限, 绝对上限)
# 上限保证装饰不淹没单位与战略地貌；下限保证小块区仍能表达。
BUDGET_CAP_ABS = {
    "tree_zone": 320, "grass_zone": 1200, "stone_zone": 700,
    "shore_zone": 260, "mountain_foot_zone": 420, "clear_zone": 0,
}
BUDGET_CAP_FLOOR = {"tree_zone": 40, "grass_zone": 60, "stone_zone": 60,
                    "shore_zone": 30, "mountain_foot_zone": 40, "clear_zone": 0}

# 建议密度（每 100 m² = 每 100 格）与最小间距
ZONE_CONFIG = {
    "tree_zone": dict(
        suggested_density_per_100m2=0.55, min_spacing_m=3.6,
        asset_role="tree",
        source_semantics=["flank_and_rear_open_land", "rock_edge_clusters",
                          "far_from_spawn_hinterland"],
        notes="成簇分布；簇心偏向侧翼、后方与岩缘。出生圈/资源圈/桥头/坡道/主通道内为 0。",
    ),
    "grass_zone": dict(
        suggested_density_per_100m2=2.00, min_spacing_m=1.4,
        asset_role="grass",
        source_semantics=["open_land_filler", "dry_plains", "shore_inland_fringe"],
        notes="低矮干草与小簇植物；作为开阔地填充层，仍受全部保护区约束。",
    ),
    "stone_zone": dict(
        suggested_density_per_100m2=0.45, min_spacing_m=2.8,
        asset_role="stone",
        source_semantics=["rock_mass_surface", "gravel_ground_patches"],
        notes="碎石与小型岩块；可贴附山体/岩体表面，禁止进入水面。",
    ),
    "shore_zone": dict(
        suggested_density_per_100m2=1.20, min_spacing_m=2.6,
        asset_role="shore",
        source_semantics=["river_bank_land_side", "lake_shore_land_side"],
        notes="连续岸线带，只在水陆交界的陆侧；不向河心延伸，不含水面格。",
    ),
    "mountain_foot_zone": dict(
        suggested_density_per_100m2=0.80, min_spacing_m=2.4,
        asset_role="mountain_foot",
        source_semantics=["deposition_fan", "scree_apron", "cliff_foot_transition"],
        notes="山脚沉积扇与岩屑过渡带；台地崖脚同样计入。",
    ),
    "clear_zone": dict(
        suggested_density_per_100m2=0.0, min_spacing_m=0.0,
        asset_role="none",
        source_semantics=["water", "bridge_and_bridgehead", "ramp_core",
                          "main_corridor", "spawn_safe_circle",
                          "resource_safe_circle", "impassable"],
        notes="任何装饰不得进入。",
    ),
}


# ---------------------------------------------------------------- 工具

def _noise(rng, scale, shape=(GRID_H, GRID_W)):
    """值噪声（整数格点随机 + smoothstep 双线性插值）。scale 单位 = 米/格。"""
    gh = int(math.ceil(shape[0] / scale)) + 2
    gw = int(math.ceil(shape[1] / scale)) + 2
    lat = rng.random((gh, gw))
    yi = np.arange(shape[0], dtype=np.float64) / scale
    xi = np.arange(shape[1], dtype=np.float64) / scale
    y0 = np.floor(yi).astype(np.int64)
    x0 = np.floor(xi).astype(np.int64)
    fy = (yi - y0)
    fx = (xi - x0)
    fy = (fy * fy * (3.0 - 2.0 * fy))[:, None]
    fx = (fx * fx * (3.0 - 2.0 * fx))[None, :]
    a = lat[np.ix_(y0, x0)]
    b = lat[np.ix_(y0, x0 + 1)]
    c = lat[np.ix_(y0 + 1, x0)]
    d = lat[np.ix_(y0 + 1, x0 + 1)]
    return (a * (1.0 - fx) + b * fx) * (1.0 - fy) + (c * (1.0 - fx) + d * fx) * fy


def _dist_field(px, pz):
    gi = np.arange(GRID_W) + 0.5
    gj = np.arange(GRID_H) + 0.5
    xx, zz = gi[None, :], gj[:, None]
    return np.hypot(xx - px, zz - pz)


def _disc(center, radius):
    return _dist_field(float(center[0]), float(center[1])) <= radius


def _grow(mask, meters):
    """形态学膨胀到约 meters 米（8 邻域，逐格 1m）。"""
    out = mask.copy()
    for _ in range(int(round(meters))):
        out = ndimage.binary_dilation(out, structure=np.ones((3, 3), dtype=bool))
    return out


def _dist_to(mask):
    """每格到 mask 的最近距离（米）。"""
    if not mask.any():
        return np.full((GRID_H, GRID_W), 1.0e4, dtype=np.float32)
    return ndimage.distance_transform_edt(~mask).astype(np.float32)


# ---------------------------------------------------------------- 主入口

def build_hints(seed, stream, geom, blocking, lane_core, params, starts,
                terrain_seed=0, g2_algo_version="0"):
    """派生装饰提示层。返回 (zones: dict[str, np.ndarray(bool)], meta: dict)。

    只读输入：不修改任何传入数组（全部先 copy / 只读派生）。
    """
    rng = gate_rng(seed, "G2", f"{stream}|{DECOR_RNG_TAG}")
    water = np.asarray(geom["water_union"]).astype(bool)
    block = np.asarray(blocking) > 0
    passable = compute_passable(np.asarray(blocking).astype(np.uint8)) > 0

    # ---- rock 面：山体/岩体（非水、非台地台面）----
    region_union = np.asarray(geom.get("region_union", np.zeros_like(block))).astype(bool)
    rock = block & ~water
    rock_mass = rock & ~region_union          # 真正的山体/岩体
    cliff_ring = rock & region_union          # 台地崖壁（同样只出 stone/foot）

    zone_id = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    clear_reason = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    veg_reason = np.zeros((GRID_H, GRID_W), dtype=np.uint8)

    def clear(mask, code):
        """标记 clear_zone（先到先得，首个原因胜出）。"""
        m = np.asarray(mask).astype(bool) & (zone_id != ZONE_CLEAR)
        clear_reason[m] = code
        zone_id[m] = ZONE_CLEAR

    # ---- 1. 桥体带 + 桥头（先于水域标注，保证桥面/桥头原因可区分）----
    bridge_band = np.zeros((GRID_H, GRID_W), dtype=bool)
    for rv in geom.get("rivers", []):
        for gap in rv.get("gaps", []):
            bridge_band |= np.asarray(gap).astype(bool)
    bridge_protect = _grow(bridge_band, BRIDGEHEAD_CLEAR_M)
    clear(bridge_protect, R_BRIDGE)

    # ---- 2. 水域与河心：全域禁入 ----
    clear(water, R_WATER)

    # ---- 3. 坡道核心 + 外扩 ----
    ramp = np.asarray(geom.get("ramp_union", np.zeros_like(block))).astype(bool)
    ramp_protect = _grow(ramp, RAMP_CLEAR_M)
    clear(ramp_protect, R_RAMP)

    # ---- 4. 主战略通道（lane_clear_width/2 + CORRIDOR_EXTRA_M；eco 路线不保护）----
    corridor_width = float(params.get("lane_clear_width", 10.0)) / 2.0 + CORRIDOR_EXTRA_M
    corridor = np.asarray(geom.get("corridors", np.zeros_like(block))).astype(bool)
    from ..pathing import polyline_field
    for name, lane in (geom.get("lanes") or {}).items():
        if lane.get("kind") == "eco":
            continue
        dist, _ = polyline_field(lane["polyline"])
        corridor |= dist <= corridor_width
    if lane_core is not None:
        corridor |= np.asarray(lane_core).astype(np.uint8) > 0
    clear(corridor, R_CORRIDOR)

    # ---- 5. 出生点安全圈 ----
    for s in starts:
        clear(_disc(s, SPAWN_SAFE_M), R_SPAWN)

    # ---- 6. 资源锚点安全圈（G2 侧锚点；G4 再用 G3 真实资源位二次收紧）----
    resource_anchors = []
    resource_anchors += [tuple(a) for a in (geom.get("exp_anchors") or [])]
    resource_anchors += [tuple(a) for a in (geom.get("flank_anchors") or [])]
    resource_anchors += [tuple(g) for g in (geom.get("gap_centers") or [])]
    resource_anchors += [tuple(n["xy"]) for n in (geom.get("contest") or [])]
    for a in resource_anchors:
        clear(_disc(a, RESOURCE_SAFE_M), R_RESOURCE)

    # ---- 7. 不可走格（不在 passable 通道内，视觉上无立足点）----
    clear(~passable & ~block & ~water, R_IMPASSABLE)

    # ---- 可装饰陆地 ----
    open_land = (zone_id == 0) & passable & ~block & ~water

    # ---- shore_zone：水陆交界陆侧连续带 ----
    d_water = _dist_to(water)
    shore = open_land & (d_water <= SHORE_WIDTH_M)
    zone_id[shore] = ZONE_SHORE

    # ---- mountain_foot_zone：山脚沉积带（含台地崖脚）----
    d_rock = _dist_to(rock)
    foot_open = open_land & (zone_id == 0)
    collar = foot_open & (d_rock <= STONE_COLLAR_M)
    zone_id[collar] = ZONE_STONE
    foot = foot_open & (zone_id == 0) & (d_rock <= MOUNTAIN_FOOT_WIDTH_M)
    zone_id[foot] = ZONE_MOUNTAIN_FOOT

    # ---- stone_zone：山体/岩体表面 + 砾石地斑块 ----
    surface = rock & ~water
    zone_id[surface & (zone_id == 0)] = ZONE_STONE
    gravel = _noise(rng, 34.0)
    rest = open_land & (zone_id == 0)
    gravel_patch = rest & (gravel >= 0.80) & (d_water > SHORE_WIDTH_M) & (d_rock > MOUNTAIN_FOOT_WIDTH_M)
    zone_id[gravel_patch] = ZONE_STONE

    # ---- tree_zone：植被生境高分位（成簇）----
    n_big = _noise(rng, 52.0)
    n_mid = _noise(rng, 17.0)
    n_fine = _noise(rng, 6.0)
    d_spawn = np.stack([_dist_field(s[0], s[1]) for s in starts]).min(axis=0)
    # 侧翼/后方加成：离出生点越远越容易长树
    bonus = np.clip((d_spawn - 34.0) / 60.0, 0.0, 1.0) * 0.20
    veg = 0.48 * n_big + 0.30 * n_mid + 0.22 * n_fine + bonus
    rest = open_land & (zone_id == 0)
    if rest.any():
        # 目标占比：可装饰陆地约 18% 为树区（分位阈值→跨 seed 稳定）
        threshold = float(np.quantile(veg[rest], 1.0 - TREE_SHARE))
        tree = rest & (veg >= threshold)
        zone_id[tree] = ZONE_TREE

    # ---- grass_zone：其余可装饰陆地 ----
    grass = open_land & (zone_id == 0)
    zone_id[grass] = ZONE_GRASS

    # ---- 排除原因统计（「为什么该格没有树/草」）----
    veg_reason[zone_id == ZONE_CLEAR] = clear_reason[zone_id == ZONE_CLEAR]
    veg_reason[(zone_id == ZONE_STONE) & (veg_reason == 0)] = R_ROCK
    veg_reason[(zone_id == ZONE_MOUNTAIN_FOOT) & (veg_reason == 0)] = R_SCREE
    veg_reason[(zone_id == ZONE_SHORE) & (veg_reason == 0)] = R_SHORE

    zones = {
        "tree_zone": zone_id == ZONE_TREE,
        "grass_zone": zone_id == ZONE_GRASS,
        "stone_zone": zone_id == ZONE_STONE,
        "shore_zone": zone_id == ZONE_SHORE,
        "mountain_foot_zone": zone_id == ZONE_MOUNTAIN_FOOT,
        "clear_zone": zone_id == ZONE_CLEAR,
    }

    total = float(GRID_H * GRID_W)
    zones_meta = {}
    for name in ZONE_NAMES.values():
        zid = NAME_TO_ZONE[name]
        cnt = int((zone_id == zid).sum())
        cfg = dict(ZONE_CONFIG[name])
        density = float(cfg["suggested_density_per_100m2"])
        expected = cnt * density / 100.0
        cap = int(round(expected * 1.5))
        cap = max(int(BUDGET_CAP_FLOOR[name]), min(int(BUDGET_CAP_ABS[name]), cap))
        cfg.update(cells=cnt, share_of_map=round(cnt / total, 6),
                   suggested_instances=int(round(expected)), budget_cap=cap)
        zones_meta[name] = cfg

    clear_by_reason = {}
    for code, label in REASONS.items():
        if code == 0:
            continue
        n = int(((zone_id == ZONE_CLEAR) & (clear_reason == code)).sum())
        if n:
            clear_by_reason[label] = n
    veg_by_reason = {}
    for code, label in REASONS.items():
        if code == 0:
            continue
        n = int((veg_reason == code).sum())
        if n:
            veg_by_reason[label] = n

    meta = dict(
        gate="G2",
        master_seed=int(seed),
        terrain_seed=int(terrain_seed),
        g2_algo_version=str(g2_algo_version),
        decoration_algo_version=DECOR_ALGO_VERSION,
        rng_stream=f"{stream}|{DECOR_RNG_TAG}",
        decoration_gate_seed=int(gate_seed_int(seed, "G2", f"{stream}|{DECOR_RNG_TAG}")),
        grid=[GRID_W, GRID_H],
        cell_m=1.0,
        world_m=[W, H],
        zone_priority=ZONE_PRIORITY,
        zones=zones_meta,
        protection=dict(
            water="水域与河心全域禁入（树/草/石均不得落水面）",
            spawn_safe_m=SPAWN_SAFE_M,
            resource_safe_m=RESOURCE_SAFE_M,
            corridor_clear_m=corridor_width,
            lane_clear_width_m=float(params.get("lane_clear_width", 10.0)),
            bridgehead_clear_m=BRIDGEHEAD_CLEAR_M,
            ramp_clear_m=RAMP_CLEAR_M,
            shore_width_m=SHORE_WIDTH_M,
            mountain_foot_width_m=MOUNTAIN_FOOT_WIDTH_M,
            stone_collar_m=STONE_COLLAR_M,
            resource_anchor_source=("g2 expansion_anchors + flank_anchors + gap_centers + "
                                    "contest_nodes；G4 阶段再并入 G3 真实资源位二次收紧"),
        ),
        exclusion=dict(
            clear_by_reason=clear_by_reason,
            clear_total=int((zone_id == ZONE_CLEAR).sum()),
            tree_grass_blocked_by_reason=veg_by_reason,
            rock_offlimits_cells=int(veg_reason[veg_reason == R_ROCK].size and
                                     (veg_reason == R_ROCK).sum()),
            tree_grass_blocked_total=int((veg_reason != 0).sum()),
        ),
        checks={},
    )
    return zones, meta, zone_id, clear_reason, veg_reason


def verify(zones, meta, blocking, geom, starts):
    """机器可判断言：新增提示层不得违反任何一条硬约束。"""
    checks = {}
    water = np.asarray(geom["water_union"]).astype(bool)
    block = np.asarray(blocking) > 0
    veg = zones["tree_zone"] | zones["grass_zone"]
    checks["no_tree_grass_on_water"] = not bool((veg & water).any())
    checks["no_stone_on_water"] = not bool((zones["stone_zone"] & water).any())
    checks["clear_zone_covers_water"] = bool((water <= zones["clear_zone"]).all())
    bridge = np.zeros_like(water)
    for rv in geom.get("rivers", []):
        for gap in rv.get("gaps", []):
            bridge |= np.asarray(gap).astype(bool)
    if bridge.any():
        checks["clear_zone_covers_bridge"] = bool((bridge <= zones["clear_zone"]).all())
    ramp = np.asarray(geom.get("ramp_union", np.zeros_like(water))).astype(bool)
    if ramp.any():
        checks["clear_zone_covers_ramp_core"] = bool((ramp <= zones["clear_zone"]).all())
    for s in starts:
        if not bool((_disc(s, SPAWN_SAFE_M - 1.0) <= zones["clear_zone"]).all()):
            checks["clear_zone_covers_spawn_safe_circle"] = False
            break
    else:
        checks["clear_zone_covers_spawn_safe_circle"] = True
    rock = block & ~water
    checks["no_tree_grass_on_rock"] = not bool((veg & rock).any())
    rock_cover = rock <= (zones["stone_zone"] | zones["clear_zone"] |
                          zones["mountain_foot_zone"])
    checks["rock_covered_by_stone_or_foot"] = bool(rock_cover.all())
    # 岸线连续：非水陆交界处不得出 shore（即 shore 只在距水 1 格内起始）
    checks["shore_never_inside_water"] = not bool((zones["shore_zone"] & water).any())
    if zones["shore_zone"].any():
        d_water = _dist_to(water)
        checks["shore_is_continuous_collar"] = bool(
            float(d_water[zones["shore_zone"]].max()) <= SHORE_WIDTH_M + 0.51)
    else:
        checks["shore_is_continuous_collar"] = True
    # 预算上限：每区必须有上限、上限不得小于建议密度所需、也不得超过绝对上限；
    # 全图装饰总量不得超过格网 3%（不淹没单位与战略地貌）。
    budget_ok = True
    total_cap = 0
    for name, cfg in meta["zones"].items():
        cap = int(cfg.get("budget_cap", 0))
        total_cap += cap
        if name == "clear_zone":
            budget_ok = budget_ok and cap == 0
            continue
        expected = int(cfg.get("suggested_instances", 0))
        if cap > int(BUDGET_CAP_ABS[name]) or cap < min(expected, int(BUDGET_CAP_FLOOR[name])):
            budget_ok = False
    checks["budget_caps_within_zone_capacity"] = budget_ok
    checks["budget_total_is_bounded"] = total_cap <= 0.03 * GRID_H * GRID_W
    return checks


def write_hints(run_dir_path, seed, stream, geom, blocking, lane_core, params, starts,
                terrain_seed=0, g2_algo_version="0"):
    """写 decoration_hints.npz + decoration_hints.json，返回 (paths, meta)。"""
    rd = Path(run_dir_path)
    rd.mkdir(parents=True, exist_ok=True)
    zones, meta, zone_id, clear_reason, veg_reason = build_hints(
        seed, stream, geom, blocking, lane_core, params, starts,
        terrain_seed=terrain_seed, g2_algo_version=g2_algo_version)
    meta["checks"] = verify(zones, meta, blocking, geom, starts)
    meta["all_pass"] = all(bool(v) for v in meta["checks"].values())

    npz = rd / "decoration_hints.npz"
    np.savez_compressed(
        npz,
        **{name: mask.astype(np.uint8) for name, mask in zones.items()},
        zone_id=zone_id,
        clear_reason=clear_reason,
        veg_reason=veg_reason,
    )
    meta["files"] = {"npz": npz.name, "json": "decoration_hints.json"}
    meta["npz_keys"] = sorted(list(zones.keys()) + ["zone_id", "clear_reason", "veg_reason"])
    write_json(rd / "decoration_hints.json", meta)
    return npz, meta


def load_hints(run_dir_path):
    """读回装饰提示层；缺文件返回 (None, None)，调用方据此优雅回退。"""
    rd = Path(run_dir_path)
    npz = rd / "decoration_hints.npz"
    js = rd / "decoration_hints.json"
    if not npz.exists() or not js.exists():
        return None, None
    from ..grid import read_json
    with np.load(npz) as data:
        zones = {k: data[k].astype(bool) for k in ZONE_NAMES.values() if k in data}
        zones["zone_id"] = data["zone_id"].astype(np.uint8)
        zones["clear_reason"] = data["clear_reason"].astype(np.uint8)
        zones["veg_reason"] = data["veg_reason"].astype(np.uint8)
    return zones, read_json(js)
