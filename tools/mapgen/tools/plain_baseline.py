"""统计 AI_RTS PlainAndSimple.tscn 的资源数量与到出生点距离，作为 G3 密度基线。

只读解析 .tscn 文本（Transform3D 平移 = 矩阵第 13-15 个数）。
输出：runs/assets/plain_baseline.json
"""
import json
import math
import re
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(_ROOT))
from rtsmap.contract import G4_AIRTS  # noqa: E402

TSCN = Path(G4_AIRTS) / "source" / "match" / "maps" / "PlainAndSimple.tscn"
OUT = _ROOT / "workbench_output" / "assets" / "plain_baseline.json"

# PlainAndSimple 4 出生点（来自 tscn Marker3D 平移）
SPAWNS = [(10, 7), (40, 7), (40, 43), (10, 43)]


def main():
    text = TSCN.read_text(encoding="utf-8")
    rows = []
    for m in re.finditer(r'\[node name="(Resource[AB]\d*)"[^\]]*instance=ExtResource\("3_3gxbc"\)\]\ntransform = Transform3D\([^)]*\)', text):
        pass
    # transform 行解析：逐节点块
    node_re = re.compile(r'\[node name="(Resource\w+)"[^\]]*\]\s*\ntransform = Transform3D\(([^)]*)\)')
    for m in node_re.finditer(text):
        name = m.group(1)
        nums = [float(v) for v in m.group(2).split(",")]
        x, z = nums[9], nums[11]  # Transform3D = 3x3 基(0..8) + origin(9,10,11)
        kind = "A" if name.startswith("ResourceA") else "B"
        dmin = min(math.hypot(x - sx, z - sz) for sx, sz in SPAWNS)
        rows.append({"name": name, "kind": kind, "x": x, "z": z,
                     "dist_to_nearest_spawn": round(dmin, 2)})
    rows.sort(key=lambda r: r["dist_to_nearest_spawn"])
    dists = [r["dist_to_nearest_spawn"] for r in rows]
    out = {
        "source": str(TSCN),
        "note": "所有资源节点（含 ResourceB*）实际都 instance=ResourceA.tscn；按节点名分类统计",
        "map_size": [50, 50],
        "count_A": sum(1 for r in rows if r["kind"] == "A"),
        "count_B": sum(1 for r in rows if r["kind"] == "B"),
        "per_player_near": 3,  # 观察值：每家 3 个 A（500 量）贴家
        "distances_sorted": dists,
        "dist_min": dists[0] if dists else None,
        "dist_median": dists[len(dists) // 2] if dists else None,
        "dist_p10": dists[int(len(dists) * 0.1)] if dists else None,
        "dist_p90": dists[int(len(dists) * 0.9)] if dists else None,
        "rows": rows,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: v for k, v in out.items() if k != "rows"}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
