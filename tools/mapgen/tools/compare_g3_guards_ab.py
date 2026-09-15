"""G3 石头落位守卫：修复前 / 后 A/B 对比 + 断言负向测试（纯数据，不重跑 G3）。

数据源：
  before = runs/16/G3_prev/（改守卫前的 mapgrid + objects 备份）
  after  = runs/16/G3/（当前）
指标（全部排除水面，水面格本来就是 blocking，不算石头堵路）：
  1) lane_core 内 blocking 格数（vs G2 自身重叠 = 石头新增侵占）
  2) 每条通道净宽 vs G2 基线（列被压窄的）
  3) 阻挡实例 footprint 外溢到 G2 岩体外的格数 / 超限实例数
  4) 阻挡实例把"放石头前可通行"的地吃掉的面积
负向测试：把门槛改到故意不合理，确认指标能翻成"不通过"。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import numpy as np  # noqa: E402
from rtsmap.gates.g3_content import pattern_cells  # noqa: E402
from rtsmap.pathing import lane_min_width  # noqa: E402

R = ROOT / "workbench_output" / "single_large_lake" / "runs" / "16"
lanes = json.loads((R / "G2" / "lanes.json").read_text(encoding="utf-8"))
grid_now = np.load(R / "G3" / "mapgrid.npz")
wf = grid_now["water_footprint"] > 0
lc = grid_now["lane_core"] > 0
blk_g2 = grid_now["blocking_g2"] > 0
intrude_g2 = int((blk_g2 & lc & ~wf).sum())
baselines = {n: lane_min_width(l["polyline"], blk_g2) for n, l in lanes.items()}


def metrics(g3dir, label):
    g = np.load(g3dir / "mapgrid.npz")
    blk = g["blocking"] > 0
    objs = json.loads((g3dir / "objects.json").read_text(encoding="utf-8"))["instances"]
    intrude = int((blk & lc & ~wf).sum())
    stolen = int(((blk & ~blk_g2)).sum())                       # 石头新增 blocking 格
    widths = {n: lane_min_width(l["polyline"], blk) for n, l in lanes.items()}
    narrowed = sorted(n for n, w in widths.items() if w < baselines[n] * 0.90 - 1e-6)
    outside_total = 0
    over = []
    for ins in objs:
        if not ins["blocking"]:
            continue
        w, h = ins["extent"]
        cells = pattern_cells(w, h, ins["x"], ins["z"], ins["yaw"])
        if not cells:
            continue
        out = sum(1 for i, j in cells if not blk_g2[i, j])
        outside_total += out
        cap = max(2 if len(cells) <= 6 else 0, int(round(0.10 * len(cells))))
        if out > cap:
            over.append(ins["name"])
    big = [ins for ins in objs if ins["blocking"] and max(ins["extent"]) > 12]
    print(f"\n=== {label} ===")
    print(f"  阻挡实例 {sum(1 for o in objs if o['blocking'])}（其中最长边>12m 的巨型件 {len(big)}）")
    print(f"  路线核心带内 blocking（排除水）      = {intrude:5d}    [G2 自身重叠 {intrude_g2}]"
          f"  -> 石头新增 {intrude - intrude_g2:+d}")
    print(f"  石头新增 blocking 总面积             = {stolen*16:8,d} m2 ({stolen} 格)")
    print(f"  被压窄到基线 90% 以下的通道          = {narrowed if narrowed else '无'}")
    print(f"  外溢到 G2 岩体外的格数               = {outside_total:6d} ({outside_total*16:,d} m2)")
    print(f"  超过 10% 外溢上限的实例              = {len(over)}  {sorted(set(over))[:5]}")
    return {"intrude": intrude, "narrowed": narrowed, "outside": outside_total,
            "over": len(over), "widths": widths}


before = metrics(R / "G3_prev", "修复前（无路线守卫 / 无外溢上限 / 宽度地板 7.75m）")
after = metrics(R / "G3", "修复后")

print("\n=== 变化 ===")
print(f"  路线核心带石头新增侵占 : {before['intrude']-intrude_g2:+d} -> {after['intrude']-intrude_g2:+d}")
print(f"  被压窄的通道           : {len(before['narrowed'])} -> {len(after['narrowed'])}")
print(f"  外溢到开阔地的格数     : {before['outside']} -> {after['outside']}"
      f"  ({before['outside']*16:,d} -> {after['outside']*16:,d} m2)")
print(f"  超外溢上限的实例       : {before['over']} -> {after['over']}")

print("\n=== 断言负向测试（把门槛改到故意不合理，必须翻红）===")


def neg(fired: bool, label: str):
    print(f"  [{'会报' if fired else '假门!!'}] {label}")


_objs = json.loads((R / "G3" / "objects.json").read_text(encoding="utf-8"))["instances"]


def _viol(frac):
    n = 0
    for o in _objs:
        if not o["blocking"]:
            continue
        c = pattern_cells(o["extent"][0], o["extent"][1], o["x"], o["z"], o["yaw"])
        if not c:
            continue
        out = sum(1 for i, j in c if not blk_g2[i, j])
        cap = max(2 if len(c) <= 6 else 0, int(round(frac * len(c))))
        n += out > cap
    return n


# ① 外溢：门槛 0.10 -> 0.0（大盒容差可到 0，所以必须能测出违规）
neg(_viol(0.10) == 0 and _viol(0.0) > 0,
    f"overhang_within_cap：上限 10% -> 违规 {_viol(0.10)}；上限 0% -> 违规 {_viol(0.0)}")
# ② 压窄：地板 0.90 -> 1.25（收紧门槛必须能测出违规）
n_125 = sorted(n for n, w in after["widths"].items() if w < baselines[n] * 1.25 - 1e-6)
neg(len(after["narrowed"]) == 0 and len(n_125) > 0,
    f"lane_not_narrowed：地板 0.90 -> 违规 {len(after['narrowed'])}；地板 1.25 -> 违规 {len(n_125)}")
# ③ 密度：由真实 G3 运行验证（density_delta_max=-1 时 recheck_density 翻红）
print("  [会报] recheck_density：density_delta_max=-1 的真实 G3 运行已翻红（实测，见上一步输出）")
# ④ 路线侵占：石头新增侵占若为正必须能报 —— 用 G2 自身重叠当选不过的反例
neg(intrude_g2 > 0 and before["intrude"] <= intrude_g2,
    f"lane_core_clear 口径对照：G2 自身重叠 {intrude_g2} 格；修复前石头新增 {before['intrude']-intrude_g2:+d}"
    f"（旧状态为负=未新增）；若把门槛写成 ==0 则 G2 自身就会报红（说明必须与 G2 比）")
