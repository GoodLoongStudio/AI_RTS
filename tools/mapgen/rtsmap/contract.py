"""契约常量：尺寸、cell、画布、方向、各闸门 algo_version、默认约束表。

约定（方案文档为准）：
- 世界坐标 X∈[0,W]、Z∈[0,H]，单位米，原点在地图西北角，中心 = (W/2, H/2)。
- 格 (i,j) 覆盖 X∈[i·CELL,(i+1)·CELL)、Z∈[j·CELL,(j+1)·CELL)，格中心 ((i+0.5)·CELL,(j+0.5)·CELL)。
- 画布 2048×2048 PNG，地图区 1920×1920 位于偏移 (64,64)；PX_PER_M = MAP_PX / W（256m 图=7.5，非整数）：
  px = 64 + x·PX_PER_M。图像 x = 世界 +X（东），图像 y = 世界 +Z（南），图像上方 = 世界 −Z（北）。
  格→像素放大用 PIL resize（见 canvas.grid_to_map），不再用 np.repeat（PX_PER_M 非整数）。任何文字/图例不得进入地图区。
"""
from __future__ import annotations

import json
import os
from pathlib import Path

# ---- 地图与格网（2026-09-15：G4 四人图统一 256×256，不再出 512）----
W = 256.0                     # G2 地图宽（米，X 向东）
H = 256.0                     # G2 地图高（米，Z 向南）
N_PLAYERS = 4
CELL = 1.0                    # 米/格
GRID_W = 256
GRID_H = 256
MAP_CENTER = (128.0, 128.0)   # (x, z) = (W/2, H/2)

# ---- 画布 ----
CANVAS = 2048
MAP_PX = 1920
OFFSET = 64
PX_PER_M = MAP_PX / W         # 像素/米（256m 图 = 7.5，非整数）


def apply_map_extent(width_m, height_m=None):
    """Override the active map extent for one generation process.

    Gate modules bind ``W`` / ``GRID_W`` at import time. Call this *before*
    importing ``rtsmap.gates`` or ``rtsmap.grid``. Default four-player G4
    maps are 256×256; use this only for one-off sizes.
    """
    global W, H, GRID_W, GRID_H, MAP_CENTER, PX_PER_M
    width_m = float(width_m)
    height_m = float(width_m if height_m is None else height_m)
    W = width_m
    H = height_m
    GRID_W = int(round(width_m / CELL))
    GRID_H = int(round(height_m / CELL))
    MAP_CENTER = (W * 0.5, H * 0.5)
    PX_PER_M = MAP_PX / W
    return {"W": W, "H": H, "GRID_W": GRID_W, "GRID_H": GRID_H}


def world_to_px(x, z):
    return (OFFSET + x * PX_PER_M, OFFSET + z * PX_PER_M)


def px_to_world(px, py):
    return ((px - OFFSET) / PX_PER_M, (py - OFFSET) / PX_PER_M)


# ---- G1 约束表（默认值；--min-pair-factor 可覆盖）----
# 2026-09-04：地图 256m + 出生点多样化（用户要求"不要总在四角"）：
#   min_pair_factor 0.50→0.35（256m→89.6m），center_gap 按 0.25·min(W,H) 缩放到 64m，
#   top_frac 0.30→0.70（实验定：四角占比 0.70→0.27、接受率 46%，多样性最佳；再高则被约束过滤反而偏角）。
G1_DEFAULTS = {
    "margin": 12.0,             # 到四边 ≥ 12 m（基地盘所需，单位驱动，不随地图缩放）
    "min_pair_factor": 0.35,    # min_pair ≥ factor·sqrt(W·H)（256m→89.6m）：每出生点"间隔圈"半径=此值/2，圈内无相邻出生点
    "center_gap": 0.0,          # 2026-09-04 用户决定：去除中央战场/中央禁区（不再往地图中间画圈）；间隔全靠 min_pair
    "angle_min": 45.0,          # 相邻夹角下限（度）
    "angle_max": 150.0,         # 相邻夹角上限（度）
    "center_ratio": 99.0,       # 2026-09-04 已禁用（无中央战场，"到中心等距"无意义，且它是四角化的主因）；公平改由 territory_ratio + nn_ratio 承担
    "territory_ratio": 1.3,     # Voronoi 领地格数 max/min
    "nn_ratio": 1.3,            # 最近邻距离 max/min
    "max_attempts": 200,        # 每 Seed 最大尝试次数
    "candidates": 32,           # 最佳候选法每次抽的候选数
    "top_frac": 0.70,           # 取距离降序前 70%（放宽→四角占比 0.70→0.27，多样性最佳）
}
G1_CORNER_DIST = 64.0           # 四角退化阈值：出生点到最近地图角 < 64 m（随地图缩放，仅报告）
CONTEST_BAND = 20.0             # 争夺带：到最近与次近出生点距离差 < 20 m（随地图缩放）
BASE_RADIUS = 10.0              # 基地盘半径（米，单位驱动，不随地图缩放）

