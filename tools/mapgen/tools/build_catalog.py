"""构建 rtsmap/data/assets_catalog.json（一次生成入库，后续闸门复用）。

输入：
  runs/assets/aabb_raw.json   （tools/godot/dump_aabb.gd 导出，含 size/min_y）
  texture_map.json            （预览渲染工程，fbx → 图集）
输出条目：fbx 相对路径、AABB 尺寸 (x,y,z) 米、min_y、图集路径、类别前缀、
blocking 建议（高 ≥1.2 且 XZ 任一边 ≥1）、允许的 terrain 类型。
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from rtsmap.contract import SRC_PREVIEW_ROOT  # noqa: E402

AABB = ROOT / "workbench_output" / "assets" / "aabb_raw.json"
TEXMAP = Path(SRC_PREVIEW_ROOT) / "texture_map.json"
OUT = ROOT / "rtsmap" / "data" / "assets_catalog.json"

PREFIX = "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/"

# terrain 类型 → 允许的资产前缀（G3 映射的结构类）。
# 注：方案文档所写 SM_Env_Rock_*/Cliff_* 前缀在 4006 包实际不存在，
# 4006 的岩石类实际为 SM_Env_Floating_Rocks_* / SM_Generic_Small_Rocks_*（2026-09-03 核对）。
TERRAIN_ALLOW = {
    1: ["SM_Env_Floating_Rocks_", "SM_Generic_Small_Rocks_", "SM_Env_Rock_",
        "SM_Env_Rock_Large_", "SM_Env_Rock_Spike_", "SM_Env_Cliff_"],
    2: ["SM_Bld_Scav_Wreckage_", "SM_Bld_Scav_Refinery_", "SM_Bld_Scav_Garage_",
        "SM_Bld_Crate_Building_"],
    3: ["SM_Bld_Corp_Wall_", "SM_Bld_Platform_Barrier_"],
    4: ["SM_Prop_Scav_Scrap_", "SM_Prop_Crate_", "SM_Env_Ground_Junk_"],
    5: ["SM_Env_Crater_Edge_"],
}
DECOR_PREFIXES = ["SM_Env_Ground_Greeble_", "SM_Decal_", "SM_Env_Plant_"]


def category(name: str) -> str:
    base = name[:-4] if name.endswith(".fbx") else name
    for p in TERRAIN_ALLOW[1] + TERRAIN_ALLOW[2] + TERRAIN_ALLOW[3] + TERRAIN_ALLOW[4] + TERRAIN_ALLOW[5]:
        if base.startswith(p):
            return p.rstrip("_")
    for p in DECOR_PREFIXES:
        if base.startswith(p):
            return p.rstrip("_")
    if base.startswith("SM_Env_"):
        return "env"
    if base.startswith("SM_Bld_"):
        return "bld"
    if base.startswith("SM_Prop_"):
        return "prop"
    return "other"


def main():
    raw = json.loads(AABB.read_text(encoding="utf-8"))
    tex = json.loads(TEXMAP.read_text(encoding="utf-8"))
    out = []
    for res_path, info in raw.items():
        if "4006_科幻世界" not in res_path:
            continue  # 素材固定使用 4006 科幻世界包
        rel = res_path[len("res://"):] if res_path.startswith("res://") else res_path
        name = rel.split("/")[-1]
        if name.endswith("_Collision.fbx"):
            continue
        size = info["size"]
        x, y, z = size
        blocking = y >= 1.2 and (x >= 1.0 or z >= 1.0)
        atlas = tex.get(res_path, [])
        # Synty 4006 全包共享少量图集；texture_map 漏记的条目（SM_Env_Rock/Crater 等）
        # fallback 到该包环境类默认图集，避免 G4 白模
        atlas_path = atlas[0] if atlas else (PREFIX + "PolygonScifiWorlds_Texture_01_A.png")
        cat = category(name)
        terrains = [t for t, prefixes in TERRAIN_ALLOW.items()
                    if any(name.startswith(p) for p in prefixes)]
        out.append({
            "fbx": rel,
            "res_path": res_path,
            "name": name,
            "size": [round(x, 3), round(y, 3), round(z, 3)],
            "min_y": round(info.get("min_y", 0.0), 3),
            "atlas": atlas_path,
            "category": cat,
            "blocking": bool(blocking),
            "terrain_types": terrains,
        })
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1, ensure_ascii=False), encoding="utf-8")
    n_blk = sum(1 for e in out if e["blocking"])
    print(f"catalog: {len(out)} entries ({n_blk} blocking-candidates) -> {OUT}")


if __name__ == "__main__":
    sys.exit(main())
