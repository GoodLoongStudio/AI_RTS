"""Bounded rasterization must preserve every cell of the original algorithms."""
import numpy as np

from rtsmap.contract import GRID_H, GRID_W
from rtsmap.gates.g2_landforms import landform_outline, polygon_mask
from rtsmap.gates.g2_layout import segment_mask
from rtsmap.pathing import polyline_field


def test_segment_mask_matches_full_distance_field():
    rng = np.random.default_rng(24)
    for _ in range(24):
        a, b = rng.uniform(-50, GRID_W + 50, (2, 2))
        width = rng.uniform(0, 40)
        distance, _ = polyline_field([a, b])
        assert np.array_equal(segment_mask(a, b, width), distance <= width / 2)
    assert not segment_mask([4, 4], [4, 4], 10).any()


def test_polygon_mask_matches_full_even_odd_fill():
    rng = np.random.default_rng(53)
    x, z = np.meshgrid(np.arange(GRID_W) + .5, np.arange(GRID_H) + .5)
    for center in [(-20, 40), (0, 0), (256, 256), (512, 512), (600, 40)]:
        points = landform_outline(center, 35, .4, rng)
        expected = np.zeros((GRID_H, GRID_W), dtype=bool)
        for a, b in zip(points, np.roll(points, -1, axis=0)):
            if abs(b[1] - a[1]) < 1e-9:
                continue
            crosses = (a[1] > z) != (b[1] > z)
            edge_x = a[0] + (z-a[1])*(b[0]-a[0])/(b[1]-a[1])
            expected ^= crosses & (x < edge_x)
        assert np.array_equal(polygon_mask(points), expected)
