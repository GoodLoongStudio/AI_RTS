"""G3 绘图：resources / resources_table / objects / overview（review）/ contact。

G3 2.0.0：适配 G2 v4.0.0（256m、water 河道）；资源含无中央战场适配的 flank B。
铁律：文字/图例只在 64px 边框区。
"""
import numpy as np
from PIL import Image, ImageDraw

from ..contract import GRID_H, GRID_W, OFFSET, OVERLAY_A, OVERLAY_B, PX_PER_M, W
from .canvas import Canvas, P_COLORS, font, contact_sheet, draw_spawn_marker, grid_to_map
from .plots_g2 import _base_terrain_image


def _wipe_border(cv):
    """把地图区（64..64+1920）之外的边框区刷白，清除旋转实例描边溢出。"""
    from .canvas import OFFSET, MAP_PX
    d = cv.d
    o, m = OFFSET, MAP_PX
    d.rectangle([0, 0, 2047, o - 1], fill=(255, 255, 255))
    d.rectangle([0, o + m, 2047, 2047], fill=(255, 255, 255))
    d.rectangle([0, 0, o - 1, 2047], fill=(255, 255, 255))
    d.rectangle([o + m, 0, 2047, 2047], fill=(255, 255, 255))

RES_A = (240, 200, 60)     # 金色
RES_B = (60, 200, 210)     # 青色
OWNER_EDGE = P_COLORS


def plot_resources(res, path):
    cv = Canvas()
    cv.paste_map_image(_base_terrain_image(res["grid"].get("blocking"),
                                           res["grid"].get("terrain")))
    cv.d = ImageDraw.Draw(cv.img, "RGBA")
    # 资源
    for r in res["resources"]:
        px, py = cv.w2p(r["x"], r["z"])
        color = RES_A if r["type"] == "A" else RES_B
        cv.d.ellipse([px - 8, py - 8, px + 8, py + 8], fill=color, outline=(40, 40, 40), width=2)
        # 归属描边 4 色（外环）
        owner = r["owner"]
        if owner.startswith("P"):
            k = int(owner[1])
        elif owner.startswith("flank_"):
            pair = res["lanes"][f"pair_{owner.split('_')[1]}_r0"]["pair"]
            k = pair[0]
        else:
            k = None
        if k is not None:
            cv.d.ellipse([px - 13, py - 13, px + 13, py + 13], outline=P_COLORS[k], width=2)
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=8)
    cv.frame(title=f"G3 Seed {res['seed']} — resources ({len(res['resources'])})",
             legend=[(RES_A, "ResourceA"), (RES_B, "ResourceB"),
                     (P_COLORS[0], "owner ring P0..P3")])
    cv.save(path)