# ---- 闸门算法版本（改算法必须升版本）----
# G2 4.0.0（2026-09-04，用户否定散点掩体后重做）：改为"结构性地形"——河道（支状水带+渡口）、
# 悬崖线（+坡口）、高地块（+坡道）、基地间分隔脊（+咽喉）；散点掩体降为少量点缀。
# 属推翻性重做，升主版本 4.0.0。
# G1 2.0.0（2026-09-04）：地图 96m→256m + 出生点多样化（min_pair_factor 0.35 / top_frac 0.50），
# 属参数与尺度的重大变更，升主版本（亦阻断对旧 1.0.0 approved 的继承）。
# G3 2.2.0（2026-09-06 适配 G2 v6）：扩张公平比事后迭代修补（防守环漏斗使距离池偏斜）；
# 实例预算 1500→2000（v6 结构簇增多）。属算法变更，升次版本。
# G3 2.1.0（2026-09-05 用户反馈）：阻碍素材改用地形（石块/悬崖/山体），弃用建筑围墙件；
# G3 2.0.0（2026-09-05，GLM5.3Flash）：适配 G2 v4.0.0 新结构（256m、无中央战场、water 地形）——
# 取消中心 2B+1A（改为每条 flank 补 1×B，保证每家 B 数量相等，属接手提示词允许的偏差）、
# 扩张资源路径带改为按各玩家扩张锚点实际距离自适应（96m 的固定 18–28m 在 256m 上不可满足）、
# 簇来源改为从 G2 npz blocking 连通分量派生（v4.0.0 不再写 obstacles.json）、water 格保留 blocking
# 不实例化（G4 以水体碰撞盒呈现）。属结构性重做，升主版本。
# G2 6.0.0（2026-09-06，v6 战略结构重做）：生成顺序改为 出生点特征→战略节点→抽象路线图→
# 路线 raster→出生点局部防守保护→台地与水域→墙体与掩体→连通与公平评分。
# 台地/水域加量（用户反馈"台地和河可以多一点"）：plateau_count 4–6、双水墙 pair_0+pair_2、独立河 (0,1)；
# 台地槽位绑定争夺区（overwatch）；新增中立争夺区、出生点防守环、台地/争夺公平验收；
# 隔墙地形改 rock（自然岩脊观感，弃近黑 wall 色）。属结构性重做，升主版本。
# G2 7.0.0: connected watershed, exposed-spawn plateaus, strategic neutral heights; no defense arcs.
# G2 7.1.0: directional landmass outlines, recessed ramp mouths, grouped outcrops.
# G2 7.2.0: supported workbench parameters, independent terrain Seed, exact crossing counts.
# G2 7.3.0: optional river, closed lakes, varied strategic sites and full G1 layout library.
# G2 7.5.0（2026-09-06）: constructive closed-lake placement (erosion-pocket candidates
# instead of ~0.3%-hit rejection sampling); fixes river+lake and double-lake combos
# failing with NoTerrainCandidate. Water sizes/counts/fairness thresholds unchanged.
ALGO_VERSION = {"G1": "2.0.0", "G2": "7.11.0", "G3": "2.2.0", "G4": "2.0.0"}
# ---- 随机流版本（gate_rng 派生用）----
# 闸门子 Seed = sha256(seed|gate|algo_version)；随机流版本与算法版本一致。
# G2 terrain_seed非0时，版本串追加 |terrain=N；实际rng_stream和gate_seed写入mapspec。
RNG_VERSION = {"G1": "2.0.0", "G2": "7.10.0", "G3": "2.2.0", "G4": "2.0.0"}
GATES = ["G1", "G2", "G3", "G4"]

