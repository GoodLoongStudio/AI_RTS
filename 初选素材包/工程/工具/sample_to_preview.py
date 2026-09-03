# -*- coding: utf-8 -*-
"""Sample FBX models per package, copy them + textures into the Godot preview
project, and emit manifest.json (res:// paths) for the capture script."""
from __future__ import annotations

import json
import random
import shutil
from collections import defaultdict
from pathlib import Path

ROOT = Path(r"G:\AIRTS\临时文件夹\_筛选解包")
PREVIEW = ROOT / "_preview"
ASSETS = PREVIEW / "assets"

# package dir -> (short name, pack root folder, sample cap)
PACKAGES = {
    "4006_科幻世界": ("4006_科幻世界", "PolygonSciFiWorlds", 80),
    "4041_西部土著": ("4041_西部土著", "PolygonWesternFrontier", 60),
    "4050_微缩城市": ("4050_微缩城市", "PolygonMini_City", 60),
    "4058_简单战争": ("4058_简单战争", "SimpleMilitary", 90),
    "463_末日废墟": ("463_末日废墟", "PolygonApocalypse", 90),
}

TEX_EXTS = {".png", ".tga", ".jpg"}


def prefix_of(stem: str) -> str:
    parts = stem.split("_")
    return "_".join(parts[:2]) if len(parts) >= 2 else stem


def main() -> None:
    rng = random.Random(20260829)
    # no rmtree here: deterministic sampling overwrites in place, and the
    # sandbox may block recursive deletes (recycle-bin unavailable)
    ASSETS.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, list[str]] = {}

    for pkg, (short, pack_root, cap) in PACKAGES.items():
        src_root = ROOT / pkg / pack_root
        dst_root = ASSETS / short / pack_root
        models_src = src_root / "Models"

        fbxs = sorted(p for p in models_src.rglob("*.fbx") if "collision" not in p.stem.lower())
        groups: dict[str, list[Path]] = defaultdict(list)
        for f in fbxs:
            groups[prefix_of(f.stem)].append(f)
        # round-robin across prefix groups, shuffle inside each group
        for g in groups.values():
            rng.shuffle(g)
        pool: list[Path] = []
        keys = sorted(groups)
        i = 0
        while len(pool) < cap and any(groups[k] for k in keys):
            k = keys[i % len(keys)]
            if groups[k]:
                pool.append(groups[k].pop())
            i += 1

        copied: list[Path] = []
        touched_dirs: set[Path] = set()
        for f in pool:
            rel = f.relative_to(models_src)
            dst = dst_root / "Models" / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
            copied.append(dst)
            touched_dirs.add(dst.parent)

        # copy all textures: original Textures/ tree + flat next to model dirs
        tex_src = src_root / "Textures"
        tex_files: list[Path] = []
        if tex_src.is_dir():
            tex_files = [p for p in tex_src.rglob("*") if p.suffix.lower() in TEX_EXTS]
            for t in tex_files:
                dst = dst_root / "Textures" / t.relative_to(tex_src)
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(t, dst)
        for d in touched_dirs:
            for t in tex_files:
                shutil.copy2(t, d / t.name)

        manifest[short] = [
            "res://" + str(p.relative_to(PREVIEW)).replace("\\", "/") for p in copied
        ]
        print(f"[{short}] sampled {len(copied)} fbx "
              f"(from {len(fbxs)}), textures {len(tex_files)} x{len(touched_dirs)} flat copies")

    (PREVIEW / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    print("manifest ->", PREVIEW / "manifest.json")


if __name__ == "__main__":
    main()
