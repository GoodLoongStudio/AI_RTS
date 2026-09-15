"""Download the licensed PBR ground materials used by the G4 terrain shader.

All Poly Haven assets are CC0 (public domain, commercial use allowed, no attribution
required).  The manifest below is the single source of truth for which texture plays
which geomorphological role in ``tools/godot/showcase_land.gdshader``; the script
writes ``assets/terrain_pbr/SOURCES.json`` plus a human readable ``SOURCES.md``.

Usage (map-tool venv, proxy set through the environment):

    python tools/fetch_terrain_pbr.py
    python tools/fetch_terrain_pbr.py --only dense_sand cliff_side
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets" / "terrain_pbr"
FILES_API = "https://api.polyhaven.com/files/"
PAGE = "https://polyhaven.com/a/"
RESOLUTION = "2k"

# role -> key consumed by showcase_land.gdshader
MANIFEST = [
    {
        "id": "dense_sand",
        "role": "ground_sand",
        "layer": "1a 主地面（浅色荒漠砂地，低对比底噪）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "压实的细粒沙。作为全区最底层的沙漠地面，色相偏米黄，亮度中等，"
                "不抢台地与山体的对比。",
    },
    {
        "id": "sand_01",
        "role": "ground_detail",
        "layer": "1b 主地面细节（碎石/砾砂宏观斑块）",
        "license": "CC0",
        "source": "polyhaven",
        "maps": ["Diffuse", "nor_gl"],
        "note": "含砾石的砂面，只提供中尺度斑块与碎石感，避免整体变成均质噪声。",
    },
    {
        "id": "moon_dusted_03",
        "role": "plateau_top",
        "layer": "2 台地顶面（更浅、更干、带粉尘的硬质面）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "灰色粉尘覆盖的硬地面。台地顶面明显比周围沙地更亮更冷，"
                "使 8 座台地在远景里先以「浅色平台」被读出。",
    },
    {
        "id": "cliff_side",
        "role": "cliff_wall",
        "layer": "3 台地垂直崖壁（深红褐分层岩）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "水平层理清晰的岩面。用于台地侧壁与坡口两侧的切面，"
                "提供与顶面相反的暗部，形成台地立体感。",
    },
    {
        "id": "dark_rock_02",
        "role": "mountain_rock",
        "layer": "4a 山体阻碍区（深色板块状岩体）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "深灰层状岩。山体阻挡区的主要材质，靠低明度把「不可通行」"
                "在远景里表达为暗色块，而不是细碎噪声。",
    },
    {
        "id": "gray_rocks",
        "role": "mountain_detail",
        "layer": "4b 山体细节（碎块状岩屑）",
        "license": "CC0",
        "source": "polyhaven",
        "maps": ["Diffuse", "nor_gl"],
        "note": "碎石块面，给山体增加块状尺度感，防止山体退化成平滑土堆。",
    },
    {
        "id": "brown_mud_02",
        "role": "river_bank",
        "layer": "5 河岸（湿润、偏深褐的窄过渡带）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "湿泥。只出现在河道两侧数米内，暗且低饱和，勾出连续河道边界。",
    },
    {
        "id": "damp_beach_sand_02",
        "role": "lake_shore",
        "layer": "6 湖岸（更宽的浅色淤泥/湿地过渡）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "潮湿的灰绿砂泥。湖岸带刻意做得比河岸宽数倍，"
                "让大型湖泊有一个渐变的浅色淤积裙边。",
    },
    {
        "id": "dirt_aerial_02",
        "role": "ramp_surface",
        "layer": "7 坡道（压实、平整、色稍浅，带车辙）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "压实土面带车辙。沿 8 座台地的主/侧坡道铺开，"
                "让坡道在远景里读作「人工通道」而非天然坡面。",
    },
    {
        "id": "metal_plate_02",
        "role": "bridge_metal",
        "layer": "8 桥梁（深灰金属）",
        "license": "CC0",
        "source": "polyhaven",
        "note": "深灰钢制板面。替换原先偏红锈的桥面，"
                "使 6 座桥与荒漠底色形成强对比。",
    },
]

MAP_EXT = {"Diffuse": "diff", "nor_gl": "normal", "Rough": "rough"}


def fetch(url: str) -> bytes:
    proxy = os.environ.get("AIRTS_HTTP_PROXY") or os.environ.get("HTTPS_PROXY")
    handlers = [urllib.request.ProxyHandler({"http": proxy, "https": proxy})] if proxy else []
    opener = urllib.request.build_opener(*handlers)
    opener.addheaders = [("User-Agent", "Mozilla/5.0 (compatible; AIRTS-terrain-fetch/1.0)")]
    with opener.open(url, timeout=120) as response:
        return response.read()


def files_for(asset: str) -> dict:
    return json.loads(fetch(FILES_API + asset).decode("utf-8"))


def download(entry: dict, resolution: str) -> dict:
    info = files_for(entry["id"])
    wanted = entry.get("maps", ["Diffuse", "nor_gl", "Rough"])
    written = {}
    for api_map in wanted:
        bucket = info.get(api_map, {}).get(resolution, {})
        fmt = next((f for f in ("jpg", "png") if f in bucket), None)
        if fmt is None:
            print(f"  ! {entry['id']}: {api_map}@{resolution} unavailable, skipped")
            continue
        suffix = MAP_EXT[api_map]
        target = DEST / f"{entry['id']}_{suffix}.{fmt}"
        payload = fetch(bucket[fmt]["url"])
        target.write_bytes(payload)
        written[suffix] = {"file": target.name, "bytes": len(payload), "md5": bucket[fmt]["md5"]}
        print(f"  {target.name:38s} {len(payload) / 1e6:6.2f} MB   {api_map}@{resolution}")
    return written


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", nargs="*", default=None, help="subset of asset ids")
    parser.add_argument("--resolution", default=RESOLUTION)
    args = parser.parse_args()

    DEST.mkdir(parents=True, exist_ok=True)
    selected = [e for e in MANIFEST if not args.only or e["id"] in args.only]
    records = []
    for entry in selected:
        print(f"[{entry['role']}] {entry['id']}")
        files = download(entry, args.resolution)
        records.append({
            "id": entry["id"],
            "role": entry["role"],
            "layer": entry["layer"],
            "license": entry["license"],
            "source": entry["source"],
            "source_page": PAGE + entry["id"],
            "resolution": args.resolution,
            "note": entry["note"],
            "files": files,
        })
    existing = {}
    manifest_path = DEST / "SOURCES.json"
    if manifest_path.exists():
        try:
            previous = json.loads(manifest_path.read_text(encoding="utf-8"))
            existing = {r["id"]: r for r in previous.get("assets", [])}
        except (ValueError, KeyError):
            existing = {}
    for record in records:
        existing[record["id"]] = record
    ordered = [existing[e["id"]] for e in MANIFEST if e["id"] in existing]
    manifest_path.write_text(
        json.dumps({"generated_for": "review/G4/g2_large_lake_kits", "assets": ordered},
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    lines = ["# assets/terrain_pbr 素材来源与许可证", "",
             "本目录下由 `tools/fetch_terrain_pbr.py` 下载的贴图均来自 Poly Haven，许可为 **CC0 1.0**",
             "（公有领域，允许商用，无需署名）。原始素材未被覆盖，旧素材（sand_diff/rock_diff/open_rock_*）保留。", "",
             "| 文件前缀 | 地貌层 | 来源页面 | 许可证 |", "| --- | --- | --- | --- |"]
    for record in ordered:
        prefix = record["files"].get("diff", {}).get("file", "?")
        lines.append(f"| `{prefix.rsplit('_', 1)[0]}` | {record['layer']} | {record['source_page']} | {record['license']} |")
    (DEST / "SOURCES.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"\nmanifest -> {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
