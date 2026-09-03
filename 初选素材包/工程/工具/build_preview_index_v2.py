# -*- coding: utf-8 -*-
"""Build index.html gallery over 预览图/ (场景 + 地形 + 分类), relative paths.
v2: no overview section (stale renders removed until env recovers)."""
from __future__ import annotations

import html
from pathlib import Path

ROOT = Path(r"G:\AIRTS\临时文件夹\_筛选解包")
GAL = ROOT / "预览图"

PKG_TITLES = {
    "4006_科幻世界": "4006 科幻世界 (POLYGON Sci-Fi Worlds, 1228 FBX)",
    "4041_西部土著": "4041 西部土著 (POLYGON Western Frontier, 305 FBX)",
    "4050_微缩城市": "4050 微缩城市 (POLYGON MINI City, 281 FBX)",
    "4019_战争地图": "4019 战争地图 (POLYGON War Map WW1, 109 FBX)",
    "463_末日废墟": "463 末日废墟 (POLYGON Apocalypse, 1805 FBX)",
}

STYLE = """
body{font-family:'Segoe UI',system-ui,sans-serif;background:#1b1e24;color:#dde2ea;margin:0;padding:24px}
h1{font-size:22px} h2{font-size:18px;margin:28px 0 10px;color:#f0b429;border-bottom:1px solid #333;padding-bottom:6px}
h3{font-size:15px;margin:18px 0 8px;color:#9fc7ff}
img{max-width:100%;border-radius:6px;border:1px solid #333;display:block;margin:6px 0}
.note{color:#8b93a3;font-size:13px}
"""

ORDER = ["4006_科幻世界", "4041_西部土著", "4050_微缩城市", "4019_战争地图", "463_末日废墟"]


def main() -> None:
    parts = ["<!DOCTYPE html><html><head><meta charset='utf-8'>",
             "<title>素材包全量预览</title>",
             f"<style>{STYLE}</style></head><body>",
             "<h1>筛选素材包 · Godot 全量渲染预览</h1>",
             "<p class='note'>每格代表一个 FBX 模型，按文件名前缀分类分页；场景为 Unity demo 场景的布局重建（Godot 实时渲染）。"
             "原始文件在 <code>_筛选解包\\&lt;包名&gt;\\</code>，索引 <code>00_内容清单.csv</code>。"
             "更新时间：2026-08-29 20:50（4019 战争地图已入库，4058 简单战争已移除）。</p>"]

    for sub, title in [("场景", "场景重建（Unity demo 布局 → Godot 实时渲染）"),
                       ("地形", "地形类模型（terr/ground/hill/cliff/rock/crater/tile 等关键词筛选）"),
                       ("分类", "全量模型 · 按类分页")]:
        d = GAL / sub
        if not d.is_dir():
            continue
        parts.append(f"<h2>{title}</h2>")
        for pkg in ORDER:
            imgs = sorted(d.glob(f"{pkg}_*.png"))
            if not imgs:
                continue
            parts.append(f"<h3>{html.escape(PKG_TITLES[pkg])}</h3>")
            for img in imgs:
                parts.append(f"<div><b>{html.escape(img.stem)}</b>"
                             f"<img loading='lazy' src='{sub}/{img.name}'></div>")

    parts.append("</body></html>")
    out = GAL / "index.html"
    data = "\n".join(parts)
    try:
        with out.open("w", encoding="utf-8") as fh:
            fh.write(data)
    except PermissionError:
        out = GAL / "index_v2.html"
        with out.open("w", encoding="utf-8") as fh:
            fh.write(data)
    n = sum(1 for _ in GAL.rglob("*.png"))
    print(f"index -> {out} ({n} images on disk)")


if __name__ == "__main__":
    main()
