"""完整地图任务编排层：G1→G2→G3→G4→引擎验证 一键贯通。

设计（主计划阶段A/E）：
- 每个任务记录：唯一 ID、目标阶段、来源布局、实际 Seed、各阶段参数/版本、状态、
  进度、耗时、上游输入哈希、产物与错误；输出独立目录，旧结果不覆盖。
- 阶段自动继续依据本次真实输入校验（gate 的 auto 模式）与几何/资源检查；
  人工 approval 与机器检查分开，不填 approved=true。
- 上游失败则依赖阶段不运行；任务 done 不等于地图 PASS（result.all_pass 另记）。
- 重试保留同一已确定输入；“重新随机”由 server 创建新任务。
- Godot 进程失败/超时/缺失都有明确阶段状态与日志。
"""
import datetime as dt
import json
import secrets
import shutil
import time
import zipfile
from pathlib import Path

from ..contract import ALGO_VERSION, G4_AIRTS
from ..gate import run_dir
from ..gates import g2_layout, g3_content, g4_export
from ..grid import read_json, sha256_file, write_json
from ..viz.review import build_g2_review, build_g3_review
from . import engine
from .settings import generator_params

PIPELINE_VERSION = "1.0.0"
STAGE_ORDER = ["g1_input", "g2_terrain", "g3_content", "g4_scene", "engine"]


def _now():
    return dt.datetime.now().isoformat(timespec="seconds")


class StageRecorder:
    """任务 stage 记录：状态/版本/参数/耗时/输入输出哈希/产物/日志/错误。"""

    def __init__(self, job, folder, save):
        self.job = job
        self.folder = Path(folder)
        self.save = save

    def begin(self, name, **info):
        st = self.job["stages"].setdefault(name, {})
        st.update(status="running", started_at=_now(), duration_s=0, error=None)
        st["pass"] = True   # 重置上一轮的 pass=False，阶段完成后按真实结果覆写
        st.update(info)
        self.save(self.job)
        return st

    def done(self, name, **info):
        st = self.job["stages"][name]
        st.update(status="done", finished_at=_now(), **info)
        st["duration_s"] = round(time.time() - st.get("_t0", time.time()), 1)
        st.pop("_t0", None)
        self.save(self.job)
        return st

    def fail(self, name, error, kind="stage_error", **info):
        st = self.job["stages"].setdefault(name, {})
        st.update(status="error", finished_at=_now(), error=str(error), error_kind=kind, **info)
        st["duration_s"] = round(time.time() - st.get("_t0", time.time()), 1)
        st.pop("_t0", None)
        self.save(self.job)
        return st

    def skip(self, name, reason):
        st = self.job["stages"].setdefault(name, {})
        st.update(status="skipped", reason=reason, finished_at=_now())
        self.save(self.job)
        return st

    def mark_t0(self, name):
        self.job["stages"].setdefault(name, {})["_t0"] = time.time()


