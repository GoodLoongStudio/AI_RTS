import numpy as np
from rtsmap import pathing as p


def test_compiled_paths_preserve_costs_ties_and_corner_rules():
    rng = np.random.default_rng(513)
    for _ in range(20):
        grid = rng.random((25, 31)) > .25
        grid[1, 1] = True
        for dst in (None, (22, 28), (1, 1), (4, 7)):
            expected, route = p._dijkstra_reference(grid, (1, 1), dst)
            actual, native_route = p.dijkstra(grid, (1, 1), dst)
            np.testing.assert_allclose(actual, expected, rtol=0, atol=1e-10)
            assert native_route == route
        np.testing.assert_array_equal(p.bfs_components(grid), p._bfs_reference(grid))
        np.testing.assert_array_equal(p.label8(grid), p._label8_reference(grid))


def test_native_polyline_projection():
    for pts in ([[0, 0], [18, 27], [83, 31]], [[5, 5], [5, 5]], []):
        actual = p.polyline_field(pts)
        expected = p._polyline_field_reference(pts)
        for a, b in zip(actual, expected):
            np.testing.assert_allclose(a, b, rtol=1e-12, atol=1e-10)
