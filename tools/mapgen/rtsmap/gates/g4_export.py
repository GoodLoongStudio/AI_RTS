"""G4：Godot 场景导出（文本 .tscn 手写生成）+ 资产复制 + 真实地形几何。

2026-09-06 重写（主计划阶段C/D）：
- 输出按唯一 map_id 隔离（map_<mapid>.tscn），不再用 seed_<N>.tscn 覆盖不同地貌。
- Terrain 为真实高程网格：运行时由 GeneratedTerrain.gd 读取 G4/height_data.bin
  （与 Python 校验同源的高度场）构建 ArrayMesh；Match 用该网格建 trimesh 碰撞，
  导航烘焙自碰撞 → 视觉/碰撞/导航/高度查询同源。
- 台地平顶 3.6m、地面 0.6m、3m 高差；坡口生成连续坡面；崖脚/岸坡连续过渡；
  桥面可走、桥下水床连续（水面板与河床分离表达）。
- 出生点/资源/物件按真实地表高度放置（处理模型原点 min_y），不再固定 Y=0。
- 视觉装饰实例来自 rtsmap/presentation 的 VisualPlan（GLM 接口），结构性遮挡
  实例仍来自 G3 objects.json（碰撞由格网游程盒统一承担，GLM 不得改结构）。

允许改动 AI_RTS 的范围：新增 source/match/maps/generated/*、新增
assets/models/scifi-worlds/*、MatchConstants.gd 的 GENERATED_MAPS 动态发现段。
其余不动；旧 seed_16/35/61 平面地图保留可运行。
"""
import json
import hashlib
import math
import re
import shutil
from pathlib import Path

import numpy as np

from ..contract import ALGO_VERSION, G2_DEFAULTS, G4_AIRTS, SRC_PREVIEW_ROOT, W, H
from ..gate import ensure_upstream_approved, run_dir
from ..grid import MapGrid, read_json, sha256_file, write_json
from ..rng import gate_seed_int
from . import g4_terrain

SRC_ROOT = Path(SRC_PREVIEW_ROOT)
DST_ASSET_ROOT = Path(G4_AIRTS) / "assets" / "models" / "scifi-worlds"
GENERATED_DIR = Path(G4_AIRTS) / "source" / "match" / "maps" / "generated"
CATALOG = Path(__file__).resolve().parents[1] / "data" / "assets_catalog.json"
SCRIPT_SRC_DIR = Path(__file__).resolve().parents[1] / "data" / "godot_scripts"

EXT_MAP_TSCN = ('[ext_resource type="PackedScene" uid="uid://b7c1crf36x1li" '
                'path="res://source/match/Map.tscn" id="1_map"]')
EXT_MAT = ('[ext_resource type="Material" uid="uid://co8vfcoqqs5i8" '
           'path="res://source/match/resources/materials/terrain.material.tres" id="2_mat"]')
EXT_RES_A = ('[ext_resource type="PackedScene" uid="uid://bf3jjdafqvh0w" '
             'path="res://source/match/units/non-player/ResourceA.tscn" id="3_resa"]')
# B 已从玩法移除（2026-09-14）：不再导出 ResourceB.tscn 实例，也不再写进 ext_resource 列表。
# 需要恢复第二种资源时，连同 `resources` 过滤（见本文件 Resources 段）一起恢复。
EXT_GEN_TERRAIN = ('[ext_resource type="Script" '
                   'path="res://source/match/maps/generated/GeneratedTerrain.gd" id="5_terrain"]')
EXT_APPLY_ATLAS = ('[ext_resource type="Script" '
                   'path="res://source/match/maps/generated/ApplyAtlas.gd" id="6_apply"]')
EXT_RIDGE_TEX = ('[ext_resource type="Texture2D" '
                 'path="res://assets/models/scifi-worlds/generated/ridge_rock.png" id="7_ridge_tex"]')
# 水面：与 review 渲染器同一份 showcase_water.gdshader（mask_from_tex=1 下
# 按世界坐标采样 terrain_masks.png 的岸距通道），纹理沿用 review 的同两张贴图。
EXT_WATER_SHADER = ('[ext_resource type="Shader" '
                    'path="res://source/match/maps/generated/showcase_water.gdshader" '
                    'id="8_water"]')
EXT_WATER_DIFF = ('[ext_resource type="Texture2D" '
                  'path="res://assets/terrain_pbr/dense_sand_diff.jpg" id="9_wdiff"]')
EXT_WATER_NORM = ('[ext_resource type="Texture2D" '
                  'path="res://assets/terrain_pbr/dense_sand_normal.jpg" id="10_wnorm"]')

G4_PARAMS_DEFAULTS = {
    # G2 remains a 256 m strategic raster; G4 exports it at 8 m per cell.
    # AI_RTS runtime uses the logical 512x512 playfield directly.  Scaling
    # this to 2048m multiplies navigation, culling and terrain workload and
    # makes the map effectively unplayable on the target client.
    "world_scale_m": 1.0,
    # 显示几何（不改变逻辑语义；见 g4_terrain 文档）
    "apron_cells": 4,        # 崖脚坡水平展宽（格）
    "shore_cells": 3,        # 岸坡水平展宽（格）
    "ramp_run_m": 15.0,      # 坡面水平长度（3m 高差 → 11.3° 连续坡）
    "water_surface_y": 0.0,  # 水面高度（地面 0.6 以下、水床 -2.4 以上）
    "bridge_deck_thickness": 0.4,
    "visual_profile": "default",
    # 高程分类值与 G2 契约保持一致（权威来源：G2_DEFAULTS）
    "ground_level": G2_DEFAULTS["ground_level"],
    "water_level": G2_DEFAULTS["water_level"],
    "plateau_level": G2_DEFAULTS["plateau_level"],
    "plateau_ramp_width": G2_DEFAULTS["plateau_ramp_width"],
}


def _res_to_dst(res_path: str) -> str:
    """res://assets/4006_科幻世界/... → res://assets/models/scifi-worlds/4006_科幻世界/..."""
    tail = res_path[len("res://assets/"):]
    return f"res://assets/models/scifi-worlds/{tail}"


def _import_uid(absolute_res_path: str):
    """导入后从 <file>.import 读 uid（无则 None）。"""
    rel = absolute_res_path[len("res://"):]
    import_file = Path(G4_AIRTS) / (rel + ".import")
    if not import_file.exists():
        return None
    m = re.search(r'uid="(uid://[^"]+)"', import_file.read_text(encoding="utf-8",
                                                               errors="ignore"))
    return m.group(1) if m else None


def copy_assets(seeds, runs_root, airts_root=None, extra_res=()):
    """复制 assets_used（+视觉计划依赖 extra_res）到 AI_RTS。

    只复制原始 .fbx/.png，不复制 .import 侧车：导入缓存（.godot/imported）
    是工程专属的，跨工程复制 .import 会指向不存在的缓存导致加载失败；
    新文件由 Godot --import 生成 .import 与 uid，场景在导入后重建以绑定 uid。
    返回 (fbx_res, atlas_res, copied_now)。
    """
    airts = Path(airts_root or G4_AIRTS)
    fbx_all, atlas_all = set(), set()
    for seed in seeds:
        u = read_json(run_dir(runs_root, seed, "G3") / "assets_used.json")
        fbx_all.update(u["fbx"])
        atlas_all.update(u["atlases"])
    for dep in extra_res:
        if str(dep).endswith(".png"):
            atlas_all.add(str(dep))
        else:
            fbx_all.add(str(dep))
    copied = 0
    for res_path in sorted(fbx_all | atlas_all):
        rel = res_path[len("res://"):]
        src = SRC_ROOT / rel
        dst = airts / rel.replace("assets/", "assets/models/scifi-worlds/", 1)
        if not src.exists():
            raise FileNotFoundError(f"素材缺失: {src}")
        if not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            copied += 1
    return sorted(fbx_all), sorted(atlas_all), copied


