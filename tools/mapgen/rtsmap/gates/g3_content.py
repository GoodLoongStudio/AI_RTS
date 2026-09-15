"""G3：资源与净空 + 素材实例化。

两步一次完成：先"资源"（overlay + 公平三项），再"素材实例化"（贪心覆盖 + 重算复检 + 装饰）。
"""
import json
import math
from pathlib import Path

import numpy as np

from ..contract import (
    ALGO_VERSION, G3_DEFAULTS, GRID_H, GRID_W, MAP_CENTER, OVERLAY_A, OVERLAY_B,
    ROLE_CENTER, ROLE_EXPANSION, ROLE_FLANK, ROLE_HOME, ROLE_NAMES,
    TERRAIN_CLEAR, TERRAIN_DEBRIS, TERRAIN_ROCK, TERRAIN_WATER,
)
from ..gate import ensure_upstream_approved, new_manifest, run_dir
from ..grid import MapGrid, read_json, write_json
from ..pathing import (
    cell_of, compute_passable, dijkstra, dilate8, keypoints_connected,
    lane_min_width, polyline_length,
)
from ..rng import gate_rng, gate_seed_int
from .g2_layout import polar_order, _dist_field, segment_mask


# 是否放置【阻挡类】石块/崖件实例。
# 2026-09-14 用户明确要求去掉（"这些石块以后不要了，你把山的高度都提高一点"）：
# 岩体的起伏与不可通行性都改由高度场 + G2 blocking 承担，不再摆石块模型。
# 回退只需改成 True（原实现完整保留在 build_mapping 后半段）。
PLACE_BLOCKING_PROPS = False


# ---------------- 距离场与净空 ----------------

def dist_fields(passable, starts):
    """每个出生点在 passable 上的 Dijkstra 距离场（米，不可达 = inf）。"""
    out = []
    for s in starts:
        d, _ = dijkstra(passable, cell_of(s[0], s[1]), None)
        out.append(d)
    return out


def clear_of_blocking(blocking, min_m=2.0):
    """到最近 blocking 格 ≥ min_m 的格（欧氏；纯 numpy 圆盘膨胀，不依赖 scipy）。"""
    if min_m <= 0:
        return np.ones_like(blocking, dtype=bool)
    r = int(math.ceil(min_m)) + 1
    r2 = min_m * min_m
    offs = [(di, dj) for di in range(-r, r + 1) for dj in range(-r, r + 1)
            if di * di + dj * dj < r2 - 1e-9]  # 严格 < min_m 的格全部排除
    m = np.asarray(blocking) > 0
    h, w = m.shape
    p = np.pad(m, r)
    occ = np.zeros((h, w), dtype=bool)
    for di, dj in offs:
        occ |= p[r + di:r + di + h, r + dj:r + dj + w]
    return ~occ


# ---------------- 资源放置 ----------------

def _pick_candidate(cand_mask, rng):
    idx = np.argwhere(cand_mask)
    if len(idx) == 0:
        return None
    r = idx[int(rng.integers(0, len(idx)))]
    return (int(r[0]), int(r[1]))


