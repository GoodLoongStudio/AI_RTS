# -*- coding: utf-8 -*-
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\anim_4006.py")
c = p.read_text(encoding="utf-8")
# Attack 关键帧：x 改 y（绕 Y 前上举/劈下）
old = """for f, ax, az, fx, sz in [(125,0,0,0,0),(134,-100,-20,-60,-22),(141,45,25,-10,28),(152,30,10,-30,10),(160,0,0,0,0)]:
    rot("RightArm", f, x=ax, z=az)
    rot("RightForeArm", f, x=fx)
    rot("Spine2", f, z=sz)"""
new = """for f, ay, az, fy, sz in [(125,0,0,0,0),(134,-100,-15,-35,-18),(141,45,20,-15,25),(152,25,10,-25,10),(160,0,0,0,0)]:
    rot("RightArm", f, y=ay, z=az)
    rot("RightForeArm", f, y=fy)
    rot("Spine2", f, z=sz)"""
assert old in c
c = c.replace(old, new)
# Walk 摆臂 40 回调 30
c = c.replace('rot("LeftArm", f, x=-40 * s)', 'rot("LeftArm", f, x=-30 * s)')
c = c.replace('rot("RightArm", f, x=40 * s)', 'rot("RightArm", f, x=30 * s)')
p.write_text(c, encoding="utf-8")
print("patched")