# ---- 格网通道与 dtype（保存顺序 = 定义顺序；下游禁止改上游通道）----
CHANNEL_DTYPES = [
    ("territory", "u2"),   # G1: Voronoi 领地 0..3
    ("region", "u2"),      # G2: 区域编号（role*10 + idx）
    ("role", "u1"),        # G2: 1 home / 2 center / 3 flank / 4 expansion / 5 hinterland
    ("lane_core", "u1"),   # G2: 通道核心带位标（bit i = main_i, bit 4+k = flank_k）
    ("terrain", "u1"),     # G2: 0 clear / 1 rock / 2 ruin / 3 wall / 4 debris / 5 crater
    ("water_footprint", "u1"), # G2 v7: river/lake beds, including water under bridge decks
    ("height", "f4"),      # G2: 高程（米）：地面0.6 / 水-2.4 / 台地顶3.6 / 坡道2.1 / 桥0.6
    ("blocking", "u1"),    # G2 写，G3 重算（唯一允许改写的上游通道）
    ("blocking_g2", "u1"), # G3: G2 原始 blocking 备份（对比用）
    ("passable", "u1"),    # G2 写，G3 重算
    ("overlay", "u1"),     # G3: 0 无 / 1 ResourceA / 2 ResourceB
]

ROLE_HOME, ROLE_CENTER, ROLE_FLANK, ROLE_EXPANSION, ROLE_HINTERLAND = 1, 2, 3, 4, 5
ROLE_NAMES = {1: "home", 2: "center", 3: "flank", 4: "expansion", 5: "hinterland"}
TERRAIN_CLEAR, TERRAIN_ROCK, TERRAIN_RUIN, TERRAIN_WALL, TERRAIN_DEBRIS, TERRAIN_WATER = 0, 1, 2, 3, 4, 5
TERRAIN_NAMES = {0: "clear", 1: "rock", 2: "ruin", 3: "wall", 4: "debris", 5: "water"}
OVERLAY_NONE, OVERLAY_A, OVERLAY_B = 0, 1, 2

# ---- 形状原型 kit（curated prototypes）：固定谐波签名，种子只选原型+旋转/缩放/位置，
# 锁住审美下限、降低种子间方差。每组=(a2,a3,a4) 为 r(θ) 的 2/3/4 次谐波系数。
BLOB_PROTOTYPES = [
    (0.22, 0.12, 0.06),
    (0.15, 0.20, 0.08),
    (0.28, 0.08, 0.10),
    (0.18, 0.14, 0.12),
]

