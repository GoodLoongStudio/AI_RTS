"""G1：4 人出生点采样 + 硬约束筛选 + Voronoi 领地。"""
import math

import numpy as np

from ..contract import (
    ALGO_VERSION, BASE_RADIUS, CONTEST_BAND, EPS, G1_CORNER_DIST, G1_DEFAULTS,
    GRID_H, GRID_W, H, MAP_CENTER, N_PLAYERS, W,
)
from ..gate import new_manifest
from ..grid import MapGrid, write_json
from ..rng import gate_rng, gate_seed_int

CONSTRAINT_ORDER = [
    "margin", "min_pair", "center_gap", "angle_gap",
    "center_ratio", "territory_ratio", "nn_ratio",
]


# ---------------- 允许区与采样 ----------------

def allowed(x: float, z: float, params) -> bool:
    """允许区 = 到四条边 ≥ margin 且到地图中心 ≥ center_gap（连续坐标）。"""
    margin = params["margin"]
    if not (margin - EPS <= x <= W - margin + EPS and margin - EPS <= z <= H - margin + EPS):
        return False
    dx, dz = x - MAP_CENTER[0], z - MAP_CENTER[1]
    return math.hypot(dx, dz) >= params["center_gap"] - EPS


def _sample_allowed(rng, params):
    lo, hi = params["margin"], min(W, H) - params["margin"]
    for _ in range(10000):
        x = float(rng.uniform(lo, hi))
        z = float(rng.uniform(lo, hi))
        if allowed(x, z, params):
            return (x, z)
    raise RuntimeError("允许区采样失败（参数异常）")


def _best_candidate(rng, placed, params):
    """抽 candidates 个候选，按到已放置各点的最小距离降序，取前 top_frac 中随机一个。"""
    cands = [_sample_allowed(rng, params) for _ in range(params["candidates"])]
    scores = []
    for cx, cz in cands:
        scores.append(min(math.hypot(cx - px, cz - pz) for px, pz in placed))
    order = np.argsort(-np.asarray(scores), kind="stable")
    n_top = max(1, int(round(params["candidates"] * params["top_frac"])))
    idx = int(rng.integers(0, n_top))
    return cands[int(order[idx])]


def sample_starts(rng, params):
    """采样器 A（默认）。返回 dict(starts, attempts, accepted, constraints, reject_reason)。"""
    for attempt in range(1, params["max_attempts"] + 1):
        pts = [_sample_allowed(rng, params)]
        for _ in range(N_PLAYERS - 1):
            pts.append(_best_candidate(rng, pts, params))
        starts = np.asarray(pts, dtype=float)
        ev = evaluate_constraints(starts, params)
        fail = first_violation(ev)
        if fail is None:
            return {"starts": starts, "attempts": attempt, "accepted": True,
                    "constraints": ev, "reject_reason": None}
        last = {"starts": starts, "attempts": attempt, "accepted": False,
                "constraints": ev, "reject_reason": fail}
    return last


def sample_starts_b(rng, params):
    """可选采样器 B：旋转模板 + ±15% 抖动（对照用，默认不跑）。"""
    cx, cz = MAP_CENTER
    base_r = (W / 2 - params["margin"]) * 0.72
    for attempt in range(1, params["max_attempts"] + 1):
        theta0 = float(rng.uniform(0, 2 * math.pi))
        pts = []
        for k in range(N_PLAYERS):
            ang = theta0 + k * math.pi / 2
            jitter = 1.0 + float(rng.uniform(-0.15, 0.15))
            r = base_r * jitter
            x = cx + r * math.cos(ang)
            z = cz + r * math.sin(ang)
            x = min(max(x, params["margin"]), W - params["margin"])
            z = min(max(z, params["margin"]), H - params["margin"])
            pts.append((x, z))
        starts = np.asarray(pts, dtype=float)
        ev = evaluate_constraints(starts, params)
        fail = first_violation(ev)
        if fail is None:
            return {"starts": starts, "attempts": attempt, "accepted": True,
                    "constraints": ev, "reject_reason": None}
        last = {"starts": starts, "attempts": attempt, "accepted": False,
                "constraints": ev, "reject_reason": fail}
    return last


# ---------------- 约束 ----------------

def voronoi_territory(starts: np.ndarray) -> np.ndarray:
    """96×96 每格按格中心归属最近出生点（并列取最小编号，确定）。返回 u16。"""
    gi = np.arange(GRID_W) + 0.5   # X
    gj = np.arange(GRID_H) + 0.5   # Z
    xx, zz = np.meshgrid(gi, gj)
    d = np.stack([np.hypot(xx - s[0], zz - s[1]) for s in starts])
    return np.argmin(d, axis=0).astype(np.uint16)