# Map instance 的世界缩放（由 build_scene_text 设置）：fbx 模型尺寸需反向补偿
_MODEL_SCALE_DIV = 1.0


def fmt_transform(x, y, z, yaw_deg=0.0, scale=1.0):
    """绕 Y 旋转 + 均匀缩放的 Transform3D 文本（Basis 行主序 = Godot roty 约定）。

    模型尺寸反向补偿：Map instance 以 world_scale 缩放（地形几何 格->世界），
    物件/桥等 fbx 模型必须 / world_scale 才能保持原生尺寸（否则 ×4 变成巨石）。
    位置 (x,y,z) 是父（instance）坐标系：不受自身 scale 影响，贴地仍自动一致。
    """
    scale = scale / _MODEL_SCALE_DIV
    a = math.radians(yaw_deg)
    c, s = math.cos(a) * scale, math.sin(a) * scale
    return (f"Transform3D({c}, 0, {s}, 0, {scale}, 0, {-s}, 0, {c}, "
            f"{x:.3f}, {y:.3f}, {z:.3f})")


def _grid_runs(mask):
    """bool 格网按行合并为横向游程 (i, j0, j1)。"""
    runs = []
    for i in range(mask.shape[0]):
        row = mask[i]
        j = 0
        while j < mask.shape[1]:
            if not row[j]:
                j += 1
                continue
            j0 = j
            while j < mask.shape[1] and row[j]:
                j += 1
            runs.append((i, j0, j - 1))
    return runs