def plot_resources_table(res, path):
    im = Image.new("RGB", (1500, 980), (255, 255, 255))
    d = ImageDraw.Draw(im)
    d.text((30, 20), f"G3 Seed {res['seed']} — resource fairness (path distance, m)",
           fill=(0, 0, 0), font=font(24, bold=True))
    f = font(20)
    fb = font(20, bold=True)
    y = 90
    for hx, hd in zip((60, 280, 500, 720, 920, 1120),
                      ("player", "near 2A sum", "exp A", "shared A sum",
                       "exp B", "shared B sum")):
        d.text((hx, y), hd, fill=(80, 80, 80), font=fb)
    y += 42
    fa = res["mapspec"]["resource_fairness"]
    for i in range(4):
        d.text((60, y), f"P{i}", fill=(0, 0, 0), font=f)
        d.text((280, y), f"{fa['near_sums'][i]:.1f}", fill=(0, 0, 0), font=f)
        d.text((500, y), f"{fa['expansion_a'][i]:.1f}", fill=(0, 0, 0), font=f)
        d.text((720, y), f"{fa['shared_sums'][i]:.1f}", fill=(0, 0, 0), font=f)
        d.text((920, y), f"{fa['expansion_b'][i]:.1f}", fill=(0, 0, 0), font=f)
        d.text((1120, y), f"{fa['shared_b_sums'][i]:.1f}", fill=(0, 0, 0), font=f)
        y += 36
    y += 20
    d.text((60, y), f"ratios: near {fa['near_ratio']:.3f} | expansion {fa['expansion_ratio']:.3f} | "
                    f"shared {fa['shared_ratio']:.3f} | shared_b {fa['shared_b_ratio']:.3f}  "
                    f"(A 三项 ≤1.3，B 报告项)  pass={fa['pass']}",
           fill=(0, 0, 0), font=f)
    y += 40
    d.text((60, y), f"quota per player: A={fa['a_counts'][0]}  B={fa['b_counts'][0]}  "
                    f"quota_equal={fa['quota_equal']}（无中央战场：中心资源取消，B 在 flank 补齐）",
           fill=(0, 0, 0), font=f)
    y += 40
    d.text((60, y), "resources (kind/type/x/z/owner/dists P0..P3)", fill=(80, 80, 80), font=fb)
    y += 40
    for r in res["resources"]:
        ds = ",".join("-" if v is None else f"{v:.0f}" for v in r["path_dists"])
        d.text((60, y), f"{r['kind']:<10} {r['type']}  ({r['x']:.0f},{r['z']:.0f})  "
                        f"{r['owner']:<9} [{ds}]", fill=(0, 0, 0), font=f)
        y += 30
        if y > 940:
            break
    im.save(path)