def evaluate_constraints(starts: np.ndarray, params) -> dict:
    """按固定顺序计算全部约束的取值与通过/失败。"""
    s = np.asarray(starts, dtype=float)
    n = len(s)
    res = {}

    # 1. margin：到四边最小距离
    margins = np.minimum.reduce([s[:, 0], W - s[:, 0], s[:, 1], H - s[:, 1]])
    res["margin"] = {"value": float(margins.min()), "limit": params["margin"],
                     "pass": bool(margins.min() >= params["margin"] - EPS)}

    # 2. min_pair
    dm = np.hypot(s[:, 0][:, None] - s[:, 0][None, :], s[:, 1][:, None] - s[:, 1][None, :])
    np.fill_diagonal(dm, np.inf)
    min_pair = float(dm.min())
    limit = params["min_pair_factor"] * math.sqrt(W * H)
    res["min_pair"] = {"value": min_pair, "limit": limit,
                       "pass": bool(min_pair >= limit - EPS)}

    # 3. center_gap
    cd = np.hypot(s[:, 0] - MAP_CENTER[0], s[:, 1] - MAP_CENTER[1])
    res["center_gap"] = {"value": float(cd.min()), "limit": params["center_gap"],
                         "pass": bool(cd.min() >= params["center_gap"] - EPS)}

    # 4. angle_gap：极角排序后相邻夹角（含首尾环绕）
    ang = np.degrees(np.arctan2(s[:, 1] - MAP_CENTER[1], s[:, 0] - MAP_CENTER[0]))
    a_sorted = np.sort(ang)
    gaps = np.diff(np.concatenate([a_sorted, [a_sorted[0] + 360.0]]))
    lo, hi = params["angle_min"], params["angle_max"]
    ok = bool(gaps.min() >= lo - EPS and gaps.max() <= hi + EPS)
    res["angle_gap"] = {"value": [float(gaps.min()), float(gaps.max())],
                        "limit": [lo, hi], "pass": ok}

    # 5. center_ratio
    cmin, cmax = float(cd.min()), float(cd.max())
    res["center_ratio"] = {"value": cmax / max(cmin, EPS), "limit": params["center_ratio"],
                           "pass": bool(cmax <= params["center_ratio"] * cmin + EPS)}

    # 6. territory_ratio（Voronoi 格数 max/min）
    terr = voronoi_territory(s)
    counts = np.bincount(terr.ravel(), minlength=n)
    tmin, tmax = int(counts.min()), int(counts.max())
    ratio = (tmax / tmin) if tmin > 0 else float("inf")
    res["territory_ratio"] = {"value": ratio, "limit": params["territory_ratio"],
                              "pass": bool(tmin > 0 and ratio <= params["territory_ratio"] + EPS),
                              "cells": [int(c) for c in counts]}

    # 7. nn_ratio（各点到最近其它点的距离 max/min）
    nn = dm.min(axis=1)
    nmin, nmax = float(nn.min()), float(nn.max())
    res["nn_ratio"] = {"value": nmax / max(nmin, EPS), "limit": params["nn_ratio"],
                       "pass": bool(nmax <= params["nn_ratio"] * nmin + EPS)}
    return res


def first_violation(evaluated: dict):
    for name in CONSTRAINT_ORDER:
        if not evaluated[name]["pass"]:
            return name
    return None


# ---------------- 统计量 ----------------

def corner_flags(starts: np.ndarray, thresh: float = G1_CORNER_DIST):
    corners = np.array([[0, 0], [W, 0], [0, H], [W, H]], dtype=float)
    out = []
    for p in np.asarray(starts, dtype=float):
        dmin = float(np.hypot(corners[:, 0] - p[0], corners[:, 1] - p[1]).min())
        out.append(bool(dmin < thresh))
    return out


def rot_sym_err(starts: np.ndarray):
    """绕中心旋转 90/180/270°，最近点匹配平均位移，取最小再除以 sqrt(W·H)。"""
    s = np.asarray(starts, dtype=float)
    c = np.array(MAP_CENTER)
    rel = s - c
    best = math.inf
    for k in (1, 2, 3):
        a = k * math.pi / 2
        rotm = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])
        rp = rel @ rotm.T + c
        dmean = float(np.mean([min(float(np.hypot(*(p - q))) for q in s) for p in rp]))
        best = min(best, dmean)
    return best / math.sqrt(W * H)