def run_pipeline(job, project, folder, save, progress):
    """执行（或续跑）一个完整地图任务。job/folder/save 由 Workbench 提供。"""
    config = job["config"]
    seed = config["layout_seed"]
    runs = Path(folder) / "runs"
    review = Path(folder) / "review"
    rec = StageRecorder(job, folder, save)
    stages = job.setdefault("stages", {})
    g4_params = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4_params["terrain_seed"] = config.get("terrain_seed", 0)

    def stage_done(name):
        return stages.get(name, {}).get("status") == "done"

    def stage_passed(name):
        return stage_done(name) and stages[name].get("pass", True)

    # ---- G1 输入：复制既有合格布局（源只读，不重新随机） ----
    if not stage_done("g1_input"):
        rec.mark_t0("g1_input")
        rec.begin("g1_input", stage="G1", version=ALGO_VERSION["G1"])
        try:
            from .catalog import g1_source_root
            src = g1_source_root(Path(project)) / str(seed) / "G1"
            dst = runs / str(seed) / "G1"
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(src, dst)
            spec = read_json(dst / "mapspec.json")
            hashes = {p.name: sha256_file(p) for p in dst.iterdir() if p.is_file()}
            rec.done("g1_input", source=str(src), source_hashes=hashes,
                     starts=spec["starts"], spacing=job.get("spacing"),
                     g1_approved=bool(read_json(dst / "manifest.json").get("approved")),
                     output_hashes={"mapgrid.npz": hashes.get("mapgrid.npz")})
        except Exception as error:
            rec.fail("g1_input", error)
            raise
    progress(dict(stage="G1", phase="出生布局已就绪"))

    # ---- G2 地形 ----
    if not stage_done("g2_terrain"):
        rec.mark_t0("g2_terrain")
        rec.begin("g2_terrain", stage="G2", version=ALGO_VERSION["G2"])
        try:
            params = generator_params(config)

            def g2_progress(value):
                progress(dict(stage="G2", **value))

            result = g2_layout.run_one(seed, runs, params, on_progress=g2_progress, auto=True)
            spec = result["mapspec"]
            build_g2_review(runs, review, [seed])
            mf = read_json(run_dir(runs, seed, "G2") / "manifest.json")
            rec.done("g2_terrain", all_pass=spec["all_pass"],
                     checks=spec["checks"], input_hash=mf["input_hash"],
                     output_hash=mf["output_hash"], params_version=spec["algo_version"],
                     chosen_attempt=spec["generation"]["chosen_attempt"],
                     summary=_g2_summary(spec))
            stages["g2_terrain"]["pass"] = bool(spec["all_pass"])
            save(job)
        except Exception as error:
            rec.fail("g2_terrain", error,
                     kind="no_candidate" if isinstance(error, g2_layout.NoTerrainCandidate) else "stage_error",
                     attempts=getattr(error, "attempts", None))
            raise
    if not stage_passed("g2_terrain"):
        for name in ("g3_content", "g4_scene", "engine"):
            rec.skip(name, "G2 几何检查未通过，依赖阶段不运行")
        _finalize(job, folder, save)
        return
    progress(dict(stage="G2", phase="地形检查通过"))

    # ---- G3 资源与素材 ----
    if not stage_done("g3_content"):
        rec.mark_t0("g3_content")
        rec.begin("g3_content", stage="G3", version=ALGO_VERSION["G3"])
        try:
            res3 = g3_content.run_one(seed, runs, dict(g3_content.G3_DEFAULTS), auto=True)
            build_g3_review(runs, review, [seed])
            mf = read_json(run_dir(runs, seed, "G3") / "manifest.json")
            spec3 = res3["mapspec"]
            rec.done("g3_content", all_pass=spec3["all_pass"],
                     checks={k: bool(v) for k, v in _g3_checks(spec3, runs, seed).items()},
                     input_hash=mf["input_hash"], output_hash=mf["output_hash"],
                     instance_count=spec3["instance_count"],
                     resource_failures=spec3["resource_failures"])
            stages["g3_content"]["pass"] = bool(spec3["all_pass"])
            save(job)
        except Exception as error:
            rec.fail("g3_content", error)
            raise
    if not stage_passed("g3_content"):
        for name in ("g4_scene", "engine"):
            rec.skip(name, "G3 检查未通过，依赖阶段不运行")
        _finalize(job, folder, save)
        return
    progress(dict(stage="G3", phase="资源与素材就绪"))

    # ---- G4 场景导出与安装 ----
    if not stage_done("g4_scene"):
        rec.mark_t0("g4_scene")
        rec.begin("g4_scene", stage="G4", version=ALGO_VERSION["G4"])
        try:
            map_id = job.get("map_id") or g4_export.make_map_id(
                seed, config.get("terrain_seed", 0), config)
            job["map_id"] = map_id
            if "visual_seed" not in job:
                job["visual_seed"] = secrets.randbelow(2147483647)
            out_dir = Path(folder) / "g4" / map_id
            _build_g4(job, seed, runs, out_dir, g4_params, rec, save, progress)
        except Exception as error:
            rec.fail("g4_scene", error)
            raise
    progress(dict(stage="G4", phase="场景已导出"))

    # ---- 引擎验证：导入 + 加载 + 截图 + 定向导航 ----
    if not stage_done("engine"):
        rec.mark_t0("engine")
        rec.begin("engine", stage="ENGINE", version="godot")
        try:
            _run_engine(job, folder, rec, save, progress)
        except Exception as error:
            rec.fail("engine", error,
                     kind="engine_error" if isinstance(error, engine.EngineError) else "stage_error")
            raise
    # 汇总
    _finalize(job, folder, save)


