"""视觉扩展接口（GLM 交接冻结层）：build_visual_plan(context, profile, visual_seed)。

契约（workbench-team/01 §五、visual-api.md）：
1. 输入只读：世界尺寸/单位、权威 height/heightfield、water_footprint、逻辑 blocking、
   台地/坡口/桥边界、出生/资源/路线保护区、可装饰区域、资产目录与独立视觉随机流。
2. 输出 VisualPlan：材质/调色配置、合法视觉实例（源路径/姿态/缩放/贴地方式/包围）、
   资产依赖、风格版本、统计与警告。
3. 视觉随机不改变出生、资源配额、逻辑格网、碰撞、导航或 G2 地貌 Seed；
   所有实例遵守结构与通路保护边界（占用格校验用有向矩形，不只中心点）。
4. 装饰无碰撞；需要碰撞/改变可走性的结构模型属于 G3/几何层，本模块不生成。
5. 缺资源或不兼容必须抛 VisualPlanError，不静默回退默认图。

GLM 允许修改：rtsmap/data/visual_profiles/*.json、本目录材质/规则实现（保持
build_visual_plan 签名与 VisualPlan schema）、受控素材索引扩展。
禁止修改：权威通道、G2/G3 几何、碰撞与导航语义、场景结构节点。
"""
import hashlib
import json
import math
from pathlib import Path

import numpy as np

from ..contract import G4_AIRTS, GRID_H, GRID_W, SRC_PREVIEW_ROOT
from ..grid import canon_json_bytes, sha256_bytes
from ..pathing import cell_of, dilate8

VISUAL_API_VERSION = "1.0.0"
PROFILE_DIR = Path(__file__).resolve().parents[1] / "data" / "visual_profiles"
SOURCE_ROOT = Path(SRC_PREVIEW_ROOT)
EXTRA_INDEX = Path(__file__).resolve().parents[1] / "data" / "visual_assets_extra.json"


def _asset_available(res_path: str) -> bool:
    """判断素材是否可用：**源路径存在** 或 **已安装到工程内**。

    【2026-09-20 修复】原先各处只查 `SOURCE_ROOT/…`（原始素材包目录），但原始包
    （4006_科幻世界 / 4041_西部前线 …）被 .gitignore **有意排除**
    （注释："Commercial / huge source pack — play via assets/models/scifi-worlds"），
    源目录不在仓库里；素材在历史上已经安装到
    `AI_RTS/assets/models/scifi-worlds/…`（见 g4_export._res_to_dst 的同名规则）
    ⇒ 明明可用却被误判为缺失，G4 导出在复刻大湖 seed16 时中断。
    现在：源存在 = 可拷贝；已安装目标存在 = 可用；都没有才算真正缺失。
    """
    rel = res_path[len("res://"):] if res_path.startswith("res://") else res_path
    if (SOURCE_ROOT / rel).exists():
        return True
    tail = rel[len("assets/"):] if rel.startswith("assets/") else rel
    return (Path(G4_AIRTS) / "assets" / "models" / "scifi-worlds" / tail).exists()


class VisualPlanError(RuntimeError):
    """样式缺资源、越界或不兼容——绝不静默回退。"""


def _extra_catalog():
    """受控素材索引（visual_assets_extra.json）→ 与 assets_catalog 同构 dict。

    4041 包实测条目（Godot headless 合并 AABB）；字段缺失或源文件缺失必须抛
    VisualPlanError，不静默回退。条目带 pools/scale_range 角色扩展字段，
    由各资产池按角色并入；对 name 匹配的 4006 原生条目零影响。
    """
    if not EXTRA_INDEX.exists():
        return {}
    raw = json.loads(EXTRA_INDEX.read_text(encoding="utf-8"))
    extras = {}
    for e in raw.get("entries", []):
        for key in ("res_path", "atlas", "name", "size", "min_y",
                    "blocking", "terrain_types", "pools"):
            if key not in e:
                raise VisualPlanError(
                    f"visual_assets_extra.json 条目缺字段 {key}: {e.get('name')}")
        for rp in (e["res_path"], e["atlas"]):
            if not _asset_available(rp):
                raise VisualPlanError(f"受控索引素材缺失（不静默回退）: {rp}")
        extras[e["res_path"]] = dict(e)
    return extras


