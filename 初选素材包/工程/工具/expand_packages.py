# -*- coding: utf-8 -*-
"""Expand 96套/筛选 unitypackages (tar.gz, GUID layout) into named folder trees.

Two-pass streaming: pass 1 reads every GUID's `pathname`; pass 2 streams each
`asset` to its restored original path. Writes a combined index CSV + stats.
"""
from __future__ import annotations

import csv
import tarfile
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"G:\AIRTS\临时文件夹")
SRC = ROOT / "_筛选解包" / "原始包"
OUT = ROOT / "素材包"

PACKAGES = {
    "4006_低面风格科幻世界": "4006_科幻世界",
    "4041_西部土著题材资产": "4041_西部土著",
    "4050_微缩城市场景包": "4050_微缩城市",
    "4019_战争地图": "4019_战争地图",
    "463_末日废墟": "463_末日废墟",
}


def find_unitypackage(pkg_dir: Path) -> Path:
    hits = sorted(pkg_dir.rglob("*.unitypackage"))
    if not hits:
        raise SystemExit(f"no unitypackage under {pkg_dir}")
    return hits[0]


def read_pathnames(tar: tarfile.TarFile) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in tar:
        name = m.name.replace("\\", "/")
        if name.endswith("/pathname"):
            guid = name.split("/")[0]
            f = tar.extractfile(m)
            if f is not None:
                rel = f.read().decode("utf-8", errors="replace").splitlines()
                out[guid] = rel[0].strip().replace("\\", "/") if rel else ""
    return out


def main() -> None:
    all_rows: list[dict[str, str]] = []
    stats: dict[str, Counter] = defaultdict(Counter)

    for src_name, short in PACKAGES.items():
        pkg = find_unitypackage(SRC / src_name)
        dest_root = OUT / short
        dest_root.mkdir(parents=True, exist_ok=True)
        print(f"=== {short} <- {pkg.name} ({pkg.stat().st_size/1e6:.0f} MB) ===")

        with tarfile.open(pkg, "r:*") as tar:
            pathnames = read_pathnames(tar)
            copied = skipped = 0
            for m in tar:
                name = m.name.replace("\\", "/")
                parts = name.split("/")
                if len(parts) != 2:
                    continue
                if parts[1] not in ("asset", "asset.meta"):
                    continue
                guid = parts[0]
                rel = pathnames.get(guid, "")
                if not rel:
                    skipped += 1
                    continue
                rel = rel[len("Assets/"):] if rel.startswith("Assets/") else rel
                if not rel or rel.endswith("/"):
                    skipped += 1
                    continue
                f = tar.extractfile(m)
                if f is None:
                    skipped += 1
                    continue
                dest = dest_root / (rel + ".meta" if parts[1] == "asset.meta" else rel)
                dest.parent.mkdir(parents=True, exist_ok=True)
                with dest.open("wb") as w:
                    w.write(f.read())
                if parts[1] == "asset":
                    copied += 1
                    ext = dest.suffix.lower() or "(noext)"
                    stats[short][ext] += 1
                    all_rows.append({
                        "package": short,
                        "guid": guid,
                        "original_path": rel,
                        "restored_path": str(dest.relative_to(OUT)),
                    })
            print(f"  restored {copied} files, skipped {skipped}")

    index = OUT / "00_内容清单.csv"
    with index.open("w", encoding="utf-8-sig", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["package", "guid", "original_path", "restored_path"])
        w.writeheader()
        w.writerows(all_rows)

    print("\n==== 每包扩展名统计 ====")
    for short, counter in stats.items():
        total = sum(counter.values())
        top = ", ".join(f"{k}:{v}" for k, v in counter.most_common(8))
        print(f"[{short}] total={total} | {top}")
    print(f"\nindex -> {index}")


if __name__ == "__main__":
    main()
