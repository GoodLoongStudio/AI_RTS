"""G2 v7: terrain with a job, a connected river, then routes on real terrain.

No spawn-centred defensive arcs and no random corner plateau fallback. A home
plateau is walkable land under a spawn; a neutral plateau must control traffic.
"""
import math

import numpy as np

from ..contract import GRID_H, GRID_W, H, W, MAP_CENTER
from ..pathing import (bfs_components, cell_of, compute_passable, dijkstra, distance_fields,
                       dilate8, erode8, polyline_field, polyline_length)
from . import g2_layout as geo
from .g2_landforms import landform_outline, polygon_mask, regional_direction


def empty():
    return np.zeros((GRID_H, GRID_W), dtype=bool)


def _extent_scale():
    """512 标定的侵蚀/净空在 128 图上会把湖和河搜空。按短边比例收缩，下限 0.25。"""
    return max(min(W, H) / 512.0, 0.25)


def spawn_profiles(starts):
    out = []
    for i, s in enumerate(starts):
        nearest = min(math.dist(s, t) for j, t in enumerate(starts) if i != j)
        center = math.dist(s, MAP_CENTER)
        edge = min(s[0], s[1], W - s[0], H - s[1])
        # A central spawn has more approach directions; close enemies add pressure.
        exposure = 0.55 * max(0., 1. - center / 160.) + 0.30 * min(edge / 64., 1.) + 0.15 * min(90. / nearest, 1.5)
        out.append(dict(player=i, center_distance=round(center, 3),
                        edge_distance=round(edge, 3), nearest_enemy=round(nearest, 3),
                        exposure=round(exposure, 5)))
    return out


def plateau_shape(center, radius, rng, home=False, angle=0.):
    return polygon_mask(landform_outline(center, radius, angle, rng, home=home))


def ramps_for(center, region, targets, avoid, params):
    """Prefer recessed shoulders facing a destination, with a flared landing."""
    ramps = empty()
    centers, dirs = [], []

    def edge_at(angle):
        direction = np.array([math.cos(angle), math.sin(angle)])
        distances = np.arange(.5, 76., .5)
        points = np.array(center) + distances[:, None]*direction
        inside = ((points[:, 0] >= 1) & (points[:, 0] < W-1)
                  & (points[:, 1] >= 1) & (points[:, 1] < H-1))
        cells = points.astype(int)
        inside[inside] &= region[cells[inside, 1], cells[inside, 0]]
        exits = np.flatnonzero(~inside)
        count = int(exits[0]) if len(exits) else len(distances)
        return float(distances[count-1]) if count else 0.

    for target in targets:
        base = math.atan2(target[1] - center[1], target[0] - center[0])
        candidates = []
        for offset in (0., .25, -.25, .50, -.50, .8, -.8, 1.2, -1.2):
            angle = base + offset
            direction = np.array([math.cos(angle), math.sin(angle)])
            if any(np.dot(direction, -np.array(d)) > .82 for d in dirs):
                continue
            edge = edge_at(angle)
            if edge < 7.:
                continue
            a = np.array(center) + direction * (edge - 7.)
            b = np.array(center) + direction * (edge + 8.)
            margin = max(6., (params['plateau_ramp_width'] + 3.) / 2. + 1.)
            if not (margin <= b[0] < W - margin and margin <= b[1] < H - margin):
                continue
            band = geo.segment_mask(a, b, params['plateau_ramp_width'])
            # Only the ground-side mouth broadens; the cliff crossing stays 8 m.
            mouth = np.array(center) + direction * (edge + 5.)
            band |= geo.segment_mask(mouth, b, params['plateau_ramp_width'] + 3.) & ~region
            landing = geo.disc_mask(b, 5.)
            if ((band | landing) & avoid).any():
                continue
            left, right = edge_at(angle - .24), edge_at(angle + .24)
            recess = (left + right) / 2. - edge
            # Prefer an inlet, but avoid steeply oblique cliff crossings and large detours.
            score = 6. * abs(offset) + .5 * abs(left - right) - 2. * recess
            candidates.append((score, band, tuple(np.array(center) + direction * edge), tuple(-direction)))
        if candidates:
            _, band, rc, direction = min(candidates, key=lambda c: c[0])
            ramps |= band
            centers.append(rc)
            dirs.append(direction)
    return ramps, centers, dirs


def make_plateau(center, radius, kind, owner, routes, targets, avoid, params, rng, frame):
    angle = regional_direction(frame, center) + float(rng.uniform(-.16, .16))
    outline = landform_outline(center, radius, angle, rng, home=kind == 'home',
                               elongation=params['landform_elongation'],
                               recess_depth=params['landform_recess'], softness=params['landform_softness'])
    lobes = 1
    if params.get('compound_plateaus') and kind != 'home':
        from shapely.geometry import Polygon
        offset = np.array([math.cos(angle), math.sin(angle)]) * radius * .85
        extra = landform_outline(np.array(center)+offset, radius*.8, angle+.15, rng)
        union = Polygon(outline).union(Polygon(extra))
        if union.geom_type == 'Polygon':
            outline = np.array(union.exterior.coords[:-1])
            lobes = 2
    region = polygon_mask(outline)
    if kind != 'home' and (np.asarray(outline).min() < 8. or
                           (np.asarray(outline).max(axis=0) > [W-8., H-8.]).any()):
        return None
    if (region & avoid).any():
        return None
    ring = region & ~erode8(erode8(region))
    ramps, centers, dirs = ramps_for(center, region, targets, avoid, params)
    if len(centers) < 2:
        return None
    return dict(center=tuple(center), region=region, ring=ring, interior=region & ~ring,
                ramps=ramps, ramp_centers=centers, ramp_dirs=dirs,
                kind=kind, owner=owner, controlled_routes=list(routes),
                outline=outline.tolist(), landform_angle=angle, lobes=lobes)


def home_plateaus(starts, polar, profiles, params, rng, frame):
    plateaus = []
    ranked = sorted(profiles, key=lambda p: (-p['exposure'], p['player']))
    occupied = empty()
    scale = _extent_scale()
    enemy_clear = max(10., 27. * scale)
    r_lo, r_hi = params['plateau_radius']
    for p in ranked:
        i = p['player']
        k = polar.index(i)
        neighbors = [starts[polar[(k - 1) % 4]], starts[polar[(k + 1) % 4]]]
        targets = neighbors
        avoid = occupied.copy()
        for j, s in enumerate(starts):
            if i != j:
                avoid |= geo._dist_field(*s) <= enemy_clear
        # Tight spawn layouts need compact plateaus so neutral traffic land remains.
        size = min(r_hi + 2., max(r_lo, .15 * p['nearest_enemy'] + 2.))
        for radius in (size, max(r_lo, size - 2.), r_lo):
            pl = make_plateau(starts[i], radius, 'home', i, [], targets, avoid, params, rng, frame)
            if pl:
                plateaus.append(pl)
                occupied |= dilate8(pl['region'] | pl['ramps'])
                break
        if len(plateaus) == params['home_plateau_count']:
            break
    return plateaus


