"""G2 v7: strategic landforms and terrain-respecting routes.

Grid channels remain compatible with G3. Strategic generation lives in
g2_strategy; the shared raster, classification and output helpers live here.
"""
import math

import numpy as np

from ..contract import (
    ALGO_VERSION, G2_DEFAULTS, GRID_H, GRID_W, H, MAP_CENTER,
    ROLE_EXPANSION, ROLE_FLANK, ROLE_HOME, ROLE_HINTERLAND, W,
    TERRAIN_ROCK, TERRAIN_RUIN, TERRAIN_WALL, TERRAIN_DEBRIS, TERRAIN_WATER,
    BLOB_PROTOTYPES,
)
from ..gate import ensure_upstream_approved, new_manifest, run_dir
from ..grid import MapGrid, read_json, write_json, sha256_file
from ..pathing import (
    bfs_components, cell_of, compute_passable, erode8, keypoints_connected,
    label8, polyline_field,
)
from ..rng import gate_rng, gate_seed_int
from .g2_landforms import landform_outline, polygon_mask, regional_direction


# ---------------- 极角顺序 / 距离场（G3 复用，勿删） ----------------

def polar_order(starts):
    """绕中心极角升序的玩家编号列表。环邻接 (0,1)(1,2)(2,3)(3,0) 与旋转方向无关。"""
    order = sorted(range(4), key=lambda i: math.atan2(starts[i][1] - MAP_CENTER[1],
                                                      starts[i][0] - MAP_CENTER[0]))
    return order


def _dist_field(px, pz):
    """每个格中心到 (px,pz) 的欧氏距离场（G3 复用，勿删）。"""
    gi = np.arange(GRID_W) + 0.5
    gj = np.arange(GRID_H) + 0.5
    xx, zz = gi[None, :], gj[:, None]
    return np.hypot(xx - px, zz - pz)


def disc_mask(center, radius):
    x, z = center
    out = np.zeros((GRID_H, GRID_W), dtype=bool)
    x0, x1 = max(0, int(math.floor(x-radius))), min(GRID_W, int(math.ceil(x+radius)))
    z0, z1 = max(0, int(math.floor(z-radius))), min(GRID_H, int(math.ceil(z+radius)))
    if x1 > x0 and z1 > z0:
        out[z0:z1, x0:x1] = np.hypot(np.arange(x0, x1)[None, :]+.5-x,
                                    np.arange(z0, z1)[:, None]+.5-z) <= radius
    return out


# ---------------- 一维平滑值噪声（Seed 驱动，禁用 random） ----------------


def _dil(m):
    from ..pathing import dilate8
    return dilate8(m)


def _ero(m):
    return erode8(m)


def smooth_mask(m, iters=2):
    """形态学平滑（闭运算填凹口 + 开运算去毛刺）圆润边缘，消除布尔/阶梯感。"""
    out = m.copy()
    for _ in range(iters):
        out = _ero(_dil(out))   # closing
        out = _dil(_ero(out))   # opening
    return out


def proto_blob(cx, cz, R, proto, phase, stretch, ang):
    """原型 kit 瓣状块：r(θ)=R*(1+a2 sin2θ'+a3 sin3θ'+a4 sin4θ')，固定谐波签名。
    种子只控制原型选择/旋转 ang/拉伸 stretch/相位 phase/半径 R → 风格恒定。"""
    gx = np.arange(GRID_W) + 0.5
    gz = np.arange(GRID_H) + 0.5
    XX, ZZ = np.meshgrid(gx, gz)
    dx = XX - cx
    dz = ZZ - cz
    ca, sa = math.cos(ang), math.sin(ang)
    uu = (dx * ca + dz * sa) / max(stretch, 1e-9)
    vv = -dx * sa + dz * ca
    rad = np.hypot(uu, vv)
    th = np.arctan2(vv, uu)
    a2, a3, a4 = proto
    r = R * (1 + a2 * np.sin(2 * th + phase)
             + a3 * np.sin(3 * th + phase * 1.7)
             + a4 * np.sin(4 * th + phase * 2.3))
    return smooth_mask(rad <= r, 1)


# ---------------- 区域几何（基地 / 扩张，保持开阔） ----------------


def segment_mask(a, b, width):
    out = np.zeros((GRID_H, GRID_W), dtype=bool)
    a, b = np.asarray(a, dtype=float), np.asarray(b, dtype=float)
    d = b - a
    length2 = float(d @ d)
    if length2 < 1e-12 or width < 0:
        return out
    radius = width / 2.0
    lo = np.maximum(np.floor(np.minimum(a, b) - radius).astype(int), 0)
    hi = np.minimum(np.ceil(np.maximum(a, b) + radius).astype(int), [GRID_W, GRID_H])
    x0, z0 = lo
    x1, z1 = hi
    if x1 <= x0 or z1 <= z0:
        return out
    x, z = np.meshgrid(np.arange(x0, x1) + .5, np.arange(z0, z1) + .5)
    t = np.clip(((x-a[0])*d[0] + (z-a[1])*d[1]) / length2, 0., 1.)
    out[z0:z1, x0:x1] = np.hypot(x-(a[0]+d[0]*t), z-(a[1]+d[1]*t)) <= radius
    return out


