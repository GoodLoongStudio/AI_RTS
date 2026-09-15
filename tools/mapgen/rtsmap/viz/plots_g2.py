"""G2 绘图（雕刻式 v2）：overview 合成图（§2.5，唯一给用户看的图）+ --detail 分项图。

铁律：文字/图例只在 64px 边框区；唯一例外是每条通道最窄处的宽度数字（字号 ≤24px）。
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from ..contract import (
    GRID_H, GRID_W, W, MAP_CENTER, PX_PER_M, ROLE_CENTER, ROLE_EXPANSION,
    ROLE_FLANK, ROLE_HOME, ROLE_HINTERLAND,
)
from ..pathing import cell_of, dijkstra, erode8, lane_width_profile
from .canvas import Canvas, P_COLORS, font, contact_sheet, draw_spawn_marker, draw_ring, draw_disc, grid_to_map
from .g4_style import (
    LEGEND_BRIDGE,
    LEGEND_CLIFF,
    LEGEND_RAMP,
    LEGEND_ROCK,
    LEGEND_SAND,
    LEGEND_TOP,
    LEGEND_WATER,
    compose_g4_style,
)

# §2.5：实体按 terrain 四色，开放区米白（无高程时的逻辑层）
OPEN_RGB = LEGEND_SAND
TERRAIN_RGB = {
    1: LEGEND_ROCK,
    2: (150, 88, 44),
    3: (72, 64, 54),
    4: (176, 168, 154),
    5: LEGEND_WATER,
}
WATER_RGB = LEGEND_WATER
PLATEAU_TOP_RGB = LEGEND_TOP
CONTOUR_RGB = (150, 128, 96)
CLIFF_RGB = LEGEND_CLIFF
RAMP_RGB = LEGEND_RAMP
BRIDGE_RGB = LEGEND_BRIDGE
WATER_EDGE_RGB = (8, 32, 42)
PLATEAU_EDGE_RGB = (120, 100, 78)
PLANK_RGB = (176, 158, 128)
RAIL_RGB = (120, 96, 70)
LANE_COLORS = {"main": "#c0392b", "flank": "#2471a3", "route": "#2471a3", "eco": "#1e8449"}
ROLE_RGB = {
    ROLE_HOME: (250, 224, 160), ROLE_CENTER: (188, 210, 240), ROLE_FLANK: (210, 180, 235),
    ROLE_EXPANSION: (180, 230, 200), ROLE_HINTERLAND: (238, 238, 228),
}


def _base_terrain_image(blocking, terrain):
    """实体按 terrain 四色、开放区米白的 (1920,1920,3) 底图。"""
    img = np.zeros((GRID_H, GRID_W, 3), dtype=np.uint8)
    img[:] = OPEN_RGB
    solid = blocking > 0
    for code, rgb in TERRAIN_RGB.items():
        img[solid & (terrain == code)] = rgb
    # 未分类实体（terrain=0 但 blocking，理论上不出现）兜底为深灰
    img[solid & (terrain == 0)] = (120, 120, 126)
    return grid_to_map(img)


def _base_height_image(blocking, terrain, height, bridges):
    """G4 同系材质底图：沙地/深水/台顶/崖壁，再放大到画布地图区。"""
    img = compose_g4_style(height, blocking, terrain, bridges)
    return grid_to_map(img)


def _narrowest(polyline, blocking):
    prof = lane_width_profile(polyline, blocking, 2.0, 30.0)
    return min(prof, key=lambda t: t.width)


def render_overview(data):
    """§2.5 一张 2048² 合成图。data: seed/blocking/terrain/height/bridges/starts/flank_anchors/exp_anchors/lanes/metrics。"""
    blocking = data["blocking"]
    terrain = data["terrain"]
    height = data.get("height")
    bridges = data.get("bridges") or []
    cv = Canvas()
    if height is not None:
        cv.paste_map_image(_base_height_image(blocking, terrain, height, bridges))
    else:
        cv.paste_map_image(_base_terrain_image(blocking, terrain))
    d = cv.d
    # 通道折线细线（main 红、flank 蓝）
    visible_lanes = data["lanes"] if data.get('show_routes', True) else []
    for lane in visible_lanes:
        color = LANE_COLORS[lane["kind"]]
        pts = [cv.w2p(p[0], p[1]) for p in lane["polyline"]]
        d.line(pts, fill=color, width=2 if lane['name'].endswith('_r1') else 3)
    # 每条通道最窄处：短横线（沿法向跨宽）+ 宽度数字（≤24px，唯一允许进地图区的文字）；
    # 水对通道改标桥中心+实测桥宽（route 折线斜穿水边会使最窄探针失真）
    marks = data.get("water_marks") or {}
    for lane in visible_lanes:
        if lane['name'].endswith('_r1'):
            continue
        if lane["kind"] == "eco":   # v6 经济路线不标宽
            continue
        color = LANE_COLORS[lane["kind"]]
        key = lane["name"].rsplit("_r", 1)[0]
        if key in marks:
            mx, mz, mw, ux, uz = marks[key]
            px, py = cv.w2p(mx, mz)
            half = max(mw, 1.0) / 2.0 * PX_PER_M
            ex, ey = ux * half, uz * half
            txt = f"{mw:.1f}"
        else:
            s = _narrowest(lane["polyline"], blocking)
            px, py = cv.w2p(s.x, s.z)
            half = max(s.width, 1.0) / 2.0 * PX_PER_M
            ex, ey = s.nx * half, s.nz * half
            txt = f"{s.width:.1f}"
        d.line([(px - ex, py - ey), (px + ex, py + ey)], fill=color, width=4)
        f = font(22, bold=True)
        tw = d.textlength(txt, font=f)
        d.rectangle([px - tw / 2 - 3, py - 40, px + tw / 2 + 3, py - 14], fill=(255, 255, 255, 220))
        d.text((px - tw / 2, py - 39), txt, fill=color, font=f)
    # flank 锚点小三角、expansion 锚点小方块
    for a in data["flank_anchors"]:
        px, py = cv.w2p(a[0], a[1])
        d.polygon([(px, py - 11), (px - 10, py + 8), (px + 10, py + 8)],
                  outline="#7d3c98", width=3)
    # v6 中立争夺区：菱形标记（分布式争夺区，非唯一中心）
    for n in data.get("contest_nodes") or []:
        if n.get("kind") != "neutral":
            continue
        px, py = cv.w2p(n["x"], n["z"])
        d.polygon([(px, py - 12), (px + 12, py), (px, py + 12), (px - 12, py)],
                  outline="#7d3c98", width=3)
    for a in data["expansion_anchors"]:
        px, py = cv.w2p(a[0], a[1])
        d.rectangle([px - 9, py - 9, px + 9, py + 9], outline="#1e8449", width=3)
    # 4 出生点（点 + 10m 圈 + P0–P3）
    for k, (x, z) in enumerate(data["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k])
    # 坡道方向箭头（缺口→顶面）
    for (rc, rd) in data.get("ramp_arrows") or []:
        tx, tz = rc[0] - rd[0] * 6.0, rc[1] - rd[1] * 6.0   # 尾（地面侧）
        hx, hz = rc[0] + rd[0] * 6.0, rc[1] + rd[1] * 6.0   # 头（顶面侧）
        p0 = cv.w2p(tx, tz)
        p1 = cv.w2p(hx, hz)
        d.line([p0, p1], fill="#8a5a2b", width=4)
        px, py = p1
        nx, nz = -rd[1], rd[0]
        d.polygon([(px, py), (px - rd[0] * 10 + nx * 6, py - rd[1] * 10 + nz * 6),
                   (px - rd[0] * 10 - nx * 6, py - rd[1] * 10 - nz * 6)], fill="#8a5a2b")
    m = data["metrics"]
    legend = [
        (WATER_RGB, "水域"), (PLATEAU_TOP_RGB, "台地"), (CLIFF_RGB, "悬崖"),
        (RAMP_RGB, "坡道"), (BRIDGE_RGB, "桥"), (OPEN_RGB, "沙地"),
        (P_COLORS[0], "P0"), (P_COLORS[1], "P1"), (P_COLORS[2], "P2"), (P_COLORS[3], "P3"),
        ("#7d3c98", "争夺"),
    ]
    if data.get("show_routes"):
        legend.extend([("#c0392b", "主路"), ("#2471a3", "侧路"), ("#1e8449", "经济路")])
    if height is None:
        legend = [(TERRAIN_RGB[1], "岩石"), (TERRAIN_RGB[2], "废墟"), (TERRAIN_RGB[3], "墙"),
                  (TERRAIN_RGB[4], "碎石"), (OPEN_RGB, "平地")] + legend[6:]
    cv.frame(
        title=f"G2 Seed {data['seed']} | {GRID_W}x{GRID_H} | {W:g}m | v{m.get('algo_version', '7.0.0')}",
        legend=legend,
    )
    # 边框区指标（顶部右侧，不与标题/刻度冲突）
    flag = "PASS" if m.get("all_pass") else "FAIL"
    info = (f"solid {m.get('solid_frac', 0) * 100:.1f}%  "
            f"river {len(data.get('bridges', []))} crossings  "
            f"pathR {m.get('flank_ratio') or float('nan'):.2f}  geometry {flag}")
    d.text((700, 24), info, fill=(20, 20, 20), font=font(19, bold=True))
    plateaus = data.get('plateaus') or []
    if plateaus:
        homes = '/'.join(f"P{pl['owner']}" for pl in plateaus if pl['kind'] == 'home')
        n_route = sum(pl['kind'] == 'route' for pl in plateaus)
        n_central = sum(pl['kind'] == 'central' for pl in plateaus)
        d.text((1120, 2003), f"Home heights {homes} | route {n_route} | central {n_central}",
               fill=(50, 45, 35), font=font(19, bold=True))
    return cv.img


# ---------------- --detail 分项图（仅自排错用） ----------------

def _tile(rgb_map, values, default=(245, 242, 232)):
    img = np.zeros((GRID_H, GRID_W, 3), dtype=np.uint8)
    img[:] = default
    for v, rgb in rgb_map.items():
        img[values == v] = rgb
    return grid_to_map(img)


def plot_detail(res):
    rd = res["run_dir"]
    grid = res["grid"]
    _detail_regions(res, rd / "regions.png")
    _detail_lanes(res, rd / "lanes.png")
    _detail_passability(res, rd / "passability.png")
    _detail_paths(res, rd / "paths.png")
    _detail_terrain(res, rd / "terrain.png")


def _detail_regions(res, path):
    grid = res["grid"]
    cv = Canvas()
    cv.paste_map_image(_tile(ROLE_RGB, grid.get("role"), default=(210, 208, 200)))
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k])
    cv.frame(title=f"G2 Seed {res['seed']} — role (open cells only)",
             legend=[(ROLE_RGB[1], "home"), (ROLE_RGB[2], "center"), (ROLE_RGB[3], "flank"),
                     (ROLE_RGB[4], "expansion"), (ROLE_RGB[5], "hinterland"),
                     ((210, 208, 200), "solid(role=0)")])
    cv.save(path)


def _detail_lanes(res, path):
    grid = res["grid"]
    cv = Canvas()
    lane_core = grid.get("lane_core")
    base = np.full((GRID_H, GRID_W, 3), 250, dtype=np.uint8)
    base[lane_core > 0] = (214, 214, 236)
    cv.paste_map_image(grid_to_map(base))
    for name, lane in res["lanes"].items():
        color = LANE_COLORS[lane["kind"]]
        pts = [cv.w2p(p[0], p[1]) for p in lane["polyline"]]
        cv.d.line(pts, fill=color, width=3)
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k])
    cv.frame(title=f"G2 Seed {res['seed']} — lanes (variable width core band)",
             legend=[("#c0392b", "main i"), ("#2471a3", "flank k"), ("#d6d6ec", "lane_core")])
    cv.save(path)


def _detail_passability(res, path):
    grid = res["grid"]
    blocking, passable = grid.get("blocking"), grid.get("passable")
    img = np.zeros((GRID_H, GRID_W, 3), dtype=np.uint8)
    img[passable > 0] = (232, 232, 226)
    from ..pathing import dilate8
    img[(dilate8(blocking > 0) & ~(blocking > 0))] = (150, 150, 148)
    img[blocking > 0] = (25, 25, 28)
    cv = Canvas()
    cv.paste_map_image(grid_to_map(img))
    for (i, j) in res["key_ij"]:
        px, py = cv.w2p(j + 0.5, i + 0.5)
        cv.d.ellipse([px - 9, py - 9, px + 9, py + 9], outline="#e67e22", width=3)
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=6)
    cv.frame(title=f"G2 Seed {res['seed']} — passability (keypoints circled)",
             legend=[("#191919", "blocking"), ("#969694", "inflation"), ("#e8e8e2", "passable"),
                     ("#e67e22", "keypoints")])
    cv.save(path)


def _detail_paths(res, path):
    grid = res["grid"]
    passable = grid.get("passable")
    blocking = grid.get("blocking")
    bimg = np.full((GRID_H, GRID_W, 3), 242, dtype=np.uint8)
    bimg[blocking > 0] = (70, 70, 74)
    cv = Canvas()
    cv.paste_map_image(grid_to_map(bimg))
    center_ij = cell_of(*MAP_CENTER)
    polar = res["mapspec"]["polar_order"]
    for i in range(4):
        sij = cell_of(*res["starts"][i])
        _, pth = dijkstra(passable, sij, center_ij)
        if pth:
            cv.d.line([cv.w2p(j + 0.5, ii + 0.5) for ii, j in pth], fill=P_COLORS[i], width=4)
        idx = polar.index(i)
        for nb in (polar[(idx - 1) % 4], polar[(idx + 1) % 4]):
            _, pth2 = dijkstra(passable, sij, cell_of(*res["starts"][nb]))
            if pth2:
                cv.d.line([cv.w2p(j + 0.5, ii + 0.5) for ii, j in pth2], fill=P_COLORS[i], width=2)
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=6)
    cv.frame(title=f"G2 Seed {res['seed']} — shortest paths", legend=[(P_COLORS[k], f"P{k}") for k in range(4)])
    cv.save(path)


def _detail_terrain(res, path):
    grid = res["grid"]
    cv = Canvas()
    height = grid.get("height") if grid.has("height") else None
    cv.paste_map_image(_base_height_image(grid.get("blocking"), grid.get("terrain"),
                                          height, res["mapspec"].get("bridges")))
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=6)
    cv.frame(title=f"G2 Seed {res['seed']} — G4 material preview",
             legend=[(WATER_RGB, "water"), (PLATEAU_TOP_RGB, "plateau-top"), (CLIFF_RGB, "cliff"),
                     (RAMP_RGB, "ramp"), (BRIDGE_RGB, "bridge"),
                     (TERRAIN_RGB[1], "rock"), (OPEN_RGB, "sand")])
    cv.save(path)


def _water_marks(ms):
    """水对通道宽度标注：桥中心 + 实测桥宽 + 桥轴方向（供短横线沿桥轴跨宽）。"""
    out = {}
    brs = ms.get("bridges", [])
    bws = ms.get("bridge_widths", {})
    for i, br in enumerate(brs):
        src = br.get("source", "")
        if not src.startswith("pair_") or src in out:
            continue
        a, b = br["a"], br["b"]
        ux, uz = b[0] - a[0], b[1] - a[1]
        L = max(float(np.hypot(ux, uz)), 1e-9)
        out[src] = ((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0,
                    float(bws.get(f"bridge_{i}", br["width"])), ux / L, uz / L)
    return out


def overview_from_res(res):
    """把 run_one 的结果转成 render_overview 需要的 data。"""
    ms = res["mapspec"]
    return {
        "seed": res["seed"],
        "blocking": res["grid"].get("blocking"),
        "terrain": res["grid"].get("terrain"),
        "height": res["grid"].get("height") if res["grid"].has("height") else None,
        "bridges": ms.get("bridges", []),
        "water_marks": _water_marks(ms),
        "contest_nodes": ms.get("contest_nodes", []),
        "plateaus": ms.get("plateaus", []),
        "ramp_arrows": [(rc, rd) for pl in ms.get("plateaus", [])
                        for rc, rd in zip(pl["ramp_centers"], pl["ramp_dirs"])],
        "starts": res["starts"],
        "flank_anchors": ms["flank_anchors"],
        "expansion_anchors": ms["expansion_anchors"],
        "lanes": [{"name": n, "kind": l["kind"], "polyline": l["polyline"]}
                  for n, l in res["lanes"].items()],
        "metrics": {
            "algo_version": ms["algo_version"], "solid_frac": ms["solid_frac"],
            "n_components": ms["n_components"], "max_block_frac": ms["max_block_frac"],
            "neighbor_wall_min": ms["neighbor_wall"]["min"],
            "flank_ratio": ms["path_fairness"]["flank_ratio"], "all_pass": ms["all_pass"],
        },
    }


def render_mini(data, size=640):
    """contact 用缩略图（每格 ≥640px）：直接缩放 overview。"""
    im = render_overview(data)
    return im.resize((size, size), Image.LANCZOS)


def render_minimap_preview(blocking, terrain, height, bridges, edge=512):
    """G4 材质俯视：无边框无路线。给游戏小地图、大厅预览和 G2 工作台。"""
    arr = compose_g4_style(height, blocking, terrain, bridges)
    im = Image.fromarray(np.ascontiguousarray(arr).astype(np.uint8))
    if im.size != (edge, edge):
        im = im.resize((edge, edge), Image.LANCZOS)
    return im


def write_minimap_preview(path, grid, bridges, edge=512, height=None):
    """把 G2/G3 格网（或 G4 高度场）写成正方形 PNG。不进 G2 哈希。"""
    if height is None:
        height = grid.get("height") if grid is not None and grid.has("height") else None
    blocking = grid.get("blocking") if grid is not None else None
    terrain = grid.get("terrain") if grid is not None else None
    im = render_minimap_preview(blocking, terrain, height, bridges or [], edge=edge)
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path)
    return path
