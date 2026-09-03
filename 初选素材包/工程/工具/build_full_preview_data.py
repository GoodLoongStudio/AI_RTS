# -*- coding: utf-8 -*-
"""Full-coverage preview data builder (v2).

1. Copy ALL non-collision FBX per package into the Godot preview project.
2. manifest_all.json: {short: {category: [fbx res paths]}}.
3. scenes.json: reconstruct demo scenes from PrefabInstance blocks.
   Hierarchy per instance: container (scene transform) + child meshes with
   LOCAL transforms resolved from (possibly nested) prefab content.
   Stripped scenes (0 instances) are reported and skipped.
"""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

ROOT = Path(r"G:\AIRTS\临时文件夹\_筛选解包")
PREVIEW = ROOT / "工程" / "预览渲染工程"
ASSETS = PREVIEW / "assets"

PACKAGES = {
    "4006_科幻世界": "PolygonSciFiWorlds",
    "4041_西部土著": "PolygonWesternFrontier",
    "4050_微缩城市": "PolygonMini_City",
    "4019_战争地图": "PolygonWarMap",
    "463_末日废墟": "PolygonApocalypse",
}

GUID_RE = re.compile(r"guid:\s*([0-9a-f]{32})")
MESH_RE = re.compile(r"m_Mesh:\s*\{[^}]*guid:\s*([0-9a-f]{32})")
PROP_RE = re.compile(
    r"propertyPath:\s*(m_LocalPosition(?:\.[xyz])?|m_LocalRotation|"
    r"m_LocalScale)\s*\n\s*value:\s*([^\n]+)")

CAT_RULES = [
    ("sm_bld", "建筑"), ("sm_env", "环境"), ("sm_prop", "道具"),
    ("sm_veh", "载具"), ("sm_chr", "角色"), ("sm_dec", "装饰"),
    ("sm_fx", "特效"), ("sm_til", "地块"), ("sm_wea", "武器"),
    ("sm_bar", "路障"),
]


def is_collision(p: Path) -> bool:
    posix = p.as_posix().lower()
    stem = p.stem.lower()
    return ("/collision/" in posix or stem.endswith("_collision")
            or stem.startswith("col_"))


def category(stem: str) -> str:
    low = stem.lower()
    for k, label in CAT_RULES:
        if low.startswith(k):
            return label
    if low.startswith("br_"):
        return "角色"
    if "zomb" in low:
        return "僵尸"
    if "corpse" in low:
        return "尸体"
    if low.startswith("fx"):
        return "特效"
    head = stem.split("_")[0]
    return {"Characters": "角色"}.get(head, head)


def parse_vec(v: str) -> list[float] | None:
    v = v.strip()
    if v.startswith("{"):
        m = re.findall(r"([xyzw]):\s*(-?[\d.eE+]+)", v)
        return [float(x[1]) for x in m] if m else None
    return None


def parse_instances(text: str, guid_prefab: dict[str, Path]) -> list[dict]:
    """PrefabInstance blocks inside one YAML document set.
    Handles both full-vector values ({x: .., y: .., z: ..}) and split-axis
    (propertyPath: m_LocalPosition.x / value: -91.2) formats."""
    out: list[dict] = []
    for doc in text.split("--- !u!"):
        m = re.search(r"m_SourcePrefab:\s*\{[^}]*guid:\s*([0-9a-f]{32})", doc)
        if not m or m.group(1) not in guid_prefab:
            continue
        pos = [None, None, None]
        rot: dict[str, float | None] = {"x": None, "y": None, "z": None, "w": None}
        scl = [None, None, None]
        vec_pos = vec_rot = vec_scl = None
        for prop, val in PROP_RE.findall(doc):
            val = val.strip()
            if prop in ("m_LocalPosition", "m_LocalRotation", "m_LocalScale"):
                vec = parse_vec(val)
                if vec is None:
                    continue
                if prop == "m_LocalPosition" and vec_pos is None and len(vec) >= 3:
                    vec_pos = vec[:3]
                elif prop == "m_LocalRotation" and vec_rot is None and len(vec) == 4:
                    vec_rot = vec
                elif prop == "m_LocalScale" and vec_scl is None and len(vec) >= 3:
                    vec_scl = vec[:3]
                continue
            # split-axis form
            base, _, axis = prop.rpartition(".")
            try:
                num = float(val)
            except ValueError:
                continue
            idx = {"x": 0, "y": 1, "z": 2}.get(axis)
            if base == "m_LocalPosition" and idx is not None:
                pos[idx] = num
            elif base == "m_LocalScale" and idx is not None:
                scl[idx] = num
            elif base == "m_LocalRotation" and axis in rot:
                rot[axis] = num
        final_pos = vec_pos if vec_pos is not None else [
            p if p is not None else 0.0 for p in pos]
        if vec_rot is not None:
            final_rot = vec_rot
        else:
            final_rot = [rot["x"] or 0.0, rot["y"] or 0.0,
                         rot["z"] or 0.0,
                         rot["w"] if rot["w"] is not None else 1.0]
        final_scl = vec_scl if vec_scl is not None else [
            s if s is not None else 1.0 for s in scl]
        out.append({"prefab": guid_prefab[m.group(1)],
                    "pos": final_pos, "rot": final_rot, "scl": final_scl})
    return out


