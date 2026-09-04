# -*- coding: utf-8 -*-
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\quick_frames2.py")
c = p.read_text(encoding="utf-8")
n = 0
for old, new in [("LA, RA = 78.0, -78.0", "LA, RA = -90.0, 90.0"),
                 ("y=LA", "x=LA"), ("y=RA", "x=RA")]:
    if old in c:
        c = c.replace(old, new)
        n += 1
p.write_text(c, encoding="utf-8")
print("patched", n)
