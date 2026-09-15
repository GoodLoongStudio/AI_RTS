"""G2 v7 regression tests. All generation writes to pytest temporary directories."""
import json
import shutil
from pathlib import Path

import numpy as np
import pytest

from rtsmap.contract import ALGO_VERSION, G2_DEFAULTS, GRID_H, GRID_W
from rtsmap.gates import g2_layout as g2
from rtsmap.gates import g2_strategy as strategy
from rtsmap.gates.g2_landforms import polygon_mask, landform_outline
from rtsmap.grid import MapGrid, sha256_file
from rtsmap.pathing import bfs_components, cell_of, polyline_field
from rtsmap.rng import gate_rng

SOURCE = Path(__file__).resolve().parents[1] / 'runs'
SEEDS = (16, 35, 61)


@pytest.fixture(scope='module', params=SEEDS)
def generated(request, tmp_path_factory):
    seed = request.param
    root = tmp_path_factory.mktemp(f'g2_{seed}')
    shutil.copytree(SOURCE / str(seed) / 'G1', root / str(seed) / 'G1')
    return g2.run_one(seed, root, dict(G2_DEFAULTS))


def test_acceptance(generated):
    checks = generated['mapspec']['checks']
    assert all(checks.values()), [name for name, ok in checks.items() if not ok]
    assert generated['mapspec']['algo_version'] == ALGO_VERSION['G2']


def test_kit_bindings_share_navigation_authority(generated):
    spec = generated['mapspec']
    bindings = spec['kit_bindings']
    contract = spec['navigation_contract']
    assert bindings['walkable_plateau_ramp'] == 'plateau_ramp'
    assert bindings['blocked_cliff_and_mountain'] == 'sandstone_mountain'
    assert contract['walkable_channel'] == 'passable'
    assert contract['blocking_channel'] == 'blocking'
    assert contract['height_channel'] == 'height'
    assert contract['agent_max_climb_m'] == 0.5


def test_g1_unchanged(generated):
    parent = MapGrid.load(SOURCE / str(generated['seed']) / 'G1' / 'mapgrid.npz')
    for name, channel in parent.channels.items():
        assert np.array_equal(channel, generated['grid'].get(name))
    source = json.loads((SOURCE / str(generated['seed']) / 'G1' / 'mapspec.json').read_text(encoding='utf-8'))
    assert generated['mapspec']['starts'] == source['starts']


def test_navigation_connectivity(generated):
    geom = generated['geom']
    labels = bfs_components(generated['grid'].get('passable'))
    assert labels.max() == 0, 'Every navigable cell must belong to the main component'
    points = generated['starts'] + geom['exp_anchors']
    points += [p['center'] for p in geom['plateaus']]
    points += [rc for p in geom['plateaus'] for rc in p['ramp_centers']]
    points += [v for br in geom['bridges'] for v in (br['a'], br['b'])]
    assert all(labels[cell_of(*p)] == 0 for p in points)


def test_connected_water_and_real_crossings(generated):
    geom, grid = generated['geom'], generated['grid']
    footprint = grid.get('water_footprint').astype(bool)
    assert np.array_equal(footprint, geom['water_union'])
    # Using navigation connectivity disallows a diagonal-only water connection.
    assert bfs_components(footprint).max() == 0
    assert len(geom['bridges']) >= 2
    for river in geom['rivers']:
        for x, z in (river['polyline'][0], river['polyline'][-1]):
            assert x in (0, GRID_W) or z in (0, GRID_H)
    bridge = strategy.empty()
    for river in geom['rivers']:
        for mask in river['gaps']:
            bridge |= mask
    assert (grid.get('blocking')[footprint & ~bridge] == 1).all()
    assert np.allclose(grid.get('height')[footprint & ~bridge], -2.4)
    assert (grid.get('blocking')[footprint & bridge] == 0).all()
    assert np.allclose(grid.get('height')[footprint & bridge], .6)
    # Removing bridge decks must separate the banks, proving these cross water.
    bank = bfs_components(~footprint)
    for br in geom['bridges']:
        assert bank[cell_of(*br['a'])] >= 0
        assert bank[cell_of(*br['b'])] >= 0
        assert bank[cell_of(*br['a'])] != bank[cell_of(*br['b'])]


