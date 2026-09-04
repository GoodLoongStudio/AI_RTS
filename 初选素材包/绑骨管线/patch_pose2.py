# -*- coding: utf-8 -*-
import pathlib
p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\render_previews.py")
c = p.read_text(encoding="utf-8")
c = c.replace('rot("RightArm", 0, 50, 0)', 'rot("RightUpLeg", -80, 0, 0)')
c = c.replace('rot("RightForeArm", 0, 65, 0)', '')
c = c.replace('rot("RightHand", 0, 15, 0)', '')
p.write_text(c, encoding="utf-8")
print("diag patched")