# ---- G2 defaults: v7 strategic terrain; older tuning keys retained for compatibility ----
G2_DEFAULTS = {
    "river_enabled": 1,
    "river_layout": 2,           # 1 single, 2 intersecting, 3 separate channels.
    "lake_count": 0,
    "lake_area": 5000,
    # v7.2 workbench controls. Seed 0 uses the ordinary gate stream.
    "terrain_seed": 0,
    "neutral_plateau_scale": 1.7,
    "river_tributaries": 0,
    "compound_plateaus": True,
    "landform_elongation": 1.2,
    "landform_recess": .2,
    "landform_softness": .16,
    "river_bend_scale": 1.0,
    # 基地 / 扩张（保持开阔，不被障碍堵）
    "home_radius": 20.0,        # 基地净空半径（内不得有障碍）
    "home_noise": 3.5,
    "flank_radius": 13.0,       # 咽喉缺口邻域（role=flank 争夺点）半径
    "expansion_radius": 16.0,
    "expansion_offset": 44.0,
    "expansion_deflect_deg": 35.0,
    "expansion_deflect2_deg": 60.0,
    "expansion_min_center_dist": 30.0,
    "expansion_min_edge_dist": 20.0,
    "expansion_connector_width": 8.0,
    "noise_harmonics": (3, 5),
    # 连续隔墙（v6：有限长连续带+单桥，不贯图）
    "ridge_half_span_frac": 0.40,   # 隔墙半长=0.40·|AB|（保证桥在墙内部、不靠端点）
    "ridge_width_range": (12.0, 16.0),  # 隔墙宽
    "ridge_bridge_count": (1, 1),      # 单桥
    "ridge_noise_amp": 3.0,     # 中心线摆动（配合粗糙化产生有机弯曲）
    "ridge_wiggle_wavelength": (60.0, 90.0),
    "line_bow": 0.10,          # 隔墙/河中心线固定弓形幅度（占|AB|比例，kit 签名）
    "line_meander": 0.05,      # 中心线固定蛇行幅度（kit 签名）
    "ridge_rough": 2.5,         # 隔墙边界平滑起伏幅度（m，轻微有机，不深切）
    "river_rough": 2.5,         # 河边界平滑起伏幅度
    "plateau_rough_frac": 0.28, # 台地边界平滑 fbm 起伏（瓣状有机块，非正圆）
    "choke_width_range": (10.0, 13.0),  # 隘口/渡口基准宽（嘴部=0.85x，落在验收 8-15）
    # 进攻走廊（绕路路线，强制开阔供 G3 避让与连通；宽须≤咽喉上限以免冲宽缺口）
    "lane_clear_width": 10.0,
    # 结构性地形（v5：贯图分隔线+台地；本次无河，用障碍线代替河的角色）
    "river_width": (16.0, 20.0),
    # 高程层（v5 台地水域阶段1，米）：见 docs/plan/台地水域-阶段1-plan.md §2
    "water_level": -2.4, "ground_level": 0.6, "plateau_level": 8.1,
    "plateau_count": (6, 8),        # Two home heights and substantial neutral bank positions.
    "plateau_top_fraction_min": .12,
    # 中立台地**基础半径**（再乘 neutral_plateau_scale=1.7 得实际半径）。
    # 2026-09-24 修：原值 (18, 26) 与 1.7 相乘得 30.6–44.2m，256m 图上一座都放不下
    # （实测 557 次候选 328 次出界、195 次撞禁入，仅 2 座出生台地成活）⇒
    # plateau_full/neutral_contest/plateau_area 全挂 → pipeline 退保底烘焙 → G3 崩 →
    # 游戏只能退回旧图（用户看到的“台地/坡道/山地是旧方案”）。
    # 现取 (9, 11)：实际半径 15.3–18.7m，对齐 G2-strategic-highlands.md 的
    # “基础半径优先 24，退让档位 21、18”里的最小退让步，6–8 座可稳定落下。
    "plateau_radius": (9.0, 11.0),
    "plateau_ramp_count": (2, 2),   # v6 固定双向对坡（首坡朝争夺区+反侧）：入口双侧→公平性稳定
    "plateau_ramp_width": 8.0,      # 坡道宽（m，≥5 供阶段2 坡烘焙）
    "bridge_count": (1, 2),         # 每水带桥数
    # 2026-09-24 8.0 → 12.0（用户报"桥上卡单位非常严重"）：可走净宽 = 桥宽 - 2×护栏宽
    # = 8-1.3 = 6.7m。9 个工人+士兵挤一条 6.7m 的走廊，RVO 互相推 + 撞护栏物理体，
    # 单位被弹下桥、随后路径查不到起点格而永久冻结（实测 t=5s 上桥 y=1.30，
    # t=10s 被拖回岸 y=0.60，之后 30s 不动）。12m → 净宽 10.7m，可并行 6~7 个单位。
    "bridge_width": 12.0,           # v7 bridge deck width (m)
    "plateau_home_cover": 60.0,     # v6 公平修补：每家到最近台地中心上限（超则补位）
    # v6 战略结构：分布式争夺区 + 出生点局部防守 + 公平
    "river_count": (2, 2),          # Two boundary-to-boundary channels with one intersection.
    "contest_neutral_count": (1, 2),  # 中立争夺区数（对角线中点偏移，分布式非唯一中心）
    "contest_radius": 10.0,         # 争夺区开放口袋半径（强制开阔）
    "contest_min_spawn_dist": 34.0, # 中立争夺区到任何出生点下限
    "home_plateau_count": 2,
    "layout_attempts": 4,          # One initial candidate, then three concurrent retries.
    "candidate_workers": 3,
    "river_crossings": 6,
    "plateau_route_reach": 18.0,
    "expansion_fair_ratio": 1.3,
    "route_width_min": 5.0,
    "bridge_keepclear_m": 9.0,       # 桥口山体净空（米）：山体可贴河岸，但不得挤占桥通道
    "plateau_fair_ratio": 1.7,      # 各家→最近台地入口 路径比上限（绕路不对称容差；直线覆盖由 plateau_home_cover 修补保证）
    "contest_fair_ratio": 1.3,      # 争夺区两_owner 路径比上限
    "route_cover_radius": 30.0,     # 可读性报告：路线覆盖半径
    "cliff_count": (0, 0),          # 不另生成短悬崖（分隔线已承担悬崖角色）
    "cliff_width": (6.0, 9.0),
    "cliff_len": (60.0, 120.0),
    "cliff_gap_width": (9.0, 12.0),
    # 掩体：少量链状岩簇（连贯块，填充开阔地到红警2量级，非纸屑）
    "cover_target_frac": 0.40,  # Water, cliffs and mountains; excludes walkable tops/decks.
    "cover_grid": 4,            # legacy compatibility; v7.1 groups cover by landforms
    "cover_radius_range": (5.0, 10.0),
    "cover_step_len": (4.0, 8.0),   # 链状游走步长（<2r 使圆盘重叠→连续）
    "cover_turn": 0.9,              # 每步最大转角（rad）
    "cover_branch_prob": 0.35,      # 分枝概率（树状/分叉轮廓）
    "cover_satellites": (0, 0),     # 每簇卫星小块数（细节层次）
    "cover_chain_steps": (3, 7),    # 每簇链长（圆盘数）
    "cover_cluster_max": 10,        # 最大簇数
    "cover_max_attempts": 3000,    # 高精度栅格下避免无效撒布循环拖慢生成
    "min_blob_cells": 20,       # 掩体 blob 扣除禁区后残留≥此格数才采纳
    "min_obstacle_area": 8,     # 小于此面积的障碍碎块清除（保留贴边掩体碎片）
    "pocket_fill_max": 3000,    # 不含关键点的封闭开阔口袋≤此面积则填成障碍（消除开放分量>1）
    "connect_width": 4.0,       # 定向打通走廊宽（孤立关键点连回主域）
    "max_recarve": 3,
    # 障碍分类阈值（cell=1m → m²）
    "wall_aspect_min": 3.0,
    "wall_area_min": 40,
    "ruin_area_min": 400,
    "rock_area_min": 120,
    # 验收（开阔地模型：障碍是点缀；v5 障碍含 ring+water+wall+cover，区间 12–22%）
    "obstacle_frac_min": 0.395,
    "obstacle_frac_max": 0.405,
    # 桥实测贯通宽验收区间：随 bridge_width 8→12 同步放宽（净宽 = 桥宽-2×护栏宽）。
    "bridge_width_pass": (5.0, 12.5),
    "solid_comp_min": 4,
    "solid_comp_max": 400,
    "max_solid_block_frac": 0.35,   # 贯图分隔线互相交叉会连成一个大网络，放宽单块上限
    "flank_width_target": (8.0, 40.0),   # 桥宽下限守≥8（可用）；上限报告向（四线交汇区度量失真）
    "neighbor_wall_frac_min": 0.30,      # 脊线中段完整度（报告向；分离性主要由 detour 把关）
    "detour_min": 1.0,                   # 连续分隔线已保证分离（必走桥），detour 仅作报告
    "fairness_ratio": 1.6,
    "agent_radius": 0.9,
    "lane_sample_step": 3.0,
    "lane_width_cap": 60.0,
    # ---- 兼容键：G3_DEFAULTS 复检沿用 ----
    "choke_main_min": 8.0,
    "choke_any_min": 8.0,
    "choke_flank_target": (8.0, 12.0),
    "density_total_min": 0.12,
    "density_total_max": 0.30,
    # 2026-09-14：上面这对绝对区间在当前地貌下【不可能满足】—— G2 自身 blocking
    # 已达 0.400（G2 全绿），G3 实例只能在既有岩体上小幅增减。故 G3 的密度门改为
    # "相对 G2 的变化幅度"口径（≤ density_delta_max），绝对上限只作兜底防失控。
    "density_delta_max": 0.02,
}