def test_plateau_semantics_and_ownership(generated):
    geom, grid = generated['geom'], generated['grid']
    block, height = grid.get('blocking'), grid.get('height')
    for plateau in geom['plateaus']:
        # The exported silhouette must describe the actual gameplay footprint.
        assert np.array_equal(polygon_mask(np.array(plateau['outline'])), plateau['region'])
        assert len(plateau['ramp_centers']) >= 2
        assert (block[plateau['interior']] == 0).all()
        assert np.allclose(height[plateau['interior']], 3.6)
        cliff = plateau['ring'] & ~plateau['ramps']
        ramp = plateau['ring'] & plateau['ramps']
        assert cliff.any() and ramp.any()
        assert (block[cliff] == 1).all()
        assert (block[ramp] == 0).all()
        assert np.allclose(height[ramp], 2.1)
        if plateau['kind'] == 'home':
            start = generated['starts'][plateau['owner']]
            assert plateau['interior'][cell_of(*start)]
            assert plateau['interior'][g2._dist_field(*start) <= 20.].all()
        else:
            assert plateau['owner'] is None
            assert plateau['controlled_routes']
            for route in plateau['controlled_routes']:
                line = geom['lanes'][route + '_r0']['polyline']
                dist, _ = polyline_field(line)
                assert dist[plateau['region']].min() <= G2_DEFAULTS['plateau_route_reach']
            if plateau['kind'] == 'central':
                assert np.linalg.norm(np.array(plateau['center']) - (128., 128.)) <= 46.


def test_home_clearance_and_legal_channels(generated):
    grid = generated['grid']
    for start in generated['starts']:
        assert (grid.get('blocking')[g2._dist_field(*start) <= 20.] == 0).all()
    assert set(np.unique(grid.get('terrain'))) <= {0, 1, 2, 3, 4, 5}
    assert (grid.get('terrain')[grid.get('blocking') > 0] != 2).all(), 'Natural outcrops cannot become ruins'
    assert (grid.get('terrain')[grid.get('blocking') > 0] != 3).all(), 'Long outcrops cannot become artificial walls'
    assert set(np.round(np.unique(grid.get('height')), 2)) <= set(np.array([-2.4, .6, 2.1, 3.6], dtype=np.float32))


def test_routes_follow_terrain_and_have_alternatives(generated):
    lanes, grid = generated['lanes'], generated['grid']
    for lane in lanes.values():
        dist, _ = polyline_field(lane['polyline'])
        assert (grid.get('passable')[dist <= .75] == 1).all()
    for k in range(4):
        main, alternate = lanes[f'pair_{k}_r0'], lanes[f'pair_{k}_r1']
        main_d, _ = polyline_field(main['polyline'])
        # Alternatives must leave the main corridor, not just rename its polyline.
        separation = max(main_d[cell_of(*p)] for p in alternate['polyline'])
        assert separation >= 10.


def test_determinism(tmp_path):
    seed = SEEDS[0]
    shutil.copytree(SOURCE / str(seed) / 'G1', tmp_path / str(seed) / 'G1')
    paths = ['mapgrid.npz', 'mapspec.json', 'lanes.json', 'report.json']
    a = g2.run_one(seed, tmp_path, dict(G2_DEFAULTS))
    before = [sha256_file(a['run_dir'] / name) for name in paths]
    b = g2.run_one(seed, tmp_path, dict(G2_DEFAULTS))
    after = [sha256_file(b['run_dir'] / name) for name in paths]
    assert before == after
    assert not json.loads((b['run_dir'] / 'manifest.json').read_text(encoding='utf-8'))['approved']


def test_central_spawn_gets_real_high_ground():
    starts = [(128., 128.), (38., 40.), (224., 55.), (120., 226.)]
    params = dict(G2_DEFAULTS)
    geom = strategy.build_geometry(starts, g2.polar_order(starts), params,
                                  gate_rng(2026, 'G2', ALGO_VERSION['G2']))
    center_home = [p for p in geom['plateaus'] if p['kind'] == 'home' and p['owner'] == 0]
    assert len(center_home) == 1
    assert center_home[0]['interior'][cell_of(128., 128.)]
    assert len(center_home[0]['ramp_centers']) >= 2
    assert all(n['kind'] != 'neutral' or np.linalg.norm(np.array(n['xy']) - (128.,128.)) > 20 for n in geom['contest'])


def test_morphology_does_not_wrap_map_edges():
    mask = strategy.empty()
    mask[80:100, :5] = True
    assert not g2._dil(mask)[:, -1].any()
    assert not g2.smooth_mask(mask)[:, -1].any()


def test_recessed_home_outlines_keep_flat_build_space():
    """Corner cutting and concavity must not eat the build disc or split the top."""
    from rtsmap.pathing import erode8
    rng = np.random.default_rng(710)
    for index in range(48):
        center = (70.25, 90.75) if index % 2 else (128., 128.)
        outline = landform_outline(center, 27. + index % 5, float(rng.uniform(0, np.pi)), rng, home=True)
        region = polygon_mask(outline)
        interior = erode8(erode8(region))
        assert interior[g2._dist_field(*center) <= 20.].all()
        assert bfs_components(interior).max() == 0
        # No enclosed voids from the inlet; open ground still surrounds the landmass.
        assert bfs_components(~region).max() == 0