def _g2_summary(spec):
    return dict(all_pass=spec["all_pass"],
                solid_percent=round(spec["solid_frac"] * 100, 1),
                plateaus=len(spec["plateaus"]),
                rivers=len(spec.get("rivers", [])), lakes=len(spec.get("lakes", [])),
                lake_area_m2=sum(lake["area_m2"] for lake in spec.get("lakes", [])),
                crossings=spec["strategy_metrics"]["crossings"])


def _g3_checks(spec3, runs, seed):
    rep = read_json(run_dir(runs, seed, "G3") / "recheck_report.json")
    return dict(quota_equal=spec3["resource_fairness"]["quota_equal"],
                fairness_pass=spec3["resource_fairness"]["pass"],
                recheck_components=spec3["recheck"]["components_pass"],
                recheck_keypoints=spec3["recheck"]["keypoints_pass"],
                recheck_widths=spec3["recheck"]["widths_pass"],
                cluster_cover=rep["cluster_cover_pass"],
                budget=rep["budget_pass"],
                no_resource_failures=not spec3["resource_failures"])


def _build_g4(job, seed, runs, out_dir, g4_params, rec, save, progress):
    from ..gates import g4_export as g4x
    map_id = job["map_id"]
    visual_seed = int(job.get("visual_seed", 0))
    visual_version = int(job.get("visual_version", 1))
    progress(dict(stage="G4", phase="生成真实地形场景"))
    airts = engine.airts_root()
    built = g4x.build_scene_text(map_id, runs, seed, out_dir, g4_params,
                                 visual_seed=visual_seed)
    scene_res, installed = g4x.install_map(out_dir, map_id, airts)
    job["scene_res"] = scene_res
    job["g4_out_dir"] = str(out_dir)
    rec.done("g4_scene", map_id=map_id, scene=str(built["tscn"]), scene_res=scene_res,
             height_data=str(built["height_data"]),
             height_data_sha256=built["height_data_sha256"],
             heightfield_report=built["hf_report"],
             visual_seed=visual_seed, visual_version=visual_version,
             visual_profile=g4_params.get("visual_profile"),
             visual_style_version=built["visual"]["style_version"],
             visual_stats=built["visual"]["stats"],
             visual_warnings=built["visual"]["warnings"],
             installed_runtime=installed,
             airts=airts)
    save(job)


