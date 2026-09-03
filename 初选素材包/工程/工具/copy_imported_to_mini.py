# -*- coding: utf-8 -*-
import os, shutil
from pathlib import Path

SRC = Path(r"G:\AIRTS\临时文件夹\_筛选解包\_preview")
DST = Path(r"G:\AIRTS\临时文件夹\_筛选解包\_mini")

n1 = 0
dst_imp = DST / ".godot" / "imported"
dst_imp.mkdir(parents=True, exist_ok=True)
for f in (SRC / ".godot" / "imported").iterdir():
    d = dst_imp / f.name
    if not d.exists():
        shutil.copy2(f, d)
        n1 += 1
print(f"imported: +{n1} -> total {sum(1 for _ in dst_imp.iterdir())}")

n2 = 0
for sidecar in SRC.glob("assets/**/*.import"):
    rel = sidecar.relative_to(SRC)
    dst = DST / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        continue
    try:
        os.link(sidecar, dst)
    except OSError:
        shutil.copy2(sidecar, dst)
    n2 += 1
print(f"sidecars: +{n2}")

for f in [".godot/uid_cache.bin", ".godot/global_script_class_cache.cfg"]:
    s = SRC / f
    if s.exists():
        shutil.copy2(s, DST / f)
print("done")
