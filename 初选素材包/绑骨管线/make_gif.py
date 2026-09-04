# -*- coding: utf-8 -*-
import pathlib
from PIL import Image

FRAMES = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\动画帧")
OUT = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Soldier_Male_animations.gif")

SEGS = [("Idle", 1, 60, 1), ("Walk", 61, 40, 2), ("Run", 101, 24, 2),
        ("Attack", 125, 36, 1), ("Death", 161, 48, 1)]

frames = []
durations = []
for name, start, count, loops in SEGS:
    for i in range(count * loops):
        f = start + (i % count)
        fp = FRAMES / ("f%03d.png" % f)
        img = Image.open(fp).convert("P", palette=Image.ADAPTIVE, colors=128)
        frames.append(img)
        durations.append(int(1000 / 30))

frames[0].save(str(OUT), save_all=True, append_images=frames[1:],
               duration=durations, loop=0, optimize=True)
print("GIF_DONE", OUT.stat().st_size // 1024, "KB", len(frames), "frames")