def plot_objects(res, path):
    cv = Canvas()
    cv.paste_map_image(_base_terrain_image(res["grid"].get("blocking"),
                                           res["grid"].get("terrain")))
    cv.d = ImageDraw.Draw(cv.img, "RGBA")
    import math as _m
    for ins in res["instances"]:
        px, py = cv.w2p(ins["x"], ins["z"])
        if ins["blocking"]:
            w, h = ins["extent"]
            th = _m.radians(ins["yaw"])
            c, sn = _m.cos(th), _m.sin(th)
            hw, hh = w / 2.0 * PX_PER_M, h / 2.0 * PX_PER_M
            pts = []
            for lx, lz in ((-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)):
                wx = lx * c + lz * sn
                wz = -lx * sn + lz * c
                pts.append((px + wx, py + wz))
            cv.d.polygon(pts, outline=(180, 30, 30))
        else:
            cv.d.rectangle([px - 3, py - 3, px + 3, py + 3], fill=(110, 110, 110))
    for k, (x, z) in enumerate(res["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=8)
    _wipe_border(cv)
    cv.d = ImageDraw.Draw(cv.img, "RGBA")
    n_blk = sum(1 for i in res["instances"] if i["blocking"])
    cv.frame(title=f"G3 Seed {res['seed']} — objects ({len(res['instances'])}, "
                    f"{n_blk} blocking)",
             legend=[((180, 30, 30), "occluder outline"), ((110, 110, 110), "decoration")])
    cv.save(path)


def render_g3_overview(data):
    """review/G3/seed_<N>_overview.png：资源 + 实例 + 复检结论合成为一张 2048² 图。

    data: seed/grid/blocking/terrain/instances/resources/starts/flank_anchors/
          expansion_anchors/metrics(mapspec)
    """
    grid = data["grid"]
    cv = Canvas()
    cv.paste_map_image(_base_terrain_image(grid.get("blocking"), grid.get("terrain")))
    d = ImageDraw.Draw(cv.img, "RGBA")
    # 装饰灰点（先画，避免盖住资源/遮挡描边）
    for ins in data["instances"]:
        if ins["blocking"]:
            continue
        px, py = cv.w2p(ins["x"], ins["z"])
        d.rectangle([px - 2, py - 2, px + 2, py + 2], fill=(120, 120, 120))
    # 遮挡实例：有向矩形描边（红）
    import math as _m
    for ins in data["instances"]:
        if not ins["blocking"]:
            continue
        px, py = cv.w2p(ins["x"], ins["z"])
        w, h = ins["extent"]
        th = _m.radians(ins["yaw"])
        c, sn = _m.cos(th), _m.sin(th)
        hw, hh = w / 2.0 * PX_PER_M, h / 2.0 * PX_PER_M
        pts = []
        for lx, lz in ((-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)):
            wx = lx * c + lz * sn
            wz = -lx * sn + lz * c
            pts.append((px + wx, py + wz))
        d.polygon(pts, outline=(190, 40, 40))
    # 资源（A 金 / B 青，外环=归属）
    for r in data["resources"]:
        px, py = cv.w2p(r["x"], r["z"])
        color = RES_A if r["type"] == "A" else RES_B
        d.ellipse([px - 8, py - 8, px + 8, py + 8], fill=color, outline=(40, 40, 40), width=2)
        owner = r["owner"]
        if owner.startswith("P"):
            k = int(owner[1])
        elif owner.startswith("flank_"):
            k = None
        else:
            k = None
        if k is not None:
            d.ellipse([px - 13, py - 13, px + 13, py + 13], outline=P_COLORS[k], width=2)
    # 锚点标记
    for a in data.get("flank_anchors", []):
        px, py = cv.w2p(a[0], a[1])
        d.polygon([(px, py - 11), (px - 10, py + 8), (px + 10, py + 8)],
                  outline="#7d3c98", width=3)
    for a in data.get("expansion_anchors", []):
        px, py = cv.w2p(a[0], a[1])
        d.rectangle([px - 9, py - 9, px + 9, py + 9], outline="#1e8449", width=3)
    cv.d = d
    for k, (x, z) in enumerate(data["starts"]):
        draw_spawn_marker(cv, x, z, k, P_COLORS[k], base_radius_m=8)
    _wipe_border(cv)
    d = ImageDraw.Draw(cv.img, "RGBA")
    cv.d = d
    ms = data["mapspec"]
    fa = ms["resource_fairness"]
    rep = ms["recheck"]
    n_blk = sum(1 for i in data["instances"] if i["blocking"])
    legend = [(RES_A, "ResourceA"), (RES_B, "ResourceB"),
              ((190, 40, 40), "occluder outline"), ((120, 120, 120), "decoration"),
              ((96, 150, 190), "water")]
    cv.frame(title=f"G3 Seed {data['seed']} — objects {len(data['instances'])} "
                   f"({n_blk} blk) | quota A{fa['a_counts'][0]}/B{fa['b_counts'][0]} | "
                   f"{'PASS' if ms['all_pass'] else 'FAIL'}",
             legend=legend)
    return cv.img


def plot_all(res):
    rd = res["run_dir"]
    plot_resources(res, rd / "resources.png")
    plot_resources_table(res, rd / "resources_table.png")
    plot_objects(res, rd / "objects.png")


def render_mini(res, size=494):
    grid = res["grid"]
    blocking = grid.get("blocking")
    terrain = grid.get("terrain")
    img = _base_terrain_image(blocking, terrain)
    im = Image.fromarray(img).resize((size, size))
    # 资源点画在缩略图上（金/青）
    d = ImageDraw.Draw(im)
    for r in res["resources"]:
        cx = (r["x"] / W) * size
        cy = (r["z"] / W) * size
        color = RES_A if r["type"] == "A" else RES_B
        d.ellipse([cx - 3, cy - 3, cx + 3, cy + 3], fill=color, outline=(40, 40, 40))
    return im


def plot_contact(sd, results):
    items = [(render_mini(r), f"Seed {r['seed']} | obj {r['mapspec']['instance_count']} | "
                              f"pass={r['mapspec']['all_pass']}") for r in results]
    if items:
        contact_sheet(items, cols=min(3, len(items))).save(sd / "contact.png")