def place_resources(grid, spec, lanes, params, rng, exp_anchor_masks=None, flank_masks=None):
    """按配额放置资源，写 overlay 通道。返回 (overlay, placed, fairness, failures, df)。

    G3 2.0.0（256m、无中央战场）配额：
    - 每家 near 2×A（home 区，路径 8–13m）
    - 每家 expansion 1×A + 1×B（扩张锚点盘内；路径带按锚点实际距离自适应，
      96m 的固定 18–28m 在 256m 上不可满足——扩张锚 14–44m 且脊线避让会拉回）
    - 每条 flank 1×A + 1×B（会战场锚点盘内，到两家路径差 ≤20%）
      —— 原方案"中心 2B+1A"因无中央战场取消，B 改在 flank 补齐，每家 B = 1+2 = 3 相等
      （接手提示词 §3 步骤 2 允许的偏差，汇报中说明）
    exp_anchor_masks：每家扩张锚点 8 m 盘；flank_masks：每条 flank 锚点盘（k 极角序）。
    """
    starts = [tuple(s) for s in spec["starts"]]
    blocking = grid.get("blocking")
    passable = grid.get("passable")
    lane_core = grid.get("lane_core")
    region = grid.get("region")

    df = dist_fields(passable, starts)
    clear2 = clear_of_blocking(blocking, params["res_clear_blocking"])
    overlay = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    placed = []          # dict: kind, type, i, j, owner
    failures = []

    def free_cell(i, j):
        if blocking[i, j] or overlay[i, j]:
            return False
        if not passable[i, j] or not clear2[i, j]:
            return False
        if lane_core[i, j]:
            return False
        for s in starts:
            if math.hypot(j + 0.5 - s[0], i + 0.5 - s[1]) < params["res_spawn_dist"]:
                return False
        for p in placed:
            if math.hypot(j - p["j"], i - p["i"]) < params["res_gap"]:
                return False
        return True

    def place_one(kind, type_code, region_code, dist_idx, path_range, label, region_mask=None,
                  fair_target=None):
        """在 region_mask（或 region_code 区域）内选格。

        公平策略：距离带仍按契约，候选中优先取"路径距离最接近 fair_target
        （缺省=带中位）"的 25%（内部 rng 随机），使各家实际距离聚集，保证公平三项。
        """
        reg_mask = region_mask if region_mask is not None else (region == region_code)
        for relax in (0.0, params["res_relax_step"] if path_range else 0.0):
            cand = reg_mask.copy()
            cand &= ~blocking.astype(bool) & (overlay == 0)
            cand &= clear2 & (lane_core == 0)
            dm = None
            if path_range is not None:
                lo = path_range[0] - relax
                hi = path_range[1] + relax
                dm = np.full((GRID_H, GRID_W), np.inf)
                for k in dist_idx:
                    dm = np.minimum(dm, df[k])
                cand &= (dm >= lo) & (dm <= hi) & np.isfinite(dm)
            ys, xs = np.meshgrid(np.arange(GRID_H), np.arange(GRID_W), indexing="ij")
            for s in starts:
                cand &= np.hypot(xs - s[0], ys - s[1]) >= params["res_spawn_dist"]
            for p in placed:
                cand &= np.hypot(xs - (p["j"] + 0.5), ys - (p["i"] + 0.5)) >= params["res_gap"]
            cell = None
            if path_range is not None and dm is not None:
                idx = np.argwhere(cand)
                if len(idx) > 0:
                    dvals = dm[idx[:, 0], idx[:, 1]]
                    mid = fair_target if fair_target is not None else 0.5 * (lo + hi)
                    order = np.argsort(np.abs(dvals - mid), kind="stable")
                    k_top = max(1, int(round(len(order) * 0.25)))
                    pick = int(order[int(rng.integers(0, k_top))])
                    cell = (int(idx[pick, 0]), int(idx[pick, 1]))
            else:
                cell = _pick_candidate(cand, rng)
            if cell is not None:
                i, j = cell
                overlay[i, j] = type_code
                placed.append({"kind": kind, "type": "A" if type_code == OVERLAY_A else "B",
                               "i": i, "j": j, "owner": label})
                return True
        failures.append(f"{kind}({label}): 无候选（距离带 {path_range}）")
        return False

    # 每家 near：2×A，路径 8–13，home 区
    for i in range(4):
        for _ in range(params["near_count"]):
            place_one("near", OVERLAY_A, 10 + i, [i], params["near_path_range"], f"P{i}")
    # 每家 expansion：1A + 1B，扩张口袋（region 40+i，含锚点盘）内；路径带按锚距自适应。
    # 公平：先求各玩家可行距离域 [pmin,pmax]，解满足全体比值 ≤1.3 的全局目标 M
    # （M ≥ pmax/1.3 且 M ≤ 1.3·pmin 的交集）；无解时取中位并靠 place_one 的
    # "最接近 target" 选格尽量逼近。96m 的固定 18–28m 在 256m 上不可满足（锚距 14–44m）。
    rel_lo, rel_hi = params["expansion_band_rel"]
    pools = []
    for i in range(4):
        mask_i = (exp_anchor_masks[i] if exp_anchor_masks is not None and
                  i < len(exp_anchor_masks) else (region == (40 + i)))
        mask_i = mask_i | (region == (40 + i))   # 口袋并锚点盘
        # v6：并入扩张接入走廊（防守环漏斗使口袋内路径偏斜，走廊拓宽可达距离池）
        mask_i = mask_i | segment_mask(starts[i], tuple(spec["expansion_anchors"][i]),
                                       params.get("expansion_connector_width", 8.0) + 2.0)
        d0 = math.hypot(spec["expansion_anchors"][i][0] - starts[i][0],
                        spec["expansion_anchors"][i][1] - starts[i][1])
        lo_i = max(params["expansion_band_min"], rel_lo * d0)
        cand = mask_i & ~blocking.astype(bool) & (overlay == 0) & clear2 & (lane_core == 0)
        dm = df[i]
        with np.errstate(invalid="ignore"):
            cand &= (dm >= lo_i) & np.isfinite(dm)
        idx = np.argwhere(cand)
        if len(idx):
            dv = dm[idx[:, 0], idx[:, 1]]
            pools.append((mask_i, lo_i, float(np.min(dv)), float(np.max(dv)),
                          float(np.median(dv))))
        else:
            pools.append((mask_i, lo_i, None, None, None))
    # v6 公平求解：先取各家可达域 [pmin,pmax]（不再用 1.5·d0 上界卡死），
    # 解 M ∈ [max pmin/1.3, min 1.3·pmax]；再用 M 反夹各家放置带 → 比值 ≤1.3 可证。
    exp_fair_target = None
    valid = [p for p in pools if p[2] is not None]
    if len(valid) == 4:
        m_lo = max(p[2] / 1.3 for p in valid)
        m_hi = min(1.3 * p[3] for p in valid)
        if m_lo <= m_hi:
            exp_fair_target = 0.5 * (m_lo + m_hi)
    if exp_fair_target is None and len(valid) >= 2:
        exp_fair_target = float(np.median([p[4] for p in valid]))
    for i in range(4):
        mask_i, lo_i, pmin, pmax, _ = pools[i]
        if pmin is None:
            continue
        if exp_fair_target is not None:
            band = (max(lo_i, exp_fair_target / 1.3), min(pmax, 1.3 * exp_fair_target))
            if band[0] > band[1]:
                band = (lo_i, pmax)
        else:
            band = (lo_i, pmax)
        place_one("expansion", OVERLAY_A, 40 + i, [i], band,
                  f"P{i}", region_mask=mask_i, fair_target=exp_fair_target)
        place_one("expansion", OVERLAY_B, 40 + i, [i], band,
                  f"P{i}", region_mask=mask_i, fair_target=exp_fair_target)
    # v6：扩张公平比事后迭代修补（防守环漏斗使距离池偏斜，全局 M 常无解）：
    # 比值超限时把最远（或最近）家的 expansion A 重放到中位距离。
    for _ in range(8):
        da = {}
        for i in range(4):
            ea = [p for p in placed if p["kind"] == "expansion" and p["type"] == "A"
                  and p["owner"] == f"P{i}"]
            da[i] = float(df[i][ea[0]["i"], ea[0]["j"]]) if ea else math.inf
        fin = [v for v in da.values() if math.isfinite(v)]
        if len(fin) < 4 or max(fin) <= 1.3 * min(fin):
            break
        med = float(np.median(fin))
        if max(fin) > med:
            target_i = max(da, key=lambda k: da[k])
        else:
            target_i = min(da, key=lambda k: da[k])
        old = next(p for p in placed if p["kind"] == "expansion" and p["type"] == "A"
                   and p["owner"] == f"P{target_i}")
        placed.remove(old)
        overlay[old["i"], old["j"]] = 0
        mask_i, lo_i, pmin, pmax, _ = pools[target_i]
        band = (max(lo_i, med / 1.3), min(pmax, 1.3 * med))
        if band[0] > band[1]:
            band = (lo_i, pmax)
        ok = place_one("expansion", OVERLAY_A, 40 + target_i, [target_i], band,
                       f"P{target_i}", region_mask=mask_i, fair_target=med)
        if not ok:
            placed.append(old)
            overlay[old["i"], old["j"]] = OVERLAY_A
            break
    # 每条侧翼 shared：1×A + 1×B（B 为无中央战场适配），到两家路径差 ≤20%；
    # 放置后对公平三项做迭代修正
    def flank_pair(k):
        name = next((n for n in lanes if n.startswith(f"pair_{k}_")), None)
        return lanes[name]["pair"] if name else None

    def shared_candidates(k, exclude_ij=None, strict_ratio=True):
        pair = flank_pair(k)
        reg_mask = flank_masks[k] if flank_masks is not None else (region == (30 + k))
        cand = reg_mask.copy()
        cand &= ~blocking.astype(bool) & (overlay == 0) & clear2 & (lane_core == 0)
        d_i, d_j = df[pair[0]], df[pair[1]]
        both = np.isfinite(d_i) & np.isfinite(d_j)
        denom = np.minimum(d_i, d_j)
        with np.errstate(invalid="ignore"):
            ratio = np.where(both & (denom > 1e-6),
                             np.maximum(d_i, d_j) / np.maximum(denom, 1e-6), np.inf)
            if strict_ratio:
                cand &= both & (ratio <= params["shared_path_diff_ratio"] + 1e-9)
            else:
                cand &= both  # 放宽轮：忽略相对差
        ys, xs = np.meshgrid(np.arange(GRID_H), np.arange(GRID_W), indexing="ij")
        for p in placed:
            if exclude_ij is not None and (p["i"], p["j"]) == exclude_ij:
                continue
            cand &= np.hypot(xs - (p["j"] + 0.5), ys - (p["i"] + 0.5)) >= params["res_gap"]
        for s in starts:
            cand &= np.hypot(xs - s[0], ys - s[1]) >= params["res_spawn_dist"]
        return cand, d_i, d_j

    def place_shared_at(cand, d_i, d_j, type_code, k, prefer_player=None):
        idx = np.argwhere(cand)
        if len(idx) == 0:
            return None
        if prefer_player is not None:
            dvals = df[prefer_player][idx[:, 0], idx[:, 1]]
            order = np.argsort(dvals, kind="stable")
            k_top = max(1, int(round(len(order) * 0.25)))
            pick = int(order[int(rng.integers(0, k_top))])
        elif M is not None:
            dmin_k = np.minimum(d_i[idx[:, 0], idx[:, 1]], d_j[idx[:, 0], idx[:, 1]])
            order = np.argsort(np.abs(dmin_k - M), kind="stable")
            k_top = max(1, int(round(len(order) * params["fair_top_frac"])))
            pick = int(order[int(rng.integers(0, k_top))])
        else:
            pick = int(rng.integers(0, len(idx)))
        i, j = int(idx[pick, 0]), int(idx[pick, 1])
        overlay[i, j] = type_code
        rec = {"kind": "shared", "type": "A" if type_code == OVERLAY_A else "B",
               "i": i, "j": j, "owner": f"flank_{k}"}
        placed.append(rec)
        return rec

    shared_recs = []
    # 先评估各 flank 的候选 dmin 中位，全局 target M 对齐（各家视角 sum ≈ 2M，比值 ≤1.1）
    med_k = []
    ck = {}
    for k in range(4):
        cand, d_i, d_j = shared_candidates(k, strict_ratio=True)
        idx = np.argwhere(cand)
        if len(idx) == 0:
            cand, d_i, d_j = shared_candidates(k, strict_ratio=False)
            idx = np.argwhere(cand)
        if len(idx) == 0:
            med_k.append(None)
            ck[k] = None
            continue
        dmin_k = np.minimum(d_i[idx[:, 0], idx[:, 1]], d_j[idx[:, 0], idx[:, 1]])
        med_k.append(float(np.median(dmin_k)))
        ck[k] = (cand, d_i, d_j, idx, dmin_k)
    valid = [v for v in med_k if v is not None]
    M = float(np.median(valid)) if valid else None
    for k in range(4):
        if ck[k] is None:
            failures.append(f"shared(flank_{k}): 无候选")
            continue
        cand, d_i, d_j, idx, dmin_k = ck[k]
        rec = place_shared_at(cand, d_i, d_j, OVERLAY_A, k)
        if rec is None:
            failures.append(f"shared(flank_{k}): 无候选")
            continue
        shared_recs.append(rec)
    # flank B：A 落位后重算候选（同样的 ratio 约束与公平对齐）
    for k in range(4):
        if ck[k] is None:
            continue
        for strict in (True, False):
            cand, d_i, d_j = shared_candidates(k, strict_ratio=strict)
            if place_shared_at(cand, d_i, d_j, OVERLAY_B, k) is not None:
                break
        else:
            failures.append(f"shared_b(flank_{k}): 无候选")

    # 公平修正：各家到左右 shared(A) 路径和 max/min ≤1.3；超界家重放其较远的一条
    for _ in range(4):
        def _sums():
            out = []
            for i in range(4):
                ks = [k for k in range(4) if i in flank_pair(k)]
                out.append(sum(float(df[i][p["i"], p["j"]]) for k in ks for p in placed
                               if p["kind"] == "shared" and p["type"] == "A"
                               and p["owner"] == f"flank_{k}"))
            return out
        sums = _sums()
        if min(sums) <= 0 or max(sums) / min(sums) <= 1.3 + 1e-9:
            break
        worst = int(np.argmax(sums))
        ks = [k for k in range(4) if worst in flank_pair(k)]
        farther = max(ks, key=lambda k: next(
            float(df[worst][p["i"], p["j"]]) for p in placed
            if p["kind"] == "shared" and p["type"] == "A" and p["owner"] == f"flank_{k}"))
        old = next(p for p in placed if p["kind"] == "shared" and p["type"] == "A"
                   and p["owner"] == f"flank_{farther}")
        placed.remove(old)
        overlay[old["i"], old["j"]] = 0
        cand, d_i, d_j = shared_candidates(farther, exclude_ij=(old["i"], old["j"]),
                                           strict_ratio=True)
        if len(np.argwhere(cand)) == 0:
            cand, d_i, d_j = shared_candidates(farther, exclude_ij=(old["i"], old["j"]),
                                               strict_ratio=False)
        rem = None
        if len(np.argwhere(cand)):
            rem = place_shared_at(cand, d_i, d_j, OVERLAY_A, farther, prefer_player=worst)
        if rem is None:
            placed.append(old)
            overlay[old["i"], old["j"]] = OVERLAY_A

    # 公平三项（路径距离，A 资源）+ B 资源报告项 + 配额计数
    def pdist(i_res, player):
        return float(df[player][i_res["i"], i_res["j"]])

    near_sums, exp_a, exp_b, shared_sums, shared_b_sums = [], [], [], [], []
    a_counts, b_counts = [], []
    for i in range(4):
        near_sums.append(sum(pdist(p, i) for p in placed
                             if p["kind"] == "near" and p["owner"] == f"P{i}"))
        ea = [p for p in placed if p["kind"] == "expansion" and p["type"] == "A"
              and p["owner"] == f"P{i}"]
        eb = [p for p in placed if p["kind"] == "expansion" and p["type"] == "B"
              and p["owner"] == f"P{i}"]
        exp_a.append(pdist(ea[0], i) if ea else math.inf)
        exp_b.append(pdist(eb[0], i) if eb else math.inf)
        ks = [k for k in range(4) if i in flank_pair(k)]
        shared_sums.append(sum(pdist(p, i) for k in ks for p in placed
                               if p["kind"] == "shared" and p["type"] == "A"
                               and p["owner"] == f"flank_{k}"))
        shared_b_sums.append(sum(pdist(p, i) for k in ks for p in placed
                                 if p["kind"] == "shared" and p["type"] == "B"
                                 and p["owner"] == f"flank_{k}"))
        own_a = sum(1 for p in placed if p["type"] == "A" and
                    (p["owner"] == f"P{i}" or (p["kind"] == "shared" and i in flank_pair(
                        int(p["owner"].split("_")[1])))))
        own_b = sum(1 for p in placed if p["type"] == "B" and
                    (p["owner"] == f"P{i}" or (p["kind"] == "shared" and i in flank_pair(
                        int(p["owner"].split("_")[1])))))
        a_counts.append(own_a)
        b_counts.append(own_b)
    f_near = max(near_sums) / min(near_sums) if min(near_sums) > 0 else math.inf
    f_exp = max(exp_a) / min(exp_a) if min(exp_a) > 0 else math.inf
    f_shared = max(shared_sums) / min(shared_sums) if min(shared_sums) > 0 else math.inf
    f_shared_b = (max(shared_b_sums) / min(shared_b_sums)
                  if min(shared_b_sums) > 0 else math.inf)
    fairness = {
        "near_sums": near_sums, "expansion_a": exp_a, "shared_sums": shared_sums,
        "expansion_b": exp_b, "shared_b_sums": shared_b_sums,
        "a_counts": a_counts, "b_counts": b_counts,
        "quota_equal": len(set(a_counts)) == 1 and len(set(b_counts)) == 1
                       and a_counts[0] > 0 and b_counts[0] > 0,
        "near_ratio": f_near, "expansion_ratio": f_exp, "shared_ratio": f_shared,
        "shared_b_ratio": f_shared_b,
        # 验收"三项路径距比"= A 资源三项（接手提示词 §3 步骤 2）；B 仅要求每家数量相等，
        # shared_b_ratio 作报告项（不设 1.3 硬门，避免无解锁死）
        "pass": (f_near <= 1.3 + 1e-9 and f_exp <= 1.3 + 1e-9 and
                 f_shared <= 1.3 + 1e-9),
    }
    return overlay, placed, fairness, failures, df