def base_ring_outside(starts: np.ndarray) -> bool:
    """检查 4 点两两基地盘（BASE_RADIUS）不重叠（仅报告用）。"""
    for i in range(len(starts)):
        for j in range(i + 1, len(starts)):
            if math.hypot(*(starts[i] - starts[j])) < 2 * BASE_RADIUS:
                return True
    return False


# ---------------- 主流程 ----------------

def _polar_angles(starts):
    return [math.degrees(math.atan2(p[1] - MAP_CENTER[1], p[0] - MAP_CENTER[0])) for p in starts]


def run_one(master_seed: int, runs_root, params: dict, sampler: str = "A"):
    from ..gate import run_dir
    from pathlib import Path

    algo = ALGO_VERSION["G1"]
    rd = run_dir(runs_root, master_seed, "G1")
    Path(rd).mkdir(parents=True, exist_ok=True)
    rng = gate_rng(master_seed, "G1", algo)
    fn = sample_starts if sampler == "A" else sample_starts_b
    r = fn(rng, params)

    starts = r["starts"]
    terr = voronoi_territory(starts)
    grid = MapGrid()
    grid.set("territory", terr)
    npz_hash = grid.save(rd / "mapgrid.npz")

    ev = r["constraints"]
    dm = np.hypot(starts[:, 0][:, None] - starts[:, 0][None, :],
                  starts[:, 1][:, None] - starts[:, 1][None, :])
    np.fill_diagonal(dm, np.inf)
    counts = np.bincount(terr.ravel(), minlength=N_PLAYERS)
    mapspec = {
        "gate": "G1",
        "master_seed": master_seed,
        "gate_seed": gate_seed_int(master_seed, "G1", algo),
        "algo_version": algo,
        "sampler": sampler,
        "params": params,
        "accepted": r["accepted"],
        "attempts": r["attempts"],
        "reject_reason": r["reject_reason"],
        "starts": [[round(float(x), 2), round(float(z), 2)] for x, z in starts],
        "pair_dist_matrix": [[float(v) for v in row] for row in dm],
        "min_pair": float(dm.min()),
        "polar_angles_deg": _polar_angles(starts),
        "adjacent_angle_gaps_deg": [float(v) for v in np.sort(
            np.diff(np.concatenate([np.sort(_polar_angles(starts)),
                                    [np.sort(_polar_angles(starts))[0] + 360.0]])))],
        "center_dists": [float(math.hypot(x - MAP_CENTER[0], z - MAP_CENTER[1])) for x, z in starts],
        "territory_cells": [int(c) for c in counts],
        "constraints": ev,
        "corner_flags": corner_flags(starts),
        "rot_sym_err": rot_sym_err(starts),
    }
    json_hash = write_json(rd / "mapspec.json", mapspec)
    manifest = new_manifest(master_seed, "G1", mapspec["gate_seed"], algo, params,
                            input_hash=None,
                            output_hash={"mapgrid.npz": npz_hash, "mapspec.json": json_hash})
    # 重跑同 Seed 同版本时继承用户已给出的 approved 状态（重跑不改算法不冲掉人工放行）
    from ..gate import load_manifest
    mp = rd / "manifest.json"
    if mp.exists():
        old = load_manifest(runs_root, master_seed, "G1")
        if (old.get("gate") == "G1" and old.get("algo_version") == algo
                and old.get("approved")):
            manifest["approved"] = True
            manifest["approved_note"] = old.get("approved_note")
            manifest["approved_at"] = old.get("approved_at")
    write_json(rd / "manifest.json", manifest)
    return rd, mapspec


def run_gate(runs_root, seeds, params: dict | None = None, sampler: str = "A",
             summary_only: bool = False, detail: bool = False, review_root: str = "review"):
    from ..viz import plots_g1
    from ..report import summary_dir

    params = {**G1_DEFAULTS, **(params or {})}
    specs = []
    for seed in seeds:
        rd, spec = run_one(seed, runs_root, params, sampler)
        # 修订1 §1：分项 PNG 只在 --detail 时写（review/ 才是给用户看的）
        if detail and not summary_only:
            plots_g1.plot_starts(spec, rd / "starts.png")
            plots_g1.plot_starts_table(spec, rd / "starts_table.png")
            plots_g1.plot_territory(spec, rd / "territory.png")
        specs.append(spec)
    make_summary(runs_root, specs, params, sampler)
    from ..viz import review
    review.build_g1_review(runs_root, review_root, seeds)
    return specs


