# -*- coding: utf-8 -*-
import pathlib
p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\render_previews.py")
c = p.read_text(encoding="utf-8")
pairs = [
    ('rot("RightArm", 0, 0, -55)', 'rot("RightArm", 0, 50, 0)'),
    ('rot("RightForeArm", 0, -70, 0)', 'rot("RightForeArm", 0, 65, 0)'),
    ('rot("RightHand", 0, -20, 0)', 'rot("RightHand", 0, 15, 0)'),
    ('rot("LeftForeArm", 0, 25, 0)', 'rot("LeftForeArm", 0, -18, 0)'),
]
n = 0
for old, new in pairs:
    if old in c:
        c = c.replace(old, new)
        n += 1
p.write_text(c, encoding="utf-8")
print("patched", n)