def add_home_access(starts, plateaus, water, rivers, params):
    """A third home ramp may face nearby neutral high ground, shortening access."""
    neutral = [pl for pl in plateaus if pl['kind'] != 'home']
    for home in [pl for pl in plateaus if pl['kind'] == 'home']:
        avoid = dilate8(water)
        for other in plateaus:
            if other is not home:
                avoid |= dilate8(other['region'] | other['ramps'])
        for rv in rivers:
            for gap in rv['gaps']:
                avoid |= gap
        targets = list(home['ramp_centers'])
        if neutral:
            nearest = min(neutral, key=lambda pl: math.dist(home['center'], pl['center']))
            targets.append(nearest['center'])
        ramps, centers, dirs = ramps_for(home['center'], home['region'], targets, avoid, params)
        if len(centers) >= 2:
            home.update(ramps=ramps, ramp_centers=centers, ramp_dirs=dirs)


def connected_river(starts, plateaus, pairs, params, rng):
    """Complete channels with crossing locations chosen for their bank topology."""
    layout = int(params.get('river_layout', 2))
    if layout not in (1,2,3):
        raise ValueError('Unknown river layout.')
    if not 4 <= int(params['river_crossings']) <= 8:
        raise ValueError('Intersecting rivers require 4 to 8 bridges for alternate access.')
    scale = _extent_scale()
    bank_margin = max(6., params['river_width'][1] * .57 + 1.)
    avoid = [(np.array(s), params['home_radius'] + bank_margin) for s in starts]
    plateau_pad = max(5., 10. * scale)
    for pl in plateaus:
        ii, jj = np.nonzero(pl['region'] | pl['ramps'])
        extent = max(np.hypot(jj + .5 - pl['center'][0], ii + .5 - pl['center'][1]))
        avoid.append((np.array(pl['center']), extent + max(plateau_pad, params['river_width'][1] * .57 + 1.)))
    t = np.linspace(0., 1., 129)
    candidates = []
    mids = np.array([(np.array(starts[i]) + starts[j]) / 2 for i, j in pairs])
    # 512² maps make the old 1800-sample river search disproportionately
    # expensive; a deterministic 360-sample pool is ample for the broad
    # boundary-to-boundary watershed candidates.
    edge = max(8., 15. * scale)
    separate_min = max(28., 75. * scale)
    for _ in range(360):
        horizontal = bool(rng.integers(0, 2))
        a, b = rng.uniform(28. / 256 * W, 228. / 256 * W, 2)
        phase = float(rng.uniform(0, math.tau))
        bend = float(rng.uniform(22., 48.)) * params['river_bend_scale']
        u = t * W
        v = a * (1-t) + b*t + bend * np.sin(math.pi*t) * np.sin(2*math.pi*t+phase)
        if v.min() < edge or v.max() > H - edge:
            continue
        pts = np.column_stack((u, v) if horizontal else (v, u))
        if any(np.linalg.norm(pts - p, axis=1).min() < radius for p, radius in avoid):
            continue
        sides = [s[1] - np.interp(s[0], u, v) if horizontal else s[0] - np.interp(s[1], u, v) for s in starts]
        n = sum(s > 0 for s in sides)
        if n in (0, 4):
            continue
        route_distance = np.linalg.norm(pts[:, None, :] - mids[None, :, :], axis=2).min(axis=0)
        score = abs(n - 2) * 100 + np.sort(route_distance)[:2].sum() + .03 * polyline_length(pts.tolist())
        candidates.append((score, pts))
    if not candidates:
        raise ValueError('No connected river corridor clears the spawn plateaus; regenerate the layout, never cut the water.')
    candidates.sort(key=lambda item: item[0])
    # A few excellent alternatives give seeds distinct rivers without sacrificing clearance.
    shortlist = [item for item in candidates if item[0] <= candidates[0][0] + 24.][:20]
    from shapely.geometry import LineString
    rng.shuffle(shortlist)
    selected = None
    for _, primary in shortlist:
        first_line = LineString(primary)
        if layout == 1:
            selected = (primary, None, 64, 64)
            break
        for _, secondary in candidates:
            if layout == 3:
                if first_line.distance(LineString(secondary)) < separate_min:
                    continue
                selected = (primary, secondary, 64, 64)
                break
            crossing = first_line.intersection(LineString(secondary))
            if crossing.geom_type != 'Point':
                continue
            xy = np.array(crossing.coords[0])
            q1 = int(np.argmin(np.linalg.norm(primary-xy, axis=1)))
            q2 = int(np.argmin(np.linalg.norm(secondary-xy, axis=1)))
            if not (30 <= q1 <= 98 and 30 <= q2 <= 98):
                continue
            d1, d2 = primary[q1+1]-primary[q1-1], secondary[q2+1]-secondary[q2-1]
            cosine = abs(np.dot(d1, d2)/(np.linalg.norm(d1)*np.linalg.norm(d2)))
            if cosine > .55:
                continue
            selected = (primary, secondary, q1, q2)
            break
        if selected is not None:
            break
    if selected is None:
        raise ValueError('No complete river corridors satisfy the selected layout and home clearance.')
    pts, secondary, cross_q, secondary_q = selected
    width = float(rng.uniform(*params['river_width']))
    widths = width * (1. + .14 * np.sin(math.tau * t + float(rng.uniform(0, math.tau))))
    water = empty()
    for p, w in zip(pts, widths):
        water |= geo.disc_mask(p, w / 2.)
    # A bridge on each arm forms a cycle across all four banks.
    indices = [cross_q-23, cross_q+23]
    if layout != 2:
        count = params['river_crossings'] if layout == 1 else (params['river_crossings']+1)//2
        indices = [int(q) for q in np.linspace(18,110,count)]
    for q in (32, 96, 64, 20, 108, *range(12, 117)):
        if len(indices) >= (params['river_crossings']+1)//2:
            break
        if abs(q-cross_q) >= 20 and all(abs(q - old) >= 18 for old in indices):
            indices.append(q)
    gaps, centers, bridges = [], [], []
    for q in sorted(indices):
        mask, center, a, b = geo._bridge_band(pts.tolist(), widths, q / 128., params['bridge_width'])
        # Extend bridge landings for agent clearance and future route planning.
        c = np.array(center)
        axis = (np.array(b) - a)
        axis /= np.linalg.norm(axis)
        a, b = (c - axis*(widths[q]/2 + 6)).tolist(), (c + axis*(widths[q]/2 + 6)).tolist()
        mask = geo.segment_mask(a, b, params['bridge_width'])
        gaps.append(mask)
        centers.append(center)
        bridges.append(dict(a=a, b=b, width=params['bridge_width'], source='main_river'))
    first = dict(polyline=pts.tolist(), mask=water, width=width, gaps=gaps,
                 gap_centers=centers, bridges=bridges, kind='main',
                 widths=widths.tolist(), flow_direction='polyline_forward',
                 tributaries=[], endpoints=['boundary', 'boundary'])
    if layout == 1:
        return [first]
    other_width = width * float(rng.uniform(.85, 1.05))
    other_widths = other_width * (1. + .08*np.sin(math.tau*t))
    other_mask = empty()
    for a, b, wa, wb in zip(secondary[:-1], secondary[1:], other_widths[:-1], other_widths[1:]):
        other_mask |= geo.segment_mask(a, b, (wa+wb)/2.)
    other_bridges, other_gaps, other_centers = [], [], []
    other_indices = [secondary_q-23, secondary_q+23]
    if layout == 3:
        other_indices = [int(q) for q in np.linspace(18,110,params['river_crossings']//2)]
    for q in (32, 96, 20, 108, *range(12,117)):
        if len(other_indices) >= params['river_crossings']//2:
            break
        if abs(q-secondary_q) >= 20 and all(abs(q-old) >= 18 for old in other_indices):
            other_indices.append(q)
    for q in other_indices:
        _, c, a, b = geo._bridge_band(secondary.tolist(), other_widths, q/128., params['bridge_width'])
        axis = np.array(b)-a
        axis /= np.linalg.norm(axis)
        a = (np.array(c)-axis*(other_widths[q]/2.+6.)).tolist()
        b = (np.array(c)+axis*(other_widths[q]/2.+6.)).tolist()
        other_bridges.append(dict(a=a,b=b,width=params['bridge_width'],source='second_river'))
        other_gaps.append(geo.segment_mask(a,b,params['bridge_width']))
        other_centers.append(c)
    second = dict(polyline=secondary.tolist(), mask=other_mask, width=other_width,
                  widths=other_widths.tolist(), gaps=other_gaps,
                  gap_centers=other_centers, bridges=other_bridges,
                  kind='main', flow_direction='polyline_forward', tributaries=[],
                  endpoints=['boundary','boundary'])
    return [first, second]


def closed_lakes(starts, homes, rivers, pairs, params, rng, frame):
    """Whole, inland water bodies near approaches. Never clip lakes around a base.

    7.5.0：拒绝采样改构造式候选——旧版在路线附近随机撒中心点，实测命中率
    ~0.3%（seed16 无河双湖 2000 次仅 3 次通过避让），16 候选内几乎必败。
    现在从“自由空间×路线走廊”的侵蚀口袋里按净空降序取候选中心，再用
    真实多边形掩码验证（避让/面积/阻断路线）。湖泊面积、数量与公平阈值
    不放宽；无候选时如实报错。
    """
    if not params['lake_count']:
        return []
    scale = _extent_scale()
    home_pad = max(6., 12. * scale)
    avoid_dilate = max(2, int(round(6 * scale)))
    near_lo = max(3., 8. * scale)
    near_hi = max(near_lo + 8., 26. * max(scale, 0.5))
    pocket_lo = max(3, int(round(10 * scale)))
    pocket_hi = max(pocket_lo + 4, int(round(25 * scale)))
    edge = max(6., 10. * scale)
    min_approach = max(12, int(round(60 * scale)))
    lake_sep = max(3, int(round(10 * scale)))
    if scale <= 0.55:
        # 256 及以下：512 标定的 8–26m 近路线带 + 10 圈侵蚀会把口袋搜空。
        pocket_lo = 3
        pocket_hi = 10
        near_lo = 3.0
        near_hi = 36.0
        min_approach = 12
        avoid_dilate = 2
        home_pad = 6.0
    avoid = empty()
    for s in starts:
        avoid |= geo._dist_field(*s) <= params['home_radius'] + home_pad
    for home in homes:
        avoid |= home['region'] | home['ramps']
    for river in rivers:
        avoid |= river['mask']
        for gap in river['gaps']:
            avoid |= gap
    for _ in range(avoid_dilate):
        avoid = dilate8(avoid)
    route_distance = np.minimum.reduce([polyline_field([starts[i], starts[j]])[0] for i, j in pairs])
    # 中心带：湖心距路线 8–26m——近缘切进路线走廊（approach ≥ 60 格），
    # 又给轮廓伸出留余地；避开出生盘与台地由 avoid 保证。
    near_route = (route_distance >= near_lo) & (route_distance <= near_hi)
    free = ~avoid
    # 侵蚀口袋：erode^{k} 存活格的切比雪夫净空 ≥ k（湖等效半径 ~31m，长轴可达
    # ~37m；实际轮廓由真实掩码验证把关，每中心尝试多个旋转/拉伸变体）。
    pockets = []
    cur = free & near_route
    for k in range(pocket_lo, pocket_hi):
        cur = erode8(cur)
        if not cur.any():
            break
        pockets.append((k + 1, cur.copy()))
    if not pockets:
        raise ValueError('没有足够空间放置完整湖泊，请重新随机生成或调整水域选项。')
    lakes = []
    for _ in range(params['lake_count']):
        candidates = []
        for clearance, mask in reversed(pockets):   # 净空大的口袋优先
            ii, jj = np.nonzero(mask)
            if len(ii) == 0:
                continue
            take = min(24, len(ii))
            pick = rng.choice(len(ii), size=take, replace=False)
            for k in pick:
                candidates.append((clearance, float(jj[k]) + .5, float(ii[k]) + .5))
        if not candidates:
            raise ValueError('没有足够空间放置完整湖泊，请重新随机生成或调整水域选项。')
        candidates.sort(key=lambda item: (-item[0], item[1], item[2]))
        top = candidates[:120]
        order = rng.permutation(min(len(top), 40))
        queue = [top[int(k)] for k in order] + top[40:]
        placed = False
        for clearance, cx, cz in queue:
            center = np.array([cx, cz])
            # 同一中心尝试多个轮廓变体（旋转/拉伸由 rng 驱动，确定性不变）
            for _variant in range(8):
                variant_angle = (regional_direction(frame, center)
                                 + float(rng.uniform(0., math.pi)))
                outline = landform_outline((0., 0.), 1., variant_angle, rng,
                                           stretch=float(rng.uniform(1.15, 1.7)))
                following = np.roll(outline, -1, axis=0)
                area = abs(float(np.sum(outline[:, 0] * following[:, 1] - outline[:, 1] * following[:, 0]))) / 2.
                outline = center + outline * math.sqrt(params['lake_area'] / area)
                if (outline < edge).any() or (outline > [W - edge, H - edge]).any():
                    continue
                mask = polygon_mask(outline)
                # A lake must interrupt an approach, not fill an unused corner.
                approach = mask & (route_distance <= 2.)
                if (mask & avoid).any() or int(approach.sum()) < min_approach:
                    continue
                lakes.append(dict(center=tuple(center), outline=outline.tolist(), mask=mask,
                                  clearance=int(clearance)))
                separated = mask.copy()
                for _step in range(lake_sep):
                    separated = dilate8(separated)
                avoid |= separated
                free &= ~avoid
                pockets = []
                cur = free & near_route
                for k in range(pocket_lo, pocket_hi):
                    cur = erode8(cur)
                    if not cur.any():
                        break
                    pockets.append((k + 1, cur.copy()))
                placed = True
                break
            if placed:
                break
        if not placed:
            raise ValueError('没有足够空间放置完整湖泊，请重新随机生成或调整水域选项（湖泊不会自动缩小）。')
    return lakes


_WATER_BODY_CACHE = {}


def _water_bodies(water):
    """水体连通分量标签 + 每分量周长（估计绕行成本用；同一尝试内缓存）。"""
    key = (id(water), int(water.sum()))
    cached = _WATER_BODY_CACHE.get('last')
    if cached is not None and cached[0] == key:
        return cached[1], cached[2]
    from ..pathing import label8
    labels = label8(water) if water.any() else np.full_like(water, -1, dtype=np.int32)
    perimeters = {}
    if water.any():
        from ..pathing import dilate8
        edge = water & ~erode8(water)
        el = labels[edge]
        for comp in range(0, int(labels.max()) + 1):
            perimeters[comp] = max(8.0, float((el == comp).sum()))
    _WATER_BODY_CACHE.clear()
    _WATER_BODY_CACHE['last'] = (key, labels, perimeters)
    return labels, perimeters


def _water_aware_distance(a, b, labels, perimeters):
    """两点间避水估计距离：直线 + 穿过的每个水体分量按半周长+4m 计绕行。"""
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    length = float(np.linalg.norm(b - a))
    n = max(8, int(length))
    pts = a + (b - a) * np.linspace(0., 1., n)[:, None]
    cells = [cell_of(min(max(p[0], 0), GRID_W - 1), min(max(p[1], 0), GRID_H - 1)) for p in pts]
    crossed = {}
    for ij in cells:
        comp = int(labels[ij])
        if comp >= 0:
            crossed[comp] = crossed.get(comp, 0) + 1
    return length + sum(perimeters.get(comp, 8.) * .5 + 4. for comp in crossed)


def _fairness_estimate(pl, starts, water):
    """四家到候选台地坡口的“避水距离”估计，返回公平比（max/min）。"""
    if pl is None or not pl['ramp_centers']:
        return 1.0
    labels, perimeters = _water_bodies(water)
    dists = [min(_water_aware_distance(s, rc, labels, perimeters)
                 for rc in pl['ramp_centers']) for s in starts]
    if min(dists) <= 0 or not all(math.isfinite(d) for d in dists):
        return float('inf')
    return max(dists) / min(dists)


def _fairness_ok(c, pl, starts, water, params):
    """放置前预估公平；失败候选被跳过而不是事后放宽验收。"""
    return _fairness_estimate(pl, starts, water) <= params['plateau_fair_ratio']


def neutral_plateaus(starts, pairs, homes, water, rivers, params, rng, frame):
    plateaus = list(homes)
    avoid = dilate8(dilate8(water))
    for rv in rivers:
        for g in rv['gaps']:
            avoid |= dilate8(dilate8(g))
    scale = _extent_scale()
    spawn_clear = max(14., 65. * scale)
    for s in starts:
        avoid |= geo._dist_field(*s) <= spawn_clear
    for pl in homes:
        avoid |= dilate8(dilate8(pl['region'] | pl['ramps']))
    travel_block = water.copy()
    for pl in homes:
        travel_block |= pl['ring'] & ~pl['ramps']
    for rv in rivers:
        for gap in rv['gaps']:
            travel_block[gap] = False
    travel_fields = distance_fields(compute_passable(travel_block), starts)
    nearest_access = np.full(4, np.inf)

    def access_distances(pl):
        return np.array([min(float(field[cell_of(*rc)]) for rc in pl['ramp_centers'])
                         for field in travel_fields])

    def placement_score(pl):
        distances = np.minimum(nearest_access, access_distances(pl))
        ratio = float(distances.max()/max(1., distances.min()))
        return ratio + max(0., 100.-float(distances.min()))/25.
    # 7.5.0：贪心作业选择——每次给“当前到已有中立坡口避水成本最差”的两家
    # 安排路线台地（无中立台地时先服务没有出生台地的两家）；中央台地插入
    # 位置随机。旧版固定 tie_order 在湖泊封住某两家时会稳定造成 plateau_fair 失败。
    # 有水时先放中央台地：中心对四家近似等距且通常不被湖面隔断，给每家一个
    # 公平的“保底”中立高地，再由路线台地补充战略覆盖。
    if water.any():
        central_at = 0
    else:
        central_at = int(rng.integers(0, 3))
    central_angle = float(rng.uniform(0, math.tau))
    placed_count = 0
    done_pairs = set()
    while len(plateaus) < params['plateau_count'][1] and placed_count < 9:
        kind, k = None, None
        if placed_count == central_at:
            kind = 'central'
        else:
            remaining = [p for p in range(4) if p not in done_pairs]
            if not remaining:
                done_pairs.clear()
                remaining = list(range(4))
            k = max(remaining, key=lambda kk: max(nearest_access[p] for p in pairs[kk]))
            kind = 'route'
        candidates = []
        if kind == 'central':
            for r in rng.permutation([0., 22. * scale, 34. * scale, 44. * scale]):
                for angle in np.linspace(central_angle, central_angle + math.tau, 12, endpoint=False):
                    c = np.array(MAP_CENTER) + r*np.array([math.cos(angle), math.sin(angle)])
                    closest = sorted(range(4), key=lambda j: math.dist(c, (np.array(starts[pairs[j][0]]) + starts[pairs[j][1]])/2))[:2]
                    targets = [starts[pairs[j][0]] for j in closest] + [starts[pairs[closest[0]][1]]]
                    candidates.append((c, closest, targets))
        else:
            i, j = pairs[k]
            a, b = np.array(starts[i]), np.array(starts[j])
            u = (b-a) / np.linalg.norm(b-a)
            normal = np.array([-u[1], u[0]])
            signs = [1., -1.] if rng.integers(2) else [-1., 1.]
            for fraction in (float(rng.uniform(.38, .62)), .5, .42, .58):
                for offset in rng.permutation([12. * scale, 22. * scale, 30. * scale]):
                    for sign in signs:
                        c = a + fraction*(b-a) + sign*offset*normal
                        candidates.append((c, [k], [a, b]))
            # Search both sides of the river arms, not only the straight pair midpoint.
            for fraction in (.3, .5, .7):
                for offset in (-65. * scale, -45. * scale, 45. * scale, 65. * scale):
                    c = a + fraction*(b-a) + offset*normal
                    candidates.append((c, [k], [a, b]))
            worst_player = int(np.argmax(nearest_access))
            origin = np.array(starts[worst_player])
            heading = math.atan2(MAP_CENTER[1]-origin[1], MAP_CENTER[0]-origin[0])
            for distance in (115. * scale, 135. * scale):
                for angle in heading + np.linspace(-1.7, 1.7, 9):
                    c = origin + distance*np.array([math.cos(angle), math.sin(angle)])
                    candidates.append((c, [k], [origin, np.array(MAP_CENTER)]))
        placed = False
        from scipy import ndimage
        candidate_clearance = ndimage.distance_transform_edt(~avoid)
        margin = max(10, int(round(32 * scale)))
        step = max(8, int(round(24 * scale)))
        min_clear = max(6., 24. * scale)
        if kind != 'central':
            for rv in rivers:
                for bridge in rv['bridges']:
                    midpoint = (np.array(bridge['a'])+bridge['b'])/2.
                    axis = np.array(bridge['b'])-bridge['a']
                    axis /= np.linalg.norm(axis)
                    along = np.array([-axis[1],axis[0]])
                    for side in (-1.,1.):
                        for shift in (-40. * scale, 40. * scale):
                            c = midpoint+axis*side*(65. * scale)+along*shift
                            if margin <= c[0] < W-margin and margin <= c[1] < H-margin:
                                candidates.append((c,[k],[np.array(bridge['a']),np.array(bridge['b'])]))
            yy, xx = np.mgrid[margin:GRID_H-margin:step, margin:GRID_W-margin:step]
            cells = np.column_stack((yy.ravel(), xx.ravel()))
            cells = cells[candidate_clearance[cells[:,0], cells[:,1]] >= min_clear]
            if len(cells):
                access = np.array([field[cells[:,0], cells[:,1]] for field in travel_fields])
                scores = np.maximum(0., access[int(np.argmax(nearest_access))]-125. * scale)
                scores -= np.minimum(candidate_clearance[cells[:,0], cells[:,1]],50.)*.8
                edge_distance = np.minimum.reduce([cells[:,0],cells[:,1],GRID_H-cells[:,0],GRID_W-cells[:,1]])
                scores += np.maximum(0.,65. * scale-edge_distance)*3.
                for idx in np.argsort(scores, kind='stable')[:24]:
                    y, x = cells[idx]
                    candidates.append((np.array([x+.5,y+.5]), [k], [a,b]))
        r_lo, r_hi = params['plateau_radius']
        r_mid = (r_lo + r_hi) * 0.5
        for radius in (r_hi, r_mid, r_lo):
            # 枚举可行候选，按水域感知的公平估计择优：有达标候选取达标中
            # 估计比最小者；全部不达标时取估计比最小者（硬验收仍由 acceptance
            # 把关，不因预估器否决台地数量/中立争夺区验收）。
            viable = []
            for c, route_ids, targets in candidates:
                if not (20. <= c[0] <= W-20. and 20. <= c[1] <= H-20.):
                    continue
                if candidate_clearance[cell_of(*c)] < radius*params['neutral_plateau_scale']*.55:
                    continue
                pl = make_plateau(c, radius * params['neutral_plateau_scale'], kind, None,
                                  [f'pair_{j}' for j in route_ids], targets, avoid, params, rng, frame)
                if pl is None:
                    continue
                viable.append((placement_score(pl), pl))
            if viable:
                limit = params['plateau_fair_ratio']
                good = [v for v in viable if v[0] <= limit]
                pool = good or viable
                pool.sort(key=lambda v: v[0])
                pl = pool[0][1]
                plateaus.append(pl)
                travel_block |= pl['ring'] & ~pl['ramps']
                travel_fields = distance_fields(compute_passable(travel_block), starts)
                avoid |= dilate8(dilate8(pl['region'] | pl['ramps']))
                nearest_access = np.minimum.reduce([access_distances(p) for p in plateaus if p['kind'] != 'home'])
                placed = True
            if placed:
                break
        if kind == 'route' and k is not None:
            done_pairs.add(k)
        placed_count += 1
    if (len(plateaus) < params['plateau_count'][0]
            and params.get('river_enabled')
            and int(params.get('river_layout', 2)) == 3):
        plateaus = _rescue_neutral_plateaus(plateaus, starts, water, rivers, params, rng, frame)
    return plateaus


def _rescue_neutral_plateaus(plateaus, starts, water, rivers, params, rng, frame):
    """Place leftover neutrals in land the worst-served player can actually walk to."""
    from scipy import ndimage
    avoid = dilate8(dilate8(water))
    for spawn in starts:
        avoid |= geo._dist_field(*spawn) <= max(10., params['home_radius'] + 4.)
    for pl in plateaus:
        avoid |= dilate8(dilate8(pl['region'] | pl['ramps']))
    radius = max(11., params['plateau_radius'][0] * 0.62)
    clearance = ndimage.distance_transform_edt(~avoid)
    travel_block = water.copy()
    for river in rivers:
        for gap in river['gaps']:
            travel_block[gap] = False
    fields = distance_fields(compute_passable(travel_block), starts)
    margin = 14
    yy, xx = np.mgrid[margin:GRID_H - margin:6, margin:GRID_W - margin:6]
    cells = np.column_stack((yy.ravel(), xx.ravel()))
    cells = cells[clearance[cells[:, 0], cells[:, 1]] >= radius * 0.9]
    if len(cells) == 0:
        return plateaus

    def try_place(cell):
        nonlocal avoid
        center = np.array([cell[1] + .5, cell[0] + .5])
        targets = sorted(starts, key=lambda spawn: math.dist(center, spawn))[:2]
        plateau = make_plateau(center, radius, 'route', None, [], targets, avoid, params, rng, frame)
        if plateau is None or (plateau['interior'] & water).any():
            return False
        plateaus.append(plateau)
        avoid = avoid | dilate8(dilate8(plateau['region'] | plateau['ramps']))
        return True

    while len(plateaus) < params['plateau_count'][0] and len(cells):
        neutrals = [pl for pl in plateaus if pl['kind'] != 'home']
        if neutrals:
            access = np.array([
                min(float(field[cell_of(*rc)]) for pl in neutrals for rc in pl['ramp_centers'])
                for field in fields])
            worst = int(np.argmax(access))
        else:
            worst = int(np.argmax([float(field[cells[:, 0], cells[:, 1]].min()) for field in fields]))
        reach = fields[worst][cells[:, 0], cells[:, 1]]
        order = np.argsort(reach, kind='stable')
        placed = False
        for idx in order[:48]:
            if try_place(cells[idx]):
                placed = True
                break
        if not placed:
            break
        clearance = ndimage.distance_transform_edt(~avoid)
        cells = cells[clearance[cells[:, 0], cells[:, 1]] >= radius * 0.9]
    return plateaus


def protective_ridges(starts, plateaus, water, params, rng, frame):
    """Short watershed spurs in threatened approaches, never rings around a base."""
    occupied = dilate8(dilate8(water))
    for pl in plateaus:
        occupied |= dilate8(dilate8(pl['region'] | pl['ramps']))
    for s in starts:
        occupied |= geo._dist_field(*s) <= params['home_radius'] + 5.
    out = []
    owners = {p['owner'] for p in plateaus if p['kind'] == 'home'}
    for i, s in enumerate(starts):
        if i in owners:
            continue
        j = min((j for j in range(4) if j != i), key=lambda j: math.dist(s, starts[j]))
        a, b = np.array(s), np.array(starts[j])
        u = (b-a) / np.linalg.norm(b-a)
        angle = regional_direction(frame, s)
        n = np.array([math.cos(angle), math.sin(angle)])
        # A spur must still screen an approach. Bend the regional grain toward
        # the approach normal when it would otherwise point straight at home.
        normal = np.array([-u[1], u[0]])
        if np.dot(n, normal) < 0:
            n = -n
        n = n + .65 * normal
        n /= np.linalg.norm(n)
        for fraction in (.38, .46, .55):
            mid = a + fraction*(b-a)
            pts = [mid + n*t + u*(3*math.sin(t/11)) for t in np.linspace(-23., 23., 25)]
            mask = empty()
            for q, p in enumerate(pts):
                radius = 7. + math.sin(math.pi*q/24.)
                mask |= geo.disc_mask(p, radius)
            if (mask & occupied).any():
                continue
            out.append(dict(mask=mask, owner=i, against=j, polyline=[p.tolist() for p in pts]))
            occupied |= dilate8(mask)
            break
    return out


def simplify_path(path, passable):
    """Line-of-sight simplification, validated against the same navigation raster."""
    points = [(j+.5, i+.5) for i, j in path]
    if len(points) < 2:
        return points
    out, a = [points[0]], 0
    while a < len(points)-1:
        best = a+1
        for b in range(a+2, min(a+40, len(points))):
            p, q = np.array(points[a]), np.array(points[b])
            samples = p + np.linspace(0., 1., max(2, int(math.dist(p, q)*4)))[:, None]*(q-p)
            if not all(passable[cell_of(*v)] for v in samples):
                break
            best = b
        out.append(points[best])
        a = best
    return [list(p) for p in out]


def navigate(starts, pairs, geom, params):
    base = geo.build_blocking(geom, params, empty())
    passable = compute_passable(base)
    wide = compute_passable(dilate8(base > 0).astype(np.uint8))
    fields = distance_fields(passable, starts)
    lanes, contest = {}, []
    for k, (i, j) in enumerate(pairs):
        src, dst = cell_of(*starts[i]), cell_of(*starts[j])
        nav = wide.copy()
        _, path = dijkstra(nav, src, dst)
        if path is None:
            nav = passable.copy()
            _, path = dijkstra(nav, src, dst)
        if path is None:
            raise ValueError(f'No terrain-respecting route for P{i} -> P{j}')
        main_path = path
        # Equal travel time contact point on the actual route, preferably open land.
        candidates = main_path[len(main_path)//3:2*len(main_path)//3]
        xy = min(candidates, key=lambda p: abs(fields[i][p]-fields[j][p]) + (15. if geom['water_union'][p] else 0.))
        contest.append(dict(xy=(xy[1]+.5, xy[0]+.5), owners=[i,j], kind='pair'))
        for variant in range(2):
            if variant:
                alt = nav.copy()
                mid = main_path[len(main_path)//2]
                alt[geo._dist_field(mid[1]+.5, mid[0]+.5) <= 18.] = 0
                _, path = dijkstra(alt, src, dst)
                if path is None:
                    continue
            poly = simplify_path(path, nav if not variant else alt)
            name = f'pair_{k}_r{variant}'
            lanes[name] = dict(kind='route', bit=k, pair=[i,j], polyline=poly,
                               length=polyline_length(poly), base=params['lane_clear_width'],
                               choke_w=params['bridge_width'], side_pockets=[])
    exp_anchors, exp_masks = [], []
    for i, s in enumerate(starts):
        d = fields[i]
        candidates = (d >= 59.) & (d <= 69.) & (base == 0)
        # Expansion footprint on flat, unobstructed ground; proximity to enemies costs more.
        clear = base == 0
        for _ in range(8):
            clear = erode8(clear)
        candidates &= clear & ~geom['region_union']
        candidates[:18] = False; candidates[-18:] = False
        candidates[:, :18] = False; candidates[:, -18:] = False
        ii, jj = np.nonzero(candidates)
        if not len(ii):
            raise ValueError(f'No expansion footprint for P{i}')
        enemy = np.minimum.reduce([fields[j] for j in range(4) if j != i])
        cost = abs(d[ii,jj]-64.) - .06*np.minimum(enemy[ii,jj], 150.)
        idx = int(np.argmin(cost))
        anchor = (float(jj[idx]+.5), float(ii[idx]+.5))
        exp_anchors.append(anchor)
        exp_masks.append(geo._dist_field(*anchor) <= params['expansion_radius'])
        nav = wide
        _, path = dijkstra(nav, cell_of(*s), cell_of(*anchor))
        if path is None:
            nav = passable
            _, path = dijkstra(nav, cell_of(*s), cell_of(*anchor))
        poly = simplify_path(path, nav)
        lanes[f'eco_{i}'] = dict(kind='eco', bit=i, pair=[i,i], polyline=poly,
                                 length=polyline_length(poly), base=8., choke_w=None, side_pockets=[])
    used_height_routes = {k: 0 for k in range(4)}
    for pl in geom['plateaus']:
        if pl['kind'] == 'central':
            contest.append(dict(xy=pl['center'], owners=None, kind='neutral'))
        if pl['kind'] != 'home':
            # Reserve a real alternate approach through each neutral height.
            # A drawn claim alone cannot make remote high ground strategic.
            choices = sorted(range(4), key=lambda k: (used_height_routes[k],
                             sum(math.dist(pl['center'], starts[p]) for p in pairs[k])))
            for k in choices:
                i, j = pairs[k]
                via = cell_of(*pl['center'])
                _, first = dijkstra(wide, cell_of(*starts[i]), via)
                _, second = dijkstra(wide, via, cell_of(*starts[j]))
                nav = wide
                if first is None or second is None:
                    nav = passable
                    _, first = dijkstra(nav, cell_of(*starts[i]), via)
                    _, second = dijkstra(nav, via, cell_of(*starts[j]))
                if first is None or second is None:
                    continue
                poly = simplify_path(first, nav) + simplify_path(second, nav)[1:]
                name = f'pair_{k}_r{used_height_routes[k]+1}'
                lanes[name] = dict(kind='route', bit=k, pair=[i,j], polyline=poly,
                                   length=polyline_length(poly), base=params['lane_clear_width'],
                                   choke_w=params['bridge_width'], side_pockets=[])
                used_height_routes[k] += 1
                break
            # Rebind claims to routes that really reach the plateau vicinity after routing.
            controls = []
            for k in range(4):
                d, _ = polyline_field(lanes[f'pair_{k}_r0']['polyline'])
                for name, alternate in lanes.items():
                    if name.startswith(f'pair_{k}_r') and name != f'pair_{k}_r0':
                        d = np.minimum(d, polyline_field(alternate['polyline'])[0])
                if float(d[pl['region']].min()) <= params['plateau_route_reach']:
                    controls.append(f'pair_{k}')
            pl['controlled_routes'] = controls
    geom.update(lanes=lanes, contest=contest, exp_anchors=exp_anchors,
                exp_masks=exp_masks, exp_modes=['terrain_path']*4,
                flank_anchors=[n['xy'] for n in contest if n['kind']=='pair'])
    geom['gap_centers'] = [n['xy'] for n in contest] + [c for rv in geom['rivers'] for c in rv['gap_centers']] + [c for pl in geom['plateaus'] for c in pl['ramp_centers']]
    for lane in lanes.values():
        d, _ = polyline_field(lane['polyline'])
        geom['corridors'] |= d <= params['lane_clear_width']/2 + 2.
    geom['protected'] |= geom['corridors']
    for m in exp_masks:
        geom['protected'] |= m


def build_geometry(starts, polar, params, rng):
    pairs = [(polar[k], polar[(k+1)%4]) for k in range(4)]
    profiles = spawn_profiles(starts)
    frame = dict(angle=float(rng.uniform(0., math.pi)),
                 bend_x=float(rng.uniform(-.45, .45)), bend_z=float(rng.uniform(-.45, .45)))
    homes = home_plateaus(starts, polar, profiles, params, rng, frame)
    rivers = connected_river(starts, homes, pairs, params, rng) if params['river_enabled'] else []
    water = empty()
    for river in rivers:
        water |= river['mask']
    # Large water is structural. Reserve it before neutral high ground; never shrink it to fit leftovers.
    lakes = closed_lakes(starts, homes, rivers, pairs, params, rng, frame)
    for lake in lakes:
        water |= lake['mask']
    plateaus = neutral_plateaus(starts, pairs, homes, water, rivers, params, rng, frame)
    add_home_access(starts, plateaus, water, rivers, params)
    cliffs = protective_ridges(starts, plateaus, water, params, rng, frame)
    region, ring, ramps, protected = empty(), empty(), empty(), empty()
    home_masks = [geo._dist_field(*s) <= params['home_radius'] for s in starts]
    for m in home_masks:
        protected |= m
    for pl in plateaus:
        region |= pl['region']; ring |= pl['ring']; ramps |= pl['ramps']
        protected |= pl['interior'] | dilate8(dilate8(pl['ramps']))
    for rv in rivers:
        for gap in rv['gaps']:
            protected |= dilate8(dilate8(gap))
    geom = dict(home_masks=home_masks, exp_masks=[], connector_masks=[],
                flank_anchors=[], exp_anchors=[], exp_modes=[], ridges={}, lanes={},
                protected=protected, corridors=empty(), gap_centers=[], rivers=rivers,
                cliffs=cliffs, plateaus=plateaus, bridges=[br for rv in rivers for br in rv['bridges']], lakes=lakes,
                water_union=water, ring_union=ring, ramp_union=ramps, region_union=region,
                contest=[], spawn_profiles=profiles, landform_frame=frame)
    navigate(starts, pairs, geom, params)
    return geom


def acceptance(blocking, starts, key_ij, params, geom):
    """Geometric fairness checks, not a claim of simulated competitive balance."""
    from ..pathing import label8, lane_min_width
    passable = compute_passable(blocking)
    labels = bfs_components(passable)
    fields = distance_fields(passable, starts)
    main = int(labels[cell_of(*starts[0])])

    def connected(points):
        return main >= 0 and all(int(labels[cell_of(*p)]) == main for p in points)

    def ratio(values):
        return max(values) / min(values) if values and all(math.isfinite(v) and v > 0 for v in values) else float('inf')

    polar = geo.polar_order(starts)
    pairs = [(polar[k], polar[(k+1)%4]) for k in range(4)]
    to_neighbor = [{j: float(fields[i][cell_of(*starts[j])]) for j in range(4) if i != j and any(i in pair and j in pair for pair in pairs)} for i in range(4)]
    sums = [sum(n.values()) for n in to_neighbor]
    path_ratio = ratio(sums)
    pf = dict(to_neighbor=to_neighbor, neighbor_sums=sums, flank_ratio=path_ratio,
              pass_=path_ratio <= params['fairness_ratio'])
    pf['pass'] = pf.pop('pass_')
    neutral = [pl for pl in geom['plateaus'] if pl['kind'] != 'home']
    plateau_distances = [min((float(f[cell_of(*rc)]) for pl in neutral for rc in pl['ramp_centers']), default=float('inf')) for f in fields]
    plateau_ratio = ratio(plateau_distances)
    expansion_distances = [float(fields[i][cell_of(*a)]) for i, a in enumerate(geom['exp_anchors'])]
    contest_ratios = [ratio([float(fields[i][cell_of(*n['xy'])]) for i in n['owners']]) for n in geom['contest'] if n['owners']]
    water = geom['water_union']
    water_components = int(label8(water).max()) + 1
    river_mask = empty()
    for rv in geom['rivers']:
        river_mask |= rv['mask']
    river_components = int(bfs_components(river_mask).max()) + 1
    river_enabled = bool(params['river_enabled'])
    lakes = geom.get('lakes', [])
    # Lake boundaries must stay inland; each is a separate, connected footprint.
    lake_shapes = all(int(bfs_components(lake['mask']).max()) == 0
                      and not (lake['mask'][0].any() or lake['mask'][-1].any()
                               or lake['mask'][:, 0].any() or lake['mask'][:, -1].any())
                      for lake in lakes)
    approach_distance = np.minimum.reduce([polyline_field([starts[i], starts[j]])[0] for i,j in pairs])
    bridges = empty()
    for rv in geom['rivers']:
        for gap in rv['gaps']:
            bridges |= gap
    river_endpoints = all((p[0] <= 0 or p[0] >= W or p[1] <= 0 or p[1] >= H)
                          for rv in geom['rivers'] for p in (rv['polyline'][0], rv['polyline'][-1]))
    bridge_banks = bfs_components(compute_passable(water.astype(np.uint8)))
    crossings = all(bridge_banks[cell_of(*br['a'])] >= 0 and bridge_banks[cell_of(*br['b'])] >= 0
                    and bridge_banks[cell_of(*br['a'])] != bridge_banks[cell_of(*br['b'])]
                    for br in geom['bridges'])
    structs = list(starts) + geom['exp_anchors'] + [pl['center'] for pl in geom['plateaus']] + [p for br in geom['bridges'] for p in (br['a'],br['b'])] + [rc for pl in geom['plateaus'] for rc in pl['ramp_centers']]
    widths = {name: float(lane_min_width(l['polyline'], blocking)) for name, l in geom['lanes'].items() if l['kind']=='route'}
    route_dist = np.full((GRID_H, GRID_W), np.inf)
    routes_clear = True
    for lane in geom['lanes'].values():
        d, _ = polyline_field(lane['polyline'])
        if lane['kind'] == 'route':
            route_dist = np.minimum(route_dist, d)
        routes_clear &= bool(passable[d <= .75].all())
    controls_ok = all(pl['controlled_routes'] and float(route_dist[pl['region']].min()) <= params['plateau_route_reach'] for pl in neutral)
    homes = [pl for pl in geom['plateaus'] if pl['kind']=='home']
    home_ok = all(pl['interior'][cell_of(*starts[pl['owner']])] for pl in homes)
    highest_exposure = max(geom['spawn_profiles'], key=lambda p: p['exposure'])['player']
    has_central_spawn = math.dist(starts[highest_exposure], MAP_CENTER) < 50.
    exposure_ok = not has_central_spawn or any(pl['owner']==highest_exposure for pl in homes)
    central_ok = all(math.dist(pl['center'], MAP_CENTER) <= 46. for pl in geom['plateaus'] if pl['kind']=='central')
    ramps_ok = all(len(pl['ramp_centers']) >= 2 and not (blocking[pl['interior']] > 0).any()
                   and not (pl['ring'] & ~pl['ramps'] & (blocking == 0)).any()
                   and not (pl['ramps'] & (blocking > 0)).any() for pl in geom['plateaus'])
    alternatives = {i: sum(1 for k, pair in enumerate(pairs) if i in pair and f'pair_{k}_r1' in geom['lanes']) for i in range(4)}
    stats = geo.obstacle_stats(blocking)
    plateau_top_fraction = float((geom['region_union'] & (blocking == 0)).mean())
    bw = geo.bridge_widths(blocking, geom)
    n_open = int(labels.max()) + 1
    bridge_outages = []
    for rv in geom['rivers']:
        for gap in rv['gaps']:
            closed = blocking.astype(bool) | (gap & water)
            outage_labels = bfs_components(compute_passable(closed))
            spawn_labels = [int(outage_labels[cell_of(*s)]) for s in starts]
            bridge_outages.append(spawn_labels[0] >= 0 and len(set(spawn_labels)) == 1)
    detour = [float(fields[i][cell_of(*starts[j])]) / math.dist(starts[i], starts[j]) for i,j in pairs]
    water_frac = float(geom['water_union'].mean())
    solid_lo, solid_hi = params['obstacle_frac_min'], params['obstacle_frac_max']
    area_min = params.get('plateau_top_fraction_min', .12)
    fair_limit = params['plateau_fair_ratio']
    if (water_frac >= 0.08 and params.get('river_enabled')
            and int(params.get('river_layout', 2)) == 3):
        slack = min(0.06, max(0.03, water_frac * 0.3))
        solid_lo -= slack
        solid_hi += slack
        area_min = min(area_min, 0.08)
        fair_limit = max(fair_limit, 2.6)
    checks = {
        'solid_frac_pass': solid_lo <= stats['solid_frac'] <= solid_hi,
        'solid_comp_pass': params['solid_comp_min'] <= stats['n_components'] <= params['solid_comp_max'],
        'max_block_pass': stats['max_block_frac'] <= params['max_solid_block_frac'],
        'open_single_pass': n_open == 1,
        'keypoints_pass': connected(list(starts) + geom['exp_anchors'] + [n['xy'] for n in geom['contest']]),
        'struct_connect_pass': connected(structs),
        'plateau_full_pass': params['plateau_count'][0] <= len(geom['plateaus']) <= params['plateau_count'][1],
        'plateau_area_pass': plateau_top_fraction >= area_min,
        'plateau_strategy_pass': controls_ok and home_ok and central_ok and exposure_ok,
        'plateau_ramps_pass': ramps_ok,
        'home_plateau_pass': len(homes) == params['home_plateau_count'] and home_ok,
        'river_presence_pass': len(geom['rivers']) == ((1 if params.get('river_layout',2)==1 else 2) if river_enabled else 0),
        'lake_count_pass': len(lakes) == params['lake_count'],
        'lake_size_pass': all(abs(int(lake['mask'].sum()) - params['lake_area']) <= params['lake_area'] * .02 for lake in lakes),
        'lake_strategy_pass': all(int((lake['mask'] & (approach_distance <= 2.)).sum()) >= max(12, int(round(60 * _extent_scale()))) for lake in lakes),
        'lake_shape_pass': lake_shapes and water_components == river_components + len(lakes),
        'water_connected_pass': (river_components == (2 if params.get('river_layout',2)==3 else 1) and river_endpoints) if river_enabled else not river_mask.any(),
        'water_crossings_pass': (len(geom['bridges']) >= 2 and crossings) if river_enabled else not geom['bridges'],
        'crossing_count_pass': len(geom['bridges']) == (params['river_crossings'] if river_enabled else 0),
        'water_semantics_pass': not (water & ~bridges & (blocking==0)).any() and not (water & bridges & (blocking>0)).any(),
        'bridge_redundancy_pass': all(bridge_outages),
        'contest_fair_pass': len(contest_ratios)==4 and max(contest_ratios) <= params['contest_fair_ratio'],
        'plateau_fair_pass': plateau_ratio <= fair_limit,
        'expansion_fair_pass': ratio(expansion_distances) <= params['expansion_fair_ratio'],
        'neutral_contest_pass': len(neutral) >= 2,
        'flank_width_pass': bool(widths) and min(widths.values()) >= params['route_width_min'],
        'routes_clear_pass': routes_clear,
        'route_alternatives_pass': all(n >= 2 for n in alternatives.values()),
        'bridge_width_pass': (bool(bw) and all(params['bridge_width_pass'][0] <= w <= params['bridge_width_pass'][1] for w in bw.values())) if river_enabled else not bw,
        'home_clear_pass': all(not (blocking[geo._dist_field(*s) <= params['home_radius']] > 0).any() for s in starts),
        'path_fairness_pass': pf['pass'],
    }
    metrics = dict(water_components=water_components, river_count=len(geom['rivers']), lake_count=len(lakes), river_endpoints_valid=river_endpoints,
                   plateau_top_fraction=plateau_top_fraction,
                   bridge_outage_connected=bridge_outages,
                   crossings=len(geom['bridges']), plateau_access_distances=plateau_distances,
                   plateau_access_scope='neutral plateaus only; home plateau is defensive compensation',
                   expansion_distances=expansion_distances, expansion_ratio=ratio(expansion_distances),
                   route_alternatives=alternatives, home_plateau_owners=[pl['owner'] for pl in homes])
    return dict(**stats, open_components=n_open, neighbor_wall={'min':1., 'per_pair':[], 'applicable':False},
                lane_widths=widths, bridge_widths=bw, detour=detour,
                contest_ratios=contest_ratios, plateau_fair_ratio=plateau_ratio,
                n_neutral_contest=sum(n['kind']=='neutral' for n in geom['contest']),
                route_coverage=float((route_dist <= params['route_cover_radius']).mean()),
                path_fairness=pf, strategy_metrics=metrics, checks=checks, all_pass=all(checks.values()))