def make_summary(runs_root, specs, params, sampler="A"):
    from ..report import summary_dir, write_summary_csv, write_summary_json, write_text
    from ..viz import plots_g1

    sd = summary_dir(runs_root, "G1")
    acc = [s for s in specs if s["accepted"]]
    rej = [s for s in specs if not s["accepted"]]

    reasons = {}
    for s in rej:
        reasons[s["reject_reason"]] = reasons.get(s["reject_reason"], 0) + 1

    corner_points = sum(1 for s in acc for f in s["corner_flags"] if f)
    total_pts = sum(len(s["corner_flags"]) for s in acc)
    summary = {
        "gate": "G1",
        "sampler": sampler,
        "params": params,
        "total_seeds": len(specs),
        "accepted": len(acc),
        "accept_rate": (len(acc) / len(specs)) if specs else 0.0,
        "attempts_mean": (float(np.mean([s["attempts"] for s in acc])) if acc else None),
        "reject_reasons": reasons,
        "corner_degenerate_rate": (corner_points / total_pts) if total_pts else 0.0,
        "rot_sym_err_mean": (float(np.mean([s["rot_sym_err"] for s in acc])) if acc else None),
        "min_pair_stats": {
            "min": float(min(s["min_pair"] for s in acc)) if acc else None,
            "median": float(np.median([s["min_pair"] for s in acc])) if acc else None,
            "max": float(max(s["min_pair"] for s in acc)) if acc else None,
        },
        "accepted_seeds": [s["master_seed"] for s in acc],
    }
    write_summary_json(sd / "summary.json", summary)

    rows = []
    for s in sorted(specs, key=lambda x: x["master_seed"]):
        rows.append({
            "seed": s["master_seed"],
            "accepted": s["accepted"],
            "attempts": s["attempts"],
            "reject_reason": s["reject_reason"],
            "min_pair": round(s["min_pair"], 2),
            "center_ratio": round(s["constraints"]["center_ratio"]["value"], 4),
            "territory_ratio": round(s["constraints"]["territory_ratio"]["value"], 4),
            "corner_flag": any(s["corner_flags"]),
            "rot_sym_err": round(s["rot_sym_err"], 4),
        })
    write_summary_csv(sd / "summary.csv", rows)

    plots_g1.plot_contacts(sd, specs)
    plots_g1.plot_hist(sd, acc)

    write_text(sd / "README.md", _readme(summary, params))


def _readme(summary, params):
    lines = [
        "# G1 汇总（出生点实验）",
        "",
        "## 复跑",
        "```",
        "python run.py --gate G1 --seeds 1-64            # 正式产物（factor 0.50）",
        "python run.py --gate G1 --seeds 1-64 --min-pair-factor 0.55 --out runs_cmp/  # 对照",
        "```",
        "",
        f"- Seed 数：{summary['total_seeds']}，接受 {summary['accepted']}（接受率 {summary['accept_rate']:.1%}）",
        f"- 平均尝试次数：{summary['attempts_mean']}",
        f"- 四角退化率：{summary['corner_degenerate_rate']:.1%}（阈值 <15%）",
        f"- rot_sym_err 均值：{summary['rot_sym_err_mean']}",
        f"- minPair min/中位/max：{summary['min_pair_stats']}",
        f"- 拒绝原因计数：{summary['reject_reasons']}",
        "",
        "## 每张图怎么看",
        "- `contact_accepted.png`：通过 Seed 拼图（4×4），每格标 Seed 与 minPair。",
        "- `contact_rejected.png`：被拒 Seed 最后一次尝试，红色标题=第一条不满足的约束。",
        "- `hist.png`：通过 Seed 的 minPair / 到中心距离 / 相邻夹角 / 领地格数比 直方图。",
        "- 单 Seed：`runs/<seed>/G1/starts.png`（红线=最小两两距离，圆=10m 基地盘）、",
        "  `starts_table.png`（距离矩阵+约束表）、`territory.png`（四色领地+白=争夺带）。",
        "",
        "## 异常数字判断",
        "- 接受率 <30% 或 >95%：先查采样器/约束实现（预期 ~75%）。",
        "- 四角退化率 ≥15%：出生点过于贴角，考虑调 factor。",
        "- 拒绝原因不是 min_pair 占绝对多数：采样器可能写错。",
        f"- 当前 min_pair_factor：{params['min_pair_factor']}（96×96 → {params['min_pair_factor'] * 96:.0f} m）。",
    ]
    return "\n".join(lines)
