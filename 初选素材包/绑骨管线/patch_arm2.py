# -*- coding: utf-8 -*-
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\quick_frames2.py")
c = p.read_text(encoding="utf-8")
# Attack 表按新基准重写 (RightArm 垂下基准 = 局部 X +90)
old = """for f, ay, ax, fy, sz in [(125, RA, 0, -20, 0),
                          (134, RA - 55, 0, -60, -20),
                          (141, RA + 42, 0, -12, 26),
                          (150, RA + 22, 0, -40, 12),
                          (160, RA, 0, -20, 0)]:
    rot("RightArm", f, y=ay)"""
new = """for f, ax, fy, sz in [(125, 90, -20, 0),
                      (134, 45, -60, -20),
                      (141, -25, -10, 26),
                      (150, 65, -40, 12),
                      (160, 90, -20, 0)]:
    rot("RightArm", f, x=ax)"""
if old in c:
    c = c.replace(old, new)
    p.write_text(c, encoding="utf-8")
    print("attack patched")
else:
    print("attack block not found - skip")