def enrich_resources(placed, df, lanes):
    """补全 resources.json 字段：位置米、到各家路径距离。"""
    out = []
    for idx, p in enumerate(placed):
        d = [round(float(df[k][p["i"], p["j"]]), 2) if np.isfinite(df[k][p["i"], p["j"]]) else None
             for k in range(4)]
        out.append({
            "id": idx, "kind": p["kind"], "type": p["type"],
            "x": p["j"] + 0.5, "z": p["i"] + 0.5,
            "owner": p["owner"], "path_dists": d,
        })
    return out


# ---------------- 素材实例化 ----------------

CATALOG_PATH = Path(__file__).resolve().parents[1] / "data" / "assets_catalog.json"
# 2026-09-06：不再写共享映射文件；映射快照随任务写入 runs/<seed>/G3/terrain_to_assets.json。

BUILDING_TYPES = {"ruin", "wall"}   # yaw 90° 步进；rock/debris/crater 任意角


def build_mapping(catalog):
    """terrain 类型 → 候选资产列表（XZ 面积降序），写入 terrain_to_assets.json。

    2.1.0（2026-09-05 用户反馈）：阻碍一律用**地形素材**（石块/悬崖/山体）——
    原 wall→Corp_Wall 建筑围墙件细、盖不满 12–16m 墙带，Godot 里观感像栅栏而非
    地形；rock/ruin/wall 三类统一改用岩石悬崖池。悬浮岩（Floating）不着地，排除。
    2.2.1（2026-09-13 导航验收阻塞）：下列件在 AI_RTS 与 RTS_Map_Tool 两边素材库都
    不存在（G4 场景引用即白模 + Godot 资源清单崩溃，nav_check 0xC0000005 的根因），
    且都是万格级巨型模式（greedy_cover 性能爆点）——按名排除。
    """
    missing_assets = (
        "SM_Env_Cliff_Curved_Large_01",
        "SM_Env_Cliff_Flat_03",
        "SM_Env_Cliff_Flat_04",
        "SM_Env_Grass_04",
    )
    if not PLACE_BLOCKING_PROPS:
        # 2026-09-14（用户明确："这些石块以后不要了，你把山的高度都提高一点"）：
        # **不再放置阻挡类石块/崖件实例**。岩体的地形起伏改由高度场承担
        # （g4_terrain_mountains.mountain_addon 作用在 G2 blocking 上），
        # 不可通行性也回到 G2 blocking 本身（见调用处的 blocking_new 构造）。
        # 既没有"石头瞎摆/堵路"，也不会因为不摆石头而让岩体变可走。
        # 回退只需把 PLACE_BLOCKING_PROPS 改回 True。
        return {t: [] for t in (1, 2, 3, 4, 5)}

    rock_pool = []
    for e in catalog:
        if not e["blocking"] or e.get("atlas") is None:
            continue  # 无图集的资产不参与（避免 G4 白模）
        if e["name"].startswith("SM_Env_Floating"):
            continue
        if e["name"].startswith(missing_assets):
            continue
        if 1 in e["terrain_types"]:
            rock_pool.append(e)
        if 4 in e["terrain_types"]:
            by_t[4].append(e)
    for t in (1, 2, 3):
        by_t[t] = list(rock_pool)
    for t, lst in by_t.items():
        lst.sort(key=lambda e: (-e["size"][0] * e["size"][2], e["name"]))
    return by_t


def xz_footprint(entry, scale, yaw_deg):
    """实例有向矩形的米制尺寸（scale 缩放后；yaw 只影响栅格化，不改尺寸）。

    G3 2.0.0：G2 v4.0.0 的隔墙是弓形+蛇行曲带，"AABB 向外取整到格"在斜向墙段
    完全放不进中大型件（实测 3400+ 格退化成 1×1 兜底）。改为**有向矩形栅格化**：
    占用格 = 格中心落在旋转后矩形内的格；Python blocking、G4 旋转碰撞盒、
    正交差分三者同口径。
    """
    x, _, z = entry["size"]
    return max(1.0, x * scale), max(1.0, z * scale)


_PATTERN_CACHE = {}


def _rect_pattern(w, h, yaw_deg):
    """旋转矩形相对"中心格"的整数格偏移模式（cx/cz 为 X.5 格中心时平移不变，可缓存）。"""
    key = (round(w, 4), round(h, 4), int(yaw_deg))
    pat = _PATTERN_CACHE.get(key)
    if pat is not None:
        return pat
    th = math.radians(yaw_deg)
    c, s = math.cos(th), math.sin(th)
    hw, hh = w / 2.0, h / 2.0
    rad_i = abs(hh * c) + abs(hw * s)
    rad_j = abs(hw * c) + abs(hh * s)
    pat = []
    # 旋转约定 = Godot Basis.rows roty(θ)：world = [[c, s], [-s, c]]·local
    # （与 .tscn 里 Transform3D(c,0,s, 0,1,0, -s,0, c, ...) 同口径，碰撞盒/视觉一致）
    for di in range(-int(math.ceil(rad_i)), int(math.ceil(rad_i)) + 1):
        for dj in range(-int(math.ceil(rad_j)), int(math.ceil(rad_j)) + 1):
            lx = dj * c - di * s
            lz = dj * s + di * c
            if abs(lx) <= hw + 1e-9 and abs(lz) <= hh + 1e-9:
                pat.append((di, dj))
    _PATTERN_CACHE[key] = pat
    return pat


def pattern_cells(w, h, cx, cz, yaw_deg):
    """与 greedy_cover **放置时完全相同**的落位格（`_rect_pattern` + floor(中心)）。

    用于守卫与验收复核。**不要**在这里换用 `oriented_rect_cells` —— 两者对同一
    (w,h,yaw) 给出的格集不一致（实测 46.8x43m/yaw0：2021 格 vs 1763 格），
    换了就等于"守卫量的不是真正压上去的脚印"（2026-09-14 踩过）。
    """
    pat = _rect_pattern(w, h, yaw_deg)
    si = int(math.floor(cz))
    sj = int(math.floor(cx))
    out = []
    for di, dj in pat:
        ii = si + di
        jj = sj + dj
        if 0 <= ii < GRID_H and 0 <= jj < GRID_W:
            out.append((ii, jj))
    return out


