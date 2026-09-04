# -*- coding: utf-8 -*-
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\anim_4006.py")
c = p.read_text(encoding="utf-8")

old_cam = 'cam_d = bpy.data.cameras.new("Cam")'
assert old_cam in c
c = c.replace(old_cam, 'w = bpy.data.worlds.new("W")\nw.color = (0.78, 0.78, 0.80)\nsc.world = w\n' + old_cam)

old_loc = "cam.location = (cx + 2.0, cy - 3.4, 1.42)"
assert old_loc in c, "loc not found"
c = c.replace(old_loc, "cam.location = (cx + 3.0, cy + 0.35, 1.30)")
old_rot = 'cam.rotation_euler = Euler((radians(76), 0, radians(30)), "XYZ")'
assert old_rot in c, "rot not found"
c = c.replace(old_rot, 'cam.rotation_euler = Euler((radians(85), 0, radians(90)), "XYZ")')

c = c.replace('rot("LeftArm", f, x=4 * sin(t))', 'rot("LeftArm", f, z=10 * sin(t))')
c = c.replace('rot("RightArm", f, x=-4 * sin(t))', 'rot("RightArm", f, z=10 * sin(t))')
c = c.replace('rot("LeftForeArm", f, x=6 * sin(t))', 'rot("LeftForeArm", f, x=8 * sin(t))')
c = c.replace('rot("RightForeArm", f, x=-6 * sin(t))', 'rot("RightForeArm", f, x=-8 * sin(t))')
c = c.replace('rot("LeftArm", f, x=-25 * s)', 'rot("LeftArm", f, x=-40 * s)')
c = c.replace('rot("RightArm", f, x=25 * s)', 'rot("RightArm", f, x=40 * s)')

p.write_text(c, encoding="utf-8")
print("patched ok")
