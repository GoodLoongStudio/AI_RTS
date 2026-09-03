# -*- coding: utf-8 -*-
"""Retry-loop: catch an intermittent healthy window to render 5 overview PNGs."""
import os
import subprocess
import time
from pathlib import Path

OUT = Path(r"G:\AIRTS\临时文件夹\_筛选解包\预览图")
PROJ = r"G:\AIRTS\临时文件夹\_筛选解包\工程\预览渲染工程"
EXE = r"G:\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
TARGETS = [OUT / f"{n}_overview.png" for n in
           ("4006_科幻世界", "4041_西部土著", "4050_微缩城市",
            "4019_战争地图", "463_末日废墟")]

marker = max((p.stat().st_mtime for p in TARGETS if p.exists()), default=0)
env = dict(os.environ, CAPTURE_MODE="overview")


def shutil_rmtree(p):
    import shutil
    shutil.rmtree(p, ignore_errors=True)


for attempt in range(1, 13):
    # pre-clean caches each attempt
    shutil_rmtree(Path(PROJ) / ".godot" / "shader_cache")
    try:
        proc = subprocess.run([EXE, "--path", PROJ], env=env,
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=900)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        rc = "timeout"
    fresh = [p for p in TARGETS if p.exists() and p.stat().st_mtime > marker]
    print(f"attempt {attempt}: rc={rc} fresh={len(fresh)}/5", flush=True)
    if len(fresh) == 5:
        print("ALL 5 OVERVIEWS RENDERED")
        break
    time.sleep(20)
