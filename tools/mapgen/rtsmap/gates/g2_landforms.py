"""Plan-view landforms: broad cliff faces and shallow recesses, no height noise."""
import math

import numpy as np

from ..contract import GRID_H, GRID_W, H, W


def regional_direction(frame, center):
    """A slowly turning regional grain shared by plateaus and rock outcrops."""
    return (frame['angle'] + frame['bend_x'] * (center[0] / W - .5)
            + frame['bend_z'] * (center[1] / H - .5))


def polygon_mask(points):
    """Even/odd fill at cell centres; avoids image-library edge rounding."""
    points = np.asarray(points)
    out = np.zeros((GRID_H, GRID_W), dtype=bool)
    if len(points) < 3:
        return out
    x0, z0 = np.maximum(np.floor(points.min(axis=0)).astype(int), 0)
    x1, z1 = np.minimum(np.ceil(points.max(axis=0)).astype(int), [GRID_W, GRID_H])
    if x1 <= x0 or z1 <= z0:
        return out
    x, z = np.meshgrid(np.arange(x0, x1) + .5, np.arange(z0, z1) + .5)
    inside = out[z0:z1, x0:x1]
    for a, b in zip(points, np.roll(points, -1, axis=0)):
        if abs(b[1] - a[1]) < 1e-9:
            continue
        crosses = (a[1] > z) != (b[1] > z)
        edge_x = a[0] + (z - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
        inside ^= crosses & (x < edge_x)
    return out


def landform_outline(center, radius, angle, rng, home=False, stretch=None,
                     elongation=1.2, recess_depth=.2, softness=.16):
    """Unequal long faces, an extended shoulder and one broad eroded recess.

    Ordered polar controls keep one connected, star-shaped body. Small corner
    cuts soften junctions while retaining the long faces; no harmonic blobs or
    fine perimeter noise. Home shapes enclose a 24 m disc *before* rasterizing,
    leaving room for the 20 m build disc and the two-cell cliff strip.
    """
    count = int(rng.integers(7, 10))
    steps = rng.uniform(.7, 1.4, count)
    theta = np.cumsum(steps) / steps.sum() * math.tau
    theta += float(rng.uniform(-.16, .16))
    reach = rng.uniform(.94, 1.07, count)
    shoulder = int(rng.integers(count))
    reach[shoulder] += .22
    reach[(shoulder + 1) % count] += .10
    elongation = float(rng.uniform(elongation - .08, elongation + .08)) if stretch is None else stretch
    raw = radius * reach[:, None] * np.column_stack((np.cos(theta) * elongation, np.sin(theta)))
    # A broad inlet interrupts one long side. Moving a circular control point
    # inward merely made bean shapes; inserting an inset face makes a real cove.
    recess = (shoulder + int(rng.integers(3, count - 1))) % count
    inlet = (.55 * raw[recess] + .45 * raw[(recess + 1) % count]) * float(rng.uniform(1. - recess_depth - .04, 1. - recess_depth + .04))
    raw = np.insert(raw, recess + 1, inlet, axis=0)
    count = len(raw)
    # Chamfer each corner asymmetrically instead of rounding the whole body.
    points = []
    for i, p in enumerate(raw):
        points.append(p + .14 * softness / .16 * (raw[i - 1] - p))
        points.append(p + .18 * softness / .16 * (raw[(i + 1) % count] - p))
    points = np.array(points)
    if home:
        nxt = np.roll(points, -1, axis=0)
        edge = nxt - points
        projection = np.clip(-np.sum(points * edge, axis=1) / np.sum(edge * edge, axis=1), 0., 1.)
        distances = np.linalg.norm(points + projection[:, None] * edge, axis=1)
        points *= max(1., 24. / float(distances.min()))
    ca, sa = math.cos(angle), math.sin(angle)
    return points @ np.array([[ca, sa], [-sa, ca]]) + np.array(center)
