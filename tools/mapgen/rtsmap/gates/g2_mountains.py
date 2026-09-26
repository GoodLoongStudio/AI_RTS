"""Continuous mountain masses outside reserved routes and buildable plateaus."""
import numpy as np
from scipy import ndimage


MIN_RADIUS = 6


def close_narrow_gaps(mask, radius=6):
    """Merge facing rock edges separated by sub-width slots."""
    padded = np.pad(mask, radius + 1, mode='edge')
    expanded = ndimage.distance_transform_edt(~padded) <= radius
    closed = ndimage.distance_transform_edt(expanded) > radius
    return closed[radius+1:-radius-1, radius+1:-radius-1]


def remove_thin_spurs(mask, radius=MIN_RADIUS):
    """Disk opening: retain broad ridges, cut narrow necks and round their ends."""
    padded = np.pad(mask, radius + 1, mode='edge')
    core = ndimage.distance_transform_edt(padded) > radius
    if not core.any():
        return np.zeros_like(mask)
    opened = ndimage.distance_transform_edt(~core) <= radius
    return opened[radius+1:-radius-1, radius+1:-radius-1]


def mountain_cover(base, forbidden, target_fraction, rng, source, water=None, keep_clear=None, hard=None):
    """按目标阻碍率铺山体。

    2026-09-24 修两处让 40% 阻碍率重新可达的问题（256m 图实测）：
    ① 净空基准改为**硬禁区**（台地/出生点/崖/水域构造 + 桥口），不再把整条国道
       走廊外撑 10m——国道只保中心走廊（调用方传进来的 forbidden），肩部留给山体。
       旧实现可用面仅 ~8%，天花板 ~28%，40% 结构性不可达。
    ② 水面本身仍不可建，但不再向外撑 10m 禁带：河岸本就是山体属地
       （docs/plan/mountain-foot-moat-plan.md 的“山脚”语义），贴河岸铺山更自然。
    """
    h, w = base.shape
    # Smooth, anisotropic regional relief creates connected ridges instead of
    # independently scattered rocks. Clearance softens their corridor edges.
    coarse = rng.normal(size=(18, 12))
    field = ndimage.zoom(coarse, (h/18, w/12), order=3)[:h, :w]
    field = ndimage.gaussian_filter(field, 3.)
    if rng.integers(2):
        field = field.T.copy()
    _water = np.asarray(water, dtype=bool) if water is not None else np.zeros_like(base, dtype=bool)
    _keep = np.asarray(keep_clear, dtype=bool) if keep_clear is not None else np.zeros_like(base, dtype=bool)
    # 净空只相对硬禁区 + 桥口计算（见 docstring ①②）；forbidden 仍是禁入面。
    _hard = np.asarray(hard, dtype=bool) if hard is not None else forbidden
    _no_water = (_hard | _keep) & ~_water
    clearance = ndimage.distance_transform_edt(~_no_water)
    scores = field + np.minimum(clearance, 22.) / 11.
    available = ~forbidden & (clearance > 3.)
    indices = np.flatnonzero(available)
    target = int(round(target_fraction * base.size))
    ordered = indices[np.argsort(scores.ravel()[indices], kind='stable')]
    best, error = np.zeros_like(base, dtype=bool), base.size
    low, high = 0, len(indices)
    from ..pathing import compute_passable, dilate8
    # Area is measured AFTER closing disconnected pockets, not before. This
    # accounts for the mountains' topology without deleting their boundaries.
    for _ in range(14):
        count = (low + high) // 2
        cover = np.zeros_like(base, dtype=bool)
        if count:
            cover.ravel()[ordered[-count:]] = True
        cover = remove_thin_spurs(close_narrow_gaps(cover) & available)
        # 连通兜底：把与主区不连通的“口袋”就地填成山体。原实现只 dilate 岛屿一圈
        # （且把圈加进 cover 后下一轮再无新圈可加），深口袋填不掉 → open_single_pass
        # 偶发失败。改为直接吞掉岛屿本身，迭代到没有新口袋为止。
        for _ in range(24):
            walk = compute_passable(base | cover)
            labels, _ = ndimage.label(walk)
            main = labels[source]
            islands = (labels > 0) & (labels != main)
            fill = islands & ~forbidden
            if not fill.any():
                break
            cover |= fill
        cover = remove_thin_spurs(close_narrow_gaps(cover) & available)
        area = int((base | cover).sum())
        if abs(area-target) < error:
            best, error = cover, abs(area-target)
        if area < target:
            low = count + 1
        else:
            high = count - 1
        if error <= base.size * .0005 or low > high:
            break
    # Thresholding can jump when a basin closes. Trim only the exposed outer
    # boundary to meet the area budget without punching holes inside mountains.
    for _ in range(8):
        surplus = int((base | best).sum()) - target
        if surplus <= 0:
            break
        walk = compute_passable(base | best)
        labels, _ = ndimage.label(walk)
        connected = labels == labels[source]
        boundary = best & (ndimage.distance_transform_edt(~connected) <= 3.)
        exposed = np.flatnonzero(boundary)
        if not len(exposed):
            break
        order = np.argsort(scores.ravel()[exposed], kind='stable')
        best.ravel()[exposed[order[:surplus]]] = False
        best = remove_thin_spurs(close_narrow_gaps(best) & available)
    return best, int(ndimage.label(best, np.ones((3, 3)))[1])