# ---- G3 默认 ----
G3_DEFAULTS = {
    "near_count": 2,            # 每家 2× ResourceA
    "near_path_range": (6.0, 9.0),  # 2026-09-15：家里矿贴基地，原 8–13 开局走太远
    "expansion_count": (1, 1),  # 每家 1×A + 1×B
    # 256m 适配：扩张锚点实际距离 14–44m（脊线避让会拉回），路径带按锚距自适应：
    # [max(band_min, rel_lo·d0), rel_hi·d0]（d0=出生点→锚点直线距）
    "expansion_band_rel": (0.7, 1.5),
    "expansion_band_min": 14.0,
    "shared_per_flank": 1,      # 每条侧翼 1× ResourceA
    "shared_b_per_flank": 1,    # 2026-09-05 无中央战场适配：每条侧翼补 1×B（原中心 2B+1A 取消）
    "shared_path_diff_ratio": 0.20,   # 到两家路径距离差 ≤ 20%
    "shared_target_ratio": 0.10,      # 公平放置用的收紧相对差（sum 比值 ≤1.3 的数学需要）
    "fair_top_frac": 0.10,            # 全局 target 对齐时取最接近的候选比例
    "flank_anchor_radius": 10.0,      # shared 资源放置盘半径（绕 flank 锚点，会战场内）
    "center_resources": (0, 0),  # 无中央战场：中心资源取消（G2 v4.0.0 无 center role）
    "res_clear_blocking": 2.0,   # 到最近 blocking 格 ≥ 2 m
    "res_gap": 3.0,              # 装置间 ≥ 3 m
    "res_spawn_dist": 6.0,       # 到出生点 ≥ 6 m
    "res_relax_step": 3.0,       # 无候选时距离带放宽 ±3 m 重试一次
    "asset_budget": 4500,        # 实例预算（含装饰）；v6 结构簇增多（台地环4–6+防守环+双水墙岩件）上调
    "overflow_frac": 0.20,       # 实例盒最多 20% 格溢出到簇外可放置区
    # 2026-09-14（用户反馈"石头瞎摆把路堵上了"）：阻挡实例 footprint 允许落在
    # G2 岩体【之外】的比例上限。巨型件（Cliff_Flat_05 最长边 46.8m、单体 1977m²）
    # 原来可以在开阔地上摊平 —— 实测 85 个 >12m 的实例伸进"放石头前可通行"区、
    # 共占 26,160 m²。设为 0.10 后巨型件必须基本落在既有岩体上。
    "cover_overhang_frac": 0.10,
    "rock_scale_range": (0.9, 1.2),
    # 植被/装饰密度：3% 在 2048m 地图上过稀（实测树/草几乎不可见），
    # 参照主流 RTS 的地表植被覆盖感提升到 10%（战区 home/expansion 仍为 0）。
    # 2026-09-24 用户反馈："生成地图上面是没有这么多摆件的，这是之前错的方案，
    # 地图上有零散的摆件就行了"。原密度 10%/10%/6% = 每 10 个开阔格就有一件
    # 摆件（花草/碎石/废料），256m 图上实测 2466 件，把整张地图铺成摆件地毯、
    # 盖住台地/坡道/山体本身。降到约 1/15：零散点缀，不再成片。
    "deco_density": {5: 0.006, 3: 0.006, 2: 0.004},
    "deco_spawn_dist": 10.0,
    "deco_res_dist": 2.0,
    # 装饰件 XZ 最大边：4.5 -> 9.0（树/岩件尺度接近单位体量，远看才成立）
    "deco_max_size": 9.0,
    "cluster_cover_min": 0.90,   # 重算后 blocking ⊇ 原簇格 ≥ 90%（water 格不计）
    # 复检沿用 G2 的阈值（recheck 跑 G2 全部检查）
    "choke_main_min": G2_DEFAULTS["choke_main_min"],
    "choke_any_min": G2_DEFAULTS["choke_any_min"],
    "choke_flank_target": G2_DEFAULTS["choke_flank_target"],
    "density_total_min": G2_DEFAULTS["density_total_min"],
    "density_total_max": G2_DEFAULTS["density_total_max"],
}

