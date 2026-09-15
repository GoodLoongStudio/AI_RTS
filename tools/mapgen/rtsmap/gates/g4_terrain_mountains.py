"""山体高度场权威实现（Python 单一事实源）。

背景：山体 relief 原本只存在于 review 渲染器（tools/godot/render_g2_kits.gd 的
GDScript 实现），G4 导出的 height_data.bin 里山体区域是 0.6 平地 —— 游戏内
没有山。本模块把 GDScript 版公式直译为 numpy 向量化实现，作为唯一权威：

  render_g2_kits.gd   -> 改为读取本模块产出的山体增量（视觉=游戏一致）
  g4_export/build_heightfield -> 将山体增量烘入 height_data（游戏内几何、
                                 碰撞、导航烘焙自动包含山体 = 不可通行自然阻挡）

公式对应关系（GDScript -> 本模块）：
  range_noise(freq .0032, oct 2)  -> _value_noise(x*.0032, z*.0032, 2 oct)
  crag_noise(freq .13, oct 4)     -> _value_noise(x*.13, z*.13, 4 oct)
  grit_noise(freq .11, oct 2)     -> _value_noise(x*.11, z*.11, 2 oct)
  Variety.catalog()/mass_relief() -> _mass_relief / _CATALOG
  tile 3x3 邻域 + band_ang 相位    -> _range_relief

坐标口径：输入输出均为 1025x1025 逻辑高度场（顶点间距 2 m，覆盖 2048 m），
与 g4_terrain.build_heightfield 的 hf 同网格。
"""

import numpy as np
from scipy import ndimage as ndimage_gaussian

GRID = 1025


# ---------------------------------------------------------------------------
# value noise（确定性 hash，numpy 向量化；与 GDScript 数值不必逐位一致，
# 视觉特征一致即可 —— 山形以本模块落盘数据为准，两端渲染同源）
# ---------------------------------------------------------------------------

def _hash01(ix: np.ndarray, iy: np.ndarray, seed: int) -> np.ndarray:
    h = (ix.astype(np.int64) * 73856093) ^ (iy.astype(np.int64) * 19349663) ^ (seed * 83492791)
    h = (h ^ (h >> 13)) * 1274126177
    h = h & 0x7FFFFFFF
    return (h & 0xFFFF).astype(np.float64) / 65535.0