def _run_engine(job, folder, rec, save, progress):
    from ..grid import read_json as rj
    from ..gates import g4_export as g4x
    folder = Path(folder)
    airts = engine.airts_root()
    seed = job["config"]["layout_seed"]
    map_id = job["map_id"]
    scene_res = job["scene_res"]
    runs = folder / "runs"
    shots = folder / "shots"
    shots.mkdir(exist_ok=True)
    log_dir = folder / "logs"
    records = []

    progress(dict(stage="引擎", phase="复制素材依赖（G3+视觉计划+桥组合）"))
    export_json = rj(runs / str(seed) / "G4" / "export.json")
    extra = []
    for dep in (export_json.get("visual_dependencies") or []):
        extra.append(dep["asset"])
        if dep.get("atlas"):
            extra.append(dep["atlas"])
    for dep in (export_json.get("bridge_assets") or []):
        extra.append(dep["asset"])
        if dep.get("atlas"):
            extra.append(dep["atlas"])
    fbx, atlases, copied = g4x.copy_assets([seed], runs, airts, extra_res=extra)
    records.append(dict(step="copy_assets", fbx=len(fbx), atlases=len(atlases),
                        copied_now=copied))

    progress(dict(stage="引擎", phase="导入资产（Godot headless）"))
    records.append(dict(step="import", **engine.import_assets(airts, log_dir)))
    # 导入后重写场景：ext_resource 的 uid 来自 .import（导入前构建拿不到）；
    # 场景本体在 G4 阶段已写入一次（产生 export.json/visual_plan 供依赖清单）。
    # profile 取值顺序（GLM 视觉轮修复）：job.visual_profile（rebuild_visual 写入）
    # → g4 stage 记录 → default。此前 stage 记录不含 profile，非默认样式会在本步
    # 被静默重置为 default 重建成另一套视觉（G4 产物与引擎安装场景不一致）。
    g4_params = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4_params["terrain_seed"] = job["config"].get("terrain_seed", 0)
    g4_params["visual_profile"] = (job.get("visual_profile")
                                   or job["stages"].get("g4_scene", {}).get("visual_profile")
                                   or g4_params["visual_profile"])
    g4x.build_scene_text(map_id, runs, seed, folder / "g4" / map_id, g4_params,
                         visual_seed=int(job.get("visual_seed", 0)))
    g4x.install_map(folder / "g4" / map_id, map_id, airts)

    progress(dict(stage="引擎", phase="正交俯视截图"))
    ortho = shots / f"{map_id}_ortho.png"
    records.append(dict(step="ortho", **engine.capture_ortho(airts, scene_res, ortho, log_dir)))
    progress(dict(stage="引擎", phase="45°轴测截图"))
    iso45 = shots / f"{map_id}_iso45.png"
    records.append(dict(step="iso45", **engine.capture_ortho(airts, scene_res, iso45,
                                                             log_dir, iso45=True)))
    progress(dict(stage="引擎", phase="游戏斜视截图"))
    oblique = shots / f"{map_id}_oblique.png"
    records.append(dict(step="oblique", **engine.capture_ortho(airts, scene_res, oblique,
                                                               log_dir, oblique=True)))

    progress(dict(stage="引擎", phase="加载与定向导航验收"))
    targets = folder / "runs" / str(seed) / "G4" / "nav_targets.json"
    nav_out = folder / "nav_check.json"
    nav_rec = engine.nav_check(airts, scene_res, targets, nav_out, log_dir)
    records.append(dict(step="nav_check", **nav_rec))
    nav_report = rj(nav_out) if nav_out.exists() else {}
    engine_pass = bool(nav_rec.get("pass")) and bool(nav_report.get("all_pass"))
    rec.done("engine", nav_all_pass=bool(nav_report.get("all_pass")),
             nav_bake_wait_s=nav_report.get("bake_wait_s"),
             nav_targets_checked=nav_report.get("targets_checked"),
             nav_paths_checked=nav_report.get("paths_checked"),
             ortho=str(ortho), iso45=str(iso45), oblique=str(oblique),
             nav_report=str(nav_out),
             processes=records)
    job["stages"]["engine"]["pass"] = engine_pass
    save(job)


def _finalize(job, folder, save):
    """任务级汇总：done ≠ PASS；PASS 需要 G2/G3 检查 + 引擎验收全过。"""
    stages = job["stages"]
    checks = {
        "g2_pass": stages.get("g2_terrain", {}).get("pass"),
        "g3_pass": stages.get("g3_content", {}).get("pass"),
        "engine_pass": stages.get("engine", {}).get("pass"),
    }
    job["map_pass"] = all(v is True for v in checks.values())
    job["checks_summary"] = checks
    build_bundle(job, Path(folder), save)
    save(job)