def _pool_extras(catalog, role):
    """受控索引中带指定角色的条目（4006 原生条目无 pools 字段，不受影响）。"""
    return sorted((e for e in catalog.values()
                   if e.get("pools") and role in e["pools"]),
                  key=lambda e: e["name"])


def load_profile(name):
    path = PROFILE_DIR / f"{name}.json"
    if not path.exists():
        raise VisualPlanError(f"视觉样式不存在: {path}")
    profile = json.loads(path.read_text(encoding="utf-8"))
    profile["_path"] = str(path)
    profile["_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    return profile


def _visual_rng(visual_seed, profile):
    digest = hashlib.sha256(
        f"{int(visual_seed)}|{profile.get('name', 'default')}|{profile.get('style_version', '')}"
        .encode("utf-8")).digest()
    return np.random.Generator(np.random.PCG64(int.from_bytes(digest[:8], "little")))


# ---------------------------------------------------------------------------
# 保护区与可装饰区域（输入 context 派生；GLM 只能收紧，不能放松）
# ---------------------------------------------------------------------------

def build_zones(context):
    """语义掩码：forbidden（实例足迹禁入）/ decorable（开阔地装饰可用）。

    若 context 携带 G2 的 decoration_hints（``context['decoration']``），则把
    ``clear_zone`` 整体并入 forbidden —— 桥面/桥头、坡道核心、主战略通道、
    出生点安全圈、资源安全圈、水域与河心一律不得进入装饰；同时把
    tree/grass/stone/shore/mountain_foot 五个分区原样透传给放置器。
    """
    from ..gates.g3_content import clear_of_blocking
    blocking = context["blocking"] > 0
    water = context["water_footprint"]
    bridge = context["bridge_mask"]
    ramp = context["ramp_blend"]
    lane_core = context.get("lane_core")
    if lane_core is None:
        lane_core = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
        for lane in (context.get("lanes") or {}).values():
            if lane.get("kind") == "eco":
                continue
            from ..gates.g2_layout import segment_mask
            lane_core |= segment_mask(tuple(lane["polyline"][0]), tuple(lane["polyline"][-1]), 0)
    forbidden = np.zeros((GRID_H, GRID_W), dtype=bool)
    forbidden |= water & ~bridge          # 水面（桥面单独保护）
    forbidden |= bridge
    forbidden |= dilate8(bridge)
    forbidden |= ramp                     # 坡面（含崖外展开）
    forbidden |= dilate8(ramp)
    if lane_core is not None:
        forbidden |= lane_core > 0        # 主路线核心带保持可读
    for s in context["starts"]:
        i, j = cell_of(*s)
        forbidden |= _disc(s, 22.0)
    for a in context.get("expansion_anchors") or []:
        forbidden |= _disc(tuple(a), 16.0)
    for r in context.get("resources") or []:
        forbidden |= _disc((float(r["x"]), float(r["z"])), 6.0)
    # G2 装饰提示层：clear_zone 是权威「任何装饰不得进入」掩码
    hints = context.get("decoration")
    if isinstance(hints, dict) and "clear_zone" in hints:
        forbidden |= np.asarray(hints["clear_zone"], dtype=bool)
    # 资源净空：实例足迹不得把 blocking 推到距资源 <3m
    res_disc = np.zeros((GRID_H, GRID_W), dtype=bool)
    for r in context.get("resources") or []:
        res_disc |= _disc((float(r["x"]), float(r["z"])), 3.0)
    decorable = (~blocking) & (~forbidden) & (context["passable"] > 0)
    # 严格禁区：clear_zone 内任何格（含岩面）都不许被装饰足迹覆盖。
    no_go = np.zeros((GRID_H, GRID_W), dtype=bool)
    if isinstance(hints, dict) and "clear_zone" in hints:
        no_go |= np.asarray(hints["clear_zone"], dtype=bool)
    return dict(forbidden=forbidden, decorable=decorable, blocking=blocking,
                res_clear=clear_of_blocking(blocking.astype(np.uint8), 3.0) & ~res_disc,
                hints=hints, no_go=no_go)


def _disc(center, radius):
    x, z = np.meshgrid(np.arange(GRID_W) + 0.5, np.arange(GRID_H) + 0.5)
    return np.hypot(x - center[0], z - center[1]) <= radius


def _boundary_walk(mask, rng, spacing):
    """边界格采样：mask 中 8 邻全同类的内部格排除，只留轮廓格（乱序后由
    调用方按随机间距筛选，避免等距串珠）。"""
    padded = np.pad(mask, 1, mode="constant", constant_values=True)
    nb = (padded[:-2, 1:-1] & padded[2:, 1:-1] & padded[1:-1, :-2] & padded[1:-1, 2:])
    b = mask & ~nb
    ii, jj = np.nonzero(b)
    if len(ii) == 0:
        return []
    order = np.lexsort((jj, ii))
    return [(int(i), int(j)) for i, j in zip(ii[order], jj[order])]


def _outward_normal(mask, i, j):
    """边界格指向可走侧的平均方向（弧度角）。"""
    votes = np.zeros(2)
    for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)):
        ii, jj = i + di, j + dj
        if 0 <= ii < GRID_H and 0 <= jj < GRID_W and not mask[ii, jj]:
            votes += (dj, di)
    if not votes.any():
        return None
    return math.atan2(votes[1], votes[0])


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------