def _value_noise(x: np.ndarray, y: np.ndarray, freq: float, octaves: int, seed: int) -> np.ndarray:
    """返回 [-1, 1] 的分形 value noise（与 FastNoiseLite 用法同构）。"""
    x = x * freq + seed * 0.173
    y = y * freq - seed * 0.079
    total = np.zeros_like(x)
    amp = 1.0
    norm = 0.0
    for o in range(octaves):
        ix = np.floor(x).astype(np.int64)
        iy = np.floor(y).astype(np.int64)
        fx = x - ix
        fy = y - iy
        ux = fx * fx * (3.0 - 2.0 * fx)
        uy = fy * fy * (3.0 - 2.0 * fy)
        a = _hash01(ix, iy, seed + o)
        b = _hash01(ix + 1, iy, seed + o)
        c = _hash01(ix, iy + 1, seed + o)
        d = _hash01(ix + 1, iy + 1, seed + o)
        total += amp * ((a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy)
        norm += amp
        amp *= 0.5
        x = x * 2.0 + 19.19
        y = y * 2.0 - 7.31
    return total / norm * 2.0 - 1.0


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------------------
# Variety.catalog() 直译：3 个家族、共 9 座 mass
# ---------------------------------------------------------------------------

_CATALOG = [
    {"masses": [
        {"cx": -2, "cz": -1, "sx": 16, "sz": 11, "height": 17.0, "shape": "ridge", "phase": 1.3},
        {"cx": 10, "cz": 3, "sx": 9, "sz": 8, "height": 10.0, "shape": "ridge_short", "phase": 3.1}]},
    {"masses": [
        {"cx": -9, "cz": -3, "sx": 17, "sz": 12, "height": 23.0, "shape": "ridge", "phase": 2.0},
        {"cx": 5, "cz": 1, "sx": 15, "sz": 13, "height": 19.0, "shape": "ridge_forked", "phase": 2.9},
        {"cx": 18, "cz": 5, "sx": 10, "sz": 9, "height": 12.0, "shape": "ridge_short", "phase": 4.0}]},
    {"masses": [
        {"cx": -18, "cz": 1, "sx": 12, "sz": 11, "height": 14.0, "shape": "ridge_short", "phase": 0.6},
        {"cx": -4, "cz": -5, "sx": 15, "sz": 12, "height": 25.0, "shape": "ridge", "phase": 2.2},
        {"cx": 11, "cz": -1, "sx": 12, "sz": 10, "height": 19.0, "shape": "ridge_forked", "phase": 3.5},
        {"cx": 24, "cz": 5, "sx": 11, "sz": 9, "height": 18.0, "shape": "ridge", "phase": 4.7}]},
]


def _mass_relief(dx: np.ndarray, dz: np.ndarray, mass: dict) -> np.ndarray:
    """mountain_variety.gd mass_relief() 直译（numpy 向量化）。"""
    sx = float(mass["sx"])
    sz = float(mass["sz"])
    phase = float(mass["phase"])
    shape = mass["shape"]

    qx = dx / sx
    qz = dz / sz
    rot = np.sin(phase * 1.31) * 0.9
    qr_x = qx * np.cos(rot) - qz * np.sin(rot)
    qr_z = qx * np.sin(rot) + qz * np.cos(rot)

    ridge_angle = phase * 1.7
    along_len = 0.88
    across_half = 0.68
    peaks = 3
    if shape == "ridge_short":
        ridge_angle += 0.8
        along_len = 0.58
        across_half = 0.72
        peaks = 2
    elif shape == "ridge_forked":
        ridge_angle -= 0.5
        along_len = 1.00
        across_half = 0.58
        peaks = 3

    ax = np.cos(ridge_angle)
    az = np.sin(ridge_angle)
    along = qr_x * ax + qr_z * az
    across = -qr_x * az + qr_z * ax

    crest = 0.26 * np.sin(along * 2.4 + phase) + 0.12 * np.sin(along * 5.3 - phase * 1.7)
    d_across = across - crest
    broad = _hash_noise_pair(along * 1.7 + phase * 23.0, d_across * 1.7, 7001)
    fine = _hash_noise_pair(along * 4.3 + phase * 11.0, d_across * 4.3, 7002)
    w = np.maximum(across_half * (0.86 + 0.14 * broad + 0.08 * fine), 0.14)
    pu = np.clip(1.0 - np.abs(d_across) / w, 0.0, 1.0)
    prof = pu * pu * (3.0 - 2.0 * pu)
    taper = 1.0 - _smoothstep(along_len * 0.75, along_len * 1.05, np.abs(along))

    summit = 0.58 + 0.14 * (0.5 + 0.5 * broad)
    top = 0.0
    defs = []
    spread = 0.66 if peaks < 3 else 0.80
    for k in range(peaks):
        t = 0.0 if peaks < 2 else k / (peaks - 1)
        side = abs(t - 0.5) * 2.0
        c = (t * 2.0 - 1.0) * along_len * spread
        hh = 1.0 - 0.28 * side + 0.10 * np.sin(phase * 2.7 + k * 2.3)
        ww = max(along_len * (0.48 + 0.14 * np.sin(phase * 1.9 + k * 2.1)), 0.18)
        defs.append((c, hh, ww))
        top = max(top, hh)
    for c, hh, ww in defs:
        u = np.clip(1.0 - np.abs((along - c) / ww), 0.0, 1.0)
        summit = np.maximum(summit, (hh / max(top, 1e-4)) * u * u * (3.0 - 2.0 * u))

    notch = np.zeros_like(along)
    for spot in (-0.40, 0.40, 0.92):
        nc = spot * along_len + 0.16 * np.sin(phase * 5.1 + spot * 3.3)
        nw = 0.11 + 0.05 * np.sin(phase * 1.3 + spot)
        nd = 0.16 + 0.10 * (0.5 + 0.5 * np.sin(phase * 3.7 + spot * 2.1))
        u = np.clip(1.0 - np.abs((along - nc) / max(nw, 0.04)), 0.0, 1.0)
        notch = np.maximum(notch, nd * u * u * (3.0 - 2.0 * u))
    notch *= 0.30 + 0.70 * prof

    ridge = mass["height"] * prof * taper * summit * (1.0 - notch)

    spur_rot = -(ridge_angle + 0.95 + 0.45 * np.sin(phase * 2.1))
    sq_x = qr_x * np.cos(spur_rot) - qr_z * np.sin(spur_rot)
    sq_z = qr_x * np.sin(spur_rot) + qr_z * np.cos(spur_rot)
    su = np.clip(1.0 - np.abs(sq_z - 0.34) / 0.28, 0.0, 1.0)
    spur_prof = su * su * (3.0 - 2.0 * su)
    spur_taper = 1.0 - _smoothstep(0.30, 0.80, np.abs(sq_x))
    spur = mass["height"] * 0.52 * spur_prof * spur_taper * (0.85 + 0.30 * broad)

    fan_noise = _hash_noise_pair(dx * 0.22 + phase * 13.0, dz * 0.22 + phase * 7.0, 7003)
    fan_warp = _hash_noise_pair(dx * 0.35 + phase * 31.0, dz * 0.35 - phase * 17.0, 7004)
    fan_reach = 1.55 + 0.35 * fan_noise
    qlen = np.sqrt(qx * qx + qz * qz)
    fan = np.clip(1.0 - (qlen + fan_warp * 0.18) / fan_reach, 0.0, 1.0)
    skirt = mass["height"] * (0.085 + 0.05 * (0.5 + 0.5 * fan_noise)) * fan

    return np.maximum(np.maximum(ridge, spur), skirt)


def _hash_noise_pair(x: np.ndarray, y: np.ndarray, seed: int) -> np.ndarray:
    """双线性插值 value noise（[0,1]，供 broad/fine/fan 使用，freq 内建于坐标）。"""
    ix = np.floor(x).astype(np.int64)
    iy = np.floor(y).astype(np.int64)
    fx = x - ix
    fy = y - iy
    ux = fx * fx * (3.0 - 2.0 * fx)
    uy = fy * fy * (3.0 - 2.0 * fy)
    a = _hash01(ix, iy, seed)
    b = _hash01(ix + 1, iy, seed)
    c = _hash01(ix, iy + 1, seed)
    d = _hash01(ix + 1, iy + 1, seed)
    return (a * (1 - ux) + b * ux) * (1 - uy) + (c * (1 - ux) + d * ux) * uy


def _elevation(px: np.ndarray, pz: np.ndarray, family: int) -> np.ndarray:
    """Variety.elevation() 直译：family 的全部 mass 取平滑最大并边界归零。"""
    height = np.zeros_like(px)
    for mass in _CATALOG[family]["masses"]:
        value = np.maximum(_mass_relief(px - mass["cx"], pz - mass["cz"], mass), 0.0)
        overlap = np.maximum(0.0, 1.5 - np.abs(height - value)) / 1.5
        height = np.maximum(height, value) + overlap * overlap * 0.375 * _smoothstep(0.0, 2.0, np.minimum(height, value))
    height *= (1.0 - _smoothstep(41.5, 43.4, np.abs(px))) * (1.0 - _smoothstep(21.5, 24.4, np.abs(pz)))
    return np.maximum(height, 0.0)


# ---------------------------------------------------------------------------
# 渲染器调用侧直译：山脉带方向场 + 3x3 tile 邻域 + 幅值/侵蚀/扇区
# ---------------------------------------------------------------------------

def _component_dmax(rock_depth: np.ndarray, rock_mask: np.ndarray, shape) -> np.ndarray:
    """每座连通岩体自己的 EDT 峰值，与 rock_depth 同形（ravel）。"""
    rd_img = rock_depth.reshape(shape)
    rock_img = rock_mask.reshape(shape)
    labels, n = ndimage_gaussian.label(rock_img)
    maxes = np.zeros(n + 1, dtype=np.float64)
    if n:
        np.maximum.at(maxes, labels.ravel(), rd_img.ravel())
    maxes[0] = 1.0
    maxes = np.maximum(maxes, 1.0)
    return maxes[labels].ravel()


def mountain_addon(x: np.ndarray, z: np.ndarray, rock_depth: np.ndarray,
                   rock_outer: np.ndarray, logical_cell: float = 3.90625,
                   lane_core: np.ndarray = None) -> np.ndarray:
    """返回要叠加到权威高度上的山体增量（米），语义与 GDScript 渲染器一致。

    x/z: 渲染索引坐标（0..1024，格距 2 m）；rock_depth/rock_outer: EDT 格。
    权威基线（水床/平地/台地三层）之外的山体全部由本函数给出：
      rock_depth > 0  -> 岩体内部（relief + ridged 侵蚀 + 山脚单调保底）
      rock_outer > 0  -> 沉积扇（低幅丘状，封顶低于岩缘保底）
      其余            -> 0（开阔沙地保持权威平地）
    只在 rock/fan 子集上计算（向量化子集索引），避免 9 邻域全网格浪费。
    """
    lc = logical_cell
    addon = np.zeros(x.shape, dtype=np.float64)

    # ---- 岩体内部子集：rock 掩码 EDT 驱动的结构化山体 ----
    # 放弃"tile+相位旋转"机制：其采样朝向逐点变化，在 hash 噪声下把山切碎成
    # 针林。改为语义驱动：山的骨架 = G2 rock 掩码本身（EDT 天然连续），主峰
    # 在山体核心（EDT 最大处），ridged 多倍频提供破碎山脊与沟壑。
    rock_mask = rock_depth > 0
    ri = np.flatnonzero(rock_mask)
    if ri.size:
        xs = x[ri]
        zs = z[ri]
        rd = rock_depth[ri]
        # 每座岩体用自己的深度峰值起峰。全局 dmax 会让小团块 rel 永远 <0.2，
        # 看起来像一摊皱毯子；大团块也被摊平。
        nside = int(round(np.sqrt(x.size)))
        dmax = _component_dmax(rock_depth, rock_mask, (nside, nside))[ri]
        # 大团块才给满幅；孤岛按尺度封顶，避免 8 格石头变成 200m 针。
        mass = _smoothstep(8.0, 28.0, dmax)
        rel = np.clip(rd / dmax, 0.0, 1.0)
        core = _smoothstep(0.0, dmax * 0.16, rd)       # 更陡的裙，iso 机能读出墙
        edge_rise = _smoothstep(0.0, dmax * 0.05, rd)
        base = rel ** 0.50                             # 比 0.75 更快聚到峰
        body = _smoothstep(2.5, np.maximum(dmax * 0.22, 8.0), rd)
        # 主脊主导。中高频 face 是"毛巾纹"的来源，不再叠加。
        rg1 = 1.0 - np.abs(_value_noise(xs, zs, 0.008, 3, 31011))
        rg2 = 1.0 - np.abs(_value_noise(xs, zs, 0.022, 2, 31012))
        rg3 = 1.0 - np.abs(_value_noise(xs, zs, 0.055, 1, 31013))
        crest = 0.75 * rg1 + 0.20 * rg2 + 0.05 * rg3 * body
        crag = _value_noise(xs, zs, 0.10, 3, 20260913) * 0.5 + 0.5
        # 主脉目标 ~180–200 世界米（用户：110m 仍然太矮）。
        h_rock = 0.4
        h_rock += core * (5.0 + 6.0 * mass)
        h_rock += base * ((6.0 + 6.0 * mass) + (10.0 + 22.0 * mass) * crest)
        h_rock += edge_rise * (6.0 + 3.0 * mass) * (1.0 - core)
        shape = np.clip(core + base, 0.0, 2.0)
        h_rock += shape * (crag - 0.5) * 0.55 * body   # 只留很淡的岩面
        h_rock = np.maximum(h_rock, edge_rise * 1.5)
        raw = h_rock - 0.6 * lc
        # 山脚保底（2026-09-14 用户："边缘为什么会有凹陷"）：
        # 旧式 raw 在 rd≈0 时 ≈ -0.8~-0.1（h_rock≈0.5+fn_b，再减 0.6*lc=2.34），
        # 而紧邻沉积扇 addon 中位 1.86 —— 剖面是沙地→扇鼓包→岩缘塌陷→再爬升。
        # 实测最外圈 96.5% addon<0。保底只作用外 6 格，向内与 raw 汇合；
        # 不扩张 rock 掩码，避免把陡坡铺到可走沙地。
        foot_w = np.clip(1.0 - (rd - 6.0) / 2.0, 0.0, 1.0)
        foot = 2.15 + 0.40 * np.clip(rd, 0.0, 6.0)
        addon[ri] = np.maximum(np.maximum(raw, foot * foot_w), 0.0)

    # ---- 沉积扇子集 ----
    fan_mask = (rock_outer > 0) & ~rock_mask
    fi = np.flatnonzero(fan_mask)
    if fi.size:
        xs = x[fi]
        zs = z[fi]
        ro = rock_outer[fi]
        fan = _smoothstep(14.0, 0.0, ro)
        fn = _hash_noise_pair(xs * 0.55, zs * 0.55, 20260912) * 0.5 + 0.5
        und = np.maximum(0.0, _value_noise(xs, zs, 0.012, 3, 20260912)) * 0.25
        # 边界贴齐岩缘保底（2.15），向外收到 0；封顶 2.10，禁止再高过岩缘。
        addon[fi] = np.minimum(fan * fan * (1.75 + fn * 0.30 + und), 2.10)

    # ---- 进攻轴线压制（lane_core 语义掩码）：山体/扇区在轴线上清零 ----
    # RTS 铁律：进攻轴线必须可走。山体（G4 层新增）加入后若切断轴线，
    # 地图不可玩 —— lane_core 区域的山体增量直接清零（边缘 2 格过渡）。
    if lane_core is not None:
        lc_d = ndimage_gaussian.gaussian_filter(lane_core.astype(np.float64), 2.0)
        addon *= (1.0 - np.clip(lc_d * 1.4, 0.0, 1.0))

    # ---- 开阔沙地：不加几何起伏 ----
    # agent_max_climb = 0.0 的导航模型下，任何连续起伏都会让相邻体素断连，
    # Recast 产出 0 多边形（实测 polygons=0）。沙地光影由 shader 的
    # 法线扰动/色彩噪声承担，权威高度保持阶梯平坦（平地/台地/坡道/岸坡）。

    return addon


def vertex_rock_fields(rock_mask_g, plateau_region, water_mask, max_outer=12.0):
    """512 格语义掩码 -> 513x513 顶点口径的 (rock_v, rock_depth, rock_outer)。

    rock 定义与 prepare_g2_kit_render.py 一致：blocking - 水 - 台地区。
    """
    from scipy import ndimage
    rock = rock_mask_g & ~water_mask & ~plateau_region
    pr = np.pad(rock, 1, mode='edge')
    rock_v = pr[:-1, :-1] | pr[:-1, 1:] | pr[1:, :-1] | pr[1:, 1:]
    rd_v = ndimage.distance_transform_edt(rock_v)
    # 轻度平滑深度场：去掉像素级齿，山脚高度沿缘不再跟着锯齿上下跳。
    # 只改高度所用的 rd，不改 rock 掩码本身（可走沙地不被填）。
    rd_v = ndimage.gaussian_filter(rd_v, 1.2)
    rd_v[~rock_v] = 0.0
    ro_v = np.minimum(ndimage.distance_transform_edt(~rock_v), max_outer)
    ro_v[rock_v] = 0.0
    return rock_v, rd_v, ro_v
