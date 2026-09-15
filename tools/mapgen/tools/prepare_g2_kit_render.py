"""Export the accepted G2 geometry for the Godot kit composition renderer.

Reads the frozen G2/JDG rasters and writes, into ``review/G4/g2_large_lake_kits``:
  ``fields.bin``      4 planes, 1025x1025 float32 (row = z)
                        0 height_m
                        1 rock_depth_cells    distance inside a mountain/rock mass
                        2 water_depth_m       |height| under the surface (unused visually)
                        3 rock_outer_cells    distance outside a rock mass (0 on/inside rock)
  ``masks.bin``       produced by prepare_g2_kit_masks.py (shore/lake/plateau distances)
  ``input.json``      scene manifest for render_g2_kits.gd
  ``decorations.json`` G4 VisualPlan decoration instances (natural profile) mapped into
                       render-world metres, so the kit renderer can show the same
                       decoration layer the exported scene uses.
No authoritative channel is written back.
"""
import json
import sys
from pathlib import Path

import numpy as np
from scipy import ndimage as ndi
from shapely import Polygon, contains, distance, points

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from rtsmap.grid import MapGrid, sha256_file  # noqa: E402
from rtsmap.gates.g4_terrain import build_heightfield  # noqa: E402
from rtsmap.gates.g4_export import G4_PARAMS_DEFAULTS  # noqa: E402

SOURCE = ROOT / 'review/G2/water_combos/single_large_lake/runs/16/G2'
RUNS = SOURCE.parents[1]
SEED = 16
OUT = ROOT / 'review/G4/g2_large_lake_kits'
LOGICAL = 2000.0 / 512.0
ORIGIN_CELLS = 0.0


def export_decoration_plan(spec, grid, hf, meta):
    """Run the G4 visual layer for the accepted G2 and map instances into render metres."""
    from rtsmap.gates import g2_decor
    from rtsmap.presentation import build_visual_plan, load_profile
    catalog_list = json.loads((ROOT / 'rtsmap/data/assets_catalog.json').read_text(encoding='utf-8'))
    zones, dmeta = g2_decor.load_hints(SOURCE)
    resources = []
    res_path = RUNS / str(SEED) / 'G3' / 'resources.json'
    if res_path.exists():
        resources = json.loads(res_path.read_text(encoding='utf-8'))['resources']
    profile = load_profile('natural')
    visual_seed = 20260912
    context = dict(
        map_id='kit-render', world_size_m=[2000.0, 2000.0], cell_m=LOGICAL,
        height=grid.get('height'), heightfield=hf,
        water_footprint=grid.get('water_footprint').astype(bool),
        blocking=grid.get('blocking'), blocking_g2=None,
        terrain=grid.get('terrain'), passable=grid.get('passable'),
        lane_core=grid.get('lane_core'),
        plateaus=spec['plateaus'], bridges=spec.get('bridges', []),
        rivers=spec.get('rivers', []), lakes=spec.get('lakes', []),
        starts=spec['starts'], resources=resources,
        expansion_anchors=spec.get('expansion_anchors', []),
        lanes=json.loads((SOURCE / 'lanes.json').read_text(encoding='utf-8')),
        ramp_blend=meta['ramp_blend'], apron=meta['apron'], shore=meta['shore'],
        bridge_mask=meta['bridge'], water_mask=meta['water'],
        catalog={e['res_path']: e for e in catalog_list},
        catalog_list=catalog_list, g4_params=dict(G4_PARAMS_DEFAULTS),
        decoration=zones, decoration_meta=dmeta,
    )
    plan = build_visual_plan(context, profile, visual_seed)
    assert all(plan['checks'].values()), plan['checks']
    out = []
    for ins in plan['instances']:
        out.append(dict(
            res=ins['asset'], atlas=ins['atlas'], name=ins['name'],
            category=ins['category'], scale=ins['scale'], yaw=ins['yaw'],
            x=round(ins['x'] * LOGICAL, 4), z=round(ins['z'] * LOGICAL, 4),
            min_y=float(ins.get('origin_min_y', 0.0) or 0.0),
            tint=ins.get('tint'),
        ))
    payload = dict(visual_seed=visual_seed, profile='natural',
                   style_version=plan['style_version'], checks=plan['checks'],
                   stats=plan['stats'], warnings=plan['warnings'],
                   logical_cell_m=LOGICAL, instances=out)
    (OUT / 'decorations.json').write_text(
        json.dumps(payload, ensure_ascii=False), encoding='utf-8')
    print('decorations ->', OUT / 'decorations.json', plan['stats'])
    return plan