# ---------------- 障碍脊线 + 咽喉 + 进攻走廊 ----------------


def _bridge_band(center, widths_q, fr, bw):
    """v5 桥：在水带弧长比例 fr 处沿水带法向放一条宽 bw、长=局部水宽+4 的通行带。
    返回 (mask, center_xy, a, b)。"""
    n_c = len(center)
    q = int(round(fr * (n_c - 1)))
    c = np.array(center[q], dtype=float)
    q0, q1 = max(q - 1, 0), min(q + 1, n_c - 1)
    t = np.array(center[q1], dtype=float) - np.array(center[q0], dtype=float)
    t = t / max(float(np.hypot(*t)), 1e-9)
    across = np.array((-t[1], t[0]))
    half = widths_q[q] / 2.0 + 2.0
    a = c - across * half
    b = c + across * half
    mask = segment_mask((float(a[0]), float(a[1])), (float(b[0]), float(b[1])), bw)
    return mask, (float(c[0]), float(c[1])), [float(a[0]), float(a[1])], [float(b[0]), float(b[1])]


def raster_lane_core(lanes, params):
    lane_core = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    for name, lane in lanes.items():
        if lane["kind"] == "eco":   # v6：经济路线不占 lane_core 位标
            continue
        dist, _ = polyline_field(lane["polyline"])
        lane_core[dist <= params["lane_clear_width"] / 2.0] |= (1 << lane["bit"])
    return lane_core


def build_geometry(starts, polar, params, rng):
    from .g2_strategy import build_geometry as generate
    return generate(starts, polar, params, rng)


# ---------------- 掩体撒布（开阔战场加障碍，拖慢早期） ----------------

def place_cover(starts, geom, params, rng, target_frac):
    """Group whole outcrops by cliff feet and river banks, following regional grain."""
    # Structural blocking excludes walkable plateau interiors.
    base = geom["water_union"] | geom["ring_union"]
    for cliff in geom["cliffs"]:
        base |= cliff["mask"]
    for rg in geom["ridges"].values():
        base |= rg["ridge"]
    forbidden = geom["protected"] | base | geom["corridors"] | geom["region_union"]
    for s in starts:
        forbidden |= (_dist_field(s[0], s[1]) <= params["home_radius"] + 4.0)
    if target_frac >= .3:
        from .g2_mountains import mountain_cover
        actual_base = build_blocking(geom, params, np.zeros_like(base)) > 0
        return mountain_cover(actual_base, forbidden, target_frac, rng, cell_of(*starts[0]))
    clusters = 0
    attempts = 0
    max_clusters = int(params["cover_cluster_max"])
    max_attempts = int(params["cover_max_attempts"])
    cover = np.zeros((GRID_H, GRID_W), dtype=bool)
    r_lo, r_hi = params["cover_radius_range"]
    if not params['river_enabled']:
        # Dry maps need broad, coherent rock formations to reach the same density floor.
        r_hi = max(r_hi, 16.)
    anchors = []
    for pl in geom['plateaus']:
        points = np.array(pl['outline'])
        for a, b in zip(points, np.roll(points, -1, axis=0)):
            tangent = b - a
            if np.linalg.norm(tangent) < 5.:
                continue
            normal = np.array([tangent[1], -tangent[0]]) / np.linalg.norm(tangent)
            anchors.append(((a + b) / 2., normal))
    for river in geom['rivers']:
        pts = np.array(river['polyline'])
        for q in range(10, len(pts)-10, 8):
            tangent = pts[q + 1] - pts[q - 1]
            normal = np.array([tangent[1], -tangent[0]]) / np.linalg.norm(tangent)
            for sign in (-1., 1.):
                anchors.append((pts[q] + sign * normal * river['width'] / 2., sign * normal))
    while (base.mean() + cover.mean() < target_frac
           and clusters < max_clusters and attempts < max_attempts):
        attempts += 1
        if anchors and rng.random() < .85:
            anchor, normal = anchors[int(rng.integers(len(anchors)))]
            tangent = np.array([-normal[1], normal[0]])
            x, z = anchor + normal * rng.uniform(11., 23.) + tangent * rng.uniform(-9., 9.)
        else:
            x, z = rng.uniform(10., W-10.), rng.uniform(10., H-10.)
        if not (6. <= x < W-6. and 6. <= z < H-6.):
            continue
        ci, cj = cell_of(x, z)
        if forbidden[ci, cj]:
            continue
        angle = regional_direction(geom['landform_frame'], (x, z)) + float(rng.uniform(-.22, .22))
        # Allocate the remaining area across the small outcrop budget. Uniform
        # tiny rocks exhausted that budget before the existing density floor.
        area_left = max(0., target_frac - base.mean() - cover.mean()) * GRID_H * GRID_W
        desired_radius = math.sqrt(area_left / max(1, max_clusters - clusters) / (math.pi * 1.75 * .8))
        lower = max(r_lo, min(r_hi - .5, desired_radius))
        outline = landform_outline((x, z), float(rng.uniform(lower, r_hi)), angle, rng,
                                   stretch=float(rng.uniform(1.4, 2.1)))
        cl = polygon_mask(outline)
        if (cl & forbidden).any():
            continue
        if int(cl.sum()) < params["min_blob_cells"]:
            continue
        cover |= cl
        # Avoid chains of almost-touching rocks that create one-cell pockets.
        spacing = cl.copy()
        for _ in range(5):
            spacing = _dil(spacing)
        forbidden |= spacing
        clusters += 1
    return cover, clusters