def make_map_id(seed, terrain_seed, config=None):
    """唯一地图 ID：同 G1 配不同地貌不覆盖（主计划代码事实 #1）。

    Codex F1 修复：仅用 (layout_seed, terrain_seed) 时，导入/载入参数后只改河湖
    或高地参数仍保留相同两个 Seed，两项历史任务会引用同一安装目录并互相覆盖。
    故纳入完整有效内容（controls + 算法/schema 版本）哈希：相同 Seed、不同参数
    → 不同 map_id → 安装/截图/导出包各自隔离。

    视觉重建不改变逻辑身份：visual_seed / visual_version 不纳入哈希，同一逻辑
    地图的各视觉版本复用同一 map_id（安装反映最新视觉，旧视觉对照在任务目录
    g4/visual_v<N>/ 归档），使“固定逻辑、只重建视觉”的历史重试关系明确。
    """
    base = f"{int(seed)}-{int(terrain_seed)}"
    if not config:
        return base
    key = {
        "controls": config.get("controls") or {},
        "algo_version": config.get("algo_version"),
        "schema_version": config.get("schema_version"),
    }
    blob = json.dumps(key, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    digest = hashlib.sha256(blob.encode("utf-8")).hexdigest()[:10]
    return f"{base}-{digest}"


# ---------------------------------------------------------------------------
# 权威数据 → 高度场 / 导航验收目标
# ---------------------------------------------------------------------------

def build_geometry_data(runs_root, seed, g3_grid, g2_spec, g4_params):
    """构造显示高度场、导航验收目标与报告（全部来自本次任务权威数据）。"""
    plateaus = g2_spec["plateaus"]
    bridges = g2_spec.get("bridges", [])
    hf, meta = g4_terrain.build_heightfield(g3_grid, g4_params, plateaus, bridges)
    report = g4_terrain.heightfield_report(hf, meta, g4_params)
    targets = _nav_targets(hf, g2_spec, g4_params, meta)
    return hf, meta, report, targets


def _nav_targets(hf, g2_spec, g4_params, meta=None):
    """定向导航验收目标：真实高度来自同源 hf，防止投影到错误平面假连通。"""
    sh = g4_terrain.sample_height
    targets = []

    def add(kind, name, x, z, y=None, required=True):
        targets.append(dict(kind=kind, name=name, x=round(float(x), 3), z=round(float(z), 3),
                            y=round(float(sh(hf, x, z)) if y is None else float(y), 3),
                            required=required))

    for k, s in enumerate(g2_spec["starts"]):
        add("spawn", f"P{k}", s[0], s[1])
    for k, a in enumerate(g2_spec.get("expansion_anchors") or []):
        add("expansion", f"exp_P{k}", a[0], a[1])
    for k, pl in enumerate(g2_spec["plateaus"]):
        cx, cz = pl["center"]
        add("plateau_top", f"top_{k}_{pl['kind']}", cx, cz)
        for r, (rc, rdir) in enumerate(zip(pl["ramp_centers"], pl["ramp_dirs"])):
            # 实测约定：ramp_dirs 指向台地内部（dot(rc-center, dir) < 0）；
            # 用点积稳健判向：坡顶在内侧 4m，坡底在外侧 8m。
            inward = np.array(rdir, dtype=float)
            if float(np.dot(np.array(rc, dtype=float) - np.array(pl["center"], dtype=float),
                            inward)) > 0:
                inward = -inward
            add("ramp_top", f"ramp_{k}_{r}_top", rc[0] + inward[0] * 4.0,
                rc[1] + inward[1] * 4.0)
            add("ramp_bottom", f"ramp_{k}_{r}_bottom", rc[0] - inward[0] * 12.0,
                rc[1] - inward[1] * 12.0)
    for b, br in enumerate(g2_spec.get("bridges") or []):
        add("bridge_bank", f"bridge_{b}_a", br["a"][0], br["a"][1])
        add("bridge_bank", f"bridge_{b}_b", br["b"][0], br["b"][1])
    # 路径验收对：出生两两 / 出生→扩张 / 坡底→坡顶 / 桥两岸（资源在 add_resource_targets 补充）
    paths = []
    n_sp = len(g2_spec["starts"])
    for i in range(n_sp):
        for j in range(i + 1, n_sp):
            paths.append([f"P{i}", f"P{j}"])
        paths.append([f"P{i}", f"exp_P{i}"])
    for k, pl in enumerate(g2_spec["plateaus"]):
        for r in range(len(pl["ramp_centers"])):
            paths.append([f"ramp_{k}_{r}_bottom", f"ramp_{k}_{r}_top"])
            paths.append([f"ramp_{k}_{r}_top", f"top_{k}_{pl['kind']}"])
    for b, br in enumerate(g2_spec.get("bridges") or []):
        paths.append([f"bridge_{b}_a", f"bridge_{b}_b"])
    forbidden = _forbidden_probes(meta, g4_params)
    return dict(targets=targets, paths=paths, forbidden=forbidden,
                height_tolerance_m=1.2, xy_tolerance_m=2.5)


def _erode(mask, n):
    """形态学腐蚀 n 格（~dilate8(~mask) 重复 n 次）。"""
    from ..pathing import dilate8
    out = mask.copy()
    for _ in range(n):
        out = ~dilate8(~out)
    return out & mask


def _spread_points(mask, n):
    """从 mask 中取至多 n 个分散点（粗网格分桶，每桶取一个）。"""
    ii, jj = np.nonzero(mask)
    if len(ii) == 0:
        return []
    import math as _m
    side = max(1, int(_m.ceil(_m.sqrt(n))))
    h, w = mask.shape
    buckets = {}
    for i, j in zip(ii, jj):
        buckets.setdefault((int(i // (h / side)), int(j // (w / side))), (int(i), int(j)))
    pts = list(buckets.values())
    return pts[:n]


def _forbidden_probes(meta, g4_params):
    """禁止穿越探测点（Codex F2）：验证导航不覆盖水域与崖壁面。

    - water：水域内部（腐蚀 3 格）点，探测于水面高度；导航最近点 3D 距离
      必须 >= clearance（水面无可走导航，单位不能穿越水域）。
    - cliff：崖壁环格（台地 region 内 blocking 且非坡道），探测于崖面中段高度
      （地面与台地顶中点）；导航最近点 3D 距离必须 >= clearance（崖面垂直不可爬）。
    """
    probes = {"water": [], "cliff": []}
    if not meta:
        return probes
    ground = float(g4_params["ground_level"])
    top = float(g4_params["plateau_level"])
    water_level = float(g4_params.get("water_surface_y", 0.0))
    mid_y = (ground + top) / 2.0
    water = meta.get("water")
    if water is not None and water.any():
        for (i, j) in _spread_points(_erode(water, 3), 8):
            probes["water"].append(dict(
                name=f"forbid_water_{len(probes['water'])}",
                x=round(j + 0.5, 3), y=round(water_level, 3), z=round(i + 0.5, 3),
                clearance_m=2.0))
    region = meta.get("plateau_region")
    blocking = meta.get("blocking")
    ramp = meta.get("ramp_blend")
    if region is not None and blocking is not None:
        cliff = region & blocking & ~(ramp if ramp is not None else False)
        for (i, j) in _spread_points(cliff, 8):
            probes["cliff"].append(dict(
                name=f"forbid_cliff_{len(probes['cliff'])}",
                x=round(j + 0.5, 3), y=round(mid_y, 3), z=round(i + 0.5, 3),
                clearance_m=1.2))
    return probes


def _hf_cell_m(hf) -> float:
    """Heightfield vertex spacing in semantic metres (not the old 2048 world)."""
    return float(W) / max(int(hf.shape[0]) - 1, 1)


def _slope_at(hf, x: float, z: float) -> float:
    """语义格中心差分坡度（等比缩放下与游戏内坡度一致）。"""
    cell = _hf_cell_m(hf)
    i = int(min(max(round(x / cell), 1), hf.shape[1] - 2))
    j = int(min(max(round(z / cell), 1), hf.shape[0] - 2))
    dhx = abs(float(hf[j, i + 1]) - float(hf[j, i - 1])) / 2.0
    dhz = abs(float(hf[j + 1, i]) - float(hf[j - 1, i])) / 2.0
    return max(dhx, dhz) / cell


def _nearest_walkable(hf, x: float, z: float, max_r: float = 30.0):
    """环形向外找最近可走点（坡度<=0.9 且非水）；找不到返回 None。"""
    cell = _hf_cell_m(hf)
    span_x, span_z = float(W), float(H)
    for ring in range(1, int(max_r / cell) + 1):
        r = ring * cell
        for k in range(16):
            ang = k / 16.0 * 6.28318
            cx, cz = x + np.cos(ang) * r, z + np.sin(ang) * r
            if not (0 <= cx <= span_x and 0 <= cz <= span_z):
                continue
            if _slope_at(hf, cx, cz) <= 0.9:
                y = float(g4_terrain.sample_height(hf, cx, cz))
                if y >= 0.3:
                    return cx, cz, y
    return None


def add_resource_targets(nav, resources, hf):
    for k, r in enumerate(resources):
        nav["targets"].append(dict(
            kind="resource", name=f"res_{k}_{r['type']}", x=round(float(r["x"]), 3),
            z=round(float(r["z"]), 3),
            y=round(float(g4_terrain.sample_height(hf, r["x"], r["z"])), 3), required=True))
        owner = r.get("owner")
        if owner and owner.startswith("P"):
            nav["paths"].append([owner, f"res_{k}_{r['type']}"])


# ---------------------------------------------------------------------------
# .tscn 组装
# ---------------------------------------------------------------------------

def build_visual_plan_safe(context, g4_params, visual_seed):
    """调用 presentation 视觉接口；缺资源/不兼容必须报错，不静默回退。"""
    from ..presentation import build_visual_plan, load_profile
    profile_name = g4_params.get("visual_profile", "default")
    profile = load_profile(profile_name)
    return build_visual_plan(context, profile, visual_seed)


def _walkable_slab_runs(hf, blocking, water_fp, bridge, ramp_band=None):
    """可走格（非 blocking、非纯水，或坡道带强制可走）按行游程合并为高度板。

    top = 游程内格心高度场均值（同游程内高度差 ≤0.06 才合并，保证板顶平整）。
    桥面格单独由桥盒承担，不重复输出。
    """
    import numpy as np
    H, W = blocking.shape
    # Runtime performance: collapse the navigation collision raster to 4x4
    # semantic cells.  The authoritative masks remain unchanged; this only
    # reduces thousands of redundant StaticBody/BoxShape nodes in the game
    # scene.  Bridges and blocked cells are still excluded at block level.
    stride = 4
    if ramp_band is None:
        ramp_band = np.zeros((H, W), dtype=bool)
    h2, w2 = (H + stride - 1) // stride, (W + stride - 1) // stride
    cell_h = np.zeros((h2, w2), dtype=np.float64)
    walkable = np.zeros((h2, w2), dtype=bool)
    for bi in range(h2):
        for bj in range(w2):
            ys=slice(bi*stride,min(H,(bi+1)*stride)); xs=slice(bj*stride,min(W,(bj+1)*stride))
            b=blocking[ys,xs]; wf=water_fp[ys,xs].astype(bool); br=bridge[ys,xs]
            # conservative: a block is walkable only when its centre is
            # walkable and it contains no blocking/water/bridge cells.
            ci=min(H-1,bi*stride+stride//2); cj=min(W-1,bj*stride+stride//2)
            walkable[bi,bj]=((blocking[ci,cj]==0) or ramp_band[ci,cj]) and not wf.any() and not br.any()
            vals=[g4_terrain.sample_height(hf,j+0.5,i+0.5) for i in range(ys.start,ys.stop) for j in range(xs.start,xs.stop)]
            cell_h[bi,bj]=float(np.mean(vals))
    H,W=h2,w2
    runs = []
    for i in range(H):
        row = walkable[i]
        j = 0
        while j < W:
            if not row[j]:
                j += 1
                continue
            j0 = j
            h0 = cell_h[i, j]
            while (j + 1 < W and row[j + 1] and abs(cell_h[i, j + 1] - h0) <= 0.06):
                j += 1
            top = float(cell_h[i, j0:j + 1].mean())
            # 斜向坡道的相邻行游程仅角相接→recast 不连通；坡道游程左右各扩 1 格
            # 使相邻行板边重叠（边相邻），保证坡面在导航里连续。
            if ramp_band[i, j0:j + 1].any():
                j0 = max(0, j0 - 1)
                j = min(W - 1, j + 1)
            runs.append((i, j0, j, top))
            j += 1
    return runs


def build_scene_text(map_id, runs_root, seed, out_dir, g4_params, visual_seed=None):
    """生成 map_<map_id>.tscn 及伴随数据文件，返回产物路径 dict。"""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    rd = run_dir(runs_root, seed, "G4")
    rd.mkdir(parents=True, exist_ok=True)

    g3_dir = run_dir(runs_root, seed, "G3")
    g2_spec = read_json(run_dir(runs_root, seed, "G2") / "mapspec.json")
    g3_spec = read_json(g3_dir / "mapspec.json")
    resources = read_json(g3_dir / "resources.json")["resources"]
    objects = read_json(g3_dir / "objects.json")["instances"]
    # Performance profile: G4 runtime keeps only terrain and structural
    # blockers.  G3 object instances are decorative props and are omitted;
    # authoritative masks remain untouched.
    if g4_params.get("visual_profile") == "natural":
        objects = []
    catalog_list = json.loads(CATALOG.read_text(encoding="utf-8"))
    catalog = {e["res_path"]: e for e in catalog_list}
    grid = MapGrid.load(g3_dir / "mapgrid.npz")
    terrain = grid.get("terrain")
    blocking = grid.get("blocking")
    starts = g2_spec["starts"]

    # ---- 真实地形几何（同源数据：网格/碰撞/导航/高度查询） ----
    hf, meta, hf_report, nav = build_geometry_data(runs_root, seed, grid, g2_spec, g4_params)

    # ---- 资源落点迁移：烘入山体后，语义层摆放可能落在山坡/水中 ----
    # （G3 语义层不知道山高）坡度超限或入水 -> 环形外推到最近可走点。
    # tscn 模型位置与 nav_targets 校验目标共用迁移后坐标。
    for r in resources:
        if _slope_at(hf, float(r["x"]), float(r["z"])) > 0.9 or \
                g4_terrain.sample_height(hf, float(r["x"]), float(r["z"])) < 0.3:
            found = _nearest_walkable(hf, float(r["x"]), float(r["z"]))
            if found is not None:
                r["x"], r["z"] = found[0], found[1]

    add_resource_targets(nav, resources, hf)
    height_data = out_dir / "height_data.bin"
    g4_terrain.write_height_data(height_data, hf)
    hf_hash = sha256_file(height_data)

    # ---- terrain_masks.png：共享 shader（showcase_land）的着色掩码 ----
    # RGBA 1025^2，与 height_data 同网格：R=plateau_d G=shore_d B=lake_d（语义米 /300 编码）
    # A=cls（(v+1)/2 编码，正=rock 强度，负=ramp）。GeneratedTerrain 建网格时采样写入 UV/UV2。
    from PIL import Image as _Image
    from scipy import ndimage as _ndi

    # Match the runtime height field: write_height_data default upsample=2
    # turns (GRID+1) vertices into (2*GRID+1). Hardcoding 1025 kept 128m maps
    # on a million-texel mask for no gameplay reason.
    size = (int(hf.shape[0]) - 1) * 2 + 1
    chan = []
    # 双极编码：v/600 + 0.5（支持 plateau/lake 的带符号距离，±300m 量程）
    for key in ("dist_plateau_d", "dist_shore_d", "dist_lake_d"):
        a = meta[key]
        up = _ndi.zoom(a, (size - 1) / max(a.shape[0] - 1, 1), order=1)
        chan.append(np.clip(up / 600.0 + 0.5, 0.0, 1.0))
    cls_up = _ndi.zoom(meta["dist_cls"], (size - 1) / max(meta["dist_cls"].shape[0] - 1, 1), order=1)
    chan.append(np.clip((cls_up + 1.0) / 2.0, 0.0, 1.0))
    mask_img = (np.dstack(chan) * 255.0).astype(np.uint8)
    _Image.fromarray(mask_img, "RGBA").save(out_dir / "terrain_masks.png")
    from ..viz.plots_g2 import write_minimap_preview
    write_minimap_preview(
        out_dir / "minimap_preview.png",
        grid,
        g2_spec.get("bridges") or [],
        height=hf,
    )

    # ---- 桥组合（4006 真实素材，替代裸 BoxMesh 桥面/护栏）----
    from . import bridge_assembly as ba
    bridge_asm = []
    bridge_res = set()
    for br in (g2_spec.get("bridges") or []):
        asm = ba.build_bridge_assembly(
            br, lambda x, z: g4_terrain.sample_height(hf, x, z))
        bridge_asm.append(asm)
        for p in asm["parts"]:
            bridge_res.add(p["res"])
    # 缺素材必须明确报错，不能静默退回旧方盒桥并标为通过。
    # 【2026-09-20 修复】原先只检查**源路径**（SRC_ROOT/…）是否存在，但素材在历史上
    # 已经安装到 `assets/models/scifi-worlds/…`（见 `_res_to_dst` 的转换目标），
    # 而源目录（原始素材包，被 .gitignore 有意排除，见其中
    # "Commercial / huge source pack" 注释）**并不在仓库里** ⇒ 明明可用却被误判为缺失，
    # G4 导出就此中断（复刻大湖 seed16 时复现）。
    # 现在改为：目标路径存在 = 已安装可用；源路径存在 = 可拷贝；两者都没有才算真正缺失。
    for res in sorted(bridge_res):
        rel = res[len("res://"):]
        dst_path = Path(G4_AIRTS) / _res_to_dst(res)[len("res://"):]
        if (SRC_ROOT / rel).exists() or dst_path.exists():
            continue
        raise FileNotFoundError(f"桥组合素材缺失（源与目标都不存在）: {res}")

    # ---- G2 装饰语义提示层（decoration_hints）：视觉排布的唯一分区依据 ----
    from . import g2_decor
    g2_dir = run_dir(runs_root, seed, "G2")
    decor_zones, decor_meta = g2_decor.load_hints(g2_dir)
    if decor_zones is not None:
        print(f"decoration hints: {g2_dir} zones="
              f"{ {k: int(v.sum()) for k, v in decor_zones.items() if v.dtype == bool} }")

    # ---- 视觉计划（GLM 扩展接口；默认样式已实现） ----
    if visual_seed is None:
        visual_seed = gate_seed_int(seed, "G4", ALGO_VERSION["G4"]) ^ (int(g4_params.get("terrain_seed", 0) or 0) * 2654435761)
        visual_seed &= 0x7FFFFFFF
    context = dict(
        map_id=map_id, world_size_m=[W * float(g4_params.get("world_scale_m", 1.0)),
                                     H * float(g4_params.get("world_scale_m", 1.0))],
        cell_m=float(g4_params.get("world_scale_m", 1.0)),
        height=grid.get("height"), heightfield=hf,
        water_footprint=grid.get("water_footprint").astype(bool),
        blocking=blocking, blocking_g2=grid.get("blocking_g2"),
        terrain=terrain, passable=grid.get("passable"),
        lane_core=grid.get("lane_core"),
        plateaus=g2_spec["plateaus"], bridges=g2_spec.get("bridges", []),
        rivers=g2_spec.get("rivers", []), lakes=g2_spec.get("lakes", []),
        starts=starts, resources=resources,
        expansion_anchors=g2_spec.get("expansion_anchors", []),
        lanes=read_json(run_dir(runs_root, seed, "G2") / "lanes.json"),
        ramp_blend=meta["ramp_blend"], apron=meta["apron"], shore=meta["shore"],
        bridge_mask=meta["bridge"], water_mask=meta["water"],
        catalog={e["res_path"]: e for e in catalog_list},
        catalog_list=catalog_list, g4_params=g4_params,
        # G2 装饰提示层（只读；None 时视觉层优雅回退到旧的规则排布）
        decoration=decor_zones, decoration_meta=decor_meta,
    )
    visual = build_visual_plan_safe(context, g4_params, visual_seed)

    # ---- ext_resource ----
    ext_lines = [EXT_MAP_TSCN, EXT_MAT, EXT_RES_A,
                 EXT_GEN_TERRAIN, EXT_APPLY_ATLAS, EXT_RIDGE_TEX,
                 EXT_WATER_SHADER, EXT_WATER_DIFF, EXT_WATER_NORM]
    fbx_ids = {}
    visual_fbxs = sorted({i["asset"] for i in visual["instances"]})
    for k, res_path in enumerate(sorted({o["fbx"] for o in objects} | set(visual_fbxs) | bridge_res)):
        dst_res = _res_to_dst(res_path)
        uid = _import_uid(dst_res)
        uid_part = f'uid="{uid}" ' if uid else ""
        eid = f"10{k:03d}"
        fbx_ids[res_path] = eid
        ext_lines.append(f'[ext_resource type="PackedScene" {uid_part}path="{dst_res}" '
                         f'id="{eid}"]')

    height_res = f"res://source/match/maps/generated/{map_id}/height_data.bin"
    # 不要把 terrain_masks.png 写成 Texture2D ext_resource。新 map_id 装机时
    # 还没有 .import / .ctex，Godot 会让整张 PackedScene 加载失败
    # （Loading 只看到“地图加载失败”）。GeneratedTerrain 运行时直接读盘。
    sub_lines = [
        # 地面/台地/坡道可视材质：未光照暖土色（GL 兼容下 trimesh 曾黑面，
        # 故基线用与碰撞同源的高度板盒顶作可视面；视觉层后续可换 trimesh+贴图）。
        '[sub_resource type="StandardMaterial3D" id="Mat_ground"]',
        f"albedo_color = Color({visual['materials']['terrain_albedo_color']})",
        "shading_mode = 0",
        "roughness = 1.0",
        "",
        '[sub_resource type="ShaderMaterial" id="Mat_water"]',
        'shader = ExtResource("8_water")',
        'shader_parameter/rock_tex = ExtResource("9_wdiff")',
        'shader_parameter/sand_normal = ExtResource("10_wnorm")',
        "shader_parameter/mask_from_tex = 1.0",
        "shader_parameter/mask_world_size = "
        f"{W * float(g4_params.get('world_scale_m', 1.0)):.1f}",
        # p 只用于水面噪声 UV；review 侧 showcase_world_scale=1.0（世界即米），
        # 游戏世界同样是米（0..2048），故一致取 1.0。
        "shader_parameter/showcase_world_scale = 1.0",
        "shader_parameter/terrain_depth = false",
        "",
        '[sub_resource type="StandardMaterial3D" id="Mat_bridge"]',
        f"albedo_color = Color({visual['materials']['bridge_albedo_color']})",
        "roughness = 0.95",
    ]

    world_scale = float(g4_params.get("world_scale_m", 1.0))
    global _MODEL_SCALE_DIV
    _MODEL_SCALE_DIV = world_scale
    node_lines = ['[node name="Map" instance=ExtResource("1_map")]',
                  f"size = Vector2({W * world_scale:.1f}, {H * world_scale:.1f})",
                  # Y 缩放与 XZ 一致：游戏内高度 = 语义 x world_scale（与 review 的
                    # 语义 x logical_cell 同尺度）。AI_RTS 无高度硬编码常量，
                    # 单位贴地走 navmesh/物理自动跟随。
                    f"scale = Vector3({world_scale:.6f}, {world_scale:.6f}, {world_scale:.6f})",
                  "",
                  '[node name="Terrain" parent="Geometry" index="1"]',
                  'script = ExtResource("5_terrain")',
                  f'height_data_path = "{height_res}"',
                  f'semantic_span = {W:.1f}',
                  f'world_scale = {world_scale:.4f}',
                  f'terrain_albedo = Color({visual["materials"]["terrain_albedo_color"]})',
                  ""]
    # SpawnPoints（真实地表高度）
    for k, (x, z) in enumerate(starts):
        name = "Marker3D" if k == 0 else f"Marker3D{k + 1}"
        # Marker is the unit pivot; unit scenes place their visual root above
        # the pivot, so keep the pivot slightly below the sampled ground.
        y = g4_terrain.sample_height(hf, x, z) - 0.75
        node_lines.append(f'[node name="{name}" type="Marker3D" parent="SpawnPoints"]')
        # Map instance scales the terrain to world metres; SpawnPoints are
        # siblings of Map, so their positions must be scaled explicitly.
        node_lines.append("transform = Transform3D(-1, 0, -8.74228e-08, 0, 1, 0, "
                          f"8.74228e-08, 0, -1, {x * world_scale:.3f}, {(y + 0.2) * world_scale:.3f}, {z * world_scale:.3f})")
        node_lines.append("")
    # Resources（真实地表高度）
    # B 已从玩法移除（见 Structure.gd：建造与出售退款只用 resource_a）⇒ 导出层**跳过 B 类型资源点**，
    # 不再产出 ResourceB.tscn 实例；口径与游戏侧白名单一致
    # （adjutant_coordinator/graph/reserves.py 的 ACTIVE_KINDS、DebugControlServer.gd 的 ADJUTANT_RESOURCE_KINDS）。
    # 编号用独立计数器：跳过 B 之后 A 矿的名字保持连续（ResourceA / ResourceA2 / …）。
    a_index = 0
    for r in resources:
        if str(r.get("type", "A")).upper() != "A":
            continue
        name = "ResourceA" if a_index == 0 else f"ResourceA{a_index + 1}"
        a_index += 1
        eid = "3_resa"
        # Resource scene has a small bottom clearance; compensate at export so
        # the base touches the generated terrain instead of hovering.
        y = g4_terrain.sample_height(hf, r["x"], r["z"]) - 0.45
        node_lines.append(f'[node name="{name}" parent="Resources" instance=ExtResource("{eid}")]')
        # Resources are also siblings of the scaled Map instance.  Leaving
        # logical 512-grid coordinates here puts all 24 mines in the first
        # quarter of the 2048 m scene, outside the visible terrain/camera.
        node_lines.append(f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, "
                          f"{r['x'] * world_scale:.3f}, {y * world_scale:.3f}, {r['z'] * world_scale:.3f})")
        node_lines.append("")
    # Decorations（G3 结构性遮挡实例：纯视觉，碰撞由下方游程盒统一承担）
    node_lines.append('[node name="Decorations" parent="." index="3"]')
    node_lines.append('script = ExtResource("6_apply")')
    node_lines.append("")
    for k, o in enumerate(objects):
        eid = fbx_ids[o["fbx"]]
        e = catalog.get(o["fbx"], {})
        min_y = float(e.get("min_y", 0.0) or 0.0)
        ground_y = g4_terrain.sample_height(hf, o["x"], o["z"])
        # 注：catalog 的 min_y 值域跨 400 倍（含异常），直接用于偏移会把物件
        # 推到空中（实测）。仅在正值（原点在模型下方）时上抬，保持既有行为。
        y = ground_y + (-min_y if min_y > 0 else 0.0)
        node_lines.append(f'[node name="Obj{k}" parent="Decorations" '
                          f'instance=ExtResource("{eid}")]')
        node_lines.append(f"transform = {fmt_transform(o['x'], y, o['z'], o['yaw'], o['scale'])}")
        node_lines.append(f'metadata/atlas = "{_res_to_dst(o["atlas"])}"')
        node_lines.append(f"metadata/blocking = {'true' if o['blocking'] else 'false'}")
        if o["terrain"] in (1, 2, 3):
            node_lines.append('metadata/tint = "1.26,1.10,0.88"')
        elif o["terrain"] == 4:
            node_lines.append('metadata/tint = "1.06,0.97,0.86"')
        node_lines.append("")
    # Visual（GLM 视觉装饰实例：无碰撞、受保护区校验，见 presentation/）
    node_lines.append('[node name="Visual" type="Node3D" parent="." index="4"]')
    node_lines.append('script = ExtResource("6_apply")')
    node_lines.append(f'metadata/style_version = "{visual["style_version"]}"')
    node_lines.append("")
    for k, ins in enumerate(visual["instances"]):
        eid = fbx_ids[ins["asset"]]
        ground_y = g4_terrain.sample_height(hf, ins["x"], ins["z"])
        min_y = float(ins.get("origin_min_y", 0.0) or 0.0)
        y = ground_y + (-min_y if min_y > 0 else 0.0)
        node_lines.append(f'[node name="Vis{k}" parent="Visual" '
                          f'instance=ExtResource("{eid}")]')
        node_lines.append(f"transform = {fmt_transform(ins['x'], y, ins['z'], ins['yaw'], ins['scale'])}")
        node_lines.append(f'metadata/atlas = "{_res_to_dst(ins["atlas"])}"')
        node_lines.append('metadata/blocking = false')
        tint = ins.get("tint")
        if tint:
            node_lines.append(f'metadata/tint = "{tint}"')
        node_lines.append("")

    # ---- 碰撞：blocking 格网按行游程 → BoxShape3D（底随高度场，顶盖过表面） ----
    # 坡道带（ramp_blend）保持可走：G3 偶发把遮挡实例放到坡口格会切断坡道，
    # 故坡道带内的 blocking 格不输出障碍盒、并强制输出可走高度板。
    # 水域格（Codex F2 禁止穿越水域）：water blocking 盒顶曾置于 water_surface+1.0，
    # 被 recast 烘成可走面 → 单位能“走水面”（穿过水面的隐藏平面通路）。故水域格
    # 不输出导航固体盒，成为导航空洞；跨水通行仅由桥面板承担（桥下 trimesh 水床连续）。
    node_lines.append('[node name="Collision" type="Node3D" parent="." index="5"]')
    node_lines.append("")
    water_fp = grid.get("water_footprint").astype(bool)
    ramp_band = meta["ramp_blend"]
    solid_mask = (blocking > 0) & ~ramp_band & ~water_fp
    # Coarsen static blocker raster for the large G4 runtime.  The source
    # blocking mask remains authoritative; this only reduces physics bodies.
    if W * world_scale >= 256.0:
        s = 4
        hh, ww = (solid_mask.shape[0] + s - 1) // s, (solid_mask.shape[1] + s - 1) // s
        coarse = np.zeros((hh, ww), dtype=bool)
        for bi in range(hh):
            for bj in range(ww):
                ys=slice(bi*s, min(solid_mask.shape[0], (bi+1)*s)); xs=slice(bj*s, min(solid_mask.shape[1], (bj+1)*s))
                coarse[bi,bj] = bool(solid_mask[ys,xs].any())
        solid_mask = coarse
    solid_runs = _grid_runs(solid_mask)
    for k, (i, j0, j1) in enumerate(solid_runs):
        s = 4 if W * world_scale >= 256.0 else 1
        w = float((j1 - j0 + 1) * s)
        cx = j0 * s + w / 2.0
        cz = i * s + s / 2.0
        cells_hf = [g4_terrain.sample_height(hf, j * s + 0.5, i * s + 0.5) for j in range(j0, j1 + 1)]
        h_min, h_max = min(cells_hf), max(cells_hf)
        bottom = h_min - 0.5
        top = min(h_max + 2.4, 6.0)
        top = max(top, bottom + 0.5)
        cy = (bottom + top) / 2.0
        sub_lines.append("")
        sub_lines.append(f'[sub_resource type="BoxShape3D" id="BoxShape3D_s{k}"]')
        sub_lines.append(f"size = Vector3({w:.1f}, {top - bottom:.2f}, {s:.1f})")
        node_lines.append(f'[node name="Solid{k}" type="StaticBody3D" '
                          f'parent="Collision" groups=["terrain_navigation_input"]]')
        # AI_RTS 约定：地形/障碍 StaticBody 用 collision_layer 2（navmesh 解析 mask 只含它）
        node_lines.append("collision_layer = 2")
        node_lines.append("collision_mask = 0")
        node_lines.append(f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, "
                          f"{cx:.1f}, {cy:.2f}, {cz:.1f})")
        node_lines.append("")
        node_lines.append(f'[node name="CollisionShape3D" type="CollisionShape3D" '
                          f'parent="Collision/Solid{k}"]')
        node_lines.append(f'shape = SubResource("BoxShape3D_s{k}")')
        node_lines.append("")

    # ---- 可走面碰撞：高度场按行游程切成“高度板”BoxShape3D（顶=格高）。
    # 开放单面高度场 trimesh 在 recast 里烘焙为 0 多边形（bake_test 实测），
    # 故导航/可走碰撞用同源高度场派生的固体高度板；坡道 0.2m/格台阶被
    # agent_max_climb=0.5 合并为连续坡，崖壁 3m 台阶不可爬。视觉/点击仍用 trimesh。
    # G4 large maps intentionally skip runtime navigation baking.  In that
    # mode walk slabs are never consumed by NavigationServer but still enter
    # the physics broadphase, costing tens of milliseconds per frame.  Omit
    # them; static blockers and bridge decks remain authoritative collisions.
    emit_walk_collision = (W * world_scale) < 256.0
    walk_runs = (_walkable_slab_runs(hf, blocking, water_fp, meta["bridge"], ramp_band)
                 if emit_walk_collision else [])
    for k, (i, j0, j1, htop) in enumerate(walk_runs):
        # _walkable_slab_runs uses a 4x4 coarse raster for runtime collision.
        stride = 4
        w = float((j1 - j0 + 1) * stride)
        cx = j0 * stride + w / 2.0
        cz = i * stride + stride / 2.0
        thick = 1.0
        cy = htop - thick / 2.0
        sub_lines.append("")
        sub_lines.append(f'[sub_resource type="BoxShape3D" id="BoxShape3D_w{k}"]')
        sub_lines.append(f"size = Vector3({w:.1f}, {thick:.2f}, {stride:.1f})")
        node_lines.append(f'[node name="Walk{k}" type="StaticBody3D" '
                          f'parent="Collision" groups=["terrain_navigation_input"]]')
        node_lines.append("collision_layer = 2")
        node_lines.append("collision_mask = 0")
        node_lines.append(f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, "
                          f"{cx:.1f}, {cy:.2f}, {cz:.1f})")
        node_lines.append("")
        node_lines.append(f'[node name="CollisionShape3D" type="CollisionShape3D" '
                          f'parent="Collision/Walk{k}"]')
        node_lines.append(f'shape = SubResource("BoxShape3D_w{k}")')
        node_lines.append("")
        # 地形 Terrain 已经负责可视地表；不要为每个导航板再创建 MeshInstance。

    # ---- 桥：4006 真实素材组合（可见）+ 校准可走板/护栏碰撞（导航/物理）----
    # 不再用程序生成的裸 BoxMesh 桥面/护栏作最终可见外观；程序仍负责定位/拼接/碰撞/导航。
    # 桥下水床/水面保持连续（水面板仍覆盖桥格）；不用隐藏平面穿水造假连通。
    for b, asm in enumerate(bridge_asm):
        node_lines.append(f'[node name="Bridge{b}" type="Node3D" parent="."]')
        # 复用 ApplyAtlas：按 metadata/atlas 给桥部件子树贴 4006 图集（FBX 原生无 albedo 会白模）
        node_lines.append('script = ExtResource("6_apply")')
        node_lines.append("")
        # 可见部件：deck 标准段重复 / end 每岸一层收口 / rail 连续护栏 / pillar 立柱
        for pi, p in enumerate(asm["parts"]):
            eid = fbx_ids[p["res"]]
            node_lines.append(f'[node name="P{pi}_{p["kind"]}" parent="Bridge{b}" '
                              f'instance=ExtResource("{eid}")]')
            node_lines.append(f"transform = {p['transform']}")
            node_lines.append(f'metadata/atlas = "{_res_to_dst(ba.ATLAS)}"')
            node_lines.append("")
        # 导航/碰撞可走板（端坡+平桥面，净宽）：进 terrain_navigation_input
        for wi, w in enumerate(asm["walk"]):
            sub_lines += ["", f'[sub_resource type="BoxShape3D" id="BoxShape3D_bw{b}_{wi}"]',
                          f"size = Vector3({w['width']:.2f}, {ba.WALK_THICK:.2f}, {w['length']:.2f})"]
            node_lines.append(f'[node name="WalkB{b}_{wi}" type="StaticBody3D" parent="Bridge{b}" '
                              f'groups=["terrain_navigation_input"]]')
            node_lines.append("collision_layer = 2")
            node_lines.append("collision_mask = 0")
            node_lines.append(f"transform = {fmt_transform(w['x'], w['top'] - ba.WALK_THICK / 2.0, w['z'], w['yaw'])}")
            node_lines.append("")
            node_lines.append(f'[node name="CollisionShape3D" type="CollisionShape3D" '
                              f'parent="Bridge{b}/WalkB{b}_{wi}"]')
            node_lines.append(f'shape = SubResource("BoxShape3D_bw{b}_{wi}")')
            node_lines.append("")
        # 护栏物理碰撞（不进导航组；导航靠净宽留洞，护栏顶不可走）
        for ri, r in enumerate(asm["rails"]):
            sub_lines += ["", f'[sub_resource type="BoxShape3D" id="BoxShape3D_brc{b}_{ri}"]',
                          f"size = Vector3({r['width']:.2f}, 1.2, {r['length']:.2f})"]
            node_lines.append(f'[node name="RailC{b}_{ri}" type="StaticBody3D" parent="Bridge{b}"]')
            node_lines.append("collision_layer = 1")
            node_lines.append("collision_mask = 0")
            node_lines.append(f"transform = {fmt_transform(r['x'], r['top'] - 0.6, r['z'], r['yaw'])}")
            node_lines.append("")
            node_lines.append(f'[node name="CollisionShape3D" type="CollisionShape3D" '
                              f'parent="Bridge{b}/RailC{b}_{ri}"]')
            node_lines.append(f'shape = SubResource("BoxShape3D_brc{b}_{ri}")')
            node_lines.append("")

    # ---- 水体视觉：水面板按行游程合并（水面 y=0，河床在高度场中连续，桥下不断水） ----
    node_lines.append('[node name="WaterBody" type="Node3D" parent="." index="6"]')
    node_lines.append("")
    ws = float(g4_params["water_surface_y"])
    # 水面片必须用 water_footprint（G2/G3 的水足迹，与权威高度场的水床
    # -2.4 一致）而不是 G3 的 terrain==5 分类 —— 实测 terrain==5 的格
    # 在高度场里是 0.6~10.3m 的高地，按其生成的水面片全部埋在地下
    # （游戏内"河没有水"的根因，2026-09-14 定位）。
    #
    # 可视水面再外扩 2 格：水面片是平面 y=0，而河床 -2.4 / 平地 0.6，岸坡在
    # shore_cells=3 格内爬升。不外扩时水面片自身的边界正好压在坡面上，2m 渲染
    # 网格把它切成锯齿梳齿（游戏内实测明显）。外扩后水面片边界埋进岸坡地下，
    # 可见水线变成"地形 ∩ y=0 平面"的连续交线 —— 与 review 渲染器同一手法。
    # 只影响视觉：water_footprint 等权威掩码不动，WaterBody 无碰撞、不进导航。
    from scipy import ndimage as _ndi_water
    # 256+ 大图运行时会藏掉这些水面片（否则 Compatibility 透明排序打穿帧率）。
    # 仍写进 tscn 只会增加 load_steps，并让未导入的水面材质拖垮整图加载。
    emit_water_meshes = (W * world_scale) < 256.0
    if emit_water_meshes:
        _water_vis = _ndi_water.binary_dilation(
            grid.get("water_footprint") > 0, iterations=2)
        water_runs = _grid_runs(_water_vis)
    else:
        water_runs = []
    for k, (i, j0, j1) in enumerate(water_runs):
        w = float(j1 - j0 + 1)
        cx = j0 + w / 2.0
        cz = i + 0.5
        sub_lines += ["", f'[sub_resource type="BoxMesh" id="BoxMesh_w{k}"]',
                      f"size = Vector3({w:.1f}, 0.1, 1)"]
        node_lines.append(f'[node name="WaterMesh{k}" type="MeshInstance3D" '
                          f'parent="WaterBody"]')
        node_lines.append(f'mesh = SubResource("BoxMesh_w{k}")')
        node_lines.append('material_override = SubResource("Mat_water")')
        node_lines.append(f"transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, "
                          f"{cx:.1f}, {ws:.2f}, {cz:.1f})")
        node_lines.append("")

    n_sub = sum(1 for ln in sub_lines if ln.startswith("[sub_resource"))
    load_steps = len(ext_lines) + n_sub + 1
    text = "\n".join([f"[gd_scene load_steps={load_steps} format=3]", ""] + ext_lines +
                     [""] + sub_lines + [""] + node_lines)
    tscn = out_dir / f"map_{map_id}.tscn"
    tscn.write_text(text, encoding="utf-8", newline="\n")

    write_json(rd / "nav_targets.json", nav)
    write_json(rd / "heightfield_report.json", hf_report)
    write_json(rd / "visual_plan.json", visual)
    write_json(rd / "export.json", {
        "gate": "G4", "master_seed": seed, "map_id": map_id,
        "gate_seed": gate_seed_int(seed, "G4", ALGO_VERSION["G4"]),
        "algo_version": ALGO_VERSION["G4"], "params": g4_params,
        "visual_seed": int(visual_seed), "visual_style_version": visual["style_version"],
        "visual_dependencies": visual["asset_dependencies"],
        "bridge_assets": [dict(asset=r, atlas=ba.ATLAS) for r in sorted(bridge_res)],
        "bridge_meta": [a["meta"] for a in bridge_asm],
        "tscn": str(tscn), "height_data": str(height_data),
        "height_data_sha256": hf_hash,
        "heightfield_report": hf_report,
        "visual_stats": visual.get("stats", {}),
        "visual_warnings": visual.get("warnings", []),
        "decoration_hints": {
            "present": decor_zones is not None,
            "path": str(g2_dir / "decoration_hints.npz"),
            "algo_version": (decor_meta or {}).get("decoration_algo_version"),
            "all_pass": (decor_meta or {}).get("all_pass"),
            "zone_cells": {k: int(v["cells"]) for k, v in (decor_meta or {}).get("zones", {}).items()},
            "protection": (decor_meta or {}).get("protection", {}),
        },
    })
    return dict(tscn=tscn, height_data=height_data, height_data_sha256=hf_hash,
                hf_report=hf_report, nav=nav, visual=visual, map_id=map_id)


def _copy_with_retry(src, dst, tries: int = 3, delay: float = 0.2):
    """覆盖拷贝，遇到 Windows「文件被占用/已映射」时重试。

    本机有并行 AI 会话开着 Godot 编辑器，它会 mmap 已加载的 tscn / height_data.bin；
    此时 `shutil.copy2` 抛 `OSError [WinError 1224] 请求的操作无法在使用用户映射区域
    打开的文件上执行`。占用通常是瞬时的（编辑器重新加载完就释放），
    但**沉默半途失败**最贵：装机中断后 AI_RTS 里留的还是旧地图，
    而我读的却是新导出（上一轮就这么误判了"山没变高"）。故重试并最终明确报错。
    """
    import time
    last = None
    for k in range(tries):
        try:
            shutil.copy2(src, dst)
            return
        except OSError as exc:
            last = exc
            if getattr(exc, "winerror", None) not in (32, 33, 1224):
                raise
            print(f"      copy busy ({k + 1}/{tries}): {dst.name}", flush=True)
            time.sleep(delay)
    raise OSError(
        f"覆盖拷贝失败（目标被占用 {tries} 次）：{dst}\n"
        f"  源: {src}\n"
        f"  最可能的原因：Godot 编辑器正在使用该文件（本机有并行会话）。\n"
        f"  处理：在编辑器里重新加载项目 / 关闭占用该地图的场景后重跑。\n"
        f"  原始错误: {last}")


def install_runtime_scripts(airts_root=None):
    """已禁用：包内 GeneratedTerrain.gd 是旧副本，会盖掉游戏内带 semantic_span 的版本。

    装机只复制地图产物（tscn / height_data.bin / masks / minimap），不覆盖
    source/match/maps/generated 下的运行时脚本。
    """
    print(
        "skip install_runtime_scripts: keep game GeneratedTerrain.gd "
        f"(airts={airts_root or G4_AIRTS})",
        flush=True,
    )
    return []


def install_map(out_dir, map_id, airts_root=None):
    """把本次任务场景+高程数据+着色掩码安装到 AI_RTS generated/<map_id>/（唯一 ID）。"""
    airts = Path(airts_root or G4_AIRTS)
    dst = airts / "source" / "match" / "maps" / "generated" / map_id
    dst.mkdir(parents=True, exist_ok=True)
    out_dir = Path(out_dir)
    installed = []
    # terrain_masks.png 是共享 shader 的着色掩码（台地/岸/湖距离场 + 分类）。
    # 此前不在拷贝清单里：新 map_id 装机后 GeneratedTerrain._load_mask_uvs 读不到
    # 掩码会**静默返回全零 UV**（use_masks=1 的分支于是把整图按 distance=0 着色），
    # 表现为"新装地图配色整体不对"却没有任何报错。缺失必须直接报错。
    names = [f"map_{map_id}.tscn", "height_data.bin", "terrain_masks.png", "minimap_preview.png"]
    for name in names:
        src = out_dir / name
        if not src.exists():
            raise FileNotFoundError(f"导出产物缺失，不静默降级: {src}")
        _copy_with_retry(src, dst / name)
        installed.append(str(dst / name))
    preview_dir = airts / "assets" / "map_previews"
    preview_dir.mkdir(parents=True, exist_ok=True)
    _copy_with_retry(out_dir / "minimap_preview.png", preview_dir / f"map_{map_id}.png")
    installed.append(str(preview_dir / f"map_{map_id}.png"))
    scene_res = f"res://source/match/maps/generated/{map_id}/map_{map_id}.tscn"
    index = {
        "path": scene_res,
        "name": f"Generated {map_id}",
        "players": 4,
        "size": [int(W), int(H)],
        # 世界米 / 语义格：512 格 × 4.0 = 2048m（与 Map 基座 scale 一致）。
        # 旧值 8.0 与 size=2048 互斥（2048/8 = 256 格），属历史漂移，未被消费但会误导。
        "cell_m": float(G4_PARAMS_DEFAULTS["world_scale_m"]),
        "map_id": map_id,
        "height_data": f"res://source/match/maps/generated/{map_id}/height_data.bin",
        "height_data_sha256": sha256_file(out_dir / "height_data.bin"),
    }
    write_json(dst / "map_index.json", index)
    installed.append(str(dst / "map_index.json"))
    return scene_res, installed


# ---------------------------------------------------------------------------
# 正式 CLI 闸门（语义保留：上游 approved；输出唯一 map_id，不再同名覆盖）
# ---------------------------------------------------------------------------

def run_gate(runs_root, seeds, params=None, out_root=None, airts_root=None):
    params = {**G4_PARAMS_DEFAULTS, **(params or {})}
    for seed in seeds:
        ensure_upstream_approved(runs_root, seed, "G4")
    fbx, atlases, copied = copy_assets(seeds, runs_root, airts_root)
    print(f"copied {len(fbx)} fbx + {len(atlases)} atlases (+{copied} new files) -> {DST_ASSET_ROOT}")
    outs = []
    for seed in seeds:
        g2_spec = read_json(run_dir(runs_root, seed, "G2") / "mapspec.json")
        g2_params = g2_spec.get("params") or {}
        # CLI 闸门：用 G2 完整生成参数 + 算法版本作为有效内容参与 map_id 哈希，
        # 与工作台路径一致地保证“相同 Seed、不同参数不覆盖”。
        cli_config = {"controls": g2_params,
                      "algo_version": g2_spec.get("algo_version")}
        map_id = make_map_id(seed, g2_params.get("terrain_seed", 0), cli_config)
        out_dir = Path(out_root) / map_id if out_root else run_dir(runs_root, seed, "G4")
        built = build_scene_text(map_id, runs_root, seed, out_dir, params)
        scene_res, installed = install_map(out_dir, map_id, airts_root)
        print(f"exported {built['tscn']} -> {scene_res}")
        outs.append(built["tscn"])
    return outs
