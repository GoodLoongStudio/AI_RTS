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


def mountain_cover(base, forbidden, target_fraction, rng, source):
    h, w = base.shape
    # Smooth, anisotropic regional relief creates connected ridges instead of
    # independently scattered rocks. Clearance softens their corridor edges.
    coarse = rng.normal(size=(18, 12))
    field = ndimage.zoom(coarse, (h/18, w/12), order=3)[:h, :w]
    field = ndimage.gaussian_filter(field, 3.)
    if rng.integers(2):
        field = field.T.copy()
    clearance = ndimage.distance_transform_edt(~forbidden)
    scores = field + np.minimum(clearance, 22.) / 11.
    available = ~forbidden & (clearance > 10.)
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
        for _ in range(6):
            walk = compute_passable(base | cover)
            labels, _ = ndimage.label(walk)
            main = labels[source]
            islands = (labels > 0) & (labels != main)
            fill = dilate8(islands) & ~forbidden
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