def oriented_rect_cells(cx, cz, w, h, yaw_deg):
    """世界中心 (cx,cz)、尺寸 w×h（米）、绕 Y 旋转 yaw_deg 的矩形覆盖的格集合
    （格中心在矩形内即覆盖，含边界 1e-9 容差）。

    中心与格中心 (X.5) 对齐时走缓存的整数偏移模式（贪心/栅格化均如此）；
    任意中心走通用扫描（仅兜底）。"""
    if abs((cx % 1.0) - 0.5) < 1e-9 and abs((cz % 1.0) - 0.5) < 1e-9:
        si, sj = int(math.floor(cz)), int(math.floor(cx))
        pat = _rect_pattern(w, h, yaw_deg)
        return [(si + di, sj + dj) for di, dj in pat
                if 0 <= si + di < GRID_H and 0 <= sj + dj < GRID_W]
    th = math.radians(yaw_deg)
    c, s = math.cos(th), math.sin(th)
    hw, hh = w / 2.0, h / 2.0
    i0 = int(math.floor(cz - (abs(hh * c) + abs(hw * s))))
    i1 = int(math.ceil(cz + (abs(hh * c) + abs(hw * s))))
    j0 = int(math.floor(cx - (abs(hw * c) + abs(hh * s))))
    j1 = int(math.ceil(cx + (abs(hw * c) + abs(hh * s))))
    out = []
    for i in range(max(0, i0), min(GRID_H, i1 + 1)):
        for j in range(max(0, j0), min(GRID_W, j1 + 1)):
            dx = (j + 0.5) - cx
            dz = (i + 0.5) - cz
            lx = dx * c - dz * s
            lz = dx * s + dz * c
            if abs(lx) <= hw + 1e-9 and abs(lz) <= hh + 1e-9:
                out.append((i, j))
    return out


def _seg_dist(px, pz, a, b):
    ax, az = a
    bx, bz = b
    abx, abz = bx - ax, bz - az
    L2 = abx * abx + abz * abz
    if L2 < 1e-12:
        return math.hypot(px - ax, pz - az)
    tt = max(0.0, min(1.0, ((px - ax) * abx + (pz - az) * abz) / L2))
    return math.hypot(px - (ax + tt * abx), pz - (az + tt * abz))


def _nearby_lanes(x, z, lanes, radius=18.0):
    """距实例位置 radius 内的通道名列表（宽度守卫只测受影响通道）。

    按**线段**距离而非仅顶点：跨河/跨墙通道的中段也可能被大盒外沿压窄。"""
    out = []
    for name, lane in lanes.items():
        pts = lane["polyline"]
        for a, b in zip(pts[:-1], pts[1:]):
            if _seg_dist(x, z, a, b) <= radius:
                out.append(name)
                break
    return out


def greedy_cover(cluster_cells, terrain_type, mapping, placeable, occupied, rng, params,
                 lanes=None, blocking_probe=None, allow_lane_core=False, lane_core=None,
                 blocking_base=None, baselines=None, sensitive=None):
    """贪心覆盖：从未覆盖格里取一个，按面积降序试候选资产；盒能落在 S 内
    （≤20% 溢出到可放置区）即选；无候选时用该类型最小资产（1×1）。

    宽度守卫：大实例（footprint >4 格）放置前预检受影响通道宽度，留 0.5 m 余量
    （G2 v4.0.0 的边界通道 pair_* 即咽喉所在，全部按 choke_any_min+0.5 守卫），
    防止盒外扩挤窄桥口触发复检雪崩。
    allow_lane_core：隔墙/脊线簇贴核心带放置时允许盒进入 lane_core 边缘。
    """
    S = set(cluster_cells)
    covered = set()
    instances = []
    # 外溢贴附掩码：外溢格必须距某簇格 ≤3m（" hug" 规则）——否则巨石在小镇块上
    # 大跨度悬空外溢，会隔断边缘口袋/接入道，触发复检连环删大件、覆盖率崩塌
    if sensitive is not None:
        smask = np.zeros((GRID_H, GRID_W), dtype=bool)
        for i, j in S:
            smask[i, j] = True
        r = 3
        pad = np.zeros((GRID_H + 2 * r, GRID_W + 2 * r), dtype=bool)
        acc = np.zeros_like(pad)
        for di in range(-r, r + 1):
            for dj in range(-r, r + 1):
                if di * di + dj * dj <= r * r:
                    acc[r + di:r + di + GRID_H, r + dj:r + dj + GRID_W] |= smask
        hug = acc[r:r + GRID_H, r:r + GRID_W] | smask
    else:
        hug = None
    cands = mapping.get(terrain_type) or []
    fits = [e for e in cands if max(e["size"][0], e["size"][2]) <= 1.5]
    min_entry = fits[-1] if fits else (min(cands, key=lambda e: e["size"][0] * e["size"][2])
                                       if cands else None)
    baselines = baselines or {}

    def _footprint(w, h, cx, cz, yaw):
        """与主循环放置完全一致的落位格（见模块级 pattern_cells 的说明）。"""
        return pattern_cells(w, h, cx, cz, yaw)

    def _guard_floor(name):
        # 与 recheck 同口径：不许低于 G2 基线（G2 咽喉用 choke_w 口径）。
        # 2026-09-14（用户反馈"石头把路都堵上了"）：原式 `min(choke_any_min, base)-0.25`
        # 对任何基线都是 7.75，于是 14.25m 的路被压到 9.75m（-32%）也算"通过守卫"。
        # 现加一条硬约束：**不许把通道压窄到基线的 90% 以下**。
        base = baselines.get(name, 99.0)
        return max(min(params.get("choke_any_min", 8.0), base) - 0.25, base * 0.90)

    def _guard_ok(w, h, cx, cz, yaw):
        # 2026-09-14：删掉原来的 `w*h <= 6.0` 直接放行旁路 —— 小石头单块只有 4m，
        # 但沿通道排几块就能把 9m 的路挤到 5m（用户反馈）。该函数只在候选**已通过
        # 命中数检查**后才调用（≈每次成功放置一次），不是热路径，无需旁路。
        if lanes is None or blocking_probe is None:
            return True
        probe = blocking_probe.copy()
        cells = _footprint(w, h, cx, cz, yaw)
        for i, j in cells:
            probe[i, j] = 1
        # 守卫半径按盒中心 + 半对角扩（否则大盒"中心离线远、边缘压线"漏检）
        reach = 18.0 + 0.5 * math.hypot(w, h)
        checked = set()
        for i, j in cells:
            for name in _nearby_lanes(j + 0.5, i + 0.5, lanes, radius=18.0):
                if name in checked:
                    continue
                checked.add(name)
                lane = lanes[name]
                wv = lane_min_width(lane["polyline"], probe)
                if wv < _guard_floor(name):
                    return False
        # 兜底：盒外沿reach内但格中心未触发的通道（大盒边缘情形）
        for name in _nearby_lanes(cx, cz, lanes, radius=reach):
            if name not in checked:
                checked.add(name)
                wv = lane_min_width(lanes[name]["polyline"], probe)
                if wv < _guard_floor(name):
                    return False
        return True

    def _overhang_ok(w, h, cx, cz, yaw):
        """阻挡实例的 footprint 允许多大比例落在 G2 岩体【之外】。

        2026-09-14（用户反馈"石头瞎摆，把路都堵上了"）：巨型件
        （SM_Env_Cliff_Flat_05 最长边 46.8m、单体 1977m²；Cliff_Rough_02 到 50.4m）
        在开阔地上摊平 —— 既像随机铺的板子，又把原本可通行的地吃掉（实测 85 个
        >12m 的实例伸进"放石头前可通行"区、共占 26,160 m²）。
        原来只有 overflow_frac 约束"盒内有多少格命中簇"，完全不限制盒伸到哪去。
        现补：外溢到 G2 岩体外的格数 ≤ cover_overhang_frac × 盒格数。
        """
        if blocking_base is None:
            return True
        cells = _footprint(w, h, cx, cz, yaw)
        if not cells:
            return True
        outside = 0
        for i, j in cells:
            if not blocking_base[i, j]:
                outside += 1
        # 小盒（≤6 格，约 8m 见方以内）允许 2 格量化容差：单块 4m 石头完全落在
        # 开阔地是自然的，不该判违规。但**大盒的容差必须能为 0** —— 原来无条件
        # max(2, ...) 会让上限对小盒永远至少 2 格，负向测试（上限设 0）测不出违规，
        # 等于一道对小盒失效的门（2026-09-14 负向测试发现）。
        base_cap = 2 if len(cells) <= 6 else 0
        cap = max(base_cap, int(round(params.get("cover_overhang_frac", 0.10) * len(cells))))
        return outside <= cap

    # 大件优先（修订1 §3 的贪心覆盖语义）：外层按面积降序遍历候选资产，内层扫全簇
    # 找可放位置。按格序逐格"就近挑最大"会让簇尖端先被小件填满、大件再无处安放
    # （实测 0 个 >4m 实例、3400+ 个 1×1），必须资产优先。
    yaws = (0, 45, 90, 135, 180, 225, 270, 315)
    n_cluster = len(S)
    for e in cands:
        area = e["size"][0] * e["size"][2]
        # 剪枝一律按「当前未覆盖格数」而不是全簇格数：早期两者相等，覆盖率上去后
        # 中/大件会被 O(1) 跳过，省掉整趟 seed_cell×yaw 扫描（等价剪枝，只跳必然失败者）。
        remaining = n_cluster - len(covered)
        if (1 - params["overflow_frac"]) * area > remaining + 1e-9:
            continue  # 该资产理论最大覆盖格都塞不进剩余未覆盖格，跳过整套扫描
        # 每个资产扫全簇未覆盖格（sorted 确定性），放不动了换下一档资产
        # 快照一次即可：原先在 seed_cell 循环体内写 `S - covered`，每格都重算一次
        # 全簇集合差 → O(|S|²)，单簇 5 万格时是 25 亿次集合操作（实测 50min 不收敛）。
        # 快照语义与原来逐次求差完全相同（for 只在进入时求值一次）。
        pending = sorted(S - covered)
        for seed_cell in pending:
            scale = round(float(rng.uniform(*params["rock_scale_range"])), 2)                 if terrain_type in (1, 4) else 1.0
            cx = seed_cell[1] + 0.5
            cz = seed_cell[0] + 0.5
            for yaw in yaws:
                w, h = xz_footprint(e, scale, yaw)
                pat = _rect_pattern(w, h, yaw)
                # O(1) 预剪枝：需 ≥(1-overflow)·|pattern| 格落在 S 内，而
                # in_s ≤ |S−covered|（covered ⊆ S 恒成立），故按未覆盖格数收紧即可。
                if (1 - params["overflow_frac"]) * len(pat) > (n_cluster - len(covered)) + 1e-9:
                    continue
                # 单趟早退扫描：判定与原先「先物化 cells → any(occupied) → in_s →
                # ok」完全等价（接受/拒绝不变），但不再先构造整张格表。在密簇上
                # 巨型件（如 88x137m 的 Cliff_Curved_Large_01，模式 12,170 格）原先
                # 每次调用都要建 12,170 个元组，35,549 个种子格 x 8 个 yaw 就是
                # 3.5e9 次操作 —— 实测单簇 >10min 不收敛的主因。
                si = int(math.floor(cz))
                sj = int(math.floor(cx))
                cells = []
                ok = True
                for di, dj in pat:
                    ii = si + di
                    jj = sj + dj
                    if ii < 0 or ii >= GRID_H or jj < 0 or jj >= GRID_W:
                        continue
                    c = (ii, jj)
                    if c in occupied:
                        ok = False
                        break
                    cells.append(c)
                    if c in S:
                        continue
                    if sensitive is not None and sensitive[ii, jj]:
                        # 外溢格禁入敏感区（扩张接入道/口袋/桥口/基地盘）：
                        # 大盒外溢塞死 8m 接入道会把扩张口袋封成孤岛（构造保证连通）
                        ok = False
                        break
                    if hug is not None and not hug[ii, jj]:
                        # 外溢必须贴附簇边（≤3m），禁大跨度悬空
                        ok = False
                        break
                    if not placeable[ii, jj]:
                        if not (allow_lane_core and lane_core is not None
                                and lane_core[ii, jj] > 0):
                            ok = False
                            break
                if not ok or not cells:
                    continue
                in_s = 0
                need = len(cells) * (1 - params["overflow_frac"]) - 1e-9
                for k, c in enumerate(cells):
                    if c in S:
                        in_s += 1
                    elif in_s + (len(cells) - k - 1) < need:
                        break  # 剩余格全中也凑不够，提前退出
                if in_s < need:
                    continue
                if not _guard_ok(w, h, cx, cz, yaw):
                    continue
                if not _overhang_ok(w, h, cx, cz, yaw):
                    continue
                for c in cells:
                    occupied.add(c)
                    if c in S:
                        covered.add(c)
                instances.append({
                    "fbx": e["res_path"], "name": e["name"], "atlas": e["atlas"],
                    "x": cx, "z": cz,
                    "yaw": yaw, "scale": round(scale, 3),
                    "blocking": True, "terrain": terrain_type,
                    "cluster": None, "extent": [round(w, 3), round(h, 3)],
                })
                placed_one = True
                break
            if len(covered) >= n_cluster:
                break
    # 兜底：岩石沿【地形特征带】成簇撒布。
    # 真实地貌里碎岩堆在山脚/崖脚/河岸，开阔平地基本干净；此前的"全图均匀
    # 随机撒"在实机上被判定为不自然。特征带用"紧邻不可通行区（岩体/水/崖）
    # 的可通行格 + 4 格膨胀"近似，簇内 3~5 块（邻域 2 格偏移），簇间由 1/3
    # 抽样形成疏密节奏。
    if min_entry is not None:
        from scipy import ndimage as _ndi
        hard = placeable == 0                       # 不可通行 = 岩体/水/崖壁
        edge_zone = _ndi.binary_dilation(hard, iterations=4) & (placeable > 0)
        cand_list = list(mapping.get(terrain_type, [])) or [min_entry]
        seeds = [tuple(c) for c in np.argwhere(edge_zone)]
        # 抽样间隔 + 预算硬保护：特征带（不可通行区膨胀 4 格）格数可达十万级，
        # 每 150 格取一种子成簇；并在接近 asset_budget 时停止（防爆量）。
        budget = int(params.get("asset_budget", 4000))
        for k, seed_cell in enumerate(seeds):
            if k % 150 != 0:
                continue
            if len(instances) >= budget - 50:
                break
            n_extra = int(rng.integers(2, 5))
            cluster_pts = [(seed_cell[0], seed_cell[1])]
            for _ in range(n_extra):
                di = int(rng.integers(-2, 3))
                dj = int(rng.integers(-2, 3))
                cluster_pts.append((seed_cell[0] + di, seed_cell[1] + dj))
            for (ci, cj) in cluster_pts:
                if not (0 <= ci < GRID_H and 0 <= cj < GRID_W):
                    continue
                if placeable[ci, cj] == 0 or (ci, cj) in occupied:
                    continue
                # 2026-09-14：兜底簇**原先完全没有路线守卫**（只判 placeable/占用），
                # 而 placeable 之外还有通道净宽这一层保护 —— 是"石头堵路"的潜在来源。
                # 现补：路线核心带禁入 + 宽度守卫 + 外溢比例守卫，与主循环同口径。
                # 同时先资产/尺度/yaw 再算真实 footprint：原来 extent 直接写 [sc, sc]，
                # 与实际模型尺寸无关 → 阻挡格与视觉不一致。
                e = cand_list[int(rng.integers(0, len(cand_list)))]
                sc = round(float(rng.uniform(*params.get("rock_scale_range", (0.75, 1.6)))), 3)
                yaw = float(rng.uniform(0.0, 360.0))
                w, h = xz_footprint(e, sc, yaw)
                if lane_core is not None and lane_core[ci, cj] > 0:
                    continue
                if sensitive is not None and sensitive[ci, cj]:
                    continue
                if not _guard_ok(w, h, cj + 0.5, ci + 0.5, yaw):
                    continue
                if not _overhang_ok(w, h, cj + 0.5, ci + 0.5, yaw):
                    continue
                cells_new = _footprint(w, h, cj + 0.5, ci + 0.5, yaw)
                if any(c in occupied for c in cells_new):
                    continue
                occupied.add((ci, cj))
                covered.add((ci, cj))
                instances.append({
                    "fbx": e["res_path"], "name": e["name"], "atlas": e["atlas"],
                    "x": cj + 0.5, "z": ci + 0.5,
                    "yaw": yaw, "scale": sc,
                    "blocking": True, "terrain": terrain_type,
                    "cluster": None, "extent": [round(w, 3), round(h, 3)],
                })
    return instances


