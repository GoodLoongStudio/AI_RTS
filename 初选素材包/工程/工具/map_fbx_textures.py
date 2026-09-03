# -*- coding: utf-8 -*-
"""Build fbx -> albedo texture mapping via Unity GUID chain.

Sources, in priority order:
  1. Prefab YAML: all guids in a prefab intersected with fbx-guid map (mesh refs)
     and mat-guid map; each mat's _MainTex guid resolves to the texture file.
  2. FBX binary: embedded texture filename references (SimpleMilitary style).
Fallback: per-pack most-common albedo textures (defaults.json).

Outputs in _preview/: texture_map.json {fbx_res: [tex_res...]} and
defaults.json {pack_short: [tex_res...]}.
"""
from __future__ import annotations

import json
import re
from collections import Counter
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
MAINTEX_RE = re.compile(r"_MainTex:\s*\n\s*m_Texture:\s*\{[^}]*guid:\s*([0-9a-f]{32})")
ALBEDO_HINTS = ("_a", "_albedo", "_basecolor", "_diffuse")
BAD_HINTS = ("emissive", "normal", "metallic", "roughness", "_ao", "mask",
             "height", "specular")


def rank(res_paths: list[str]) -> list[str]:
    uniq: list[str] = []
    for r in res_paths:
        if r not in uniq:
            uniq.append(r)

    def score(res: str) -> int:
        stem = Path(res).stem.lower()
        s = 0
        if any(stem.endswith(h) for h in ALBEDO_HINTS):
            s += 20
        if any(h in stem for h in BAD_HINTS):
            s -= 30
        s -= len(stem) // 8
        return -s

    return sorted(uniq, key=score)


def main() -> None:
    tex_map: dict[str, list[str]] = {}   # (short, models_rel) -> [tex_res]
    defaults: dict[str, list[str]] = {}
    fbx_hit_src: Counter = Counter()

    for short, pack_root in PACKAGES.items():
        full = ROOT / "素材包" / short / pack_root
        # guid -> file maps (full tree)
        guid_tex: dict[str, str] = {}
        guid_mat: dict[str, str] = {}
        guid_fbx: dict[str, Path] = {}
        for p in (full / "Textures").rglob("*"):
            if p.suffix.lower() in (".png", ".tga", ".jpg") and p.with_name(p.name + ".meta").exists():
                m = GUID_RE.search(p.with_name(p.name + ".meta").read_text(errors="ignore"))
                if m:
                    guid_tex[m.group(1)] = str(p)
        for p in full.rglob("*.mat"):
            meta = p.with_name(p.name + ".meta")
            if meta.exists():
                m = GUID_RE.search(meta.read_text(errors="ignore"))
                if m:
                    guid_mat[m.group(1)] = str(p)
        for p in (full / "Models").rglob("*.fbx"):
            meta = p.with_name(p.name + ".meta")
            if meta.exists():
                m = GUID_RE.search(meta.read_text(errors="ignore"))
                if m:
                    guid_fbx[m.group(1)] = p

        mat_tex: dict[str, list[str]] = {}
        for g, mat_path in guid_mat.items():
            text = Path(mat_path).read_text(errors="ignore")
            tex_guids = MAINTEX_RE.findall(text)
            mat_tex[g] = [guid_tex[t] for t in tex_guids if t in guid_tex]

        pack_counter: Counter = Counter()
        chained = 0
        for prefab in full.rglob("*.prefab"):
            text = prefab.read_text(errors="ignore")
            guids = GUID_RE.findall(text)
            fbx_hits = [guid_fbx[g] for g in guids if g in guid_fbx]
            mat_hits = [g for g in guids if g in guid_mat]
            if not fbx_hits or not mat_hits:
                continue
            texs: list[str] = []
            for g in mat_hits:
                texs.extend(mat_tex.get(g, []))
            if not texs:
                continue
            chained += 1
            for fbx in set(fbx_hits):
                rel = str(fbx.relative_to(full / "Models"))
                tex_map.setdefault((short, rel), []).extend(rank(texs))
            for t in set(texs):
                pack_counter[t] += 1

        # source 2: embedded refs in FBX binaries (preview copies)
        preview_tex = list((ASSETS / short).rglob("*.png")) + \
                      list((ASSETS / short).rglob("*.tga")) + \
                      list((ASSETS / short).rglob("*.jpg"))
        stems = [(p.stem, "res://" + str(p.relative_to(PREVIEW)).replace("\\", "/"))
                 for p in preview_tex]
        for fbx in (ASSETS / short).rglob("*.fbx"):
            rel = str(fbx.relative_to(ASSETS / short / pack_root / "Models"))
            if (short, rel) in tex_map:
                continue
            low = fbx.read_bytes().lower()
            hits = [res for stem, res in stems
                    if stem.lower().encode() in low or stem.encode() in fbx.read_bytes()]
            if hits:
                tex_map[(short, rel)] = rank(hits)
                fbx_hit_src["embedded"] += 1

        defaults[short] = []
        for p, _c in pack_counter.most_common(12):
            tp = Path(p)
            rel = tp.relative_to(full / "Textures")
            prev = ASSETS / short / pack_root / "Textures" / rel
            if prev.exists():
                defaults[short].append(
                    "res://" + str(prev.relative_to(PREVIEW)).replace("\\", "/"))
        if not defaults[short]:
            def fallback_score(res: str) -> int:
                stem = Path(res).stem.lower()
                s = 0
                if any(stem.endswith(h) for h in ALBEDO_HINTS):
                    s += 20
                if "texture" in stem:
                    s += 8
                if any(h in stem for h in BAD_HINTS):
                    s -= 40
                for color in ("blue", "red", "green", "yellow", "purple", "orange", "pink", "white", "black"):
                    if stem.endswith(color):
                        s -= 10
                return -s
            ranked = sorted(stems, key=lambda x: fallback_score(x[1]))
            defaults[short] = [r for _st, r in ranked[:6]]
        covered = sum(1 for (s, _r) in tex_map if s == short)
        print(f"[{short}] prefab-chain {chained} prefabs; covered fbx {covered}; "
              f"embedded-extra {fbx_hit_src['embedded']}")

    # emit keyed by preview res path; resolve every candidate by filename
    out_map: dict[str, list[str]] = {}
    for short, pack_root in PACKAGES.items():
        prev_by_name: dict[str, str] = {}
        for p in (ASSETS / short).rglob("*"):
            if p.suffix.lower() in (".png", ".tga", ".jpg") and p.name not in prev_by_name:
                prev_by_name[p.name] = "res://" + str(p.relative_to(PREVIEW)).replace("\\", "/")
        for (s, rel), texs in tex_map.items():
            if s != short:
                continue
            fbx_res = "res://assets/{}/{}/Models/{}".format(short, pack_root, rel.replace("\\", "/"))
            resolved: list[str] = []
            for t in texs:
                r = prev_by_name.get(Path(str(t)).name)
                if r and r not in resolved:
                    resolved.append(r)
            if resolved:
                out_map[fbx_res] = resolved[:4]
    (PREVIEW / "texture_map.json").write_text(
        json.dumps(out_map, ensure_ascii=False, indent=0), encoding="utf-8")
    (PREVIEW / "defaults.json").write_text(
        json.dumps(defaults, ensure_ascii=False, indent=1), encoding="utf-8")

    n_fbx = sum(1 for _ in ASSETS.rglob("*.fbx"))
    print(f"mapped {len(out_map)}/{n_fbx} preview fbx")
    for k in list(out_map)[:4]:
        print(" ", Path(k).stem, "->", [Path(v).stem for v in out_map[k][:2]])


if __name__ == "__main__":
    main()
