"""G2/G4 俯视底图：按 showcase_land 同系 PBR 上色，给工作台和小地图用。"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

from ..contract import G2_DEFAULTS, G4_AIRTS, GRID_H, GRID_W, H, W

PBR_DIR = Path(G4_AIRTS) / "assets" / "terrain_pbr"

# G4 fragment 里的水面：浅 (0.09,0.30,0.36) → 深 (0.02,0.06,0.12)
WATER_SHALLOW = np.array((23, 77, 92), dtype=np.float32)
WATER_DEEP = np.array((5, 15, 31), dtype=np.float32)
BRIDGE_DECK = np.array((168, 142, 104), dtype=np.float32)
BRIDGE_PLANK = np.array((132, 110, 80), dtype=np.float32)
BRIDGE_RAIL = np.array((92, 76, 56), dtype=np.float32)
FALLBACK = {
    "sand": np.array((176, 152, 118), dtype=np.float32),
    "top": np.array((186, 168, 140), dtype=np.float32),
    "cliff": np.array((122, 104, 86), dtype=np.float32),
    "rock": np.array((78, 68, 60), dtype=np.float32),
    "ramp": np.array((154, 128, 96), dtype=np.float32),
    "shore": np.array((128, 116, 92), dtype=np.float32),
}

# 工作台图例用的代表色（合成后再取中位会漂，图例固定这些）
LEGEND_WATER = (18, 58, 72)
LEGEND_SAND = (176, 152, 118)
LEGEND_TOP = (186, 168, 140)
LEGEND_CLIFF = (110, 92, 74)
LEGEND_RAMP = (154, 128, 96)
LEGEND_BRIDGE = (168, 142, 104)
LEGEND_ROCK = (78, 68, 60)


@lru_cache(maxsize=16)
def _load_tex(name: str):
    path = PBR_DIR / name
    if not path.is_file():
        return None
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.uint8)


def _sample(tex, x, z, period_m, fallback):
    if tex is None:
        return np.broadcast_to(fallback, x.shape + (3,)).astype(np.float32)
    th, tw = tex.shape[:2]
    u = np.mod((x / max(period_m, 1e-3)) * tw, tw).astype(np.int32)
    v = np.mod((z / max(period_m, 1e-3)) * th, th).astype(np.int32)
    return tex[v, u].astype(np.float32)


def _world_xz(shape):
    gh, gw = shape
    xs = (np.arange(gw, dtype=np.float32) + 0.5) * (float(W) / float(max(gw, 1)))
    zs = (np.arange(gh, dtype=np.float32) + 0.5) * (float(H) / float(max(gh, 1)))
    return np.meshgrid(xs, zs)


def _hillshade(height):
    dz, dx = np.gradient(height.astype(np.float32))
    nx, ny, nz = -dx, np.full_like(dx, 1.35), -dz
    denom = np.sqrt(nx * nx + ny * ny + nz * nz)
    denom = np.maximum(denom, 1e-6)
    lit = (nx * 0.42 + ny * 0.82 + nz * 0.28) / denom
    return np.clip(0.70 + 0.36 * lit, 0.48, 1.18)


def _smoothstep(edge0, edge1, value):
    t = np.clip((value - edge0) / max(edge1 - edge0, 1e-6), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def compose_g4_style(height, blocking=None, terrain=None, bridges=None):
    """按 G4 材质合成一张 (H,W,3) uint8 俯视。height 缺省则只画平地。"""
    if height is None:
        height = np.full((GRID_H, GRID_W), G2_DEFAULTS["ground_level"], dtype=np.float32)
    height = np.asarray(height, dtype=np.float32)
    gh, gw = height.shape
    if blocking is None:
        blocking = np.zeros((gh, gw), dtype=np.uint8)
    else:
        blocking = np.asarray(blocking)
        if blocking.shape != height.shape:
            blocking = np.array(
                Image.fromarray(blocking.astype(np.uint8)).resize((gw, gh), Image.NEAREST)
            )
    if terrain is None:
        terrain = np.zeros((gh, gw), dtype=np.uint8)
    else:
        terrain = np.asarray(terrain)
        if terrain.shape != height.shape:
            terrain = np.array(
                Image.fromarray(terrain.astype(np.uint8)).resize((gw, gh), Image.NEAREST)
            )

    xx, zz = _world_xz(height.shape)
    ground_y = float(G2_DEFAULTS["ground_level"])
    water_y = float(G2_DEFAULTS["water_level"])
    top_y = float(G2_DEFAULTS["plateau_level"])

    sand = _sample(_load_tex("dense_sand_diff.jpg"), xx, zz, 48.0, FALLBACK["sand"])
    top_tex = _sample(_load_tex("moon_dusted_03_diff.jpg"), xx, zz, 36.0, FALLBACK["top"])
    cliff_tex = _sample(_load_tex("cliff_side_diff.jpg"), xx, zz, 22.0, FALLBACK["cliff"])
    rock_tex = _sample(_load_tex("dark_rock_02_diff.jpg"), xx, zz, 28.0, FALLBACK["rock"])
    ramp_tex = _sample(_load_tex("dirt_aerial_02_diff.jpg"), xx, zz, 30.0, FALLBACK["ramp"])
    shore_tex = _sample(_load_tex("damp_beach_sand_02_diff.jpg"), xx, zz, 26.0, FALLBACK["shore"])
    grain = _sample(_load_tex("sand_01_diff.jpg"), xx + 7.0, zz - 4.0, 18.0, FALLBACK["sand"])

    sand = sand * np.array((1.10, 1.00, 0.82), dtype=np.float32)
    sand = 0.70 * sand + 0.30 * grain
    # 台顶：更干、更亮，避免和沙地糊成一块
    top = top_tex * np.array((1.08, 1.04, 0.96), dtype=np.float32)
    top = np.clip(0.55 * top + 0.45 * np.array((198, 178, 148), dtype=np.float32), 0, 255)
    cliff = 0.50 * cliff_tex + 0.50 * np.array((108, 90, 72), dtype=np.float32)
    rock = 0.35 * rock_tex + 0.65 * np.array((58, 50, 44), dtype=np.float32)
    ramp = 0.45 * sand + 0.55 * ramp_tex * np.array((1.04, 0.96, 0.82), dtype=np.float32)
    shore = 0.60 * shore_tex + 0.40 * sand * np.array((0.78, 0.86, 0.88), dtype=np.float32)

    water_mask = height < 0.12
    solid = blocking > 0
    rock_mask = solid & (terrain == 1) & ~water_mask
    dz, dx = np.gradient(height)
    slope = np.hypot(dx, dz)
    flat = slope < 0.28
    steep = slope > 0.55
    mesa = (height >= top_y - 1.8) & (height <= top_y + 2.8) & ~water_mask
    top_mask = mesa & flat & ~solid
    mid = (height > ground_y + 0.7) & (height < top_y - 1.4)
    ramp_mask = mid & ~solid & ~water_mask & ~steep
    mountain = (
        ((height > top_y + 3.0) | (steep & (height > ground_y + 3.5)) | rock_mask)
        & ~water_mask
        & ~top_mask
    )
    mesa_core = ndimage.binary_opening(mesa, iterations=1)
    cliff_ring = (
        ndimage.binary_dilation(mesa_core, iterations=2)
        & ~ndimage.binary_erosion(mesa_core, iterations=1)
        & ~water_mask
    )
    cliff_mask = (cliff_ring | (solid & (terrain != 5) & (height > ground_y + 1.2))) & ~top_mask & ~water_mask

    col = sand.copy()
    col = np.where(ramp_mask[..., None], ramp, col)
    col = np.where(top_mask[..., None], top, col)
    col = np.where(cliff_mask[..., None], cliff, col)
    col = np.where(mountain[..., None], rock, col)

    wet = ndimage.binary_dilation(water_mask, iterations=2) & ~water_mask
    col = np.where(wet[..., None], shore, col)

    depth = _smoothstep(water_y + 0.4, 0.2, height)
    water_col = WATER_SHALLOW * (1.0 - depth)[..., None] + WATER_DEEP * depth[..., None]
    ripple = _sample(_load_tex("dense_sand_normal.jpg"), xx, zz, 14.0, np.array((128, 128, 128), dtype=np.float32))
    water_col = water_col * (0.88 + 0.14 * (ripple[..., 0:1] / 255.0))
    col = np.where(water_mask[..., None], water_col, col)

    shade = _hillshade(height)
    shade = np.where(top_mask, np.clip(0.94 + 0.08 * (shade - 0.7), 0.88, 1.12), shade)
    shade = shade[..., None]
    col = col * np.where(water_mask[..., None], 0.78 + 0.22 * shade / 1.18, shade)

    if not bridges:
        def _opp(mask, axis, reach):
            pos = np.zeros_like(mask)
            neg = np.zeros_like(mask)
            for step in range(1, reach + 1):
                pos |= np.roll(mask, step, axis)
                neg |= np.roll(mask, -step, axis)
            return pos & neg

        span = _opp(water_mask, 0, 6) | _opp(water_mask, 1, 6)
        auto = span & ~water_mask & (height > -0.05) & (height < ground_y + 1.6)
        lab, ncomp = ndimage.label(auto)
        keep = np.zeros_like(auto)
        counts = np.bincount(lab.ravel())
        for idx in range(1, ncomp + 1):
            if 8 <= counts[idx] <= 2200:
                keep |= lab == idx
        keep = ndimage.binary_dilation(keep, iterations=1) & ~water_mask
        wood = np.broadcast_to(BRIDGE_DECK * 0.82, col.shape)
        col = np.where(keep[..., None], wood, col)
    from ..pathing import polyline_field
    for br in bridges or []:
        a, b = br["a"], br["b"]
        dist, _ = polyline_field([a, b])
        if dist.shape != height.shape:
            dist = np.array(Image.fromarray(dist.astype(np.float32), mode="F").resize((gw, gh), Image.BILINEAR))
        half = float(br.get("width", 8.0)) / 2.0
        band = dist <= half
        ux, uz = b[0] - a[0], b[1] - a[1]
        length = max(float(np.hypot(ux, uz)), 1e-9)
        ux, uz = ux / length, uz / length
        proj = (xx - a[0]) * ux + (zz - a[1]) * uz
        deck = np.broadcast_to(BRIDGE_DECK, col.shape)
        plank = np.broadcast_to(BRIDGE_PLANK, col.shape)
        rail = np.broadcast_to(BRIDGE_RAIL, col.shape)
        striped = np.where(((proj % 2.4) < 0.7)[..., None], plank, deck)
        col = np.where(band[..., None], striped, col)
        rail_band = band & (dist > half - 0.7)
        col = np.where(rail_band[..., None], rail, col)

    return np.clip(col, 0, 255).astype(np.uint8)


def compose_g4_style_from_bin(bin_path, blocking=None, terrain=None, bridges=None):
    raw = Path(bin_path).read_bytes()
    vw, vh = np.frombuffer(raw[:8], dtype=np.int32)
    hf = np.frombuffer(raw[8:], dtype=np.float32).reshape(int(vh), int(vw))
    return compose_g4_style(hf, blocking, terrain, bridges)