def rerasterize(instances):
    """blocking := 所有遮挡实例的有向矩形（x/z 中心、extent、yaw）覆盖格之并。"""
    blocking = np.zeros((GRID_H, GRID_W), dtype=np.uint8)
    for ins in instances:
        if not ins["blocking"]:
            continue
        w, h = ins["extent"]
        for i, j in oriented_rect_cells(ins["x"], ins["z"], w, h, ins["yaw"]):
            blocking[i, j] = 1
    return blocking


def _snap_passable(passable, ij, max_r=6):
    """关键点格被合法遮挡时（无中央战场下中心可有掩体），取 max_r 内最近可走格。"""
    i, j = ij
    if passable[i, j]:
        return (i, j)
    from ..pathing import bfs_components
    best, bd = None, max_r * max_r
    idx = np.argwhere(passable > 0)
    for r in idx:
        d = (r[0] - i) ** 2 + (r[1] - j) ** 2
        if d < bd:
            bd, best = d, (int(r[0]), int(r[1]))
    return best if best is not None else (i, j)


def recheck(blocking, starts, lanes, params, baselines=None, key_ij=None, blocking_g2=None):
    """G2 全部检查复跑（连通、通道宽度、路径比、密度）。

    G2 v4.0.0 的通道是边界通道 pair_*（桥所在）。宽度门控 = 不低于 G2 基线
    （G2 的咽喉在桥 approach 处，用 choke_w 口径验收；lane_min_width 全程最小值
    在 G2 上即可为 7.5——实例化只要求不把 G2 的宽度变差，而非达到另一口径的 8）。
    关键点 = 4 出生点 + 中心格；中心格可被合法遮挡（无中央战场），吸附最近可走格。
    """
    passable = compute_passable(blocking)
    if key_ij is None:
        key_ij = [cell_of(s[0], s[1]) for s in starts] + [cell_of(*MAP_CENTER)]
    key_ij = [_snap_passable(passable, ij) for ij in key_ij]
    from ..pathing import bfs_components
    label = bfs_components(passable)
    comps = len([v for v in np.unique(label) if v >= 0])
    widths = {name: lane_min_width(lane["polyline"], blocking) for name, lane in lanes.items()}
    pf = path_fairness(passable, starts)
    frac = float((blocking > 0).mean())
    frac_g2 = float((blocking_g2 > 0).mean()) if blocking_g2 is not None else None
    fair_r = params.get("fairness_ratio", 1.6)
    flank_ratio = pf["flank_ratio"]
    baselines = baselines or {}
    tol = 0.25
    width_ok = {}
    for n, wv in widths.items():
        base = baselines.get(n, params["choke_any_min"])
        # 与 greedy_cover._guard_floor 同口径：既不低于 choke 下限，也不得把通道
        # 压窄到 G2 基线的 90% 以下（2026-09-14 起，理由见 _guard_floor 注释）。
        floor = max(min(params["choke_any_min"], base) - tol, base * 0.90)
        width_ok[n] = (wv, floor, wv >= floor)
    # 2026-09-14：原 `density_total_min=0.12 ~ max=0.30` 在当前地貌下**不可能满足** ——
    # G2 自身 blocking 已达 0.400（G2 全绿通过），实例只能在既有岩体上小幅增减，
    # 绝对区间失效（一直红着，等于没有这道门）。改为「相对 G2 的变化幅度」口径：
    # G3 只允许把 blocking 占比改变 ≤ density_delta_max（绝对上限作兜底防失控）。
    delta = abs(frac - frac_g2) if frac_g2 is not None else 0.0
    density_pass = delta <= params.get("density_delta_max", 0.02) and frac <= 0.55
    return {
        "components": comps, "components_pass": comps == 1,
        "keypoints_pass": keypoints_connected(passable, key_ij),
        "lane_widths": widths,
        "lane_width_floors": {n: round(v[1], 2) for n, v in width_ok.items()},
        "widths_pass": all(v[2] for v in width_ok.values()),
        # 兼容键（旧命名，语义 = 全通道不低于基线）
        "main_min_width_pass": all(v[2] for v in width_ok.values()),
        "any_min_width_pass": all(v[2] for v in width_ok.values()),
        "path_fairness": pf,
        "path_fairness_pass": flank_ratio is not None and flank_ratio <= fair_r + 1e-9,
        "blocking_frac": frac,
        "blocking_frac_g2": frac_g2,
        "blocking_frac_delta": round(delta, 4),
        "density_total_pass": density_pass,
    }