def build_bundle(job, folder, save):
    """生成可下载地图包：场景 + 高程数据 + 登记项 + 依赖清单 + 安装脚本 + 报告。"""
    folder = Path(folder)
    seed = job["config"]["layout_seed"]
    map_id = job.get("map_id")
    if not map_id:
        return None
    runs = folder / "runs"
    g4_dir = folder / "g4" / map_id
    bundle_dir = folder / "bundle"
    bundle_dir.mkdir(exist_ok=True)
    root = bundle_dir / f"map_{map_id}"
    if root.exists():
        shutil.rmtree(root)
    (root / "source").mkdir(parents=True)
    (root / "assets").mkdir(parents=True)
    shutil.copy2(g4_dir / f"map_{map_id}.tscn", root / "source" / f"map_{map_id}.tscn")
    shutil.copy2(g4_dir / "height_data.bin", root / "source" / "height_data.bin")
    index = {
        "path": f"res://source/match/maps/generated/{map_id}/map_{map_id}.tscn",
        "name": f"Generated {map_id}",
        "players": 4,
        "size": [256, 256],
        "map_id": map_id,
        "height_data": f"res://source/match/maps/generated/{map_id}/height_data.bin",
        "height_data_sha256": sha256_file(g4_dir / "height_data.bin"),
    }
    write_json(root / "source" / "map_index.json", index)
    reports_dir = root / "reports"
    reports_dir.mkdir(parents=True, exist_ok=True)
    for name in ("nav_targets.json", "export.json", "heightfield_report.json",
                 "visual_plan.json"):
        src = runs / str(seed) / "G4" / name
        if src.exists():
            shutil.copy2(src, reports_dir / name)
    # 数据与报告
    data_dir = root / "data"
    for gate_name in ("G1", "G2", "G3", "G4"):
        gd = runs / str(seed) / gate_name
        if not gd.exists():
            continue
        for path in sorted(gd.iterdir()):
            if path.is_file() and path.suffix in (".json", ".npz", ".bin"):
                target = data_dir / gate_name / path.name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
    write_json(root / "config.json", job["config"])
    write_json(root / "job_summary.json", dict(
        job_id=job["id"], map_id=map_id, map_pass=job.get("map_pass"),
        stage_versions={k: v.get("version") for k, v in job.get("stages", {}).items()},
        visual_seed=job.get("visual_seed"), visual_version=job.get("visual_version"),
        created_at=job.get("created_at"), pipeline_version=PIPELINE_VERSION,
        algo_versions=dict(ALGO_VERSION)))
    # 依赖清单（Codex F4）：合并 G3 assets_used + G4 export.json 的 visual_dependencies
    # （视觉计划引入的 G3 之外素材，如 natural 样式的 4041 岩件），逐项带 sha256；
    # 运行脚本/内置贴图随包冻结到 runtime/，安装用包内副本而非开发机或目标工程，
    # 历史包不受当前脚本变化影响；缺素材必须明确失败，不生成不完整的“安装完成”包。
    export_json = read_json(runs / str(seed) / "G4" / "export.json")
    assets_used = read_json(runs / str(seed) / "G3" / "assets_used.json")
    asset_res = set(assets_used["fbx"]) | set(assets_used["atlases"])
    for dep in (export_json.get("visual_dependencies") or []):
        asset_res.add(dep["asset"])
        if dep.get("atlas"):
            asset_res.add(dep["atlas"])
    for dep in (export_json.get("bridge_assets") or []):
        asset_res.add(dep["asset"])
        if dep.get("atlas"):
            asset_res.add(dep["atlas"])
    asset_deps = []
    missing_assets = []
    for res_path in sorted(asset_res):
        rel = res_path[len("res://"):]
        install_to = rel.replace("assets/", "assets/models/scifi-worlds/", 1)
        src = g4_export.SRC_ROOT / rel
        if src.exists():
            asset_deps.append(dict(res_path=res_path, install_to=install_to,
                                   sha256=sha256_file(src), source_hint=str(src)))
        else:
            missing_assets.append(res_path)
    if missing_assets:
        raise FileNotFoundError(
            f"导出包素材依赖缺失（不生成不完整包）: {missing_assets[:6]}")
    # 运行脚本 + 内置贴图：冻结进包（root/runtime），安装从包内取
    runtime_dir = root / "runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    airts_live = Path(G4_AIRTS)
    runtime_specs = [
        ("res://source/match/maps/generated/GeneratedTerrain.gd",
         "source/match/maps/generated/GeneratedTerrain.gd",
         airts_live / "source/match/maps/generated/GeneratedTerrain.gd"),
        ("res://source/match/maps/generated/ApplyAtlas.gd",
         "source/match/maps/generated/ApplyAtlas.gd",
         airts_live / "source/match/maps/generated/ApplyAtlas.gd"),
        ("res://assets/models/scifi-worlds/generated/ridge_rock.png",
         "assets/models/scifi-worlds/generated/ridge_rock.png",
         airts_live / "assets/models/scifi-worlds/generated/ridge_rock.png"),
    ]
    runtime_deps = []
    for res_path, install_to, src in runtime_specs:
        if not src.exists():
            raise FileNotFoundError(f"运行脚本/内置贴图缺失，无法冻结进包: {src}")
        shutil.copy2(src, runtime_dir / src.name)
        runtime_deps.append(dict(res_path=res_path, install_to=install_to,
                                 bundled=f"runtime/{src.name}", sha256=sha256_file(src)))
    write_json(root / "assets" / "dependencies.json", dict(
        target_project="AI_RTS (Godot 4.7 mono)",
        runtime_requirements=dict(
            godot="4.7.1-stable_mono", engine_min="4.7",
            pipeline_version=PIPELINE_VERSION, algo_versions=dict(ALGO_VERSION),
            terrain_navmesh_agent_max_climb=0.5,
            note=("生成地图坡道依赖 terrain navmesh agent_max_climb>=0.3（1 voxel，"
                  "cell_height=0.3）；AI_RTS Match.tscn 的 NavigationMesh_exfwj 已配套"
                  "设为 0.5，崖壁 3m 台阶仍不可爬。目标工程若为 0.0 需先应用此配套。")),
        runtime_scripts=runtime_deps,
        assets=asset_deps))
    _write_installer(root, map_id, runtime_deps, asset_deps)
    (root / "安装说明.txt").write_text(_install_readme(map_id), encoding="utf-8")
    # 预览图（存在才打包）
    shots = folder / "shots"
    previews = root / "previews"
    previews.mkdir(parents=True, exist_ok=True)
    for png in shots.glob(f"{map_id}_*.png"):
        shutil.copy2(png, previews / png.name)
    zip_path = folder / f"map_bundle_{map_id}.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(bundle_dir).as_posix())
    job["bundle"] = dict(path=str(zip_path), sha256=sha256_file(zip_path),
                         map_id=map_id, built_at=_now())
    save(job)
    return zip_path