# ---- G4 工程根 / 引擎 / 素材（发现，不写盘符绝对路径）----
MAPGEN_ROOT = Path(__file__).resolve().parents[1]
_WORKBENCH_LOCAL = Path(__file__).resolve().parent / "workbench" / "engine.local.json"


def _read_local_engine_config() -> dict:
    if not _WORKBENCH_LOCAL.is_file():
        return {}
    try:
        data = json.loads(_WORKBENCH_LOCAL.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def discover_airts_root(start: Path | None = None) -> str:
    """向上找到带 project.godot 的游戏工程根。"""
    env = os.environ.get("RTSMAP_AIRTS", "").strip()
    if env and (Path(env) / "project.godot").is_file():
        return str(Path(env).resolve())
    cfg = _read_local_engine_config().get("airts")
    if cfg and (Path(cfg) / "project.godot").is_file():
        return str(Path(cfg).resolve())
    here = Path(start or __file__).resolve()
    for folder in (here, *here.parents):
        if (folder / "project.godot").is_file():
            return str(folder)
    return str(Path(__file__).resolve().parents[3])


def _godot_console_in_dir(folder: Path, depth: int = 2) -> str:
    if depth < 0 or not folder.is_dir():
        return ""
    try:
        entries = list(folder.iterdir())
    except OSError:
        return ""
    consoles = [
        item for item in entries
        if item.is_file() and "mono" in item.name.lower() and item.name.lower().endswith("_console.exe")
    ]
    if consoles:
        return str(sorted(consoles, key=lambda p: p.name)[-1])
    if depth == 0:
        return ""
    for item in entries:
        name = item.name.lower()
        if item.is_dir() and ("godot" in name or "mono" in name):
            found = _godot_console_in_dir(item, depth - 1)
            if found:
                return found
    return ""


def discover_godot_mono() -> str:
    """RTSMAP_GODOT → engine.local.json → PATH → 工程旁 Godot 目录。"""
    env = os.environ.get("RTSMAP_GODOT", "").strip()
    if env and Path(env).is_file():
        return str(Path(env).resolve())
    cfg = _read_local_engine_config().get("godot")
    if cfg and Path(cfg).is_file():
        return str(Path(cfg).resolve())
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        if not folder:
            continue
        found = _godot_console_in_dir(Path(folder), depth=0)
        if found:
            return found
    project = Path(discover_airts_root())
    for base in (project, project.parent):
        found = _godot_console_in_dir(base, depth=2)
        if found:
            return found
    return ""


def preview_source_root(project: str | Path | None = None) -> Path:
    root = Path(project or discover_airts_root())
    return root / "初选素材包" / "工程" / "预览渲染工程"


G4_AIRTS = discover_airts_root()
G4_GODOT_MONO = discover_godot_mono()
SRC_PREVIEW_ROOT = preview_source_root(G4_AIRTS)
G4_DIFF_MAX = 0.02          # 差分不一致率 < 2%
G4_BAKE_MAX_S = 10.0
G4_SMOKE_MINUTES = 5

# ---- 数值容差（浮点约束比较用，不改变语义）----
EPS = 1e-9