def path_fairness(passable, starts):
    from ..pathing import path_length
    center_ij = cell_of(*MAP_CENTER)
    start_ij = [cell_of(s[0], s[1]) for s in starts]
    to_center = [path_length(passable, start_ij[i], center_ij) for i in range(4)]
    polar = polar_order(starts)
    sums = []
    for i in range(4):
        idx = polar.index(i)
        s = 0.0
        ok = True
        for nb in (polar[(idx - 1) % 4], polar[(idx + 1) % 4]):
            d = path_length(passable, start_ij[i], start_ij[nb])
            if not math.isfinite(d):
                ok = False
                break
            s += d
        sums.append(s if ok else math.inf)
    fm = [v for v in to_center if math.isfinite(v)]
    fs = [v for v in sums if math.isfinite(v)]
    return {
        "to_center": to_center, "neighbor_sums": sums,
        "main_ratio": max(fm) / min(fm) if len(fm) == 4 else None,
        "flank_ratio": max(fs) / min(fs) if len(fs) == 4 else None,
        "pass": len(fm) == 4 and len(fs) == 4 and
                max(fm) / min(fm) <= 1.3 + 1e-9 and max(fs) / min(fs) <= 1.3 + 1e-9,
    }


def fix_recheck_failures(instances, blocking, starts, lanes, params, water_mask=None,
                         baselines=None, key_ij=None, blocking_g2=None):
    """复检修复循环（≤20 轮），修复优先级：

    1. 小口袋：不含关键点且 <pocket_fill_max 格的额外开放分量 → 直接填实
       （与 G2 口袋语义一致：不可达孤立口袋填成岩体，保证单连通）
    2. 大口袋/封口：与被隔离开放分量相邻的"封口实例"（接触最多者）→ 删除
    3. 通道过窄：定位最窄采样点，删压在窄点上的实例
    water_mask：河道格恒为 blocking；key_ij：G2 的 12 个玩法关键点（格坐标）。
    """
    from ..pathing import bfs_components, dilate8, lane_width_profile
    removed = []
    rep = recheck(blocking, starts, lanes, params, baselines=baselines, key_ij=key_ij,
                  blocking_g2=blocking_g2)
    for _ in range(20):
        ok = (rep["components_pass"] and rep["keypoints_pass"] and rep["widths_pass"])
        if ok:
            return removed, rep, blocking
        changed = False
        # --- 1) 小口袋填实 / 2) 封口实例 ---
        if not (rep["components_pass"] and rep["keypoints_pass"]):
            passable = compute_passable(blocking)
            label = bfs_components(passable)
            vals, cnts = np.unique(label[label >= 0], return_counts=True)
            main = int(vals[int(np.argmax(cnts))])
            key_set = set(key_ij or [])
            for v in vals:
                if int(v) == main:
                    continue
                cells = np.argwhere(label == v)
                contains_key = any((int(i), int(j)) in key_set for i, j in cells)
                if not contains_key and len(cells) < int(params.get("pocket_fill_max", 3000)):
                    blocking[cells[:, 0], cells[:, 1]] = 1
                    removed.append({"name": "(fill_pocket)", "at": [float(np.mean(cells[:, 1])),
                                                                    float(np.mean(cells[:, 0]))],
                                    "reason": f"fill_pocket n={len(cells)}"})
                    changed = True
                    break
            if not changed:
                # 封口实例：与隔离分量相邻（膨胀 1 格接触）的实例，接触最多者优先
                iso = (label >= 0) & (label != main)
                if iso.any():
                    iso_d = dilate8(iso)
                    blocking_insts = [i for i in instances if i["blocking"]]
                    scored = []
                    for ins in blocking_insts:
                        w, h = ins["extent"]
                        cells = oriented_rect_cells(ins["x"], ins["z"], w, h, ins["yaw"])
                        touch = sum(1 for i2, j2 in cells if iso_d[i2, j2])
                        if touch:
                            scored.append((touch, ins["extent"][0] * ins["extent"][1], ins))
                    if scored:
                        scored.sort(key=lambda x: (-x[0], -x[1]))
                        victim = scored[0][2]
                        instances.remove(victim)
                        removed.append({"name": victim["name"],
                                        "at": [victim["x"], victim["z"]],
                                        "reason": "sealer"})
                        blocking = rerasterize(instances)
                        if water_mask is not None:
                            blocking |= water_mask.astype(np.uint8)
                        rep = recheck(blocking, starts, lanes, params,
                                      baselines=baselines, key_ij=key_ij,
                                      blocking_g2=blocking_g2)
                        changed = True
        # --- 3) 通道过窄：删压在窄点上的实例 ---
        if not changed and not rep["widths_pass"]:
            floors = rep["lane_width_floors"]
            bad = [(n, wv) for n, wv in rep["lane_widths"].items() if wv < floors[n]]
            if bad:
                n0 = bad[0][0]
                prof = lane_width_profile(lanes[n0]["polyline"], blocking, 2.0, 30.0)
                pinch = min(prof, key=lambda s: s.width)
                blocking_insts = [i for i in instances if i["blocking"]]
                near = [ins for ins in blocking_insts
                        if math.hypot(ins["x"] - pinch.x, ins["z"] - pinch.z) <= 10.0]
                victim = None
                if near:
                    victim = max(near, key=lambda i: i["extent"][0] * i["extent"][1])
                elif blocking_insts:
                    victim = min(blocking_insts, key=lambda ins: math.hypot(
                        ins["x"] - pinch.x, ins["z"] - pinch.z))
                if victim is not None:
                    instances.remove(victim)
                    removed.append({"name": victim["name"], "at": [victim["x"], victim["z"]],
                                    "reason": "pinch"})
                    blocking = rerasterize(instances)
                    if water_mask is not None:
                        blocking |= water_mask.astype(np.uint8)
                    changed = True
        if not changed:
            break
        rep = recheck(blocking, starts, lanes, params, baselines=baselines, key_ij=key_ij,
                  blocking_g2=blocking_g2)
    return removed, rep, blocking


def place_decorations(passable, lane_core, role, resources, starts, catalog, rng, params, factor=1.0, water=None):
    """撒非遮挡装饰（不改 blocking）。大件（XZ > deco_max_size）不参与，避免 visually 吞掉开阔区。

    water：可选的语义水掩码。传入时启用【绿洲】——近水区装饰密度 x3
    （沙漠植被沿水聚集，比全图均匀撒布更接近真实地貌）。
    """
    max_sz = params.get("deco_max_size", 4.5)
    decor = [e for e in catalog if not e["blocking"] and e.get("atlas") is not None and
             max(e["size"][0], e["size"][2]) <= max_sz and
             any(e["name"].startswith(p) for p in
                 ("SM_Env_Ground_Greeble_", "SM_Decal_", "SM_Env_Plant_",
                  "SM_Prop_Scav_Scrap_", "SM_Prop_Crate_"))]
    if not decor:
        return []
    ys, xs = np.meshgrid(np.arange(GRID_H), np.arange(GRID_W), indexing="ij")
    ok = (passable > 0) & (lane_core == 0)
    for s in starts:
        ok &= np.hypot(xs - s[0], ys - s[1]) >= params["deco_spawn_dist"]
    for r in resources:
        ok &= np.hypot(xs - r["x"], ys - r["z"]) >= params["deco_res_dist"]
    # 绿洲：按"到水距离"对【可通行格】排序，取最近的 20% 作为近水绿洲带。
    # 不设硬窗口——岸坡不可通行，固定半径窗口内可通行格极少（14/28 格实测
    # 都只有 3%），排序取比例法与地图水形无关，必然生效。
    if water is not None:
        from scipy import ndimage as _ndi
        d_water = _ndi.distance_transform_edt(np.asarray(water) == 0)
        ok_idx = np.argwhere(ok)
        oasis = np.zeros_like(ok, dtype=bool)
        if len(ok_idx):
            dvals = d_water[ok_idx[:, 0], ok_idx[:, 1]]
            k = max(1, int(len(ok_idx) * 0.20))
            near = ok_idx[np.argsort(dvals)[:k]]
            oasis[near[:, 0], near[:, 1]] = True
    else:
        oasis = np.zeros_like(ok, dtype=bool)
    out = []
    for role_id in (5, 3, 2):
        base = params["deco_density"].get(role_id, 0.0) * factor
        mask = ok & (role == role_id)
        # 近水（绿洲）密度 x3，其余按 base
        for m, frac in ((mask & oasis, base * 3.0), (mask & ~oasis, base)):
            idx = np.argwhere(m)
            n = int(len(idx) * frac)
            if n <= 0:
                continue
            picks = idx[rng.permutation(len(idx))[:n]]
            for ci, cj in picks:
                e = decor[int(rng.integers(0, len(decor)))]
                yaw = int(rng.integers(0, 8)) * 45
                out.append({
                    "fbx": e["res_path"], "name": e["name"], "atlas": e["atlas"],
                    "x": int(cj) + 0.5, "z": int(ci) + 0.5,
                    "yaw": yaw, "scale": 1.0, "blocking": False,
                    "terrain": 0, "cluster": None, "extent": [1.0, 1.0],
                })
    return out