def _write_installer(root, map_id, runtime_deps, asset_deps):
    """安装脚本（Codex F4）：运行脚本从包内冻结副本安装；素材从 -AssetSource
    （包声明来源）安装，缺失明确失败（exit 1）而非 Write-Warning 后 continue 并
    打印“安装完成”；校验目标工程 terrain navmesh agent_max_climb 配套。"""
    default_asset_source = str(g4_export.SRC_ROOT).replace("\\", "/")
    lines = [
        "# 把本地图包安装进 AI_RTS（在同版本工程中执行）",
        "param([Parameter(Mandatory=$true)][string]$AirtsRoot,",
        f"      [string]$AssetSource = '{default_asset_source}',",
        "      [string]$GodotExe = '')",
        "$ErrorActionPreference = 'Stop'",
        "$src = Split-Path -Parent $MyInvocation.MyCommand.Path",
        f"$mapDir = Join-Path $AirtsRoot 'source/match/maps/generated/{map_id}'",
        "New-Item -ItemType Directory -Force -Path $mapDir | Out-Null",
        "Copy-Item (Join-Path $src 'source/*') $mapDir -Force",
        "$deps = Get-Content (Join-Path $src 'assets/dependencies.json') -Raw -Encoding UTF8 | ConvertFrom-Json",
        "# 1) 运行脚本/内置贴图：从包内冻结副本安装（不取开发机/目标工程，历史包自洽）",
        "foreach ($r in $deps.runtime_scripts) {",
        "  $dst = Join-Path $AirtsRoot $r.install_to",
        "  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null",
        "  Copy-Item (Join-Path $src $r.bundled) $dst -Force",
        "}",
        "# 2) 素材依赖：从 -AssetSource 安装，缺失统一收集后明确失败",
        "$missing = @()",
        "foreach ($d in $deps.assets) {",
        "  $dst = Join-Path $AirtsRoot $d.install_to",
        "  if (Test-Path $dst) { continue }",
        "  $rel = $d.res_path -replace '^res://',''",
        "  $found = Join-Path $AssetSource $rel",
        "  if (-not (Test-Path $found)) { $missing += $d.res_path; continue }",
        "  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null",
        "  Copy-Item $found $dst -Force",
        "}",
        "if ($missing.Count -gt 0) {",
        "  Write-Error ('缺失素材依赖，安装失败（未生成可用地图）: ' + ($missing -join ', '))",
        "  exit 1",
        "}",
        "# 3) 校验 terrain navmesh 配套（坡道连通需 agent_max_climb>=0.3）",
        "$matchTscn = Join-Path $AirtsRoot 'source/match/Match.tscn'",
        "if (Test-Path $matchTscn) {",
        "  $txt = Get-Content $matchTscn -Raw",
        "  $m = [regex]::Match($txt, 'terrain_navigation_input[\\s\\S]*?agent_max_climb\\s*=\\s*([0-9.]+)')",
        "  if ($m.Success -and ([double]$m.Groups[1].Value) -lt 0.3) {",
        "    Write-Error ('目标工程 terrain navmesh agent_max_climb=' + $m.Groups[1].Value + ' < 0.3，' +",
        "                 '生成地图坡道无法连通。请先将 Match.tscn 中 terrain_navigation_input 所属' +",
        "                 ' NavigationMesh 的 agent_max_climb 设为 0.5。')",
        "    exit 1",
        "  }",
        "}",
        "if ($GodotExe) {",
        "  & $GodotExe --headless --path $AirtsRoot --import",
        "  if ($LASTEXITCODE -ne 0) { Write-Error 'Godot 导入失败'; exit 1 }",
        f"  Write-Host '导入完成。启动游戏后在地图列表选择 Generated {map_id}。'",
        "} else {",
        "  Write-Host '文件已安装。请用 Godot 打开工程完成导入（或带 -GodotExe 参数重跑）。'",
        "}",
    ]
    # utf-8-sig（带 BOM）：Windows PowerShell 5.1 无 BOM 会按 ANSI 误读中文注释/字符串导致 parse error
    (root / "install.ps1").write_text("\n".join(lines), encoding="utf-8-sig", newline="\r\n")


