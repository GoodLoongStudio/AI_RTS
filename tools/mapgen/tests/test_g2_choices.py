"""Player-facing options must change real map data while preserving G1 and checks."""
import shutil
from pathlib import Path

import numpy as np
import pytest

from rtsmap.gates import g2_layout as g2
from rtsmap.grid import MapGrid, read_json, sha256_file
from rtsmap.gate import ensure_upstream_approved
from rtsmap.pathing import bfs_components
from rtsmap.workbench.catalog import layout_catalog
from rtsmap.workbench.settings import validate_config, generator_params, G2_DEFAULTS

PROJECT = Path(__file__).resolve().parents[1]


def test_full_existing_layout_library_and_distances():
    layouts = layout_catalog(PROJECT)
    assert len(layouts) == 30
    assert {k: sum(p['spacing'] == k for p in layouts) for k in ('close', 'standard', 'far')} == dict(close=19, standard=6, far=5)
    for layout in layouts:
        original = read_json(PROJECT / 'runs' / str(layout['seed']) / 'G1/mapspec.json')
        assert layout['starts'] == original['starts']
        assert original['accepted'] and all(c['pass'] for c in original['constraints'].values())


@pytest.mark.parametrize('seed,river,lakes', [
    (16, 0, 0), (16, 0, 1), (16, 1, 0), (16, 1, 1),   # seed16 适配组合
    (14, 0, 2),                                    # 双湖无河适配布局（scan 实测 pass）
    (47, 1, 2),                                    # 河+双湖适配布局（scan 实测 pass）
])
def test_water_choices_are_real_connected_geometry(tmp_path, seed, river, lakes):
    shutil.copytree(PROJECT / f'runs/{seed}/G1', tmp_path / f'{seed}/G1')
    config = validate_config(dict(layout_seed=seed, controls=dict(river_enabled=river, lake_count=lakes, layout_attempts=16)), [seed])
    params = generator_params(config)
    for key in ('obstacle_frac_min','obstacle_frac_max','fairness_ratio','home_radius','route_width_min'):
        assert params[key] == G2_DEFAULTS[key]
    result = g2.run_one(seed, tmp_path, params, auto=True)
    spec, grid = result['mapspec'], result['grid']
    assert spec['all_pass'], spec['generation']
    assert len(spec['rivers']) == river and len(spec['lakes']) == lakes
    assert len(spec['bridges']) == (3 if river else 0)
    footprint = grid.get('water_footprint').astype(bool)
    assert int(bfs_components(footprint).max()) + 1 == river + lakes
    assert int(bfs_components(grid.get('passable')).max()) == 0
    assert np.array_equal(grid.get('territory'), MapGrid.load(tmp_path / f'{seed}/G1/mapgrid.npz').get('territory'))
    water = footprint & (grid.get('blocking') > 0)
    assert (grid.get('terrain')[water] == 5).all()
    assert np.allclose(grid.get('height')[water], -2.4)
    # 湖泊面积不被缩小（标准 3000±2%）
    for lake in spec.get('lakes', []):
        assert abs(lake['area_m2'] - G2_DEFAULTS['lake_area']) <= G2_DEFAULTS['lake_area'] * 0.02


def test_known_hard_combo_fails_cleanly_without_shrinking_water(tmp_path):
    """seed16 + 河+双湖 为已知空间冲突：应明确报无候选，且不产出缩小湖冒充通过。"""
    seed, river, lakes = 16, 1, 2
    shutil.copytree(PROJECT / f'runs/{seed}/G1', tmp_path / f'{seed}/G1')
    config = validate_config(dict(layout_seed=seed, controls=dict(river_enabled=river, lake_count=lakes, layout_attempts=16)), [seed])
    params = generator_params(config)
    with pytest.raises(g2.NoTerrainCandidate):
        g2.run_one(seed, tmp_path, params, auto=True)
    # 无候选 => 不应存在任何 G2 产物湖/河被“缩小后通过”
    assert not (tmp_path / f'{seed}/G2/mapgrid.npz').exists()


def test_unapproved_g1_preview_preserves_source_and_formal_gate(tmp_path):
    seed = 14  # existing medium-distance layout, accepted but not formally approved
    source = PROJECT / 'runs' / str(seed) / 'G1'
    before = {p.name: sha256_file(p) for p in source.iterdir() if p.is_file()}
    shutil.copytree(source, tmp_path / str(seed) / 'G1')
    assert not read_json(source / 'manifest.json')['approved']
    with pytest.raises(RuntimeError):
        ensure_upstream_approved(tmp_path, seed, 'G2')
    result = g2.run_preview(seed, tmp_path, dict(G2_DEFAULTS))
    assert result['mapspec']['starts'] == read_json(source / 'mapspec.json')['starts']
    assert result['mapspec']['checks']['spawn_layout_pass']
    assert result['mapspec']['preview_only']
    for gate in ('G1', 'G2'):
        assert not read_json(tmp_path / str(seed) / gate / 'manifest.json')['approved']
    with pytest.raises(RuntimeError):
        ensure_upstream_approved(tmp_path, seed, 'G3')
    for name, digest in before.items():
        assert sha256_file(source / name) == digest == sha256_file(tmp_path / str(seed) / 'G1' / name)