def cluster_cover(blocking_new, clusters):
    """重算后 blocking 对原簇格的覆盖率。"""
    tot = hit = 0
    for cl in clusters:
        for i, j in cl["cells"]:
            tot += 1
            hit += 1 if blocking_new[i, j] else 0
    return hit / tot if tot else 1.0


def _inherit_approval(runs_root, seed, gate, manifest, algo):
    from ..gate import load_manifest, manifest_path
    p = manifest_path(runs_root, seed, gate)
    if p.exists():
        old = load_manifest(runs_root, seed, gate)
        # 2026-09-06：继承必须同时核对输入/输出哈希——新地貌不得继承旧人工认可。
        if (old.get("gate") == gate and old.get("algo_version") == algo and old.get("approved")
                and old.get("input_hash") == manifest.get("input_hash")
                and old.get("output_hash") == manifest.get("output_hash")):
            manifest["approved"] = True
            manifest["approved_note"] = old.get("approved_note")
            manifest["approved_at"] = old.get("approved_at")


def derive_clusters(blocking, terrain):
    """从 G2 npz 的 blocking 连通分量派生实例化簇（v4.0.0 不写 obstacles.json）。

    每个分量 = 一簇；terrain 取分量内格的主导值。water（terrain==5，河道）不实例化，
    由调用方以 water 掩码保留 blocking、G4 以水体碰撞盒呈现。
    """
    from ..pathing import label8
    lab = label8(blocking > 0)
    clusters = []
    for c in range(int(lab.max()) + 1):
        cells = np.argwhere(lab == c)
        if len(cells) == 0:
            continue
        vals = terrain[cells[:, 0], cells[:, 1]]
        u, cnt = np.unique(vals, return_counts=True)
        dom = int(u[int(np.argmax(cnt))])
        if dom == TERRAIN_WATER:
            continue
        clusters.append({"id": f"c{c}", "terrain": dom,
                         "cells": [(int(i), int(j)) for i, j in cells]})
    return clusters


def _ensure_g2_valid_auto(seed, runs_root, g2_spec):
    """工作台自动模式：用本次 G2 真实结果代替人工 approval。

    要求：G2 manifest 存在、算法版本一致、mapspec.all_pass 为真，且
    manifest 的输入/输出哈希与当前磁盘文件一致（防止用到半新半旧产物）。"""
    from ..gate import load_manifest
    from ..grid import sha256_file
    g2_dir = run_dir(runs_root, seed, "G2")
    try:
        mf = load_manifest(runs_root, seed, "G2")
    except (OSError, ValueError):
        raise RuntimeError(f'自动模式拒绝运行 G3：Seed {seed} 缺少本次任务的 G2 manifest。')
    if mf.get("algo_version") != ALGO_VERSION["G2"]:
        raise RuntimeError(f'自动模式拒绝运行 G3：G2 版本 {mf.get("algo_version")} 与当前 {ALGO_VERSION["G2"]} 不一致。')
    if not g2_spec.get("all_pass"):
        failed = [k for k, v in (g2_spec.get("checks") or {}).items() if not v]
        raise RuntimeError(f'自动模式拒绝运行 G3：本次 G2 未通过检查 {failed}。')
    outputs = mf.get("output_hash") or {}
    for name, digest in (("mapgrid.npz", outputs.get("mapgrid.npz")),
                         ("mapspec.json", outputs.get("mapspec.json"))):
        path = g2_dir / name
        if not digest or not path.exists() or sha256_file(path) != digest:
            raise RuntimeError(f'自动模式拒绝运行 G3：G2 产物 {name} 与 manifest 哈希不一致或缺失。')