def build_visual_plan(context, profile, visual_seed):
    """纯视觉入口。返回机器可校验的 VisualPlan（schema 见 visual-api.md）。"""
    rng = _visual_rng(visual_seed, profile)
    zones = build_zones(context)
    catalog = context["catalog"]
    # 受控素材索引并入（4041 实测条目）：浅拷贝 context/catalog，不改写权威输入；
    # 由 profile 开关 use_extra_assets 门控——default 样式保持 100% 4006 原生目录
    # （契约测试断言 default 实例 ∈ 原生 catalog），natural 等新样式显式启用。
    extras = _extra_catalog() if profile.get("use_extra_assets") else {}
    if extras:
        catalog = dict(catalog)
        catalog.update(extras)
        context = dict(context)
        context["catalog"] = catalog
    by_path = catalog
    blocking = zones["blocking"]
    forbidden = zones["forbidden"]
    no_go = zones.get("no_go")

    instances = []
    warnings = []

    def add_instance(category, entry, x, z, yaw, scale, ground):
        from ..gates.g3_content import oriented_rect_cells, xz_footprint
        # 对齐到格心，保证有向包围至少含 1 格（校验体积非空）
        x = float(int(x) + 0.5)
        z = float(int(z) + 0.5)
        # 先取整 yaw/scale，再用取整后的值算足迹与占用格，保证与 _validate 完全一致
        yaw = round(float(yaw) % 360.0, 2)
        scale = round(float(scale), 4)
        w, h = xz_footprint(entry, scale, yaw)
        cells = oriented_rect_cells(x, z, w, h, yaw)
        # 校验考虑视觉体积（有向矩形占用格），不只中心点
        over = [(i, j) for i, j in cells
                if forbidden[i, j] and not blocking[i, j]]
        if over:
            return False
        if any(i < 0 or j < 0 or i >= GRID_H or j >= GRID_W for i, j in cells):
            return False
        # clear_zone 是绝对禁区：岩面也不能豁免
        if no_go is not None and any(no_go[i, j] for i, j in cells):
            return False
        instances.append(dict(
            category=category, asset=entry["res_path"], atlas=entry["atlas"],
            name=entry["name"], x=x, z=z,
            yaw=yaw, scale=scale,
            footprint_m=[w, h],
            origin_min_y=entry.get("min_y", 0.0) or 0.0,
            ground=ground, collision=False, blocking=False,
        ))
        return True

    # ---- 崖脚/崖线岩体：坐在 blocking 边界格上，足迹不得悬到可走侧 ----
    cliff_cfg = profile.get("cliff_rocks", {})
    if cliff_cfg.get("enabled", True):
        pool = _cliff_pool(catalog, cliff_cfg)
        cliff_mask = blocking & (context["terrain"] != 5)
        n_placed = 0
        budget = int(cliff_cfg.get("budget", 170))
        sites = _boundary_walk(cliff_mask, rng, 0)
        order = rng.permutation(len(sites))
        sites = [sites[k] for k in order]
        placed_pts = []
        for (i, j) in sites:
            if n_placed >= budget:
                break
            lo, hi = cliff_cfg.get("spacing_m", [5.0, 11.0])
            if any(math.hypot(i - p[0], j - p[1]) < rng.uniform(lo, hi) for p in placed_pts[-40:]):
                continue
            normal = _outward_normal(cliff_mask, i, j)
            if normal is None:
                continue
            entry = pool[int(rng.integers(len(pool)))]
            if rng.random() < float(cliff_cfg.get("large_chance", 0.25)):
                large = [e for e in pool if max(e["size"][0], e["size"][2]) >= 12.0]
                if large:
                    entry = large[int(rng.integers(len(large)))]
            s_lo, s_hi = entry.get("scale_range") or cliff_cfg.get("scale_range", [0.85, 1.15])
            scale = float(rng.uniform(s_lo, s_hi))
            if max(entry["size"][0], entry["size"][2]) * scale > float(cliff_cfg.get("max_footprint_m", 26.0)):
                continue
            yaw = math.degrees(normal) + float(rng.uniform(-30.0, 30.0))
            if add_instance("cliff", entry, j + 0.5, i + 0.5, yaw, scale, "surface"):
                n_placed += 1
                placed_pts.append((i, j))

    # ---- 岸边过渡：水岸线小岩件 + 耐水植物 ----
    shore_cfg = profile.get("shore_props", {})
    if shore_cfg.get("enabled", True):
        shore_rocks = _shore_pool(catalog)
        shore_plants = _plant_pool(catalog)
        bank = blocking & (context["terrain"] == 5)
        n_placed = 0
        budget = int(shore_cfg.get("budget", 130))
        sites = _boundary_walk(bank, rng, 0)
        order = rng.permutation(len(sites))
        sites = [sites[k] for k in order]
        placed_pts = []
        for (i, j) in sites:
            if n_placed >= budget:
                break
            lo, hi = shore_cfg.get("spacing_m", [6.0, 14.0])
            if any(math.hypot(i - p[0], j - p[1]) < rng.uniform(lo, hi) for p in placed_pts[-40:]):
                continue
            normal = _outward_normal(bank, i, j)
            if normal is None:
                continue
            use_plant = shore_plants and rng.random() < float(shore_cfg.get("plant_chance", 0.35))
            pool = shore_plants if use_plant else shore_rocks
            entry = pool[int(rng.integers(len(pool)))]
            s_lo, s_hi = entry.get("scale_range") or shore_cfg.get("scale_range", [0.8, 1.2])
            scale = float(rng.uniform(s_lo, s_hi))
            yaw = math.degrees(normal) + float(rng.uniform(-45.0, 45.0))
            if add_instance("shore", entry, j + 0.5, i + 0.5, yaw, scale, "surface"):
                n_placed += 1
                placed_pts.append((i, j))

    # ---- 开阔地点缀：小型非遮挡植被/碎石，成簇疏密有别 ----
    # 簇心偏向崖脚/岩缘带（视觉上“植物长在岩石边”），其余落在开阔地，
    # 避免全图均匀撒点（02 文档：装饰密度有主次）。
    scat_cfg = profile.get("scatter", {})
    if scat_cfg.get("enabled", True):
        props = _scatter_pool(catalog, scat_cfg)
        decorable = zones["decorable"] & zones["res_clear"]
        budget = int(scat_cfg.get("budget", 350))
        attempts = int(scat_cfg.get("attempts", 8000))  # 预留：受控重试上限
        clusters = []
        n_placed = 0
        n_clusters = max(6, budget // 14)
        r_lo, r_hi = scat_cfg.get("cluster_radius_m", [4.0, 9.0])
        c_lo, c_hi = scat_cfg.get("cluster_size", [6, 16])
        ii, jj = np.nonzero(decorable)
        if len(ii) and props:
            edge_zone = zones["decorable"] & dilate8(zones["blocking"])
            ei, ej = np.nonzero(edge_zone & zones["res_clear"])
            for _c in range(n_clusters):
                pick_edge = len(ei) > 0 and rng.random() < float(
                    scat_cfg.get("edge_cluster_ratio", 0.6))
                src_i, src_j = (ei, ej) if pick_edge else (ii, jj)
                k = int(rng.integers(len(src_i)))
                clusters.append((float(src_j[k]) + 0.5, float(src_i[k]) + 0.5,
                                 float(rng.uniform(r_lo, r_hi)),
                                 int(rng.integers(c_lo, c_hi + 1))))
            for cx, cz, radius, count in clusters:
                placed = 0
                for _t in range(count * 6):
                    if n_placed >= budget or placed >= count:
                        break
                    ang = float(rng.uniform(0, math.tau))
                    rad = radius * math.sqrt(float(rng.random()))
                    x, z = cx + math.cos(ang) * rad, cz + math.sin(ang) * rad
                    if not (2.0 <= x < GRID_W - 2.0 and 2.0 <= z < GRID_H - 2.0):
                        continue
                    i, j = cell_of(x, z)
                    if not decorable[i, j]:
                        continue
                    entry = props[int(rng.integers(len(props)))]
                    s_lo, s_hi = entry.get("scale_range") or (1.0, 1.5)
                    scale = float(rng.uniform(s_lo, s_hi))
                    yaw = float(rng.uniform(0.0, 360.0))
                    if add_instance("scatter", entry, x, z, yaw, scale, "surface"):
                        n_placed += 1
                        placed += 1
        if n_placed == 0 and budget > 0:
            warnings.append("scatter: 无可装饰区域或资产池为空")

    # ---- 装饰语义分区（G2 decoration_hints 驱动：tree/grass/stone/shore/mountain_foot）----
    dz_cfg = profile.get("decoration_zones", {})
    if dz_cfg.get("enabled"):
        _place_decoration_zones(context, profile, zones, catalog, rng,
                                add_instance, warnings)

    # ---- 资产依赖校验：源文件必须真实存在（只读素材包） ----
    deps = {}
    for ins in instances:
        deps.setdefault(ins["asset"], ins["atlas"])
    missing = []
    for res_path, atlas in sorted(deps.items()):
        for rp in (res_path, atlas):
            if not _asset_available(rp):
                missing.append(rp)
    if missing:
        raise VisualPlanError(f"视觉样式引用的素材缺失（不静默回退）: {missing[:8]}")

    plan = dict(
        api_version=VISUAL_API_VERSION,
        style_version=str(profile.get("style_version", "0")),
        profile=str(profile.get("name", "default")),
        profile_sha256=profile.get("_sha256", ""),
        visual_seed=int(visual_seed),
        materials=dict(profile.get("materials", {})),
        tint=dict(profile.get("tint", {})),
        instances=instances,
        asset_dependencies=[dict(asset=a, atlas=t) for a, t in sorted(deps.items())],
        stats=dict(
            total=len(instances),
            cliff=sum(1 for x in instances if x["category"] == "cliff"),
            shore=sum(1 for x in instances if x["category"] == "shore"),
            scatter=sum(1 for x in instances if x["category"] == "scatter"),
            tree=sum(1 for x in instances if x["category"] == "tree_zone"),
            grass=sum(1 for x in instances if x["category"] == "grass_zone"),
            stone=sum(1 for x in instances if x["category"] == "stone_zone"),
            shore_zone=sum(1 for x in instances if x["category"] == "shore_zone"),
            mountain_foot=sum(1 for x in instances if x["category"] == "mountain_foot_zone"),
            budget_total=int(profile.get("budget_total", 700)),
        ),
        warnings=warnings,
        checks={},
    )
    _apply_tints(plan, profile)
    plan["checks"] = _validate(plan, profile, zones, context)
    if not all(plan["checks"].values()):
        failed = [k for k, v in plan["checks"].items() if not v]
        raise VisualPlanError(f"视觉计划校验失败: {failed}")
    return plan


def _apply_tints(plan, profile):
    tint = profile.get("tint", {})
    for ins in plan["instances"]:
        key = ins["category"]
        if tint.get(key):
            ins["tint"] = tint[key]


def _validate(plan, profile, zones, context):
    from ..gates.g3_content import oriented_rect_cells
    forbidden = zones["forbidden"]
    blocking = zones["blocking"]
    no_go = zones.get("no_go")
    footprint_ok = True
    bounds_ok = True
    collision_free = True
    clear_zone_ok = True
    for ins in plan["instances"]:
        if ins["collision"] or ins["blocking"]:
            collision_free = False
        w, h = ins["footprint_m"]
        cells = oriented_rect_cells(ins["x"], ins["z"], w, h, ins["yaw"])
        for i, j in cells:
            if not (0 <= i < GRID_H and 0 <= j < GRID_W):
                bounds_ok = False
                break
            if forbidden[i, j] and not blocking[i, j]:
                footprint_ok = False
            if no_go is not None and no_go[i, j]:
                clear_zone_ok = False
    budget_ok = plan["stats"]["total"] <= plan["stats"]["budget_total"]
    assets_ok = all(d["asset"] in context["catalog"] for d in plan["asset_dependencies"])
    return dict(footprint_protection_pass=footprint_ok, bounds_pass=bounds_ok,
                collision_free_pass=collision_free, budget_pass=budget_ok,
                clear_zone_empty_pass=clear_zone_ok,
                assets_resolvable_pass=assets_ok,
                no_logic_channels_touched=True)


def plan_fingerprint(plan):
    """机器可校验指纹：同视觉 Seed/样式/权威输入 → 同指纹（确定性验收用）。"""
    payload = dict(api_version=plan["api_version"], style_version=plan["style_version"],
                   profile_sha256=plan["profile_sha256"], visual_seed=plan["visual_seed"],
                   instances=plan["instances"], materials=plan["materials"])
    return sha256_bytes(canon_json_bytes(payload))


# ---------------------------------------------------------------------------
# 资产池（受控筛选；GLM 扩展新池时在 visual-api.md 登记）
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# G2 装饰语义分区放置器（decoration_hints 驱动）
# ---------------------------------------------------------------------------
# 分区语义（与 rtsmap/gates/g2_decor.py 一致，只读不改）：
#   tree_zone          树 / 灌木 / 废土植被（成簇，侧翼后方与岩缘）
#   grass_zone         低矮草、干草、小簇植物（开阔地填充）
#   stone_zone         碎石、小型岩块（含山体/岩体表面）
#   shore_zone         湿岸植物与小石块（水陆交界陆侧）
#   mountain_foot_zone 山脚沉积扇、碎石与岩屑
#   clear_zone         任何装饰不得进入（已在 build_zones 并入 forbidden）
# 全部实例 collision=false / blocking=false，不参与导航烘焙。

DECOR_ROLES = ("stone", "mountain_foot", "shore", "tree", "grass")

# 预览实看剔除（与既有池保持一致）：异形红系蕨/花、深褐黑刺海带、
# 科技六边底座残骸、浮空岩——都不是自然地表装饰。
DECOR_EXCLUDE_PREFIX = ("SM_Env_Plant_Fern", "SM_Env_Plant_Flower", "SM_Env_Plant_Kelp",
                        "SM_Env_Ground_Greeble", "SM_Env_Floating")


def _eff_xz(entry):
    """条目在世界里的有效 XZ 边长（原生尺寸 × 缩放上限）。"""
    sr = entry.get("scale_range") or [1.0, 1.0]
    return max(entry["size"][0], entry["size"][2]) * float(max(sr))


def _zone_pool(catalog, role, cfg):
    """按角色取资产池。受控索引条目靠 pools 字段，4006 原生条目靠名称前缀。"""
    max_size = cfg.get("max_size_m", {})
    out = []
    for _k, e in catalog.items():
        if not e.get("atlas"):
            continue
        name = e["name"]
        if any(name.startswith(p) for p in DECOR_EXCLUDE_PREFIX):
            continue
        pools = e.get("pools") or []
        blocking = bool(e["blocking"])
        eff = _eff_xz(e)
        if role == "stone":
            ok = (not blocking) and ("Rock" in name or "rock" in name) and \
                 ("shore" in pools or "scatter" in pools or
                  name.startswith(("SM_Generic_Small_Rocks", "SM_Env_Rock_Spike")))
            ok = ok and eff <= float(max_size.get("stone", 6.0))
        elif role == "mountain_foot":
            ok = ("Rock" in name or "Quarry" in name) and \
                 ("scatter" in pools or "cliff" in pools or
                  name.startswith(("SM_Generic_Small_Rocks", "SM_Env_Rock_Spike")))
            ok = ok and eff <= float(max_size.get("mountain_foot", 9.0))
        elif role == "shore":
            ok = ("shore" in pools or "shore_veg" in pools) and \
                 ("Rock" in name or "Reeds" in name or "Grass" in name or
                  name.startswith("SM_Env_Plant"))
            ok = ok and eff <= float(max_size.get("shore", 4.0))
        elif role == "tree":
            ok = (not blocking) and name.startswith(
                ("SM_Env_Bush", "SM_Env_Tree", "SM_Env_Shrub_", "SM_Env_Plant_Small",
                 "SM_Env_Plant_Cactus", "SM_Env_Plant_Shrub"))
            ok = ok and eff >= float(cfg.get("tree_min_size_m", 0.7))
        elif role == "grass":
            ok = (not blocking) and name.startswith(
                ("SM_Env_Grass", "SM_Env_ShrubGrass", "SM_Env_Plant", "SM_Env_Bush",
                 "SM_Env_Shrub_", "SM_Env_Reeds"))
            ok = ok and eff <= float(max_size.get("grass", 2.2))
        else:
            ok = False
        if ok:
            out.append(e)
    out.sort(key=lambda e: (e["name"], e["res_path"]))
    return out


def _patch_noise(x, z, scale=120.0):
    """确定性 patch 噪声（默认 ~120 m 尺度，返回 0..1）。

    用于给簇心做门控：均匀采样出来的簇心在 RTS 远景里读作等间距串珠，而真实
    植被是成片聚集、片间留裸地。按格哈希而非 rng，保证同 seed 复现。
    """
    xi, zi = int(x // scale), int(z // scale)
    h = (xi * 73856093) ^ (zi * 19349663) ^ 0x9E3779B9
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h >> 8) & 0xFFFF) / 65535.0


