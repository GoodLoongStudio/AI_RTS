"""River topology and directed confluence regressions."""
import numpy as np
from scipy import ndimage
from shapely.geometry import LineString

from rtsmap.contract import G2_DEFAULTS
from rtsmap.gates.g2_rivers import tributary_curve
from rtsmap.gates.g2_strategy import connected_river
from rtsmap.pathing import compute_passable, bfs_components, cell_of


def test_tributaries_have_downstream_mouths_and_no_self_intersections():
    for seed in range(100):
        rng = np.random.default_rng(seed)
        direction = rng.normal(size=2)
        direction /= np.linalg.norm(direction)
        mouth = np.array([256., 256.])
        points, widths = tributary_curve(mouth, direction, (-1.)**seed, 120., 11., rng)
        arrival = points[-1]-points[-2]
        cosine = np.dot(arrival, direction)/np.linalg.norm(arrival)
        assert .5 < cosine < .95
        assert np.allclose(points[-1], mouth)
        assert LineString(points).is_simple
        assert np.all(np.diff(widths) > 0)
        assert widths[0] < widths[-1]*.3


def test_water_network_connects_without_covering_bridge_landings():
    starts = [(75., 75.), (437., 75.), (437., 437.), (75., 437.)]
    pairs = [(0, 1), (1, 2), (2, 3), (3, 0)]
    for seed in (16, 35, 61):
        rivers = connected_river(starts, [], pairs, dict(G2_DEFAULTS), np.random.default_rng(seed))
        assert len(rivers) == 2
        assert all(not river['tributaries'] for river in rivers)
        water = np.logical_or.reduce([river['mask'] for river in rivers])
        bridges = [b for river in rivers for b in river['bridges']]
        gaps = [g for river in rivers for g in river['gaps']]
        assert len(bridges) == 6
        assert ndimage.label(water)[1] == 1
        blocking = water & ~np.logical_or.reduce(gaps)
        for gap in gaps:
            labels = bfs_components(compute_passable(blocking | (water & gap)))
            ids = [labels[cell_of(*s)] for s in starts]
            assert ids[0] >= 0 and len(set(ids)) == 1
        for bridge in bridges:
            for x, y in (bridge['a'], bridge['b']):
                assert not water[int(y), int(x)]