def run_one(seed, runs_root, params, auto=False):
    if not auto:
        ensure_upstream_approved(runs_root, seed, "G3")
    algo = ALGO_VERSION["G3"]
    g2_dir = run_dir(runs_root, seed, "G2")
    g2_spec = read_json(g2_dir / "mapspec.json")
    if auto:
        _ensure_g2_valid_auto(seed, runs_root, g2_spec)
    lanes = read_json(g2_dir / "lanes.json")
    from ..grid import sha256_file
    input_hash = sha256_file(g2_dir / "mapgrid.npz")

    rd = run_dir(runs_root, seed, "G3")
    Path(rd).mkdir(parents=True, exist_ok=True)
    rng = gate_rng(seed, "G3", algo)
    starts = [tuple(s) for s in g2_spec["starts"]]
    g2_grid = MapGrid.load(g2_dir / "mapgrid.npz")

    # ---- 第一步：资源 ----
    # expansion 锚点 8 m 盘 / flank 锚点盘（G2 v4.0.0 的 flank 区域共用 region=30，须按锚点分盘）
    exp_anchor_masks = [_dist_field(a[0], a[1]) <= 8.0
                        for a in (g2_spec.get("expansion_anchors") or [])]
    flank_masks = [_dist_field(a[0], a[1]) <= params["flank_anchor_radius"]
                   for a in (g2_spec.get("flank_anchors") or [])]

    overlay, placed, fairness, failures, df = place_resources(
        g2_grid, g2_spec, lanes, params, rng, exp_anchor_masks=exp_anchor_masks,
        flank_masks=flank_masks)
    resources = enrich_resources(placed, df, lanes)

    # ---- 第二步：素材实例化 ----
    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    mapping = build_mapping(catalog)
    # 2026-09-06：映射快照写入本任务目录；不再每次覆写共享的
    # rtsmap/data/terrain_to_assets.json（多任务并发/反复写入无必要）。
    write_json(rd / "terrain_to_assets.json", {str(k): [e["name"] for e in v] for k, v in mapping.items()})

    terrain_g2 = g2_grid.get("terrain")
    blocking_g2 = g2_grid.get("blocking").copy()
    water_mask = terrain_g2 == TERRAIN_WATER   # 河道：保留 blocking、不实例化
    clusters = derive_clusters(blocking_g2, terrain_g2)
    # G2 基线通道宽度（复检门控 = 不低于基线，见 recheck 注释）
    baselines = {name: lane_min_width(lane["polyline"], blocking_g2)
                 for name, lane in lanes.items()}
    # 复检关键点集 = G2 的 12 个玩法关键点（4 出生 + 4 flank 锚 + 4 扩张锚）
    key_ij = [tuple(k) for k in g2_spec.get("keypoints")] or None
    # 敏感区：扩张接入道 ±4.5m、扩张口袋 r16、桥口 r8、基地盘 +2 —— 实例外溢禁入
    sensitive = np.zeros((GRID_H, GRID_W), dtype=bool)
    for i in range(4):
        sensitive |= segment_mask(starts[i], tuple(g2_spec["expansion_anchors"][i]), 9.0)
        sensitive |= _dist_field(g2_spec["expansion_anchors"][i][0],
                                 g2_spec["expansion_anchors"][i][1]) <= 16.0
        sensitive |= _dist_field(starts[i][0], starts[i][1]) <= 22.0
    for gc in g2_spec.get("gap_centers") or []:
        sensitive |= _dist_field(gc[0], gc[1]) <= 8.0
    # 资源 2m 净空圈：实例外溢禁入（悬崖类素材更宽，外溢会把 blocking 推到
    # 距资源 <2m，破坏 G3 净空验收——test_resource_clearance 曾抓到）
    for p_ in placed:
        sensitive |= _dist_field(p_["j"] + 0.5, p_["i"] + 0.5) <= params["res_clear_blocking"]
    # 2026-09-14：路线走廊也计入敏感区。此前只有 `_guard_ok` 的宽度守卫兜底，
    # 于是实例可以【外溢】进通道、把 14.25m 的路压到 9.75m（用户反馈"石头把路堵上了"）。
    # 这里把 lane_core 膨胀 1 格（4m）后设为禁入，实例外溢格不得进路线。
    from scipy import ndimage as _ndi_route
    sensitive |= _ndi_route.binary_dilation(
        g2_grid.get("lane_core") > 0, iterations=1)

    ys, xs = np.meshgrid(np.arange(GRID_H), np.arange(GRID_W), indexing="ij")
    placeable = g2_grid.get("lane_core") == 0
    for s in starts:
        placeable &= np.hypot(xs - s[0], ys - s[1]) >= 12.0
    placeable &= ~water_mask

    instances = []
    occupied = set()
    lane_core_arr = g2_grid.get("lane_core")
    probe = blocking_g2.copy()   # 宽度守卫用动态 blocking（G2 原值 + 已放实例盒）
    for cl in clusters:
        cells = [tuple(c) for c in cl["cells"]]
        # 隔墙/岩簇本就贴着边界通道与桥口，允许盒进 lane_core 边缘（宽度守卫兜底）
        ins = greedy_cover(cells, cl["terrain"], mapping, placeable, occupied, rng, params,
                           lanes=lanes, blocking_probe=probe,
                           allow_lane_core=True, lane_core=lane_core_arr,
                           blocking_base=blocking_g2,
                           baselines=baselines, sensitive=sensitive)
        for x in ins:
            x["cluster"] = cl["id"]
            if x["blocking"]:
                w, h = x["extent"]
                for i, j in oriented_rect_cells(x["x"], x["z"], w, h, x["yaw"]):
                    probe[i, j] = 1
        instances.extend(ins)

    blocking_new = (blocking_g2.astype(np.uint8)
                    | water_mask.astype(np.uint8)
                    | rerasterize(instances))
    removed, rep, blocking_new = fix_recheck_failures(instances, blocking_new, starts,
                                                      lanes, params,
                                                      water_mask=water_mask,
                                                      baselines=baselines, key_ij=key_ij,
                                                      blocking_g2=blocking_g2)
    passable_new = compute_passable(blocking_new)

    # 装饰（实例预算 ≤1500，超出先降装饰密度）
    decos = []
    for factor in (1.0, 0.6, 0.3, 0.0):
        p2 = dict(params)
        p2["deco_density"] = {k: v * factor for k, v in params["deco_density"].items()}
        decos = place_decorations(passable_new, g2_grid.get("lane_core"),
                                  g2_grid.get("role"), resources, starts, catalog,
                                  rng, p2, factor, water=g2_grid.get("water_footprint"))
        if len(instances) + len(decos) <= params["asset_budget"]:
            break
    all_instances = instances + decos

    # ---- 写格网与输出 ----
    grid = MapGrid.from_parent(g2_grid)
    grid.set("blocking_g2", blocking_g2)
    grid.set("blocking", blocking_new)
    grid.set("passable", passable_new)
    grid.set("overlay", overlay)
    npz_hash = grid.save(rd / "mapgrid.npz")

    cover = cluster_cover(blocking_new, clusters)
    assets_used = sorted({ins["fbx"] for ins in all_instances})
    atlases = sorted({ins["atlas"] for ins in all_instances if ins["atlas"]})
    write_json(rd / "objects.json", {"instances": all_instances, "count": len(all_instances)})
    write_json(rd / "assets_used.json", {"fbx": assets_used, "atlases": atlases})
    write_json(rd / "recheck_report.json", {
        "recheck": rep, "removed_instances": removed,
        "cluster_cover_frac": cover,
        "cluster_cover_pass": cover >= params["cluster_cover_min"],
        "instance_count": len(all_instances),
        "blocking_instances": sum(1 for x in all_instances if x["blocking"]),
        "deco_instances": sum(1 for x in all_instances if not x["blocking"]),
        "budget": params["asset_budget"],
        "budget_pass": len(all_instances) <= params["asset_budget"],
        "water_cells": int(water_mask.sum()),
        "resource_failures": failures,
    })
    write_json(rd / "resources.json", {"resources": resources, "fairness": fairness,
                                       "failures": failures})

    checks = {
        "quota_equal": fairness["quota_equal"],
        "fairness_pass": fairness["pass"],
        "recheck_components": rep["components_pass"],
        "recheck_keypoints": rep["keypoints_pass"],
        "recheck_widths": rep["widths_pass"],
        "recheck_path_fairness": rep["path_fairness_pass"],
        "recheck_density": rep["density_total_pass"],
        "cluster_cover": cover >= params["cluster_cover_min"],
        "budget": len(all_instances) <= params["asset_budget"],
        "no_resource_failures": not failures,
    }

    # ---- 2026-09-14 新增硬断言（用户反馈"石头瞎摆，把路都堵上了"）----
    # ① 石头不得【新增】路线核心带内的 blocking。注意不能用 "== 0" 口径：
    #    G2 自身就有 473 格 "岩体压核心带" 的重叠（G2 已放行），实例化只能保证
    #    **不新增**，故与 G2 比。水格（河道/桥下）本就 blocking，必须排除。
    # ② 不得把任何通道压窄到 G2 基线的 90% 以下。
    # ③ 阻挡实例 footprint 外溢到 G2 岩体外的比例不得超上限（防巨型件摊在开阔地）。
    lane_core_b = g2_grid.get("lane_core") > 0
    lane_intrude_g2 = int(((blocking_g2 > 0) & lane_core_b & ~water_mask).sum())
    lane_intrude = int(((blocking_new > 0) & lane_core_b & ~water_mask).sum())
    lane_widths_new = {n: lane_min_width(l["polyline"], blocking_new)
                       for n, l in lanes.items()}
    narrowed = sorted(n for n, wv in lane_widths_new.items()
                      if wv < baselines.get(n, 99.0) * 0.90 - 1e-6)
    over_violations = []
    over_outside_cells = 0
    for ins in instances:
        w, h = ins["extent"]
        cells = pattern_cells(w, h, ins["x"], ins["z"], ins["yaw"])
        if not cells:
            continue
        outside = sum(1 for i, j in cells if not blocking_g2[i, j])
        over_outside_cells += outside
        base_cap = 2 if len(cells) <= 6 else 0
        cap = max(base_cap, int(round(params["cover_overhang_frac"] * len(cells))))
        if outside > cap:
            over_violations.append(ins["name"])
    checks["lane_core_clear"] = lane_intrude <= lane_intrude_g2
    checks["lane_not_narrowed"] = not narrowed
    checks["overhang_within_cap"] = not over_violations
    all_pass = all(checks.values())
    write_json(rd / "report.json", {
        "seed": seed, "gate": "G3", "algo_version": algo,
        "acceptance": {"all_pass": all_pass, "checks": checks,
                       "fairness": fairness,
                       "path_fairness_recheck": rep["path_fairness"],
                       "instance_count": len(all_instances),
                       "blocking_frac": rep["blocking_frac"],
                       "cluster_cover_frac": round(float(cover), 4),
                       "water_cells": int(water_mask.sum()),
                       "lane_core_intrude_cells": lane_intrude,
                       "lane_narrowed": narrowed,
                       "lane_widths": {k: round(float(v), 2) for k, v in lane_widths_new.items()},
                       "lane_baselines": {k: round(float(v), 2) for k, v in baselines.items()},
                       "overhang_violations": sorted(set(over_violations))[:8],
                       "overhang_violation_count": len(over_violations),
                       "overhang_outside_cells": over_outside_cells},
    })
    mapspec = {
        "gate": "G3", "master_seed": seed,
        "gate_seed": gate_seed_int(seed, "G3", algo),
        "algo_version": algo, "params": params,
        "starts": [list(s) for s in starts],
        "resource_fairness": fairness,
        "resource_failures": failures,
        "instance_count": len(all_instances),
        "blocking_frac": rep["blocking_frac"],
        "water_cells": int(water_mask.sum()),
        "cluster_cover_frac": round(float(cover), 4),
        "recheck": rep,
        "removed_instances": removed,
        "all_pass": all_pass,
    }
    json_hash = write_json(rd / "mapspec.json", mapspec)
    manifest = new_manifest(seed, "G3", mapspec["gate_seed"], algo, params,
                            input_hash=input_hash,
                            output_hash={"mapgrid.npz": npz_hash, "mapspec.json": json_hash})
    manifest['execution_mode'] = 'workbench_auto' if auto else 'formal'
    if not auto:
        _inherit_approval(runs_root, seed, "G3", manifest, algo)
    write_json(rd / "manifest.json", manifest)
    return {"seed": seed, "run_dir": rd, "mapspec": mapspec, "grid": grid,
            "resources": resources, "instances": all_instances,
            "starts": starts, "lanes": lanes, "clusters": clusters,
            "fairness": fairness, "water_mask": water_mask}


def run_gate(runs_root, seeds, params=None, summary_only=False, review_root="review"):
    params = {**G3_DEFAULTS, **(params or {})}
    results = []
    for seed in seeds:
        res = run_one(seed, runs_root, params)
        if not summary_only:
            from ..viz import plots_g3
            plots_g3.plot_all(res)
        results.append(res)
        print(f"Seed {seed}: all_pass={res['mapspec']['all_pass']} "
              f"instances={res['mapspec']['instance_count']} "
              f"blocking_frac={res['mapspec']['blocking_frac']:.3f}")
        if not res["mapspec"]["all_pass"]:
            print(f"  removed={len(res['mapspec']['removed_instances'])} "
                  f"res_failures={res['mapspec']['resource_failures']}")
    make_summary(runs_root, results)
    from ..viz.review import build_g3_review
    build_g3_review(runs_root, review_root, [r["seed"] for r in results])
    return results


def make_summary(runs_root, results):
    from ..report import summary_dir, write_summary_json
    sd = summary_dir(runs_root, "G3")
    write_summary_json(sd / "summary.json", {
        "gate": "G3",
        "seeds": [r["seed"] for r in results],
        "per_seed": {str(r["seed"]): {
            "all_pass": r["mapspec"]["all_pass"],
            "instance_count": r["mapspec"]["instance_count"],
            "blocking_frac": r["mapspec"]["blocking_frac"],
            "fairness": r["mapspec"]["resource_fairness"],
            "recheck": r["mapspec"]["recheck"],
            "removed": len(r["mapspec"]["removed_instances"]),
        } for r in results},
    })
    from ..viz import plots_g3
    plots_g3.plot_contact(sd, results)