def resolve_prefab(pf: Path, guid_prefab: dict[str, Path],
                   guid_fbx: dict[str, Path], models_src: Path,
                   to_res, depth: int = 0, seen: frozenset = frozenset()
                   ) -> list[dict]:
    """Children (mesh entries with LOCAL transforms) of one prefab."""
    if depth > 3 or pf in seen:
        return []
    text = pf.read_text(errors="ignore")
    out: list[dict] = []
    direct = [guid_fbx[g] for g in MESH_RE.findall(text) if g in guid_fbx]
    for mesh in direct:
        rel = mesh.relative_to(models_src).as_posix()
        out.append({"res": to_res(rel), "pos": [0.0, 0.0, 0.0],
                    "rot": [0.0, 0.0, 0.0, 1.0], "scl": [1.0, 1.0, 1.0]})
    for inst in parse_instances(text, guid_prefab):
        for child in resolve_prefab(inst["prefab"], guid_prefab, guid_fbx,
                                    models_src, to_res, depth + 1,
                                    seen | {pf}):
            out.append(child)  # child transform is local to the source
            # prefab root; nesting offsets within composed prefabs are small
    return out


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    manifest_all: dict[str, dict[str, list[str]]] = {}
    scenes_out: dict[str, dict[str, list[dict]]] = {}

    for short, pack_root in PACKAGES.items():
        full = ROOT / "素材包" / short / pack_root
        dst_root = ASSETS / short / pack_root
        models_src = full / "Models"

        # 1. copy all non-collision fbx (idempotent)
        fbxs = sorted(p for p in models_src.rglob("*.fbx") if not is_collision(p))
        rel_list: list[str] = []
        for f in fbxs:
            rel = f.relative_to(models_src).as_posix()
            dst = dst_root / "Models" / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists() or dst.stat().st_size != f.stat().st_size:
                shutil.copy2(f, dst)
            rel_list.append(rel)

        # textures: full Textures tree + flat copies next to model dirs
        tex_src = full / "Textures"
        tex_files = ([p for p in tex_src.rglob("*")
                      if p.suffix.lower() in (".png", ".tga", ".jpg")]
                     if tex_src.is_dir() else [])
        model_dirs = {f.parent for f in fbxs}
        for t in tex_files:
            dst = dst_root / "Textures" / t.relative_to(tex_src)
            dst.parent.mkdir(parents=True, exist_ok=True)
            if not dst.exists():
                shutil.copy2(t, dst)
            for d in model_dirs:
                flat = dst_root / "Models" / d.relative_to(models_src) / t.name
                flat.parent.mkdir(parents=True, exist_ok=True)
                if not flat.exists():
                    shutil.copy2(t, flat)

        # 2. categories
        cats: dict[str, list[str]] = {}
        for rel in rel_list:
            cats.setdefault(category(Path(rel).stem), []).append(
                f"res://assets/{short}/{pack_root}/Models/{rel}")
        manifest_all[short] = {k: cats[k] for k in sorted(cats)}

        # 3. guid maps
        guid_fbx: dict[str, Path] = {}
        for p in models_src.rglob("*.fbx"):
            meta = p.with_name(p.name + ".meta")
            if meta.exists():
                m = GUID_RE.search(meta.read_text(errors="ignore"))
                if m:
                    guid_fbx[m.group(1)] = p
        guid_prefab: dict[str, Path] = {}
        for p in full.rglob("*.prefab"):
            meta = p.with_name(p.name + ".meta")
            if meta.exists():
                m = GUID_RE.search(meta.read_text(errors="ignore"))
                if m:
                    guid_prefab[m.group(1)] = p

        def to_res(rel: str) -> str:
            return f"res://assets/{short}/{pack_root}/Models/{rel}"

        # 4. scenes anywhere under the pack
        scenes: dict[str, list[dict]] = {}
        skipped = []
        for scene in sorted(full.rglob("*.unity")):
            insts = parse_instances(scene.read_text(errors="ignore"), guid_prefab)
            if not insts:
                skipped.append(scene.stem)
                continue
            entries: list[dict] = []
            for it in insts:
                children = resolve_prefab(it["prefab"], guid_prefab, guid_fbx,
                                          models_src, to_res)
                if children:
                    entries.append({"pos": it["pos"], "rot": it["rot"],
                                    "scl": it["scl"], "meshes": children})
            if entries:
                scenes[scene.stem] = entries
            print(f"[{short}] scene {scene.stem}: {len(entries)} placed / "
                  f"{len(insts)} instances")
        if skipped:
            print(f"[{short}] stripped/empty scenes skipped: {skipped}")
        scenes_out[short] = scenes

        print(f"[{short}] fbx {len(rel_list)} in {len(cats)} categories")

    (PREVIEW / "manifest_all.json").write_text(
        json.dumps(manifest_all, ensure_ascii=False, indent=1), encoding="utf-8")
    (PREVIEW / "scenes.json").write_text(
        json.dumps(scenes_out, ensure_ascii=False, indent=1), encoding="utf-8")
    total = sum(len(v) for cats in manifest_all.values() for v in cats.values())
    n_scenes = sum(len(s) for s in scenes_out.values())
    print(f"\nDONE: {total} fbx, {n_scenes} reconstructable scenes")


if __name__ == "__main__":
    main()
