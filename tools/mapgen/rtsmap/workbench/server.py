"""Loopback-only HTTP workbench; one generator job at a time, isolated outputs.

2026-09-06 扩展（主计划阶段A/D）：
- 普通主流程 target='full'：G1→G2→G3→G4→引擎验证 一键贯通（pipeline.py）。
- 辅助入口 target='g2'：保留原 G2 快速预览调参流程。
- 重试复用同一已确定输入（同 job、同 config、同 Seed）；“重新随机”才创建新任务。
- 视觉重建（固定逻辑、只换视觉 Seed）走 /api/jobs/<id>/rebuild_visual。
- 完整地图下载 = 可导入 AI_RTS 的地图包（场景+高程+登记项+依赖清单+安装脚本）。
"""
import copy
import datetime as dt
import io
import json
import math
import mimetypes
import re
import secrets
import shutil
import threading
import time
import traceback
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from ..contract import ALGO_VERSION, W, H, CELL, GRID_W, GRID_H
from ..gates.g2_layout import NoTerrainCandidate, run_one, run_preview
from ..grid import read_json
from ..viz.review import build_g2_review
from .settings import CONTROLS, CHOICES, SPACING, SCHEMA_VERSION, CHECK_LABELS, config_from_spec, generator_params, validate_config
from .catalog import layout_catalog
from . import compat, pipeline

STATIC = Path(__file__).parent / 'static'
STAGE_LABELS = {
    'g1_input': '出生布局', 'g2_terrain': '地形生成', 'g3_content': '资源与素材',
    'g4_scene': '游戏场景导出', 'engine': '引擎加载与导航验收',
}
HALL_DEFAULT_MAP_IDS = frozenset({'16-0-1ca6e21aa1'})