# ---------------- blocking 构建（开阔默认 + 脊线 + 掩体 - 强制开阔） ----------------

def build_blocking(geom, params, cover):
    """v5 blocking 语义：水=挡、桥=通、台地顶=通、悬崖环=挡、坡道=通。
    blocking = 隔墙(含水墙) ∪ cover ∪ ring ∪ water；再开桥/坡道/墙咽喉。"""
    blocking = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    ridge_u = np.zeros((GRID_H, GRID_W), dtype=bool)
    for rg in geom["ridges"].values():
        blocking[rg["ridge"]] = 1
        ridge_u |= rg["ridge"]
    river_u = np.zeros((GRID_H, GRID_W), dtype=bool)
    for rv in geom["rivers"]:
        blocking[rv["mask"]] = 1
        river_u |= rv["mask"]
    river_u |= geom['water_union']
    blocking[river_u] = 1
    for cl in geom["cliffs"]:
        blocking[cl["mask"]] = 1
    ring_u = geom["ring_union"]
    blocking[ring_u] = 1
    blocking[cover] = 1
    # 强制开阔不侵蚀河/墙/悬崖环（否则扩张/接入道会把隔墙冲残、桥变宽口）；
    # 只开 intentional 桥/坡道/咽喉 + 之外的强制开阔区。
    prot = geom["protected"]
    blocking[prot & (~ridge_u) & (~river_u) & (~ring_u)] = 0
    for rg in geom["ridges"].values():
        for g in rg["gaps"]:
            blocking[g] = 0
    for rv in geom["rivers"]:
        for g in rv["gaps"]:
            blocking[g] = 0
    for pl in geom["plateaus"]:
        blocking[pl["ramps"]] = 0
    return blocking


def build_height(geom, blocking, params):
    """v5 height(f4) 通道（米）：地面 0.6 / 水 -2.4 / 台地顶与悬崖环 3.6 / 坡道 2.1 / 桥 0.6。
    水内可走格=桥/渡口修正=0.6；悬崖环内可走格=坡道/打通修正=2.1（与最终 blocking 一致）。"""
    h = np.full((GRID_H, GRID_W), params["ground_level"], dtype=np.float32)
    water_u = geom["water_union"]
    h[water_u] = params["water_level"]
    for pl in geom["plateaus"]:
        h[pl["ring"] | pl["interior"]] = params["plateau_level"]
    open_ = blocking == 0
    h[water_u & open_] = params["ground_level"]
    mid = (params["ground_level"] + params["plateau_level"]) / 2.0
    for pl in geom["plateaus"]:
        h[pl["ring"] & open_] = mid
    return h


def clean_specks(blocking, params):
    """去掉面积过小的障碍碎块（观感），保留成片的脊线/掩体。"""
    solid = blocking > 0
    if not solid.any():
        return blocking
    lab = label8(solid)
    ncomp = int(lab.max()) + 1
    keep = np.zeros((GRID_H, GRID_W), dtype=bool)
    counts = np.bincount(lab[lab >= 0], minlength=ncomp)
    for c in range(ncomp):
        if counts[c] >= params["min_obstacle_area"]:
            keep |= (lab == c)
    out = blocking.copy()
    out[(blocking > 0) & (~keep)] = 0
    return out


