"""G2 parameter boundaries and the local HTTP contract; outputs stay in tmp_path."""
import copy
import io
import json
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from rtsmap.contract import ALGO_VERSION, G2_DEFAULTS
from rtsmap.gates import g2_layout as g2
from rtsmap.gates import g2_strategy as strategy
from rtsmap.grid import MapGrid, read_json, sha256_file, write_json
from rtsmap.pathing import bfs_components, erode8
from rtsmap.workbench import server as api
from rtsmap.workbench.settings import CONTROLS, DEFAULTS, CHECK_LABELS, SCHEMA_VERSION, generator_params, validate_config

PROJECT = Path(__file__).resolve().parents[1]


def config(**changes):
    # 注意：target 不属于可导出配置；需要 G2 快速预览时在请求体里加 target='g2'
    #（见 g2_body）；完整地图流水线（target='full'，默认）契约在 test_pipeline.py。
    return validate_config(dict(layout_seed=16, terrain_seed=0, controls=changes), [16, 35, 61])


def g2_body(**changes):
    body = config(**changes)
    body['target'] = 'g2'
    return body


def request(server, path, body=None, raw=None):
    data = json.dumps(body).encode() if body is not None else raw
    req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}{path}', data=data,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            status, headers, content = response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        status, headers, content = error.code, error.headers, error.read()
    if headers.get_content_type() == 'application/json':
        content = json.loads(content, parse_constant=lambda value: pytest.fail(f'Non-standard JSON: {value}'))
    return status, headers, content


@pytest.fixture
def server(tmp_path):
    server = api.make_server(PROJECT, port=0, output=tmp_path)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield server
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