def _install_readme(map_id):
    return f"""生成的 RTS 地图包 {map_id}
================================

内容：
- source/map_{map_id}.tscn     地图场景（真实高程地形、桥、水域、资源、装饰）
- source/height_data.bin       地形高度场（与场景/碰撞/导航同源）
- source/map_index.json        地图登记项（AI_RTS 自动发现，无需手改代码）
- runtime/                     随包冻结的运行脚本/内置贴图（GeneratedTerrain.gd、
                               ApplyAtlas.gd、ridge_rock.png），安装从包内取，不依赖开发机
- data/                        G1–G4 权威数据（npz/json，可复现与审计）
- reports/                     导航验收目标、导出与高度场报告、视觉计划
- assets/dependencies.json     完整依赖清单：运行脚本 + 素材（逐项 sha256、来源）
                               + 运行时版本要求（Godot/算法版本/terrain navmesh climb）
- install.ps1                  安装脚本（缺依赖明确失败 exit 1，不会假报完成）
- previews/                    正交与游戏斜视截图（Godot 实际输出）

安装（目标：Godot 4.7 mono 版 AI_RTS）：
1. 在 PowerShell 中执行（-AssetSource 为素材来源目录，默认指向包声明的初选素材包）：
   .\\install.ps1 -AirtsRoot "<AI_RTS工程根>" -GodotExe "<Godot_v*-stable_mono_win64_console.exe>"
2. 脚本把地图复制到 source/match/maps/generated/{map_id}/，从包内 runtime/ 装运行脚本，
   从 -AssetSource 装素材（缺失则 exit 1 并列出缺项），校验 terrain navmesh 配套后运行 Godot 导入。
3. 启动 AI_RTS，在 Play → 地图列表选择 “Generated {map_id}”。

运行时要求（dependencies.json.runtime_requirements）：
- Godot 4.7.1-stable mono；算法/管线版本见清单。
- terrain navmesh agent_max_climb 必须 >=0.3（坡道连通）；本包配套值为 0.5，
  安装脚本会校验目标 Match.tscn，若为 0.0 则失败并提示先应用配套。
- 素材 FBX/PNG 若目标工程已存在则跳过；其余从 -AssetSource 安装，允许外部素材目录，
  但任何缺项都会使安装明确失败（不生成不可用的“安装完成”）。
"""


