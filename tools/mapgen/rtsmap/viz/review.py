"""review/<gate>/ —— 唯一给用户看的地方（修订1 §1）。

固定内容：
- contact.png：本闸门所有 Seed 的缩略拼图（每格 ≥ 640 px）
- summary.md：每 Seed 一行，列出本闸门全部验收指标的数值与 ✓/✗
- 每 Seed 一张 seed_<N>_overview.png：把该闸门所有信息合成在一张图上

本模块一律从 runs/<seed>/<gate>/ 的权威数据（mapgrid.npz / mapspec.json / lanes.json）
读取后重画，绝不回读 PNG；因此既能在 run_gate 中实时生成，也能对既有产物补做（如 G1）。
"""
from pathlib import Path

from ..grid import MapGrid, read_json
from . import plots_g1, plots_g2, plots_g3
from .canvas import contact_sheet


def review_dir(review_root, gate: str) -> Path:
    d = Path(review_root) / gate
    d.mkdir(parents=True, exist_ok=True)
    return d


def _list_seeds(runs_root, gate):
    root = Path(runs_root)
    out = []
    if not root.exists():
        return out
    for child in sorted(root.iterdir(), key=lambda p: (len(p.name), p.name)):
        if child.is_dir() and child.name.isdigit() and (child / gate / "mapspec.json").exists():
            out.append(int(child.name))
    return out


def _check(ok):
    return "✓" if ok else "✗"


# ---------------- G2 ----------------

def _load_g2_data(runs_root, seed):
    rd = Path(runs_root) / str(seed) / "G2"
    ms = read_json(rd / "mapspec.json")
    grid = MapGrid.load(rd / "mapgrid.npz")
    lanes_json = read_json(rd / "lanes.json")
    lanes = [{"name": n, "kind": l["kind"], "polyline": l["polyline"]}
             for n, l in lanes_json.items()]
    return {
        "seed": seed,
        "blocking": grid.get("blocking"),
        "terrain": grid.get("terrain"),
        "height": grid.get("height") if grid.has("height") else None,
        "bridges": ms.get("bridges", []),
        "water_marks": plots_g2._water_marks(ms),
        "contest_nodes": ms.get("contest_nodes", []),
        "plateaus": ms.get("plateaus", []),
        "ramp_arrows": [(rc, rd) for pl in ms.get("plateaus", [])
                        for rc, rd in zip(pl["ramp_centers"], pl["ramp_dirs"])],
        "starts": ms["starts"],
        "flank_anchors": ms["flank_anchors"],
        "expansion_anchors": ms["expansion_anchors"],
        "lanes": lanes,
        "metrics": {
            "algo_version": ms["algo_version"], "solid_frac": ms["solid_frac"],
            "n_components": ms["n_components"], "max_block_frac": ms["max_block_frac"],
            "neighbor_wall_min": ms["neighbor_wall"]["min"],
            "flank_ratio": ms["path_fairness"]["flank_ratio"], "all_pass": ms["all_pass"],
        },
        "mapspec": ms,
    }


def build_g2_review(runs_root, review_root, seeds):
    rd = review_dir(review_root, "G2")
    datas = [_load_g2_data(runs_root, s) for s in seeds]
    # 每 Seed overview
    thumbs = []
    for data in datas:
        img = plots_g2.render_overview({**data, 'show_routes': False})
        img.save(rd / f"seed_{data['seed']}_overview.png")
        plots_g2.render_overview({**data, 'show_routes': True}).save(rd / f"seed_{data['seed']}_strategy.png")
        plots_g2.render_minimap_preview(
            data["blocking"], data["terrain"], data.get("height"),
            data.get("bridges") or [],
        ).save(rd / f"seed_{data['seed']}_minimap.png")
        thumbs.append((img.resize((640, 640), 1), _g2_thumb_label(data)))
    # contact
    if thumbs:
        cols = min(3, len(thumbs))
        contact_sheet(thumbs, cols=cols, cell=640).save(rd / "contact.png")
    # summary.md
    (rd / "summary.md").write_text(_g2_summary_md(datas), encoding="utf-8", newline="\n")
    return rd


def _g2_thumb_label(data):
    m = data["metrics"]
    return (f"Seed {data['seed']} | solid {m['solid_frac'] * 100:.0f}% | "
            f"blk {m['n_components']} | {'PASS' if m['all_pass'] else 'FAIL'}")