def finished(server, job_id, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, _, job = request(server, f'/api/jobs/{job_id}')
        assert status == 200
        if job['status'] != 'running':
            return job
        time.sleep(.05)
    pytest.fail('Generator did not finish within test deadline')


def test_config_defaults_and_parameter_mapping():
    c = config()
    assert c['algo_version'] == ALGO_VERSION['G2']
    assert c['schema_version'] == SCHEMA_VERSION
    assert generator_params(c) == G2_DEFAULTS
    changed = generator_params(config(plateau_max=6, river_width=18, obstacle_percent=20,
                                       landform_recess=.28, plateau_ramp_width=12))
    assert changed['plateau_count'] == (4, 6)
    assert changed['river_width'] == (16., 20.)
    assert changed['cover_target_frac'] == .2
    assert changed['landform_recess'] == .28 and changed['plateau_ramp_width'] == 12
    for key in ('ground_level', 'plateau_level', 'home_radius', 'home_plateau_count',
                'obstacle_frac_min', 'obstacle_frac_max', 'fairness_ratio', 'plateau_fair_ratio',
                'expansion_fair_ratio', 'contest_fair_ratio', 'route_width_min'):
        assert changed[key] == G2_DEFAULTS[key], key


def test_bad_configs_rejected_and_range_endpoints_supported():
    invalid = [None, [], {'layout_seed': True}, {'layout_seed': 99},
               {'layout_seed': 16, 'terrain_seed': -1}, {'layout_seed': 16, 'terrain_seed': 1.5},
               {'layout_seed': 16, 'terrain_seed': 2147483648},
               {'layout_seed': 16, 'schema_version': True},
               {'layout_seed': 16, 'algo_version': '7.1.0'},
               {'layout_seed': 16, 'controls': {'home_radius': 0}},
               {'layout_seed': 16, 'controls': {'plateau_ramp_width': True}},
               {'layout_seed': 16, 'controls': {'river_width': float('nan')}},
               {'layout_seed': 16, 'controls': {'river_width': float('inf')}},
               {'layout_seed': 16, 'controls': {'river_crossings': 2.5}},
               {'layout_seed': 16, 'controls': {'layout_attempts': 5}}]
    for value in invalid:
        with pytest.raises(ValueError):
            validate_config(value, [16, 35, 61])
    for control in CONTROLS:
        for bound in ('min', 'max'):
            assert config(**{control['key']: control[bound]})['controls'][control['key']] == control[bound]


@pytest.mark.parametrize('knob,low,high', [
    ('landform_elongation', 1., 1.6), ('landform_recess', .08, .3), ('landform_softness', .05, .28),
])
def test_shape_controls_change_real_geometry_and_keep_home_clearance(knob, low, high):
    masks = []
    for value in (low, high):
        params = generator_params(config(**{knob: value}))
        plateau = strategy.make_plateau((128, 128), 27, 'home', 0, [], [(200,128), (50,128)],
            strategy.empty(), params, np.random.default_rng(71), dict(angle=.4, bend_x=.2, bend_z=-.2))
        assert plateau is not None
        assert plateau['interior'][g2._dist_field(128, 128) <= 20].all()
        assert bfs_components(plateau['interior']).max() == 0
        masks.append(plateau['region'])
    assert not np.array_equal(*masks), f'{knob} only changed metadata'


def test_shape_extremes_do_not_split_or_erode_the_home():
    from rtsmap.gates.g2_landforms import landform_outline, polygon_mask
    rng = np.random.default_rng(720)
    for index in range(16):
        outline = landform_outline((128,128), 27, float(rng.uniform(0, np.pi)), rng, home=True,
            elongation=1.6 if index % 2 else 1., recess_depth=.3 if index % 4 else .08,
            softness=.28 if index % 3 else .05)
        region = polygon_mask(outline)
        interior = erode8(erode8(region))
        assert interior[g2._dist_field(128,128) <= 20].all()
        assert bfs_components(interior).max() == 0


def test_crossing_control_matches_actual_bridges_without_splitting_river():
    starts = read_json(PROJECT / 'runs/16/G1/mapspec.json')['starts']
    polar = g2.polar_order(starts)
    pairs = [(polar[i], polar[(i+1)%4]) for i in range(4)]
    masks = []
    for count in (2,3,4):
        params = generator_params(config(river_crossings=count, river_width=18))
        river = strategy.connected_river(starts, [], pairs, params, np.random.default_rng(71))[0]
        assert len(river['bridges']) == count
        assert bfs_components(river['mask']).max() == 0
        masks.append(river['mask'])
    assert all(np.array_equal(masks[0], mask) for mask in masks[1:])


def test_bootstrap_uses_source_versions_and_real_artifacts(server):
    status, _, boot = request(server, '/api/bootstrap')
    assert status == 200 and boot['schema_version'] == SCHEMA_VERSION
    assert len(boot['layouts']) == 30
    assert [p['seed'] for p in boot['layouts'] if p['approved']] == [16,35,61]
    assert boot['fixed']['plateau_height_difference_m'] == 3
    assert {c['key'] for c in boot['controls']} == set(DEFAULTS)
    source = next(job for job in boot['jobs'] if job['id'] == 'baseline-16')
    assert source['config']['algo_version'] == source['result']['version'] == '7.1.0'
    for name in ('overview.png', 'strategy.png'):
        status, _, raw = request(server, f'/artifacts/baseline-16/{name}')
        assert status == 200
        with Image.open(io.BytesIO(raw)) as preview:
            assert preview.size == (2048,2048)
    status, _, exported = request(server, '/artifacts/baseline-16/config.json')
    assert status == 200 and exported == source['config']
    assert request(server, '/api/generate', body=exported)[0] == 400, 'Do not silently replay old versions as current'
    assert request(server, '/artifacts/baseline-16/unknown.json')[0] == 404
    assert request(server, '/api/generate', raw=b'{')[0] == 400
    assert request(server, '/api/generate', body={'layout_seed': 99})[0] == 400


def test_busy_job_error_and_restart_are_explicit(server, monkeypatch):
    entered, release = threading.Event(), threading.Event()

    def fail_after_release(*args, on_progress, **kwargs):
        on_progress(dict(attempt=1, limit=8, phase='test candidate'))
        entered.set()
        release.wait(timeout=10)
        raise g2.NoTerrainCandidate(16, [dict(attempt=1, rejected='No room for the terrain')])

    monkeypatch.setattr(api, 'run_one', fail_after_release)
    status, _, first = request(server, '/api/generate', body=g2_body())
    assert status == 202 and first['status'] == 'running'
    assert entered.wait(timeout=5)
    try:
        assert request(server, '/api/generate', body=g2_body())[0] == 409
        _, _, state = request(server, '/api/jobs')
        assert state['active'] == first['id']
        assert request(server, f"/artifacts/{first['id']}/overview.png")[0] == 404
        reloaded = api.Workbench(PROJECT, server.app.output)
        assert reloaded.get(first['id'])['error_kind'] == 'interrupted'
    finally:
        release.set()
    final = finished(server, first['id'], timeout=15)
    assert final['status'] == 'error' and final['error_kind'] == 'no_candidate'
    assert final['attempts'][0]['rejected'] == 'No room for the terrain'
    assert server.app.active is None
    assert not (server.app.output / first['id'] / 'runs/16/G2/mapgrid.npz').exists()
    reloaded = api.Workbench(PROJECT, server.app.output)
    assert reloaded.get(first['id'])['error_kind'] == 'no_candidate'


def test_fail_result_stays_done_but_never_becomes_pass(server, monkeypatch):
    source = read_json(PROJECT / 'runs_v7_1/16/G2/mapspec.json')
    source.update(all_pass=False, plateau_fair_ratio=float('inf'))
    source['checks']['plateau_fair_pass'] = False
    monkeypatch.setattr(api, 'run_one', lambda *a, **kw: {'mapspec': source})
    monkeypatch.setattr(api, 'build_g2_review', lambda *a, **kw: None)
    status, _, job = request(server, '/api/generate', body=g2_body())
    assert status == 202
    result = finished(server, job['id'], timeout=15)
    assert result['status'] == 'done'
    assert result['result']['all_pass'] is False
    assert result['result']['neutral_ratio'] is None
    assert not result['result']['checks']['plateau_fair_pass']


def test_storage_failure_does_not_leave_busy_state(server, monkeypatch):
    def broken_save(*a):
        raise OSError('test storage failure')
    monkeypatch.setattr(server.app, '_save', broken_save)
    assert request(server, '/api/generate', body=g2_body())[0] == 500
    assert server.app.active is None
    assert all(j['baseline'] for j in server.app.listing())


def test_changed_inputs_or_outputs_never_inherit_approval(tmp_path):
    from rtsmap.gate import new_manifest, manifest_path
    original = new_manifest(16, 'G2', 12, ALGO_VERSION['G2'], {}, 'g1-a', {'grid': 'g2-a'})
    original.update(approved=True, approved_note='Test fixture', approved_at='test')
    path = manifest_path(tmp_path, 16, 'G2')
    path.parent.mkdir(parents=True)
    write_json(path, original)
    for input_hash, output_hash, expected in [('g1-a', {'grid':'g2-a'}, True),
            ('g1-b', {'grid':'g2-a'}, False), ('g1-a', {'grid':'g2-b'}, False)]:
        current = new_manifest(16, 'G2', 12, ALGO_VERSION['G2'], {}, input_hash, output_hash)
        g2._inherit_approval(tmp_path, 16, 'G2', current, ALGO_VERSION['G2'])
        assert current['approved'] is expected


def test_real_http_generation_and_terrain_seed_replay(server):
    """A real POST -> generator -> images -> bundle -> restart path, plus replay."""
    source_files = list((PROJECT / 'runs/16/G1').iterdir())
    source_hashes = {p.name: sha256_file(p) for p in source_files if p.is_file()}
    results = []
    for terrain_seed in (0, 101, 101):
        c = config(river_crossings=4, plateau_ramp_width=10) if terrain_seed else config()
        c['terrain_seed'] = terrain_seed
        c['target'] = 'g2'
        status, _, initial = request(server, '/api/generate', body=c)
        assert status == 202
        job = finished(server, initial['id'])
        assert job['status'] == 'done', job
        folder = server.app.output / job['id'] / 'runs/16'
        spec = read_json(folder / 'G2/mapspec.json')
        assert spec['params'] == json.loads(json.dumps(generator_params(c)))
        assert spec['master_seed'] == 16
        assert len(spec['bridges']) == c['controls']['river_crossings']
        assert spec['all_pass'] == all(spec['checks'].values()) == job['result']['all_pass']
        assert set(spec['checks']) <= set(CHECK_LABELS)
        assert not read_json(folder / 'G2/manifest.json')['approved']
        for p in source_files:
            if p.is_file():
                assert sha256_file(folder / 'G1' / p.name) == source_hashes[p.name] == sha256_file(p)
        grid = MapGrid.load(folder / 'G2/mapgrid.npz')
        assert np.array_equal(grid.get('territory'), MapGrid.load(folder / 'G1/mapgrid.npz').get('territory'))
        results.append((job, [sha256_file(folder / 'G2' / name) for name in ('mapgrid.npz','mapspec.json','lanes.json','report.json')]))
    assert results[0][1][0] != results[1][1][0], 'Changing terrain Seed must change real geometry'
    assert results[1][1] == results[2][1], 'Same terrain Seed and controls must reproduce bytes'
    job = results[1][0]
    for name in ('overview.png','strategy.png'):
        status, _, raw = request(server, f"/artifacts/{job['id']}/{name}")
        assert status == 200
        with Image.open(io.BytesIO(raw)) as img:
            assert img.size == (2048,2048)
    status, _, blob = request(server, f"/artifacts/{job['id']}/bundle.zip")
    assert status == 200
    with zipfile.ZipFile(io.BytesIO(blob)) as bundle:
        assert '16/G2/mapgrid.npz' in bundle.namelist()
        assert json.loads(bundle.read('config.json')) == job['config']
        assert not json.loads(bundle.read('16/G2/manifest.json'))['approved']
    restored = api.Workbench(PROJECT, server.app.output)
    assert restored.get(job['id'])['result'] == job['result']