def rebuild_visual(job, project, folder, save, new_visual_seed=None, profile=None):
    """固定逻辑地图，只重建视觉（交接接口 #7）：新视觉版本，不覆盖前一版对照。

    逻辑数据（G1–G3 权威通道与哈希）不动；仅重跑 G4 场景组装 + 引擎截图。
    """
    folder = Path(folder)
    seed = job["config"]["layout_seed"]
    runs = folder / "runs"
    map_id = job["map_id"]
    if new_visual_seed is None:
        new_visual_seed = secrets.randbelow(2147483647)
    old_version = int(job.get("visual_version", 1))
    new_version = old_version + 1
    # 归档前一版对照（不覆盖）
    archive = folder / "g4" / f"visual_v{old_version}"
    archive.mkdir(parents=True, exist_ok=True)
    for name in ("visual_plan.json", "export.json"):
        src = runs / str(seed) / "G4" / name
        if src.exists():
            shutil.copy2(src, archive / name)
    shots = folder / "shots"
    for png in list(shots.glob(f"{map_id}_*.png")) + list(shots.glob(f"{map_id}_v*")):
        shutil.move(str(png), str(archive / png.name))
    job["visual_seed"] = int(new_visual_seed)
    job["visual_version"] = new_version
    g4_params = dict(g4_export.G4_PARAMS_DEFAULTS)
    g4_params["terrain_seed"] = job["config"].get("terrain_seed", 0)
    if profile:
        g4_params["visual_profile"] = profile
        job["visual_profile"] = profile  # 供 _run_engine 重写场景时沿用同一样式
    # 逻辑哈希核对：重建前后 G2/G3 权威数据必须一致
    logic_before = _logic_hashes(runs, seed)
    rec = StageRecorder(job, folder, save)
    rec.mark_t0("g4_scene")
    rec.begin("g4_scene", stage="G4", version=ALGO_VERSION["G4"],
              note=f"visual rebuild v{new_version}")
    out_dir = folder / "g4" / map_id
    _build_g4(job, seed, runs, out_dir, g4_params, rec, save,
              lambda v: None)
    logic_after = _logic_hashes(runs, seed)
    if logic_before != logic_after:
        raise RuntimeError("视觉重建改变了逻辑数据哈希——已中止（接口契约 #3）。")
    job.setdefault("visual_history", []).append(dict(
        version=old_version, archive=str(archive),
        visual_seed=job.get("visual_seed"), rebuilt_at=_now()))
    rec2 = StageRecorder(job, folder, save)
    rec2.mark_t0("engine")
    rec2.begin("engine", stage="ENGINE", version="godot", note=f"visual rebuild v{new_version}")
    _run_engine(job, folder, rec2, save, lambda v: None)
    _finalize(job, folder, save)
    return job


def _logic_hashes(runs, seed):
    out = {}
    for gate_name in ("G1", "G2", "G3"):
        npz = Path(runs) / str(seed) / gate_name / "mapgrid.npz"
        if npz.exists():
            out[gate_name] = sha256_file(npz)
    return out
