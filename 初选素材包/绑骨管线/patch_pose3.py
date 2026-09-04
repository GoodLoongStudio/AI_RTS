# -*- coding: utf-8 -*-
import pathlib
p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\render_previews.py")
c = p.read_text(encoding="utf-8")
c = c.replace('rot("RightUpLeg", -80, 0, 0)', 'rot("RightArm", -50, 0, 0)')
pairs = [
    ('rot("RightForeArm", 0, 65, 0)', 'rot("RightForeArm", -40, 0, 0)'),
    ('rot("RightHand", 0, 15, 0)', 'rot("RightHand", -15, 0, 0)'),
    ('rot("LeftForeArm", 0, -18, 0)', 'rot("LeftForeArm", 0, -25, 0)'),
]
for old, new in pairs:
    if old in c:
        c = c.replace(old, new)
p.write_text(c, encoding="utf-8")
print("patched")