def _place_decoration_zones(context, profile, zones, catalog, rng, add_instance, warnings):
    """按 G2 装饰语义分区摆放实例（无碰撞、保护区零侵入、确定性）。"""
    cfg = profile.get("decoration_zones", {})
    hints = zones.get("hints")
    if not isinstance(hints, dict) or "tree_zone" not in hints:
        warnings.append("decoration_zones: G2 decoration_hints 缺失，跳过分区装饰")
        return
    forbidden = zones["forbidden"]
    blocking = zones["blocking"]
    budgets = cfg.get("budgets", {})
    spacing_all = cfg.get("min_spacing_m", {})
    radius_all = cfg.get("cluster_radius_m", {})
    size_all = cfg.get("cluster_size", {})
    for role in DECOR_ROLES:
        budget = int(budgets.get(role, 0))
        if budget <= 0:
            continue
        zone_name = "shore_zone" if role == "shore" else f"{role}_zone"
        mask = np.asarray(hints.get(zone_name), dtype=bool).copy()
        if not mask.any():
            continue
        # stone / mountain_foot 允许贴在山体表面上；其余分区只落可走地。
        if role not in ("stone", "mountain_foot"):
            mask &= ~blocking
        mask &= ~forbidden
        ii, jj = np.nonzero(mask)
        if len(ii) == 0:
            warnings.append(f"decoration_zones[{role}]: 分区内无可用格")
            continue
        pool = _zone_pool(catalog, role, cfg)
        if not pool:
            warnings.append(f"decoration_zones[{role}]: 资产池为空")
            continue
        r_lo, r_hi = radius_all.get(role) or [4.0, 8.0]
        c_lo, c_hi = [int(v) for v in (size_all.get(role) or [2, 6])]
        spacing = float(spacing_all.get(role, 2.0))
        placed = []
        n = 0
        # 簇心带 patch 噪声门控（见 _patch_noise）：植被成片、片间留裸地，而不是
        # 均匀撒点。门控平均丢掉约 4 成簇心，故按 1/0.62 补偿簇数以免总量缩水。
        n_clusters = max(8, int(budget / max(1, (c_lo + c_hi) // 2) / 0.62))
        for k in rng.integers(0, len(ii), size=n_clusters):
            if n >= budget:
                break
            cx, cz = float(jj[k]) + 0.5, float(ii[k]) + 0.5
            if _patch_noise(cx, cz) < 0.40:
                continue
            want = int(rng.integers(c_lo, c_hi + 1))
            got = 0
            for _t in range(want * 12):
                if n >= budget or got >= want:
                    break
                ang = float(rng.uniform(0.0, math.tau))
                rad = float(rng.uniform(r_lo, r_hi)) * math.sqrt(float(rng.random()))
                x, z = cx + math.cos(ang) * rad, cz + math.sin(ang) * rad
                if not (2.0 <= x < GRID_W - 2.0 and 2.0 <= z < GRID_H - 2.0):
                    continue
                i, j = cell_of(x, z)
                if not mask[i, j]:
                    continue
                if spacing > 0.0 and any(
                        math.hypot(x - p[0], z - p[1]) < spacing for p in placed[-48:]):
                    continue
                entry = pool[int(rng.integers(len(pool)))]
                s_lo, s_hi = entry.get("scale_range") or (1.0, 1.0)
                scale = float(rng.uniform(float(s_lo), float(s_hi)))
                yaw = float(rng.uniform(0.0, 360.0))
                if add_instance(f"{role}_zone", entry, x, z, yaw, scale, "surface"):
                    placed.append((x, z))
                    n += 1
                    got += 1
        if n == 0:
            warnings.append(f"decoration_zones[{role}]: 未能放置任何实例")


def _cliff_pool(catalog, cfg):
    # "pools" not in e：受控索引条目由角色追加统一并入，避免前缀匹配重复
    pool = [e for _k, e in catalog.items() if e["blocking"] and e.get("atlas")
            and "pools" not in e
            and not e["name"].startswith("SM_Env_Floating")
            and 1 in e["terrain_types"]
            and e["name"].startswith(("SM_Env_Rock", "SM_Env_Cliff"))]
    # 4041 受控条目（实测 Quarry 崩壁/扁岩/立岩）按角色并入
    pool += _pool_extras(catalog, "cliff")
    if not pool:
        raise VisualPlanError("崖体资产池为空：catalog 中没有 SM_Env_Rock/Cliff 条目")
    pool.sort(key=lambda e: (e["name"], e["res_path"]))
    return pool


def _shore_pool(catalog):
    pool = [e for _k, e in catalog.items() if e.get("atlas")
            and "pools" not in e
            and e["name"].startswith(("SM_Generic_Small_Rocks", "SM_Env_Rock_Spike"))
            and max(e["size"][0], e["size"][2]) <= 8.0]
    # 4041 小碎石/扁岩并入（岸线暖色岩件）
    pool += _pool_extras(catalog, "shore")
    pool.sort(key=lambda e: (e["name"], e["res_path"]))
    if not pool:
        raise VisualPlanError("岸边资产池为空")
    return pool


def _plant_pool(catalog):
    # 预览实看剔除：SM_Env_Plant_Fern/Flower（异形红系）、SM_Env_Plant_Shrub
    # （青蓝色龙舌兰，冷色冲突）、SM_Env_Plant_Kelp（深褐黑刺，读成焦黑）。
    # 保留：Plant_Small（土黄泥块）、Plant_Cactus（绿+橙）+ 4041 水岸植被。
    names = ("SM_Env_Plant_Small", "SM_Env_Plant_Cactus")
    pool = [e for _k, e in catalog.items() if e.get("atlas")
            and "pools" not in e
            and not e["blocking"]
            and any(e["name"].startswith(n) for n in names)]
    pool += _pool_extras(catalog, "shore_veg")
    pool.sort(key=lambda e: (e["name"], e["res_path"]))
    return pool


def _scatter_pool(catalog, cfg):
    # 剔除：SM_Env_Ground_Greeble（科技六边底座/残骸，非自然物）、
    #       SM_Env_Plant_Fern/Flower（异形红系）——均经预览实看核验。
    names = ("SM_Generic_Small_Rocks", "SM_Env_Plant_Cactus",
             "SM_Env_Plant_Shrub", "SM_Env_Plant_Small")
    max_size = float(cfg.get("max_size_m", 4.5))
    pool = [e for _k, e in catalog.items() if e.get("atlas") and "pools" not in e
            and not e["blocking"]
            and any(e["name"].startswith(n) for n in names)
            and max(e["size"][0], e["size"][2]) <= max_size]
    # 4041 草灌/碎石/树桩并入（scale_range 含尺度补偿）
    pool += [e for e in _pool_extras(catalog, "scatter")
             if max(e["size"][0], e["size"][2]) <= max_size]
    pool.sort(key=lambda e: (e["name"], e["res_path"]))
    if not pool:
        raise VisualPlanError("开阔地装饰资产池为空")
    return pool