def focus_points(spec, grid, meta, plan):
    """给渲染器挑三个机位焦点：最大山体中心 / 河道直段岸边 / 最密装饰簇。"""
    water = grid.get('water_footprint').astype(bool)
    rock = (grid.get('blocking') > 0) & ~water & ~meta['plateau_region']
    labels, count = ndi.label(rock, np.ones((3, 3)))
    biggest_cells = 0
    mountain = [256.0, 256.0]
    if count > 0:
        sizes = np.bincount(labels.ravel())
        sizes[0] = 0
        big = int(np.argmax(sizes))
        biggest_cells = int(sizes[big])
        # Pick the *best centred* large mass rather than simply the largest: in a
        # border-hugging range the largest component sits against the map edge and
        # any close-up of it necessarily frames the edge of the terrain slab.
        hh, ww = rock.shape
        best = (big, -1.0, biggest_cells)
        for idx in np.argsort(sizes)[::-1][:8]:
            if idx == 0 or sizes[idx] < 0.25 * biggest_cells:
                continue
            ii, jj = np.nonzero(labels == idx)
            cx, cy = float(jj.mean()) + 0.5, float(ii.mean()) + 0.5
            edge = min(cx, cy, ww - cx, hh - cy)
            if edge > best[1]:
                best = (int(idx), edge, int(sizes[idx]))
        ii, jj = np.nonzero(labels == best[0])
        mountain = [float(jj.mean()) + 0.5, float(ii.mean()) + 0.5]
        biggest_cells = best[2]
        comp_idx = best[0]
    # 河道直段岸边：主河中心线中点 + 法向×（半宽 + 8m），落在陆侧
    bank = [256.0, 128.0]
    rivers = spec.get('rivers') or []
    if rivers:
        poly = np.asarray(rivers[0]['polyline'], dtype=float)
        q = len(poly) // 2
        t = poly[min(q + 1, len(poly) - 1)] - poly[max(q - 1, 0)]
        t = t / max(float(np.hypot(*t)), 1e-9)
        n = np.array([-t[1], t[0]])
        half = float(rivers[0].get('width', 20.0)) / 2.0 + 8.0
        for sign in (1.0, -1.0):
            p = poly[q] + n * half * sign
            i = int(min(max(p[1], 1), grid.get('blocking').shape[0] - 2))
            j = int(min(max(p[0], 1), grid.get('blocking').shape[1] - 2))
            if not water[i, j] and grid.get('blocking')[i, j] == 0:
                bank = [float(p[0]), float(p[1])]
                break
    # 最密装饰簇：取 tree_zone 中 40m 内邻居最多的那一个
    scale = [mountain[0], mountain[1]]
    trees = [i for i in plan['instances'] if i['category'] == 'tree_zone'] \
        or [i for i in plan['instances'] if i['category'] == 'grass_zone']
    if trees:
        pts = np.array([[i['x'], i['z']] for i in trees], dtype=float)
        tbest, tbest_n = 0, -1
        for k in range(len(pts)):
            n = int((np.hypot(pts[:, 0] - pts[k, 0], pts[:, 1] - pts[k, 1]) <= 40.0).sum())
            if n > tbest_n:
                tbest, tbest_n = k, n
        scale = [float(pts[tbest, 0]), float(pts[tbest, 1])]
    # 山脚：所选岩体朝地图内陆那一侧的边界格 + 外向法线，供「山脚沉积扇」机位使用。
    # 用质心（=一座峰顶）当机位焦点会落在平原上，看不到任何扇裙。
    comp = labels == comp_idx if count > 0 else np.zeros_like(rock)
    boundary = comp & ~ndi.binary_erosion(comp, iterations=2)
    bi, bj = np.nonzero(boundary)
    hh, ww = rock.shape
    if bi.size:
        to_centre = np.array([ww / 2.0 - mountain[0], hh / 2.0 - mountain[1]])
        to_centre = to_centre / max(float(np.hypot(*to_centre)), 1e-9)
        proj = (bj + 0.5 - mountain[0]) * to_centre[0] + (bi + 0.5 - mountain[1]) * to_centre[1]
        k = int(np.argmax(proj))
        foot = [float(bj[k]) + 0.5, float(bi[k]) + 0.5]
        nvec = np.array([foot[0] - mountain[0], foot[1] - mountain[1]])
        nvec = nvec / max(float(np.hypot(*nvec)), 1e-9)
        foot_normal = [float(nvec[0]), float(nvec[1])]
    else:
        foot = list(mountain)
        foot_normal = [0.0, 1.0]
    return dict(mountain_focus=[round(v * LOGICAL, 3) for v in mountain],
                riverbank_focus=[round(v * LOGICAL, 3) for v in bank],
                scale_focus=[round(v * LOGICAL, 3) for v in scale],
                mountain_foot_focus=[round(v * LOGICAL, 3) for v in foot],
                mountain_foot_normal=[round(float(v), 5) for v in foot_normal],
                mountain_component_cells=biggest_cells)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    spec = json.loads((SOURCE / 'mapspec.json').read_text(encoding='utf-8'))
    grid = MapGrid.load(SOURCE / 'mapgrid.npz')
    assert spec['all_pass']
    hf, meta = build_heightfield(grid, dict(G4_PARAMS_DEFAULTS), spec['plateaus'], spec['bridges'])
    # Bridge kit decks provide the crossing; the terrain beneath remains riverbed.
    water_mask = grid.get('water_footprint').astype(bool)
    submerged = ndi.binary_erosion(water_mask, iterations=1)
    hf[np.pad(submerged, ((0, 1), (0, 1)), mode='edge')] = -2.4
    rock = (grid.get('blocking') > 0) & ~water_mask & ~meta['plateau_region']
    # build_heightfield 内部已叠加权威山体增量（mountain_addon，与游戏内
    # height_data 同源）—— 渲染器不再自行计算 relief。
    rock_depth = ndi.distance_transform_edt(rock)
    rock_outer = ndi.distance_transform_edt(~rock)
    rock_outer[rock] = 0.0
    rock_outer = np.minimum(rock_outer, 12.0)
    # Export vertex-aligned fields; masks remain tied to the accepted G2 raster.
    water_distance = ndi.distance_transform_edt(water_mask)
    pad = ((0, 1), (0, 1))
    fields = np.stack([hf,
                       np.pad(rock_depth, pad, mode='edge'),
                       np.pad(water_distance, pad, mode='edge'),
                       np.pad(rock_outer, pad, mode='edge')]).astype('<f4')
    # Two-metre render sampling resolves the narrower kit side ramps.
    fields = np.stack([ndi.zoom(f, 1025 / 513, order=1) for f in fields]).astype('<f4')
    # Smooth the rendered banks, not the authoritative water/passability masks.
    # Gaussian support is under one logical cell; terrain and collision share it.
    shore_band = np.abs(fields[0] - .05) < 2.45
    bank_height = ndi.gaussian_filter(fields[0], 1.6)
    fields[0][shore_band] = bank_height[shore_band]
    fields[1] = ndi.gaussian_filter(fields[1], 1.0)
    fields[3] = ndi.gaussian_filter(fields[3], 2.0)
    zz, xx = np.mgrid[:1025, :1025] * .5
    samples = points(xx, zz)
    plateau_field = np.zeros(xx.shape, dtype=np.float32)
    for pl in spec['plateaus']:
        polygon = Polygon(pl['outline'])
        inside = contains(polygon, samples)
        dist = distance(polygon.boundary, samples) * (2000 / 512)
        # Narrow cliff bevel; the kit ramp cutter separately controls entrances.
        t = np.clip(np.where(inside, dist, -dist) / 7 + .5, 0, 1)
        plateau_field = np.maximum(plateau_field, t * t * (3 - 2 * t) * 12)
    old_region = ndi.binary_dilation(meta['plateau_region'] | meta['ramp_blend'] | meta['apron'], iterations=5)
    old_region = ndi.zoom(np.pad(old_region, pad, mode='edge').astype(float), 1025 / 513, order=0) > 0
    fields[0][old_region] = .6 + plateau_field[old_region] / (2000 / 512)
    # Keep imported deck triangles above the terrain at both abutments.
    for b in spec['bridges']:
        a, end = np.asarray(b['a']), np.asarray(b['b'])
        axis = (end - a) / np.linalg.norm(end - a)
        along = (xx - a[0]) * axis[0] + (zz - a[1]) * axis[1]
        across = np.abs((xx - a[0]) * axis[1] - (zz - a[1]) * axis[0])
        deck = (along >= 0) & (along <= np.linalg.norm(end - a)) & (across <= b['width'] / 2)
        fields[0][deck] = np.minimum(fields[0][deck], .6 - .8 / (2000 / 512))
    fields.tofile(OUT / 'fields.bin')
    plan = export_decoration_plan(spec, grid, hf, meta)
    focus = focus_points(spec, grid, meta, plan)
    manifest = dict(source=str(SOURCE), source_sha256=sha256_file(SOURCE / 'mapgrid.npz'),
                    world_size_m=[2000, 2000], cell_m=2000 / 1024, logical_cell_m=2000 / 512,
                    vertex_size=1025, field_planes=4,
                    field_plane_names=['height_m', 'rock_depth_cells', 'water_depth_m',
                                       'rock_outer_cells'],
                    plateau_height_m=12, main_ramp_width_m=100 / 3, main_angle_degrees=20,
                    side_angle_degrees=30,
                    plateaus=spec['plateaus'], bridges=spec['bridges'], starts=spec['starts'],
                    g2_checks=spec['checks'], lake_area_logical_m2=sum(l['area_m2'] for l in spec['lakes']),
                    decoration_stats=plan['stats'], decoration_checks=plan['checks'],
                    navigation_validated=False, g3_resources_generated=bool(
                        (RUNS / str(SEED) / 'G3' / 'resources.json').exists()),
                    **focus)
    (OUT / 'input.json').write_text(json.dumps(manifest), encoding='utf-8')
    print('focus:', json.dumps(focus, ensure_ascii=False))
    print('Exported accepted G2 fields:', OUT)


if __name__ == '__main__':
    main()
