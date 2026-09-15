"""完整地图流水线契约测试（HTTP 层 + 编排层；引擎/闸门用受控替身，秒级完成）。

真实几何/引擎验收由 test_g2*.py、test_g3.py、test_visual_api.py 与基准地图
实跑日志承担；本文件验证任务模型：唯一 ID、阶段状态机、上游失败不运行下游、
重试输入不变、重启中断标记、地图包内容、视觉重建隔离。
"""
import json
import threading
import time
import zipfile
from pathlib import Path

import numpy as np
import pytest

from rtsmap.contract import ALGO_VERSION
from rtsmap.workbench import server as api
from rtsmap.workbench.settings import validate_config

PROJECT = Path(__file__).resolve().parents[1]
SEED = 16


def body(**changes):
    config = validate_config(dict(layout_seed=SEED, terrain_seed=0, controls=changes), [SEED])
    config['target'] = 'full'
    return config


def request(server, path, body_=None):
    import urllib.error
    import urllib.request
    data = json.dumps(body_).encode() if body_ is not None else None
    req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}{path}', data=data,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            status, content = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, content = error.code, error.read()
    if content and (content[:1] in (b'{', b'[')):
        content = json.loads(content)
    return status, content


def finished(server, job_id, timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status, job = request(server, f'/api/jobs/{job_id}')
        assert status == 200
        if job['status'] != 'running':
            return job
        time.sleep(.05)
    pytest.fail('Pipeline did not finish within test deadline')


G2_SPEC = {
    'gate': 'G2', 'master_seed': SEED, 'algo_version': ALGO_VERSION['G2'],
    'all_pass': True, 'solid_frac': 0.15,
    'starts': [[58.2, 179.5], [84.2, 54.6], [180.8, 191.5], [210.2, 96.3]],
    'plateaus': [dict(center=[58.2, 179.5], kind='home', owner=1, ramp_centers=[], ramp_dirs=[],
                      outline=[], landform_angle=0, controlled_routes=[])],
    'rivers': [], 'lakes': [], 'bridges': [],
    'expansion_anchors': [[34.5, 145.5], [55.5, 22.5], [143.5, 208.5], [227.5, 59.5]],
    'flank_anchors': [], 'keypoints': [], 'gap_centers': [],
    'strategy_metrics': dict(crossings=0, expansion_ratio=1.1, water_components=0),
    'path_fairness': dict(flank_ratio=1.2),
    'lane_widths': {'pair_0_r0': 8.0},
    'plateau_fair_ratio': 1.3,
    'generation': dict(chosen_attempt=2, attempts=[dict(attempt=1, failed_checks=['x']),
                                                    dict(attempt=2, failed_checks=[])]),
    'checks': {'solid_frac_pass': True, 'open_single_pass': True},
}


def _write_gate(runs, gate, spec_extra=None, all_pass=True):
    rd = runs / str(SEED) / gate
    rd.mkdir(parents=True, exist_ok=True)
    np.savez(rd / 'mapgrid.npz', territory=np.zeros((4, 4), dtype=np.uint16))
    spec = dict(G2_SPEC)
    spec.update(gate=gate, algo_version=ALGO_VERSION[gate])
    if spec_extra:
        spec.update(spec_extra)
    spec['all_pass'] = all_pass
    (rd / 'mapspec.json').write_text(json.dumps(spec), encoding='utf-8')
    (rd / 'manifest.json').write_text(json.dumps(dict(
        gate=gate, algo_version=ALGO_VERSION[gate], approved=False,
        input_hash='in', output_hash={'mapgrid.npz': 'out', 'mapspec.json': 'spec'})),
        encoding='utf-8')
    return rd


@pytest.fixture
def pipeline_server(tmp_path, monkeypatch):
    """受控替身：闸门与引擎全部本地模拟，产物结构真实。"""
    from rtsmap.gates import g2_layout, g3_content, g4_export
    from rtsmap.workbench import engine as engine_mod
    from rtsmap.workbench import pipeline as pipeline_mod
    from rtsmap.workbench import review_sync as review_sync_mod

    fail_engine = {'value': False}
    fail_g2 = {'value': False}
    scene_builds = []

    def fake_g2(seed, runs, params, on_progress=None, auto=False):
        assert auto is True, '流水线必须使用显式 auto 模式而非人工 approval'
        if on_progress:
            on_progress(dict(attempt=1, limit=16, phase='test'))
        _write_gate(Path(runs), 'G2', all_pass=not fail_g2['value'])
        return {'mapspec': json.loads((Path(runs) / str(seed) / 'G2' / 'mapspec.json').read_text(encoding='utf-8'))}

    def fake_g3(seed, runs, params, auto=False):
        assert auto is True
        rd = _write_gate(Path(runs), 'G3', spec_extra=dict(
            instance_count=1500, resource_failures=[],
            resource_fairness={'quota_equal': True, 'pass': True},
            recheck=dict(components_pass=True, keypoints_pass=True, widths_pass=True,
                         path_fairness_pass=True, density_total_pass=True),
            removed_instances=[], blocking_frac=0.16, water_cells=0,
            cluster_cover_frac=0.95))
        (rd / 'recheck_report.json').write_text(json.dumps(dict(
            cluster_cover_pass=True, budget_pass=True, instance_count=1500, budget=2000)),
            encoding='utf-8')
        (rd / 'resources.json').write_text(json.dumps(dict(
            resources=[dict(id=0, type='A', x=66.5, z=173.5, owner='P0')], fairness={})),
            encoding='utf-8')
        (rd / 'objects.json').write_text(json.dumps(dict(instances=[], count=0)), encoding='utf-8')
        (rd / 'assets_used.json').write_text(json.dumps(dict(fbx=[], atlases=[])), encoding='utf-8')
        return {'mapspec': json.loads((rd / 'mapspec.json').read_text(encoding='utf-8'))}

    def fake_build_scene(map_id, runs, seed, out_dir, params, visual_seed=None):
        out_dir = Path(out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        scene_builds.append(dict(map_id=map_id, visual_seed=visual_seed,
                                 profile=params.get('visual_profile')))
        (out_dir / f'map_{map_id}.tscn').write_text('[gd_scene]\n; fake', encoding='utf-8')
        (out_dir / 'height_data.bin').write_bytes(b'\x00' * 64)
        rd = Path(runs) / str(seed) / 'G4'
        rd.mkdir(parents=True, exist_ok=True)
        (rd / 'export.json').write_text(json.dumps(dict(
            visual_dependencies=[], map_id=map_id, visual_seed=visual_seed)), encoding='utf-8')
        (rd / 'nav_targets.json').write_text(json.dumps(dict(targets=[], paths=[])), encoding='utf-8')
        (rd / 'heightfield_report.json').write_text(json.dumps(dict(
            walkable_slope_step_ok=True, max_step_walkable_m=0.4)), encoding='utf-8')
        (rd / 'visual_plan.json').write_text(json.dumps(dict(
            style_version='1.0.0', instances=[], stats=dict(total=0))), encoding='utf-8')
        return dict(tscn=out_dir / f'map_{map_id}.tscn', height_data=out_dir / 'height_data.bin',
                    height_data_sha256='fakehash',
                    hf_report=dict(walkable_slope_step_ok=True, max_step_walkable_m=0.4),
                    nav=dict(targets=[], paths=[]),
                    visual=dict(style_version='1.0.0', stats=dict(total=0), warnings=[],
                                asset_dependencies=[]),
                    map_id=map_id)

    def fake_install_map(out_dir, map_id, airts_root=None):
        return f'res://source/match/maps/generated/{map_id}/map_{map_id}.tscn', []

    def fake_import(airts, log_dir, timeout_s=2400):
        return dict(exit_code=0, duration_s=0.1, log='fake', cmd=[], timed_out=False)

    def fake_capture(airts, scene_res, out_png, log_dir, oblique=False, size=256,
                     timeout_s=600, flat=False, center=None, radius=None, iso45=False):
        Path(out_png).parent.mkdir(parents=True, exist_ok=True)
        Path(out_png).write_bytes(b'\x89PNG fake')
        return dict(exit_code=0, duration_s=0.1, log='fake', cmd=[], timed_out=False)

    def fake_nav(airts, scene_res, targets_json, out_json, log_dir, timeout_s=900):
        if fail_engine['value']:
            raise engine_mod.EngineError('模拟引擎失败')
        Path(out_json).write_text(json.dumps(dict(all_pass=True, bake_wait_s=1.2,
                                                  targets_checked=0, paths_checked=0)),
                                  encoding='utf-8')
        return {'exit_code': 0, 'duration_s': 0.1, 'log': 'fake', 'cmd': [],
                'timed_out': False, 'pass': True}

    monkeypatch.setattr(pipeline_mod.g2_layout, 'run_one', fake_g2)
    monkeypatch.setattr(pipeline_mod.g3_content, 'run_one', fake_g3)
    monkeypatch.setattr(pipeline_mod, 'build_g2_review', lambda *a, **k: None)
    monkeypatch.setattr(pipeline_mod, 'build_g3_review', lambda *a, **k: None)
    monkeypatch.setattr(g4_export, 'build_scene_text', fake_build_scene)
    monkeypatch.setattr(g4_export, 'install_map', fake_install_map)
    monkeypatch.setattr(g4_export, 'install_runtime_scripts', lambda airts_root=None: [])
    monkeypatch.setattr(g4_export, 'copy_assets', lambda *a, **k: ([], [], 0))
    monkeypatch.setattr(engine_mod, 'airts_root', lambda: str(tmp_path / 'fake_airts'))
    monkeypatch.setattr(engine_mod, 'import_assets', fake_import)
    monkeypatch.setattr(engine_mod, 'capture_ortho', fake_capture)
    monkeypatch.setattr(engine_mod, 'nav_check', fake_nav)
    # 测试不得写真实 review/、不跑慢速 PIL 联系图，也不与 retry 竞争 job.json
    monkeypatch.setattr(review_sync_mod, 'sync_jobs', lambda *a, **k: [])

    server = api.make_server(PROJECT, port=0, output=tmp_path / 'wb_out')
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    server.fail_engine = fail_engine
    server.fail_g2 = fail_g2
    server.scene_builds = scene_builds
    yield server
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


def test_full_pipeline_success_map_pass_and_bundle(pipeline_server):
    status, job = request(pipeline_server, '/api/generate', body())
    assert status == 202
    assert job['target'] == 'full' and job['status'] == 'running'
    result = finished(pipeline_server, job['id'])
    assert result['status'] == 'done', result
    assert result['map_pass'] is True
    # F1：map_id 纳入完整有效内容哈希（相同 Seed、不同参数不覆盖）
    from rtsmap.gates.g4_export import make_map_id
    mid = result['map_id']
    assert mid == make_map_id(SEED, 0, result['config'])
    assert mid.startswith(f'{SEED}-0-')
    for stage in ('g1_input', 'g2_terrain', 'g3_content', 'g4_scene', 'engine'):
        assert result['stages'][stage]['status'] == 'done', (stage, result['stages'][stage])
    assert result['stages']['g2_terrain']['pass'] is True
    assert result['stages']['engine']['nav_all_pass'] is True
    assert isinstance(result['visual_seed'], int)
    # 地图包：场景 + 高程数据 + 登记项 + 依赖清单 + 安装脚本 + 数据
    status, blob = request(pipeline_server, f"/artifacts/{job['id']}/bundle.zip")
    assert status == 200
    import io
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        names = archive.namelist()
        assert f'map_{mid}/source/map_{mid}.tscn' in names
        assert f'map_{mid}/source/height_data.bin' in names
        assert f'map_{mid}/source/map_index.json' in names
        assert f'map_{mid}/assets/dependencies.json' in names
        assert f'map_{mid}/install.ps1' in names
        assert any(n.startswith(f'map_{mid}/data/G2/') for n in names)
        index = json.loads(archive.read(f'map_{mid}/source/map_index.json'))
        assert index['path'] == f'res://source/match/maps/generated/{mid}/map_{mid}.tscn'
    # G1 源文件不变（正式 runs 只读）
    src = PROJECT / 'runs' / str(SEED) / 'G1' / 'mapspec.json'
    assert json.loads(src.read_text(encoding='utf-8'))['master_seed'] == SEED


def test_map_id_isolates_same_seed_different_params(tmp_path):
    """F1 验收：相同 layout_seed+terrain_seed、不同河湖参数的两项任务，
    得到不同 map_id，真实 install_map 写入不同目录，第二份不覆盖第一份。"""
    from rtsmap.gates import g4_export

    first = dict(layout_seed=SEED, terrain_seed=0, schema_version=2,
                 algo_version=ALGO_VERSION['G2'],
                 controls=dict(lake_count=0, river_enabled=1))
    second = dict(layout_seed=SEED, terrain_seed=0, schema_version=2,
                  algo_version=ALGO_VERSION['G2'],
                  controls=dict(lake_count=2, river_enabled=1, lake_area=4500))
    mid_a = g4_export.make_map_id(SEED, 0, first)
    mid_b = g4_export.make_map_id(SEED, 0, second)
    assert mid_a != mid_b, '相同 Seed、不同参数必须得到不同 map_id'
    # 相同配置稳定（重试/复现复用同一身份）
    assert mid_a == g4_export.make_map_id(SEED, 0, dict(first))

    airts = tmp_path / 'airts'
    outs = {}
    for tag, mid, marker in (('a', mid_a, 'FIRST'), ('b', mid_b, 'SECOND')):
        out = tmp_path / f'out_{tag}'
        out.mkdir()
        (out / f'map_{mid}.tscn').write_text(f'[gd_scene]\n; {marker}', encoding='utf-8')
        (out / 'height_data.bin').write_bytes(marker.encode())
        outs[tag] = out
    g4_export.install_map(outs['a'], mid_a, airts)
    g4_export.install_map(outs['b'], mid_b, airts)
    scene_a = airts / 'source/match/maps/generated' / mid_a / f'map_{mid_a}.tscn'
    scene_b = airts / 'source/match/maps/generated' / mid_b / f'map_{mid_b}.tscn'
    assert scene_a.exists() and scene_b.exists(), '两份安装必须各自存在'
    assert 'FIRST' in scene_a.read_text(encoding='utf-8'), '第一份不得被第二份覆盖'
    assert 'SECOND' in scene_b.read_text(encoding='utf-8')
    assert (airts / 'source/match/maps/generated' / mid_a / 'height_data.bin').read_bytes() == b'FIRST'


def test_g2_failure_stops_downstream_and_retry_keeps_inputs(pipeline_server):
    pipeline_server.fail_g2['value'] = True
    status, job = request(pipeline_server, '/api/generate', body())
    assert status == 202
    result = finished(pipeline_server, job['id'])
    assert result['status'] == 'done' and result['map_pass'] is False
    assert result['stages']['g2_terrain']['pass'] is False
    for stage in ('g3_content', 'g4_scene', 'engine'):
        assert result['stages'][stage]['status'] == 'skipped', stage
    config_before = result['config']
    # 重试保留同一已确定输入（同布局/地貌 Seed 与参数）
    pipeline_server.fail_g2['value'] = False
    status, retried = request(pipeline_server, f"/api/jobs/{job['id']}/retry", body_={})
    assert status == 202
    final = finished(pipeline_server, job['id'])
    if not final.get('map_pass'):
        print('DEBUG final stages:', json.dumps(
            {k: {kk: vv for kk, vv in v.items() if kk in ('status', 'pass', 'error')}
             for k, v in final['stages'].items()}, ensure_ascii=False))
        print('DEBUG checks_summary:', final.get('checks_summary'))
    assert final['status'] == 'done' and final['map_pass'] is True
    assert final['config'] == config_before
    assert final['id'] == job['id'], '重试不得创建新任务'


def test_engine_failure_is_explicit_and_retryable(pipeline_server):
    pipeline_server.fail_engine['value'] = True
    status, job = request(pipeline_server, '/api/generate', body())
    result = finished(pipeline_server, job['id'])
    assert result['status'] == 'error'
    assert result['error_kind'] == 'engine_error'
    assert result['stages']['engine']['status'] == 'error'
    # G2/G3/G4 阶段保留为 done：重试只补引擎段
    assert result['stages']['g4_scene']['status'] == 'done'
    pipeline_server.fail_engine['value'] = False
    status, _ = request(pipeline_server, f"/api/jobs/{job['id']}/retry", body_={})
    assert status == 202
    final = finished(pipeline_server, job['id'])
    assert final['status'] == 'done' and final['map_pass'] is True


def test_restart_marks_running_job_interrupted(pipeline_server, tmp_path):
    status, job = request(pipeline_server, '/api/generate', body())
    assert status == 202
    result = finished(pipeline_server, job['id'])
    folder = pipeline_server.app.output / job['id']
    raw = json.loads((folder / 'job.json').read_text(encoding='utf-8'))
    raw['status'] = 'running'
    raw['stages']['engine']['status'] = 'running'
    (folder / 'job.json').write_text(json.dumps(raw), encoding='utf-8')
    reloaded = api.Workbench(PROJECT, pipeline_server.app.output)
    restored = reloaded.get(job['id'])
    assert restored['status'] == 'error' and restored['error_kind'] == 'interrupted'
    assert restored['stages']['engine']['status'] == 'error'


def test_rebuild_visual_requires_full_job_and_records_versions(pipeline_server):
    status, job = request(pipeline_server, '/api/generate', body())
    result = finished(pipeline_server, job['id'])
    assert result['map_pass'] is True
    seed_before = result['visual_seed']
    status, rebuilt = request(pipeline_server, f"/api/jobs/{job['id']}/rebuild_visual",
                              body_={'visual_seed': 424242})
    assert status == 202
    final = finished(pipeline_server, job['id'])
    assert final['status'] == 'done'
    assert final['visual_seed'] == 424242
    assert final['visual_version'] == 2
    assert final['visual_history'][0]['version'] == 1
    assert final['config'] == result['config'], '视觉重建不得改变逻辑输入'


def test_rebuild_visual_persists_profile_through_second_build(pipeline_server):
    """F3：非默认 profile 必须在 rebuild_visual→_build_g4→_run_engine 导入后
    重建场景的全链保持一致，不能第二次构建时静默回退 default。"""
    status, job = request(pipeline_server, '/api/generate', body())
    result = finished(pipeline_server, job['id'])
    assert result['map_pass'] is True
    pipeline_server.scene_builds.clear()
    status, _ = request(pipeline_server, f"/api/jobs/{job['id']}/rebuild_visual",
                        body_={'visual_seed': 999, 'profile': 'natural'})
    assert status == 202
    final = finished(pipeline_server, job['id'])
    assert final['status'] == 'done'
    assert final['visual_profile'] == 'natural'
    assert final['visual_version'] == 2
    # 关键：rebuild 会调 build_scene_text 两次（_build_g4 一次、_run_engine 导入后
    # 重写一次）；两次都必须用 natural。旧缺陷：第二次从未保存字段读 profile
    # 回退 default，导致安装场景与 G4 产物不一致。
    profiles = [c['profile'] for c in pipeline_server.scene_builds]
    assert len(profiles) >= 2, f'应至少构建场景两次（含导入后重建），实际 {profiles}'
    assert all(p == 'natural' for p in profiles), f'二次构建回退了 profile: {profiles}'
    # g4 stage 记录 profile，供后续任何二次构建沿用同一值
    assert final['stages']['g4_scene']['visual_profile'] == 'natural'


def _bundle_fixture(tmp_path, monkeypatch, with_assets=True):
    """构造一个最小但真实的 build_bundle 输入（runs/G1-G4 + g4/<map_id> + shots）。"""
    from rtsmap.gates import g4_export
    seed, map_id = 16, '16-0-bundletest'
    src_root = tmp_path / 'srcroot'
    rels = ['assets/pack/g3rock.fbx', 'assets/pack/visrock.fbx', 'assets/pack/atlas.png']
    for rel in (rels if with_assets else []):
        p = src_root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b'DATA-' + rel.encode())
    (src_root).mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(g4_export, 'SRC_ROOT', src_root)
    folder = tmp_path / 'job'
    g4 = folder / 'g4' / map_id
    g4.mkdir(parents=True)
    (g4 / f'map_{map_id}.tscn').write_text('[gd_scene]', encoding='utf-8')
    (g4 / 'height_data.bin').write_bytes(b'\x00' * 8)
    runs = folder / 'runs' / str(seed)
    for gate in ('G1', 'G2', 'G3', 'G4'):
        (runs / gate).mkdir(parents=True)
    (runs / 'G3' / 'assets_used.json').write_text(json.dumps(
        dict(fbx=['res://assets/pack/g3rock.fbx'], atlases=[])), encoding='utf-8')
    (runs / 'G4' / 'export.json').write_text(json.dumps(
        dict(visual_dependencies=[dict(asset='res://assets/pack/visrock.fbx',
                                       atlas='res://assets/pack/atlas.png')])),
        encoding='utf-8')
    (folder / 'shots').mkdir()
    job = dict(id='jobtest', config=dict(layout_seed=seed, terrain_seed=0),
               map_id=map_id, stages={}, created_at='now')
    return job, folder, map_id


def test_bundle_merges_visual_deps_hashes_and_freezes_runtime(tmp_path, monkeypatch):
    """F4：导出包依赖表合并 export.json 的 visual_dependencies（G3 之外素材），
    逐项带 sha256；运行脚本冻结进包 runtime/；声明运行时版本要求。"""
    from rtsmap.workbench import pipeline as pipeline_mod
    job, folder, map_id = _bundle_fixture(tmp_path, monkeypatch, with_assets=True)
    pipeline_mod.build_bundle(job, folder, lambda j: None)
    root = folder / 'bundle' / f'map_{map_id}'
    deps = json.loads((root / 'assets' / 'dependencies.json').read_text(encoding='utf-8'))
    asset_paths = {a['res_path'] for a in deps['assets']}
    assert 'res://assets/pack/g3rock.fbx' in asset_paths
    assert 'res://assets/pack/visrock.fbx' in asset_paths, 'F4: 视觉依赖未并入导出包'
    assert 'res://assets/pack/atlas.png' in asset_paths, 'F4: 视觉依赖 atlas 未并入'
    assert all(a.get('sha256') for a in deps['assets']), '每项素材必须带 sha256'
    rt = {r['install_to'] for r in deps['runtime_scripts']}
    assert 'source/match/maps/generated/GeneratedTerrain.gd' in rt
    assert (root / 'runtime' / 'GeneratedTerrain.gd').exists(), '运行脚本未冻结进包'
    assert (root / 'runtime' / 'ridge_rock.png').exists()
    rr = deps['runtime_requirements']
    assert rr['terrain_navmesh_agent_max_climb'] >= 0.3
    assert rr['godot'].startswith('4.7')
    # 安装脚本不得再对缺失依赖 Write-Warning 后 continue
    installer = (root / 'install.ps1').read_text(encoding='utf-8')
    assert 'exit 1' in installer and 'AssetSource' in installer


def test_bundle_fails_on_missing_asset_dependency(tmp_path, monkeypatch):
    """F4：素材依赖缺失时必须明确失败，不生成不完整的包。"""
    from rtsmap.workbench import pipeline as pipeline_mod
    job, folder, map_id = _bundle_fixture(tmp_path, monkeypatch, with_assets=False)
    with pytest.raises(FileNotFoundError):
        pipeline_mod.build_bundle(job, folder, lambda j: None)