def json_safe(value):
    """Failed geometry can contain infinite distances; HTTP JSON must stay valid."""
    if isinstance(value, dict):
        return {k: json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def summary(spec):
    sm = spec.get('strategy_metrics') or {}
    # 保底烘焙（g2_bake）产出的 spec 不带 strategy_metrics / plateau_fair_ratio 等
    # 派生量。这里一律 .get 兜底：汇总代码抛异常会让整次任务判 error，
    # 游戏只能退回旧图——用户看到的"随机地图是旧方案"正是这条链的末端。
    return dict(version=spec['algo_version'], all_pass=spec['all_pass'],
                solid_percent=round(spec['solid_frac'] * 100, 1),
                plateaus=len(spec['plateaus']), crossings=sm.get('crossings', 0),
                plateau_top_percent=round(sm.get('plateau_top_fraction', 0) * 100, 1),
                rivers=len(spec.get('rivers', [])), lakes=len(spec.get('lakes', [])),
                lake_area_m2=sum(lake['area_m2'] for lake in spec.get('lakes', [])),
                river_width_m=round(sum(rv['width'] for rv in spec.get('rivers', [])) / len(spec['rivers']), 1) if spec.get('rivers') else 0,
                nearest_pair_m=round(min(math.dist(a, b) for i, a in enumerate(spec['starts']) for b in spec['starts'][i+1:]), 1),
                neutral_ratio=spec.get('plateau_fair_ratio'),
                expansion_ratio=sm.get('expansion_ratio'),
                neighbor_ratio=(spec.get('path_fairness') or {}).get('flank_ratio'),
                min_route_width=min((spec.get('lane_widths') or {}).values(), default=None),
                chosen_attempt=(spec.get('generation') or {}).get('chosen_attempt'),
                checks=spec['checks'], attempts=(spec.get('generation') or {}).get('attempts'))


class Workbench:
    def __init__(self, project, output=None):
        self.project = Path(project).resolve()
        self.output = Path(output or self.project / 'workbench_output').resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.active = None
        self.jobs = {}
        self.layouts = layout_catalog(self.project)
        for layout in self.layouts:
            seed = layout['seed']
            ms = self.project / 'runs_v7_1' / str(seed) / 'G2' / 'mapspec.json'
            preview = self.project / 'review_v7_1' / 'G2' / f'seed_{seed}_overview.png'
            if ms.exists() and preview.exists():
                source_spec = read_json(ms)
                self.jobs[f'baseline-{seed}'] = dict(id=f'baseline-{seed}', baseline=True, status='done',
                    created_at='', title=f'原版参考 · 布局 {seed}', target='g2',
                    config=config_from_spec(source_spec),
                    result=summary(source_spec), duration=0)
        for entry in self.output.iterdir():
            if not entry.is_dir() or not re.fullmatch(r'[a-f0-9]{32}', entry.name):
                continue
            path = entry / 'job.json'
            try:
                job = read_json(path)
                if job['id'] != entry.name:
                    continue
                job.setdefault('target', 'g2')
                job.setdefault('stages', {})
                if job['status'] == 'running':
                    job.update(status='error', error_kind='interrupted',
                               error='服务重启中断了生成，请点击重试继续本任务（输入不变）。')
                    for stage in job['stages'].values():
                        if stage.get('status') == 'running':
                            stage.update(status='error', error_kind='interrupted',
                                         error='服务重启中断')
                    self._save(job)
                if job['status'] == 'done' and job['target'] == 'g2':
                    spec_path = entry / 'runs' / str(job['config']['layout_seed']) / 'G2/mapspec.json'
                    if spec_path.exists():
                        # Backfill new display fields without changing historical precision.
                        for key, value in summary(read_json(spec_path)).items():
                            job['result'].setdefault(key, value)
                self.jobs[entry.name] = job
            except (OSError, ValueError, KeyError):
                continue

    def listing(self):
        with self.lock:
            return [self.get(j['id']) for j in sorted(self.jobs.values(), key=lambda j: j['created_at'], reverse=True)]

    def snapshot(self):
        with self.lock:
            return dict(jobs=self.listing(), active=self.active)

    def get(self, job_id):
        with self.lock:
            if job_id not in self.jobs:
                raise KeyError(job_id)
            job = copy.deepcopy(self.jobs[job_id])
            if job['status'] == 'running':
                job['duration'] = round(time.time() - job['started'], 1)
            return job

    def _save(self, job):
        folder = self.output / job['id']
        folder.mkdir(exist_ok=True)
        temp = folder / 'job.tmp'
        temp.write_text(json.dumps(json_safe(job), ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
        # Windows 上 review 同步/读取可能瞬间占用 job.json，replace 偶发 PermissionError；
        # 短暂重试以避免因文件锁丢失一次状态写入。
        target = folder / 'job.json'
        for attempt in range(6):
            try:
                temp.replace(target)
                return
            except PermissionError:
                if attempt == 5:
                    raise
                time.sleep(0.05 * (attempt + 1))

    def start(self, request):
        # Normal UI requests contain preferences only. Resolve randomness once,
        # then save concrete Seeds so the exported config can replay this exact result.
        layout_locked = True
        terrain_locked = True
        layout_pool = None
        if isinstance(request, dict):
            request = dict(request)
            target = request.pop('target', 'full')
            if target not in ('full', 'g2'):
                raise ValueError('生成目标不正确。')
            layout_locked = 'layout_seed' in request
            terrain_locked = 'terrain_seed' in request
            spacing = request.get('player_spacing', 'any')
            if not isinstance(spacing, str) or spacing not in SPACING:
                raise ValueError('玩家距离选项不正确。')
            pool = compat.spacing_pool(self.layouts, spacing)
            if not pool:
                raise ValueError('当前玩家距离下没有可用布局。')
            if not layout_locked:
                # 已由人工验证能容纳所选水系的布局优先（见 compat.VERIFIED_WATER_LAYOUTS）：
                # 否则「双湖盆地」这类水系会在池子里盲轮 28 套布局、耗时 87s 仍不过检。
                layout_pool = compat.generation_pool(
                    self.layouts, spacing,
                    water_preferred=compat.preferred_water_layouts(
                        self.layouts, request.get('controls'), spacing))
                request['layout_seed'] = layout_pool[0]
            else:
                layout_pool = [request['layout_seed']]
            request.setdefault('terrain_seed', secrets.randbelow(2147483648))
        else:
            target = 'full'
        config = validate_config(request, [p['seed'] for p in self.layouts])
        layout = next((p for p in layout_catalog(self.project) if p['seed'] == config['layout_seed']), None)
        if layout is None:
            raise RuntimeError('所选 G1 布局已不再通过检查，请刷新布局库。')
        if config['player_spacing'] != 'any' and layout['spacing'] != config['player_spacing']:
            raise ValueError('所选布局与玩家距离筛选不一致，请重新随机生成。')
        with self.lock:
            if self.active:
                raise RuntimeError('已有地图正在生成，请等待本次完成。')
            job_id = uuid.uuid4().hex
            job = dict(id=job_id, baseline=False, status='running', config=config,
                       target=target, spacing=layout['spacing'],
                       created_at=dt.datetime.now().isoformat(timespec='seconds'), started=time.time(),
                       duration=0, title=f"布局 {config['layout_seed']} · 地貌 {config['terrain_seed']}",
                       pipeline_version=pipeline.PIPELINE_VERSION,
                       stage_versions=dict(ALGO_VERSION),
                       stages={},
                       layout_locked=layout_locked,
                       terrain_locked=terrain_locked,
                       layout_pool=list(layout_pool or [config['layout_seed']]),
                       layout_tried=[],
                       preview_only=(target == 'g2' and not layout['approved']),
                       progress=dict(attempt=0, limit=config['controls']['layout_attempts'],
                                     phase='准备出生布局', stage='G1'))
            self.jobs[job_id] = job
            self.active = job_id
            try:
                self._save(job)
            except OSError:
                self.active = None
                del self.jobs[job_id]
                raise
            result = copy.deepcopy(job)
            threading.Thread(target=self._generate, args=(job_id,), daemon=True).start()
            return result

    def retry(self, job_id):
        """重试保留同一已确定输入（布局/地貌/参数不变），从失败阶段继续。"""
        with self.lock:
            if self.active:
                raise RuntimeError('已有地图正在生成，请等待本次完成。')
            job = self.jobs.get(job_id)
            if job is None or job.get('baseline'):
                raise KeyError(job_id)
            if job['status'] == 'running':
                raise RuntimeError('本任务正在运行。')
            if job['status'] == 'done' and job.get('map_pass'):
                raise RuntimeError('本任务已完成并通过验收；如需新地图请重新随机生成。')
            # 从第一个未成功阶段起全部重跑（含 done 但 pass=False 的阶段）；
            # 之前已通过的阶段直接复用（输入哈希校验在 gate auto 模式）。
            order = ['g1_input', 'g2_terrain', 'g3_content', 'g4_scene', 'engine']
            names = [n for n in order if n in job['stages']] + \
                    [n for n in job['stages'] if n not in order]
            dropping = False
            for name in names:
                stage = job['stages'].get(name)
                ok = stage is not None and stage.get('status') == 'done' and stage.get('pass') is not False
                if not ok:
                    dropping = True
                if dropping:
                    job['stages'].pop(name, None)
            job.update(status='running', started=time.time(), error=None, error_kind=None,
                       progress=dict(stage='重试', phase='从上次失败的阶段继续'))
            self.active = job_id
            self._save(job)
            threading.Thread(target=self._generate, args=(job_id,), daemon=True).start()
            return copy.deepcopy(job)

    def rebuild_visual(self, job_id, body):
        """固定逻辑地图，只重建视觉：新视觉版本，不覆盖前一版对照（接口 #7）。"""
        with self.lock:
            if self.active:
                raise RuntimeError('已有任务正在运行，请等待本次完成。')
            job = self.jobs.get(job_id)
            if job is None or job.get('baseline') or job.get('target') != 'full':
                raise KeyError(job_id)
            if job['status'] == 'running':
                raise RuntimeError('本任务正在运行。')
            if job['stages'].get('g4_scene', {}).get('status') != 'done':
                raise RuntimeError('本任务还没有可重建的 G4 场景。')
            visual_seed = (body or {}).get('visual_seed')
            if visual_seed is None:
                visual_seed = secrets.randbelow(2147483647)
            if not isinstance(visual_seed, int) or not 0 <= visual_seed <= 2147483647:
                raise ValueError('视觉 Seed 必须是 0–2147483647 的整数。')
            profile = (body or {}).get('profile') or None
            job.update(status='running', started=time.time(), error=None, error_kind=None,
                       progress=dict(stage='视觉重建', phase='固定逻辑地图，仅重建视觉层'))
            self.active = job_id
            self._save(job)
            threading.Thread(target=self._rebuild_visual, args=(job_id, visual_seed, profile),
                            daemon=True).start()
            return copy.deepcopy(job)

    def _generate(self, job_id):
        job = self.jobs[job_id]
        config, folder = job['config'], self.output / job_id
        seed = config['layout_seed']

        def progress(value):
            with self.lock:
                job['progress'] = value
                self._save(job)

        try:
            (folder / 'config.json').write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding='utf-8')
            if job.get('target') == 'full':
                pipeline.run_pipeline(job, self.project, folder, self._locked_save, progress)
                seed = job['config']['layout_seed']
                (folder / 'config.json').write_text(
                    json.dumps(job['config'], ensure_ascii=False, indent=2), encoding='utf-8')
                spec_path = folder / 'runs' / str(seed) / 'G2/mapspec.json'
                finished = dict(result=summary(read_json(spec_path)) if spec_path.exists() else None,
                                status='done')
            else:
                result = self._generate_g2(job, folder, progress)
                seed = job['config']['layout_seed']
                progress(dict(attempt=result['mapspec']['generation']['chosen_attempt'],
                              limit=job['config']['controls']['layout_attempts'], phase='绘制总览与路线'))
                build_g2_review(folder / 'runs', folder / 'review', [seed])
                finished = dict(result=summary(result['mapspec']), status='done')
        except NoTerrainCandidate as error:
            tried = job.get('layout_tried') or []
            if not job.get('layout_locked', True) and tried:
                finished = dict(status='error', error_kind='no_candidate', attempts=error.attempts,
                                error=f"当前河湖组合在已试的 {len(tried)} 套出生布局上都放不下。不会缩小湖泊。")
            else:
                finished = dict(status='error', error_kind='no_candidate', attempts=error.attempts,
                                error=f"在 {len(error.attempts)} 个候选内未找到可用地貌。请重新随机生成，或调整水域选项；所选湖泊不会自动缩小。")
        except Exception as error:
            traceback.print_exc()
            finished = dict(status='error', error_kind=self._error_kind(error), error=str(error))
        finally:
            with self.lock:
                job.update(finished)
                job['duration'] = round(time.time() - job['started'], 1)
                try:
                    self._save(job)
                except OSError:
                    traceback.print_exc()
                    job.update(status='error', error_kind='storage_error', error='无法保存生成记录，请检查本地输出目录。')
                finally:
                    self.active = None
            self._sync_review(job_id)

    def _generate_g2(self, job, folder, progress):
        from .catalog import g1_source_root
        best = None
        best_seed = None
        while True:
            seed = job['config']['layout_seed']
            # ⚠ 生成方式必须**每轮重算**：布局轮换会换到"未 approve"的 seed，若沿用第一次算好的
            # `run_one`，`ensure_upstream_approved` 会直接抛 `G1 未 approve` 把任务打死 ——
            # 玩家看到的就是"生成一下就没结果了"（2026-09-15 实测：首轮落在 approved 布局时
            # 轮换必然踩）。未 approve 的布局本来就走预览模式。
            layout_meta = next((item for item in self.layouts if item['seed'] == seed), None)
            preview_only = bool(job.get('target') == 'g2'
                                and layout_meta is not None and not layout_meta.get('approved'))
            job['preview_only'] = preview_only
            generate = run_preview if preview_only else run_one
            dest = folder / 'runs' / str(seed) / 'G1'
            if not dest.exists():
                shutil.copytree(g1_source_root(self.project) / str(seed) / 'G1', dest)
            try:
                result = generate(seed, folder / 'runs', generator_params(job['config']),
                                  on_progress=progress)
            except NoTerrainCandidate as error:
                compat.record_layout_try(job, seed, 'no_candidate', error.attempts)
                if compat.note_hard_reject(job, error.attempts):
                    # 连续多套布局都"根本放不下所选水域" ⇒ 整池没戏，收手别让玩家干等。
                    job['layout_pool'] = []
                nxt = compat.next_layout_seed(job)
                if nxt is None:
                    if best is not None:
                        compat.bind_job_layout(job, best_seed, self.layouts)
                        return best
                    raise
                compat.bind_job_layout(job, nxt, self.layouts, reroll_terrain=True)
                progress(dict(stage='G2', phase=f'布局 {seed} 放不下所选水域，改试布局 {nxt}',
                              attempt=0, limit=job['config']['controls']['layout_attempts']))
                (folder / 'config.json').write_text(
                    json.dumps(job['config'], ensure_ascii=False, indent=2), encoding='utf-8')
                continue
            if result['mapspec'].get('all_pass') or not compat.should_rotate_failed_checks(job, result['mapspec']):
                return result
            if best is None:
                best, best_seed = result, seed
            compat.record_layout_try(job, seed, 'checks', result['mapspec'].get('generation', {}).get('attempts'))
            nxt = compat.next_layout_seed(job)
            if nxt is None:
                if best_seed is not None:
                    compat.bind_job_layout(job, best_seed, self.layouts)
                return best or result
            compat.bind_job_layout(job, nxt, self.layouts, reroll_terrain=True)
            progress(dict(stage='G2', phase=f'布局 {seed} 未通过地貌检查，改试布局 {nxt}',
                          attempt=0, limit=job['config']['controls']['layout_attempts']))
            (folder / 'config.json').write_text(
                json.dumps(job['config'], ensure_ascii=False, indent=2), encoding='utf-8')

    def _rebuild_visual(self, job_id, visual_seed, profile):
        job = self.jobs[job_id]
        folder = self.output / job_id
        try:
            pipeline.rebuild_visual(job, self.project, folder, self._locked_save,
                                    new_visual_seed=visual_seed, profile=profile)
            spec_path = folder / 'runs' / str(job['config']['layout_seed']) / 'G2/mapspec.json'
            finished = dict(result=summary(read_json(spec_path)) if spec_path.exists() else job.get('result'),
                            status='done')
        except Exception as error:
            traceback.print_exc()
            finished = dict(status='error', error_kind=self._error_kind(error), error=str(error))
        finally:
            with self.lock:
                job.update(finished)
                job['duration'] = round(time.time() - job['started'], 1)
                try:
                    self._save(job)
                except OSError:
                    traceback.print_exc()
                finally:
                    self.active = None
            self._sync_review(job_id)

    def _sync_review(self, job_id):
        """任务稳定后同步到离线 review 索引（生成/重试/视觉重建/交付都更新）。

        失败也同步（显示失败项），不用旧成功图冒充新结果；同步异常不影响任务状态。
        只重渲本任务，索引合并既有记录（见 review_sync）。
        """
        try:
            from . import review_sync
            # review 根取 output 的父目录：生产 output=<proj>/workbench_output → <proj>/review；
            # 测试 output=tmp/wb_out → tmp/review（隔离，不污染真实 review）。
            review_sync.sync_jobs([job_id], root=self.output.parent, output=self.output)
        except Exception:
            traceback.print_exc()

    @staticmethod
    def _error_kind(error):
        from . import engine as _engine
        from ..presentation import VisualPlanError
        if isinstance(error, _engine.EngineError):
            return 'engine_error'
        if isinstance(error, VisualPlanError):
            return 'visual_error'
        return 'generation_error'

    def _locked_save(self, job):
        with self.lock:
            self._save(job)

    def delete(self, job_id):
        """删除一条生成记录：任务目录 + 已安装到游戏工程的场景。

        原版参考不能删；正在跑的任务不能删（避免半截输出和 active 指针悬空）。
        """
        with self.lock:
            if self.active == job_id:
                raise RuntimeError('本任务正在生成，不能删除。')
            job = self.jobs.get(job_id)
            if job is None:
                raise KeyError(job_id)
            if job.get('baseline'):
                raise RuntimeError('原版参考图不能删除。')
            map_id = str(job.get('map_id') or '')
            if map_id in HALL_DEFAULT_MAP_IDS:
                raise RuntimeError('大厅默认地图不能删除。')
            folder = self.output / job_id
            del self.jobs[job_id]
        if folder.exists():
            shutil.rmtree(folder)
        self._delete_installed_map(map_id)
        return {'ok': True, 'id': job_id, 'map_id': map_id}

    @staticmethod
    def _delete_installed_map(map_id):
        if not map_id or any(token in map_id for token in ('/', '\\', '..')):
            return
        try:
            from . import engine as _engine
            airts = Path(_engine.airts_root())
        except Exception:
            return
        installed = airts / 'source' / 'match' / 'maps' / 'generated' / map_id
        if installed.is_dir():
            shutil.rmtree(installed)
        preview = airts / 'assets' / 'map_previews' / f'map_{map_id}.png'
        for path in (preview, Path(str(preview) + '.import')):
            if path.is_file():
                path.unlink()

    def artifact(self, job_id, name):
        job = self.get(job_id)
        seed = job['config']['layout_seed']
        allowed = ('overview.png', 'strategy.png', 'g3.png', 'g4_ortho.png',
                   'g4_iso45.png', 'g4_oblique.png', 'config.json', 'bundle.zip')
        if name not in allowed:
            raise KeyError(name)
        if name == 'config.json':
            return json.dumps(job['config'], ensure_ascii=False, indent=2).encode('utf-8'), 'application/json'
        if job['status'] != 'done':
            raise KeyError('生成尚未完成')
        if name == 'bundle.zip':
            if job.get('target') == 'full' and job.get('bundle'):
                path = Path(job['bundle']['path'])
                if not path.exists():
                    raise KeyError('地图包缺失，请重试任务。')
                return path.read_bytes(), 'application/zip'
        if job['baseline']:
            runs, review = self.project / 'runs_v7_1', self.project / 'review_v7_1'
        else:
            runs, review = self.output / job_id / 'runs', self.output / job_id / 'review'
        if name == 'overview.png' or name == 'strategy.png':
            path = review / 'G2' / f'seed_{seed}_{name}'
            return path.read_bytes(), 'image/png'
        if name == 'g3.png':
            path = review / 'G3' / f'seed_{seed}_overview.png'
            return path.read_bytes(), 'image/png'
        if name in ('g4_ortho.png', 'g4_iso45.png', 'g4_oblique.png'):
            map_id = job.get('map_id')
            if not map_id:
                raise KeyError('本任务没有 G4 产物')
            path = self.output / job_id / 'shots' / f'{map_id}_{name[3:-4]}.png'
            if not path.exists():
                # 旧任务可能没有该机位（如 45° 轴测是后加的），按缺图处理而非 500。
                raise KeyError(f'本任务没有 {name} 截图')
            return path.read_bytes(), 'image/png'
        # 旧 G2 数据打包（完整地图包在上方 bundle 分支）
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
            for gate in ('G1', 'G2'):
                for path in sorted((runs / str(seed) / gate).iterdir()):
                    if path.is_file() and path.suffix in ('.json', '.npz'):
                        archive.write(path, f'{seed}/{gate}/{path.name}')
            for kind in ('overview', 'strategy'):
                archive.write(review / 'G2' / f'seed_{seed}_{kind}.png', f'{kind}.png')
            archive.writestr('config.json', json.dumps(job['config'], ensure_ascii=False, indent=2))
        return buffer.getvalue(), 'application/zip'


def make_server(project, port=8765, output=None):
    app = Workbench(project, output)

    class Handler(BaseHTTPRequestHandler):
        def send(self, status, data, mime='application/json', filename=None):
            if not isinstance(data, bytes):
                data = json.dumps(json_safe(data), ensure_ascii=False, allow_nan=False).encode('utf-8')
            self.send_response(status)
            self.send_header('Content-Type', mime + ('; charset=utf-8' if mime.startswith('text/') or mime == 'application/json' else ''))
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            if filename:
                self.send_header('Content-Disposition', f'attachment; filename="{filename}"')
            self.end_headers()
            self.wfile.write(data)

        def local_request(self):
            host = self.headers.get('Host', '')
            try:
                local = urlsplit('http://' + host).hostname in ('127.0.0.1', 'localhost')
            except ValueError:
                local = False
            if not local:
                self.send(403, {'error': '仅支持本机访问。'})
                return False
            origin = self.headers.get('Origin')
            if origin and origin != 'http://' + host:
                self.send(403, {'error': '请求来源不匹配。'})
                return False
            return True

        def read_body(self):
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 32768:
                raise ValueError('参数内容过大或为空。')
            if length == 0:
                return {}
            return json.loads(self.rfile.read(length))

        def do_GET(self):
            if not self.local_request():
                return
            path = urlsplit(self.path).path
            try:
                if path == '/api/bootstrap':
                    return self.send(200, dict(schema_version=SCHEMA_VERSION, version=ALGO_VERSION['G2'],
                        algo_versions=dict(ALGO_VERSION), pipeline_version=pipeline.PIPELINE_VERSION,
                        layouts=app.layouts, controls=CONTROLS, choices=CHOICES, check_labels=CHECK_LABELS,
                        stage_labels=STAGE_LABELS,
                        fixed=dict(map_size_m=[W, H], grid_size=[GRID_W, GRID_H], cell_m=CELL, plateau_height_difference_m=3,
                                   home_clearance_m=20, home_plateaus=2, bridge_width_m=8), **app.snapshot()))
                if path == '/api/jobs':
                    return self.send(200, app.snapshot())
                match = re.fullmatch(r'/api/jobs/([a-z0-9-]+)', path)
                if match:
                    return self.send(200, app.get(match[1]))
                match = re.fullmatch(r'/artifacts/([a-z0-9-]+)/([a-z0-9._]+)', path)
                if match:
                    data, mime = app.artifact(match[1], match[2])
                    download = f'g2-{match[1][:12]}-{match[2]}' if match[2] in ('bundle.zip', 'config.json') else None
                    return self.send(200, data, mime, download)
                if path in ('/', '/app.js', '/style.css'):
                    file = STATIC / ('index.html' if path == '/' else path[1:])
                    return self.send(200, file.read_bytes(), mimetypes.guess_type(file.name)[0] or 'text/plain')
                self.send(404, {'error': '未找到内容。'})
            except (KeyError, FileNotFoundError):
                self.send(404, {'error': '未找到生成结果。'})
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_POST(self):
            if not self.local_request():
                return
            route = urlsplit(self.path).path
            try:
                if route == '/api/generate':
                    if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                        return self.send(415, {'error': '请使用 JSON 参数。'})
                    config = self.read_body()
                    self.send(202, app.start(config))
                    return
                match = re.fullmatch(r'/api/jobs/([a-z0-9-]+)/retry', route)
                if match:
                    self.send(202, app.retry(match[1]))
                    return
                match = re.fullmatch(r'/api/jobs/([a-z0-9-]+)/rebuild_visual', route)
                if match:
                    body = self.read_body() if self.headers.get('Content-Type', '').split(';')[0] == 'application/json' else {}
                    self.send(202, app.rebuild_visual(match[1], body))
                    return
                self.send(404, {'error': '未找到接口。'})
            except (ValueError, UnicodeError) as error:
                self.send(400, {'error': str(error)})
            except KeyError:
                self.send(404, {'error': '未找到任务。'})
            except RuntimeError as error:
                self.send(409, {'error': str(error)})
            except OSError:
                traceback.print_exc()
                self.send(500, {'error': '无法创建本地生成任务，请检查输出目录。'})

        def do_DELETE(self):
            if not self.local_request():
                return
            route = urlsplit(self.path).path
            try:
                match = re.fullmatch(r'/api/jobs/([a-z0-9-]+)', route)
                if match:
                    return self.send(200, app.delete(match[1]))
                self.send(404, {'error': '未找到接口。'})
            except KeyError:
                self.send(404, {'error': '未找到任务。'})
            except RuntimeError as error:
                self.send(409, {'error': str(error)})
            except OSError:
                traceback.print_exc()
                self.send(500, {'error': '无法删除本地地图文件。'})

        def log_message(self, message, *args):
            # 【2026-09-15 修复：pythonw 下"非 200 响应直接断连"】
            # 服务由游戏端用 `pythonw.exe`（无控制台）启动时 `sys.stderr is None`，
            # `super().log_message()` 写 stderr 会抛 AttributeError —— 而它是在
            # `send_response` 内部被调用的，于是 **任何非 200/202 的响应**
            # （404/409/403/500）都会在写出响应头之前异常 ⇒ 连接被断开、客户端收不到
            # 任何内容（curl 显示 000 / http.client 报 RemoteDisconnected）。
            # 症状：面板点"删除这张地图"永远报兜底文案"删除失败"，而服务端其实
            # 正常处理了；只有 200/202 因为不写日志才看起来正常。
            # 兜底：输出不可用时静默丢弃日志，绝不让日志失败影响响应写出。
            if len(args) > 1 and str(args[1]) not in ('200', '202'):
                try:
                    super().log_message(message, *args)
                except Exception:
                    pass

    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.app = app
    return server