def _g2_summary_md(datas):
    versions = ', '.join(sorted({data['mapspec']['algo_version'] for data in datas}))
    natural = any('landform_frame' in data['mapspec'] for data in datas)
    lines = [
        f"# G2 v{versions} 战略地貌候选 · 256m",
        "",
        "本轮重点：可选完整主河（包含桥下水体）、独立湖泊、出生台地、路线/中部高地、实际寻路。",
        "",
        ("轮廓更新：不等长崖段、浅凹口和延伸地块；同区域台地与岩体采用相关走向；坡口优先靠凹口并预留展开空间；岩块沿崖脚与河岸成组安排。地面0.6m、台地3.6m，保留3m高差。" if natural else "沿用本版本的原始地貌轮廓。"),
        "",
        "几何验收：开放分量严格为1；出生20m净空；有河时主河贯通且具备至少2个有效跨水点；湖泊完整分离；台地至少2个坡道；",
        "出生台地包含出生点；中立台地关联实际路线；每家两组对外主路/备选路线；扩张路程比≤1.3；",
        "邻接争夺路程比≤1.3；最近中立高地入口路程比≤1.7；邻接玩家路程和比≤1.6；障碍12–22%。",
        "",
        "PASS仅代表这些几何检查通过，尚未验证单位射程、视野、高地伤害加成或实战胜率。",
        "",
        "| Seed | 障碍 | 水系/桥 | 台地（出生/路线/中部） | 扩张比 | 中立高地比 | 邻接路程比 | 候选轮次 | 几何结论 |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for data in datas:
        ms = data['mapspec']
        metrics = ms['strategy_metrics']
        counts = [sum(p['kind'] == kind for p in ms['plateaus']) for kind in ('home', 'route', 'central')]
        lines.append(
            f"| {data['seed']} | {ms['solid_frac']*100:.1f}% | {metrics['water_components']} / {metrics['crossings']} "
            f"| {' / '.join(map(str, counts))} | {metrics['expansion_ratio']:.3f} | {ms['plateau_fair_ratio']:.3f} "
            f"| {ms['path_fairness']['flank_ratio']:.3f} | {ms['generation']['chosen_attempt']} "
            f"| {'PASS' if ms['all_pass'] else 'FAIL'} |")
    for data in datas:
        ms = data['mapspec']
        lines += ['', f"## Seed {data['seed']}", '',
                  f"[地貌总览](seed_{data['seed']}_overview.png) · [路线叠加](seed_{data['seed']}_strategy.png)", '']
        for p in ms['plateaus']:
            purpose = f"P{p['owner']} 出生保护" if p['kind'] == 'home' else f"{p['kind']}，关联 {', '.join(p['controlled_routes'])}"
            lines.append(f"- 台地 ({p['center'][0]:.1f}, {p['center'][1]:.1f})：{purpose}；{len(p['ramp_centers'])} 个坡道。")
        lines += ['', '生成记录：']
        for attempt in ms['generation']['attempts']:
            reason = attempt.get('rejected') or ', '.join(attempt.get('failed_checks', [])) or '全部通过'
            lines.append(f"- 第 {attempt['attempt']} 版：{reason}。")
    lines += ['', '主河可选零或一条，湖泊可独立选择零至两个。中部空间不足时允许没有中立中央台地；已有中心出生台地也会占据中部。',
              '数据兼容字段保留，但本轮没有运行 G3/G4，没有将候选自动放行。', '']
    return "\n".join(lines)


# ---------------- G1（补做） ----------------

def build_g1_review(runs_root, review_root, seeds=None):
    rd = review_dir(review_root, "G1")
    if seeds is None:
        seeds = _list_seeds(runs_root, "G1")
    specs = [read_json(Path(runs_root) / str(s) / "G1" / "mapspec.json") for s in seeds]
    acc = [s for s in specs if s["accepted"]]
    # contact.png = 现有 contact_accepted（≤16 通过 Seed），每格 ≥640px
    if acc:
        items = [(plots_g1.render_mini(s, size=640),
                  f"Seed {s['master_seed']} | minPair {s['min_pair']:.1f}") for s in acc[:16]]
        contact_sheet(items, cols=4, cell=640).save(rd / "contact.png")
    (rd / "summary.md").write_text(_g1_summary_md(specs, acc), encoding="utf-8", newline="\n")
    return rd


def _g1_summary_md(specs, acc):
    n = len(specs)
    rate = (len(acc) / n) if n else 0.0
    lines = [
        "# G1 出生点 · 验收汇总",
        "",
        "验收线（修订1 §1：去掉四角退化率，只保留接受率与目视认可）：factor 0.50 下接受率 30–95%。",
        "",
        f"- Seed 数：{n}，接受 {len(acc)}，**接受率 {rate * 100:.1f}%** "
        f"{_check(0.30 <= rate <= 0.95)}",
        f"- 本轮带入 G2 的 Seed（用户 2026-09-03 指定）：8、24、45",
        "",
        "| Seed | accepted | attempts | minPair | centerRatio | territoryRatio | nnRatio |",
        "|---|---|---|---|---|---|---|",
    ]
    for s in sorted(specs, key=lambda x: x["master_seed"]):
        c = s["constraints"]
        lines.append(
            f"| {s['master_seed']} | {'✓' if s['accepted'] else '✗ ' + str(s['reject_reason'])} "
            f"| {s['attempts']} | {s['min_pair']:.1f} "
            f"| {c['center_ratio']['value']:.3f} | {c['territory_ratio']['value']:.3f} "
            f"| {c['nn_ratio']['value']:.3f} |"
        )
    lines.append("")
    return "\n".join(lines)


# ---------------- G3 ----------------

def _load_g3_data(runs_root, seed):
    rd = Path(runs_root) / str(seed) / "G3"
    g2_rd = Path(runs_root) / str(seed) / "G2"
    ms = read_json(rd / "mapspec.json")
    grid = MapGrid.load(rd / "mapgrid.npz")
    g2_spec = read_json(g2_rd / "mapspec.json")
    objects = read_json(rd / "objects.json")
    resources = read_json(rd / "resources.json")
    return {
        "seed": seed,
        "grid": grid,
        "instances": objects["instances"],
        "resources": resources["resources"],
        "starts": ms["starts"],
        "flank_anchors": g2_spec["flank_anchors"],
        "expansion_anchors": g2_spec["expansion_anchors"],
        "mapspec": ms,
    }


def build_g3_review(runs_root, review_root, seeds):
    rd = review_dir(review_root, "G3")
    datas = [_load_g3_data(runs_root, s) for s in seeds]
    thumbs = []
    for data in datas:
        img = plots_g3.render_g3_overview(data)
        img.save(rd / f"seed_{data['seed']}_overview.png")
        thumbs.append((img.resize((640, 640), 1), _g3_thumb_label(data)))
    if thumbs:
        cols = min(3, len(thumbs))
        contact_sheet(thumbs, cols=cols, cell=640).save(rd / "contact.png")
    (rd / "summary.md").write_text(_g3_summary_md(datas), encoding="utf-8", newline="\n")
    return rd


def _g3_thumb_label(data):
    ms = data["mapspec"]
    fa = ms["resource_fairness"]
    return (f"Seed {data['seed']} | obj {ms['instance_count']} | "
            f"A{fa['a_counts'][0]}/B{fa['b_counts'][0]} | "
            f"{'PASS' if ms['all_pass'] else 'FAIL'}")


def _g3_summary_md(datas):
    lines = [
        "# G3 资源 + 素材实例化 · 验收汇总（algo 2.2.0、256m、无中央战场）",
        "",
        "验收线：每家配额相等（A=5、B=3，B 在 flank 补齐——中心资源因无中央战场取消，允许偏差）· "
        "公平三项（near 和 / expansion A / shared A 和）比 ≤1.3 · G2 复检全过（分量=1、关键点连通、"
        "宽度不低于基线、路径比 ≤1.6、密度 0.12–0.30）· 实例 ≤2000 · 簇覆盖 ≥90%。",
        "",
        "| Seed | 配额 A/B | near比 | exp比 | shared比 | 复检分量 | 关键点 | 宽≥基线 | 复检路径比 | "
        "实例(遮挡/装饰) | 覆盖% | 结论 |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for data in datas:
        ms = data["mapspec"]
        fa = ms["resource_fairness"]
        rep = ms["recheck"]
        n_blk = sum(1 for i in data["instances"] if i["blocking"])
        n_dec = sum(1 for i in data["instances"] if not i["blocking"])
        cover = ms.get("cluster_cover_frac", 0.0)
        lines.append(
            f"| {data['seed']} "
            f"| {fa['a_counts'][0]}/{fa['b_counts'][0]} {_check(fa['quota_equal'])} "
            f"| {fa['near_ratio']:.3f} {_check(fa['near_ratio'] <= 1.3)} "
            f"| {fa['expansion_ratio']:.3f} {_check(fa['expansion_ratio'] <= 1.3)} "
            f"| {fa['shared_ratio']:.3f} {_check(fa['shared_ratio'] <= 1.3)} "
            f"| {rep['components']} {_check(rep['components_pass'])} "
            f"| {_check(rep['keypoints_pass'])} "
            f"| {_check(rep['widths_pass'])} "
            f"| {(rep['path_fairness']['flank_ratio'] or 0):.3f} "
            f"{_check(rep['path_fairness_pass'])} "
            f"| {ms['instance_count']} ({n_blk}/{n_dec}) "
            f"| {cover * 100:.0f} {_check(cover >= 0.9)} "
            f"| {'✓ PASS' if ms['all_pass'] else '✗ FAIL'} |"
        )
    lines += ["", "资源失败/被删实例：", ""]
    for data in datas:
        ms = data["mapspec"]
        lines.append(f"- Seed {data['seed']}: res_failures={ms['resource_failures'] or '无'} "
                     f"removed={len(ms['removed_instances'])} "
                     f"water_cells={ms.get('water_cells', '-')}")
    lines.append("")
    return "\n".join(lines)