def build_with_retry(starts, polar, geom, key_ij, params, rng):
    """Add only optional cover; retain water/cliff topology exactly."""
    cover, _ = place_cover(starts, geom, params, rng, params["cover_target_frac"])
    cover = clean_specks(cover.astype(np.uint8), params).astype(bool)
    blocking = build_blocking(geom, params, cover)
    # Optional cover may create navigation slivers. Remove the touching cover,
    # never carve a new crossing through water or a cliff.
    from ..pathing import dilate8
    for _ in range(6):
        passable = compute_passable(blocking)
        labels = bfs_components(passable)
        main = int(labels[key_ij[0]])
        islands = (labels >= 0) & (labels != main)
        if not islands.any():
            break
        if params['cover_target_frac'] >= .3:
            # Close pockets with no strategic point instead of deleting the
            # perimeter of an entire connected mountain range.
            from scipy import ndimage
            ids = set(int(labels[tuple(k)]) for k in key_ij)
            expendable = islands & ~np.isin(labels, list(ids))
            fill = dilate8(expendable) & ~geom['protected'] & ~geom['region_union'] & ~geom['water_union']
            if fill.any():
                cover |= fill
                blocking = build_blocking(geom, params, cover)
                continue
        near = islands.copy()
        for _step in range(5):
            near = dilate8(near)
        remove = cover & near
        if not remove.any():
            break
        cover[remove] = False
        blocking = build_blocking(geom, params, cover)
    # 水域/台地/岩体组合可能夹出封闭可走口袋（如河湖之间的半岛）。
    # 定向处理：小口袋（≤pocket_fill_max，不含关键点）填成障碍岩体；
    # 大口袋/含关键点挖障碍陆地走廊回主域——绝不缩小水域、不新增过河点、
    # 不开HOME台地崖壁。
    carves = 0
    for _ in range(4):
        passable = compute_passable(blocking)
        labels = bfs_components(passable)
        main = int(labels[key_ij[0]])
        if main < 0 or not ((labels >= 0) & (labels != main)).any():
            break
        changed = False
        key_cells = set(tuple(k) for k in key_ij)
        n_comp = int(labels.max()) + 1
        counts = np.bincount(labels[labels >= 0], minlength=n_comp)
        for lab in range(n_comp):
            if lab == main or counts[lab] == 0:
                continue
            island = labels == lab
            has_key = any(tuple(k) in key_cells and island[k] for k in key_ij)
            if not has_key and counts[lab] <= int(params.get("pocket_fill_max", 3000)):
                blocking[island] = 1          # 小封闭口袋填实（后续分类为岩体）
                carves += 1
                changed = True
                continue
            ii, jj = np.nonzero(island)
            rep = (int(ii[len(ii) // 2]), int(jj[len(jj) // 2]))
            seg = _carve_corridor(blocking, geom, rep, main, labels, params)
            if seg is not None:
                blocking = seg
                carves += 1
                changed = True
        if not changed:
            break
    from .g2_mountains import close_narrow_gaps
    from scipy import ndimage
    rock = (blocking > 0) & ~geom['region_union'] & ~geom['water_union']
    filled = close_narrow_gaps(rock, radius=3) & ~rock
    labels_fill, _ = ndimage.label(filled)
    sizes = np.bincount(labels_fill.ravel())
    filled &= sizes[labels_fill] <= 80
    filled &= ~geom['protected'] & ~geom['region_union'] & ~geom['water_union']
    blocking[filled] = 1
    # Seal only expendable pockets created by the final rock-slot cleanup.
    for _ in range(3):
        labels = bfs_components(compute_passable(blocking))
        main = int(labels[key_ij[0]])
        islands = (labels >= 0) & (labels != main)
        if not islands.any():
            break
        fill = dilate8(islands) & ~geom['protected'] & ~geom['region_union'] & ~geom['water_union']
        if not fill.any():
            break
        blocking[fill] = 1
    if float(blocking.mean()) > params['obstacle_frac_max']:
        structural = build_blocking(geom, params, np.zeros_like(blocking, dtype=bool)) > 0
        optional = (blocking > 0) & ~structural
        parts, count = ndimage.label(optional, np.ones((3,3)))
        areas = np.bincount(parts.ravel())
        for part in sorted(range(1,count+1), key=lambda p: areas[p]):
            remaining = int(blocking.sum())-int(areas[part])
            if remaining < params['obstacle_frac_min']*blocking.size:
                continue
            blocking[parts == part] = 0
            if float(blocking.mean()) <= params['obstacle_frac_max']:
                break
    passable = compute_passable(blocking)
    connected = keypoints_connected(passable, key_ij)
    return blocking, carves, connected


def _carve_corridor(blocking, geom, src_ij, main_label, labels, params):
    """从孤岛关键点挖一条宽 6m 的陆地走廊回主连通域。

    代价：可走格 1 / 障碍陆地格 12 / 禁止格不可入（水体、桥、HOME 台地崖环）。
    中立台地崖环代价极高（60）——万不得已才穿，且不破坏 ramps。返回新 blocking
    或 None（无可达走廊）。"""
    import heapq
    import numpy as np
    water = geom["water_union"]
    bridges = np.zeros((GRID_H, GRID_W), dtype=bool)
    for rv in geom["rivers"]:
        for g in rv["gaps"]:
            bridges |= g
    home_ring = np.zeros((GRID_H, GRID_W), dtype=bool)
    neutral_ring = np.zeros((GRID_H, GRID_W), dtype=bool)
    for pl in geom["plateaus"]:
        target = home_ring if pl["kind"] == "home" else neutral_ring
        target |= (pl["ring"] & ~pl["ramps"])
    forbidden = water | bridges | home_ring
    cost = np.ones((GRID_H, GRID_W), dtype=np.float64)
    cost[blocking > 0] = 12.0
    cost[neutral_ring] = 60.0
    cost[forbidden] = np.inf
    # 目标：主分量任意格
    goal = (labels == main_label) & ~forbidden
    if not goal.any():
        return None
    dist = np.full((GRID_H, GRID_W), np.inf)
    prev = {}
    si, sj = src_ij
    dist[si, sj] = 0.0
    heap = [(0.0, si, sj)]
    found = None
    while heap:
        d, i, j = heapq.heappop(heap)
        if d > dist[i, j]:
            continue
        if goal[i, j] and (i, j) != (si, sj):
            found = (i, j)
            break
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
            ii, jj = i + di, j + dj
            if not (0 <= ii < GRID_H and 0 <= jj < GRID_W):
                continue
            step = cost[ii, jj] * (1.4142 if (di and dj) else 1.0)
            if not math.isfinite(step):
                continue
            nd = d + step
            if nd < dist[ii, jj]:
                dist[ii, jj] = nd
                prev[(ii, jj)] = (i, j)
                heapq.heappush(heap, (nd, ii, jj))
    if found is None:
        return None
    path = [found]
    while path[-1] != (si, sj):
        path.append(prev[path[-1]])
    path.reverse()
    polyline = [[j + 0.5, i + 0.5] for i, j in path]
    dist_field, _ = polyline_field(polyline)
    corridor = dist_field <= max(3.0, params.get("connect_width", 4.0) / 2.0 + 1.0)
    corridor &= ~forbidden                      # 绝不触碰水体/桥/HOME 崖环
    out = blocking.copy()
    out[corridor] = 0
    return out


def build_keypoints(starts, exp_anchors, gap_centers, plateau_centers=()):
    key = [cell_of(s[0], s[1]) for s in starts]
    key += [cell_of(a[0], a[1]) for a in exp_anchors]
    key += [cell_of(g[0], g[1]) for g in gap_centers]
    # Plateau interiors are gameplay keypoints; they may never become decorative pockets.
    key += [cell_of(c[0], c[1]) for c in plateau_centers]
    return key


# ---------------- 地形分类（沿用 v2） ----------------

def _aspect_ratio(comp):
    ii, jj = np.nonzero(comp)
    if len(ii) < 4:
        return 1.0
    pts = np.stack([jj, ii], axis=1).astype(float)
    pts -= pts.mean(axis=0)
    cov = np.cov(pts.T)
    ev = np.linalg.eigvalsh(cov)
    l1, l2 = float(ev[-1]), float(ev[0])
    if l2 <= 1e-9:
        return 99.0 if l1 > 1e-9 else 1.0
    return math.sqrt(l1 / l2)


def classify_terrain(blocking, params, rng):
    terrain = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    solid = blocking > 0
    if not solid.any():
        return terrain
    lab = label8(solid)
    ncomp = int(lab.max()) + 1
    for c in range(ncomp):
        comp = (lab == c)
        A = int(comp.sum())
        if A == 0:
            continue
        r = _aspect_ratio(comp)
        if r > params["wall_aspect_min"] and A >= params["wall_area_min"]:
            code = TERRAIN_WALL
        elif A >= params["ruin_area_min"]:
            code = TERRAIN_RUIN if rng.random() < 0.5 else TERRAIN_ROCK
        elif A >= params["rock_area_min"]:
            code = TERRAIN_ROCK
        else:
            code = TERRAIN_DEBRIS
        terrain[comp] = code
    return terrain


def build_terrain(geom, blocking, params, rng):
    """Assign terrain classes; walkable tops, ramps and decks use the height channel."""
    terrain = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    solid = blocking > 0
    for rv in geom["rivers"]:
        terrain[rv["mask"] & solid] = TERRAIN_WATER
    terrain[geom['water_union'] & solid] = TERRAIN_WATER
    for cl in geom["cliffs"]:
        terrain[cl["mask"] & solid] = TERRAIN_ROCK
    for pl in geom["plateaus"]:
        terrain[pl["ring"] & solid] = TERRAIN_ROCK
    for rg in geom["ridges"].values():
        code = TERRAIN_WATER if rg.get("water") else TERRAIN_ROCK
        terrain[rg["ridge"] & solid] = code
    leftover = solid & (terrain == 0)
    # G2 optional cover is natural rock. Area/aspect must not silently turn a
    # large outcrop into a ruin or a long one into an artificial wall downstream.
    terrain[leftover] = TERRAIN_ROCK
    return terrain


# ---------------- 验收指标 ----------------

def obstacle_stats(blocking):
    solid = blocking > 0
    total = GRID_H * GRID_W
    if not solid.any():
        return {"solid_frac": 0.0, "n_components": 0, "max_block_frac": 0.0}
    lab = label8(solid)
    ncomp = int(lab.max()) + 1
    counts = np.bincount(lab[lab >= 0], minlength=ncomp)
    return {
        "solid_frac": float(solid.sum() / total),
        "n_components": ncomp,
        "max_block_frac": float(counts.max() / total) if counts.size else 0.0,
    }


def bridge_widths(blocking, geom):
    """v5 桥实测贯通宽：桥中心沿桥宽方向（桥轴 a→b 的法向）两侧遇实体停的开放格数。"""
    out = {}
    for bi, br in enumerate(geom["bridges"]):
        a = np.array(br["a"], dtype=float)
        b = np.array(br["b"], dtype=float)
        c = (a + b) / 2.0
        u = b - a
        u = u / max(float(np.hypot(*u)), 1e-9)
        nrm = np.array((-u[1], u[0]))
        cnt = 0
        for sgn in (1.0, -1.0):
            t = 0.5
            while t <= 20.0:
                x = c[0] + nrm[0] * sgn * t
                z = c[1] + nrm[1] * sgn * t
                if x < 0 or z < 0 or x >= W or z >= H:
                    break
                ci, cj = cell_of(x, z)
                if blocking[ci, cj] > 0:
                    break
                cnt += 1
                t += 1.0
        out[f"bridge_{bi}"] = float(cnt)
    return out


def acceptance(blocking, role, lanes, starts, key_ij, params, geom):
    from .g2_strategy import acceptance as validate
    return validate(blocking, starts, key_ij, params, geom)


def assign_role_region(geom, blocking, starts):
    open_mask = blocking == 0
    role = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    region = np.zeros((GRID_H, GRID_W), dtype=np.uint16)
    d_all = np.stack([_dist_field(s[0], s[1]) for s in starts])
    nearest = np.argmin(d_all, axis=0)
    role[open_mask] = ROLE_HINTERLAND
    region[open_mask] = (50 + nearest[open_mask]).astype(np.uint16)
    for i in range(4):
        m = geom["exp_masks"][i] & open_mask
        role[m] = ROLE_EXPANSION
        region[m] = 40 + i
    # 咽喉缺口邻域 = flank（会战/争夺点）
    for gc in geom["gap_centers"]:
        m = (_dist_field(gc[0], gc[1]) <= G2_DEFAULTS["flank_radius"]) & open_mask
        role[m] = ROLE_FLANK
        region[m] = 30 + 0
    for i in range(4):
        m = geom["home_masks"][i] & open_mask
        role[m] = ROLE_HOME
        region[m] = 10 + i
    return role, region


def lane_to_json(lane, params, bonus):
    return {
        "kind": lane["kind"], "bit": lane["bit"], "pair": lane.get("pair"),
        "base": lane["base"], "bonus": 0.0, "length": lane["length"],
        "polyline": lane["polyline"], "choke_w": lane.get("choke_w"),
        "side_pockets": lane.get("side_pockets", []),
    }


# ---------------- 主流程 ----------------

HARD_LAYOUT_REJECTS = (
    'No complete river corridors satisfy the selected layout',
    'No connected river corridor clears the spawn plateaus',
    'Unknown river layout',
)


def hard_layout_reject(text):
    message = str(text or '')
    return any(tag in message for tag in HARD_LAYOUT_REJECTS)


class NoTerrainCandidate(ValueError):
    """A valid request exhausted its candidate budget before geometry existed."""
    def __init__(self, seed, attempts):
        super().__init__(f'G2 seed {seed}: no valid terrain candidate in {len(attempts)} attempts')
        self.attempts = attempts


def run_one(seed, runs_root, params, detail=False, on_progress=None, auto=False):
    if not auto:
        ensure_upstream_approved(runs_root, seed, "G2")
    g1_dir = run_dir(runs_root, seed, "G1")
    g1_spec = read_json(g1_dir / "mapspec.json")
    if auto:
        _ensure_g1_valid_auto(seed, g1_spec)
    return _generate_from_parent(seed, runs_root, params, g1_spec,
                                 MapGrid.load(g1_dir / 'mapgrid.npz'), detail, on_progress,
                                 execution_mode='workbench_auto' if auto else 'formal')


def _ensure_g1_valid_auto(seed, g1_spec):
    """工作台自动模式：不依赖人工 approval，用本次输入的真实检查代替。

    与 run_preview 同源：G1 必须 accepted、master_seed 一致、约束无违反。
    正式 CLI 语义不变（run_one 默认仍要求上游 approved）。"""
    from .g1_starts import evaluate_constraints, first_violation
    if (not g1_spec.get('accepted') or g1_spec.get('master_seed') != seed
            or first_violation(evaluate_constraints(g1_spec['starts'], g1_spec['params'])) is not None):
        raise RuntimeError(f'自动模式拒绝运行 G2：Seed {seed} 的 G1 输入未通过出生布局检查。')


def run_preview(seed, runs_root, params, on_progress=None):
    """Local preview of an accepted G1 candidate; formal gate execution stays unchanged."""
    from .g1_starts import evaluate_constraints, first_violation
    g1_dir = run_dir(runs_root, seed, 'G1')
    g1_spec = read_json(g1_dir / 'mapspec.json')
    parent = MapGrid.load(g1_dir / 'mapgrid.npz')
    ev = evaluate_constraints(g1_spec['starts'], g1_spec['params'])
    if (not g1_spec.get('accepted') or g1_spec['master_seed'] != seed
            or first_violation(ev) is not None):
        raise ValueError('出生布局未通过距离、领地与公平检查。')
    return _generate_from_parent(seed, runs_root, params, g1_spec, parent,
                                 on_progress=on_progress, preview_only=True,
                                 execution_mode='workbench_preview')


def _generate_from_parent(seed, runs_root, params, g1_spec, parent, detail=False,
                          on_progress=None, preview_only=False, execution_mode='formal'):
    from pathlib import Path
    algo = ALGO_VERSION['G2']
    params = {**G2_DEFAULTS, **params}
    g1_dir = run_dir(runs_root, seed, 'G1')
    input_hash = sha256_file(g1_dir / "mapgrid.npz")

    # The parent Seed chooses the G1 layout; terrain_seed varies G2 independently.
    # Preserve the approved 7.10 crossed-river random stream when adding layouts.
    from ..contract import RNG_VERSION
    random_version = RNG_VERSION['G2']
    stream = random_version if not params['terrain_seed'] else f"{random_version}|terrain={params['terrain_seed']}"
    rng = gate_rng(seed, "G2", stream)
    starts = [tuple(s) for s in g1_spec["starts"]]
    if parent.get('territory').shape != (GRID_H, GRID_W):
        raise ValueError(f'G1 grid must be {GRID_W}x{GRID_H}; regenerate matching G1 inputs.')
    polar = polar_order(starts)

    candidates, best, best_score = [], None, None
    from .g2_candidates import candidates as generate_candidates
    for record, result in generate_candidates(seed, stream, starts, params):
        candidates.append(record)
        attempt = record['attempt'] - 1
        if on_progress:
            on_progress({'attempt': attempt + 1, 'limit': params['layout_attempts'], **record})
        if result is None:
            continue
        acc = result[7]
        failed = record['failed_checks']
        score = (len(failed), acc['plateau_fair_ratio'], acc['path_fairness']['flank_ratio'])
        if best_score is None or score < best_score:
            best_score = score
            best = result
        if acc['all_pass']:
            break
    if best is None:
        raise NoTerrainCandidate(seed, candidates)
    geom, key_ij, blocking, retries, connected, role, region, acc, chosen = best
    terrain = build_terrain(geom, blocking, params, rng)
    height = build_height(geom, blocking, params)
    passable = compute_passable(blocking)
    lane_core = raster_lane_core(geom["lanes"], params)

    grid = MapGrid.from_parent(parent)
    grid.set("region", region)
    grid.set("role", role)
    grid.set("lane_core", lane_core)
    grid.set("terrain", terrain)
    grid.set("height", height)
    grid.set("water_footprint", geom["water_union"].astype(np.uint8))
    grid.set("blocking", blocking)
    grid.set("passable", passable)

    rd = run_dir(runs_root, seed, "G2")
    Path(rd).mkdir(parents=True, exist_ok=True)
    npz_hash = grid.save(rd / "mapgrid.npz")

    lanes_json = {name: lane_to_json(lane, params, {}) for name, lane in geom["lanes"].items()}
    write_json(rd / "lanes.json", lanes_json)

    mapspec = {
        "gate": "G2", "master_seed": seed, "gate_seed": gate_seed_int(seed, "G2", stream),
        "algo_version": algo, "params": params, "rng_stream": stream,
        "generation": {"chosen_attempt": chosen, "attempts": candidates},
        "starts": g1_spec["starts"], "polar_order": polar,
        "flank_anchors": [list(a) for a in geom["flank_anchors"]],
        "expansion_anchors": [list(a) for a in geom["exp_anchors"]],
        "expansion_modes": geom["exp_modes"],
        "gap_centers": [list(g) for g in geom["gap_centers"]],
        "keypoints": [[int(i), int(j)] for i, j in key_ij],
        "height_levels": {"ground": params["ground_level"], "water": params["water_level"],
                          "plateau": params["plateau_level"],
                          "ramp": (params["ground_level"] + params["plateau_level"]) / 2.0},
        # G2 is the authority for gameplay semantics; G3/G4 only dress these
        # roles with meshes and materials. Keep the visual kit names beside
        # the raster channels so a kit cannot silently diverge from passability.
        "kit_bindings": {
            "walkable_ground": "terrain_ground",
            "walkable_plateau_top": "plateau_top",
            "walkable_plateau_ramp": "plateau_ramp",
            "blocked_cliff_and_mountain": "sandstone_mountain",
            "blocked_ridge": "sandstone_ridge",
            "blocked_water": "water_bed",
            "walkable_bridge": "bridge_deck",
        },
        "navigation_contract": {
            "walkable_channel": "passable",
            "blocking_channel": "blocking",
            "height_channel": "height",
            "ramp_width_m": float(params["plateau_ramp_width"]),
            "max_slope_degrees": 30.0,
            "agent_max_climb_m": 0.5,
        },
        "bridges": geom["bridges"],
        "contest_nodes": [{"x": n["xy"][0], "z": n["xy"][1], "owners": n["owners"],
                           "kind": n["kind"]} for n in geom["contest"]],
        "contest_ratios": acc["contest_ratios"],
        "plateau_fair_ratio": acc["plateau_fair_ratio"],
        "n_neutral_contest": acc["n_neutral_contest"],
        "route_coverage": acc["route_coverage"],
        "spawn_profiles": geom["spawn_profiles"],
        "landform_frame": geom["landform_frame"],
        "rivers": [{"polyline": rv["polyline"], "width": rv["width"],
                    "widths": rv.get("widths", []), "flow_direction": rv.get("flow_direction"),
                    "tributaries": rv.get("tributaries", []),
                    "kind": rv["kind"], "endpoints": rv["endpoints"]} for rv in geom["rivers"]],
        "lakes": [{"center": list(lake['center']), "outline": lake['outline'],
                   "area_m2": int(lake['mask'].sum())} for lake in geom.get('lakes', [])],
        "strategy_metrics": acc["strategy_metrics"],
        "plateaus": [{"center": list(pl["center"]),
                      "footprint_area_m2": int(pl['region'].sum()),
                      "walkable_top_area_m2": int((pl['region'] & (blocking == 0)).sum()),
                      "lobes": pl.get("lobes", 1),
                      "outline": pl["outline"], "landform_angle": pl["landform_angle"],
                      "kind": pl["kind"], "owner": pl["owner"],
                      "controlled_routes": pl["controlled_routes"],
                      "ramp_centers": [list(rc) for rc in pl["ramp_centers"]],
                      "ramp_dirs": [list(rd) for rd in pl["ramp_dirs"]]}
                     for pl in geom["plateaus"]],
        "recarve": {"retries": retries, "connected": connected},
        "solid_frac": acc["solid_frac"], "n_components": acc["n_components"],
        "max_block_frac": acc["max_block_frac"], "open_components": acc["open_components"],
        "neighbor_wall": acc["neighbor_wall"], "lane_widths": acc["lane_widths"],
        "bridge_widths": acc["bridge_widths"],
        "detour": acc["detour"],
        "path_fairness": acc["path_fairness"], "checks": acc["checks"], "all_pass": acc["all_pass"],
    }
    if preview_only:
        mapspec.update(preview_only=True)
        mapspec['checks']['spawn_layout_pass'] = True  # rechecked by run_preview before generation
    json_hash = write_json(rd / "mapspec.json", mapspec)
    write_json(rd / "report.json", {
        "seed": seed, "algo_version": algo, "acceptance": acc, "recarve": mapspec["recarve"],
    })
    # ---- 装饰语义提示层（纯附加产物；不写入任何权威通道，不影响上面两个哈希）----
    from . import g2_decor
    decor_path, decor_meta = g2_decor.write_hints(
        rd, seed, stream, geom, blocking, lane_core, params, starts,
        terrain_seed=int(params.get("terrain_seed", 0) or 0), g2_algo_version=algo)
    if not decor_meta.get("all_pass", False):
        failed = [k for k, v in decor_meta["checks"].items() if not v]
        raise ValueError(f"G2 装饰提示层自检失败: {failed}")
    manifest = new_manifest(seed, "G2", mapspec["gate_seed"], algo, params,
                            input_hash=input_hash,
                            output_hash={"mapgrid.npz": npz_hash, "mapspec.json": json_hash})
    manifest['execution_mode'] = execution_mode
    manifest['decoration'] = {
        "algo_version": decor_meta["decoration_algo_version"],
        "files": ["decoration_hints.npz", "decoration_hints.json"],
        "all_pass": decor_meta["all_pass"],
        "zone_cells": {k: v["cells"] for k, v in decor_meta["zones"].items()},
        "note": "纯附加提示层；不参与 blocking/passable/导航，不改已有 G2 掩码",
    }
    if preview_only:
        manifest['preview_only'] = True
    elif execution_mode == 'formal':
        _inherit_approval(runs_root, seed, "G2", manifest, algo)
    write_json(rd / "manifest.json", manifest)
    # 附加产物：游戏小地图/大厅预览。不进 output_hash，避免改图翻掉已通过的 G2。
    from ..viz.plots_g2 import write_minimap_preview
    write_minimap_preview(rd / "minimap_preview.png", grid, mapspec.get("bridges") or [])

    res = {"seed": seed, "run_dir": rd, "mapspec": mapspec, "grid": grid,
           "lanes": geom["lanes"], "lanes_json": lanes_json, "starts": starts,
           "geom": geom, "key_ij": key_ij}
    if detail:
        from ..viz import plots_g2
        plots_g2.plot_detail(res)
    return res


def _inherit_approval(runs_root, seed, gate, manifest, algo):
    from ..gate import load_manifest, manifest_path
    p = manifest_path(runs_root, seed, gate)
    if p.exists():
        old = load_manifest(runs_root, seed, gate)
        if (old.get("gate") == gate and old.get("algo_version") == algo and old.get("approved")
                and old.get("input_hash") == manifest.get("input_hash")
                and old.get("output_hash") == manifest.get("output_hash")):
            manifest["approved"] = True
            manifest["approved_note"] = old.get("approved_note")
            manifest["approved_at"] = old.get("approved_at")


def run_gate(runs_root, seeds, params=None, summary_only=False, detail=False, review_root="review"):
    params = {**G2_DEFAULTS, **(params or {})}
    results = []
    for seed in seeds:
        res = run_one(seed, runs_root, params, detail=detail)
        results.append(res)
        acc = res["mapspec"]
        print(f"Seed {seed}: all_pass={acc['all_pass']} obstacle={acc['solid_frac']:.3f} "
              f"comps={acc['n_components']} water_components={acc['strategy_metrics']['water_components']} "
              f"retry={acc['recarve']['retries']}")
        if not acc["all_pass"]:
            print(f"  failed: {[k for k, v in acc['checks'].items() if not v]}")
    from ..viz import review
    review.build_g2_review(runs_root, review_root, [r["seed"] for r in results])
    return results
