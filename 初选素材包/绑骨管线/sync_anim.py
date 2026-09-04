# -*- coding: utf-8 -*-
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\anim_4006.py")
c = p.read_text(encoding="utf-8")
n = 0
pairs = [
    # 1. 地面 + 浅背景（插在相机创建前）
    ('cam_d = bpy.data.cameras.new("Cam")',
     'w = bpy.data.worlds.new("W")\nw.color = (0.78, 0.78, 0.80)\nsc.world = w\ng_mesh = bpy.data.meshes.new("G")\ng_obj = bpy.data.objects.new("G", g_mesh)\nsc.collection.objects.link(g_obj)\nimport bmesh\nbm = bmesh.new()\nbmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=4.0)\nbm.to_mesh(g_mesh)\nbm.free()\ng_mat = bpy.data.materials.new("GM")\ng_mat.use_nodes = True\nnext(n2 for n2 in g_mat.node_tree.nodes if n2.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)\ng_obj.data.materials.append(g_mat)\ng_obj.location = (cx, cy, -0.001)\ncam_d = bpy.data.cameras.new("Cam")'),
    # 2. 相机拉远 + 自动对准
    ('cam.location = (cx + 1.4, cy - 2.5, 1.1)',
     'cam.location = (cx + 2.4, cy - 2.9, 1.15)'),
    ('cam.rotation_euler = Euler((radians(74), 0, radians(30)), "XYZ")',
     'cam.rotation_euler = (Vector((cx, cy, 0.95)) - cam.location).to_track_quat("-Z", "Y").to_euler()'),
    # 3. Idle 垂臂
    ('rot("LeftArm", f, x=4 * sin(t))', 'rot("LeftArm", f, x=-90)'),
    ('rot("RightArm", f, x=-4 * sin(t))', 'rot("RightArm", f, x=90)'),
    ('rot("LeftForeArm", f, x=6 * sin(t))', 'rot("LeftForeArm", f, x=-12 + 4 * sin(t))'),
    ('rot("RightForeArm", f, x=-6 * sin(t))', 'rot("RightForeArm", f, x=-12 - 4 * sin(t))'),
    # 4. Walk 垂臂摆
    ('rot("LeftArm", f, x=-25 * s)', 'rot("LeftArm", f, x=-90 + 26 * s)'),
    ('rot("RightArm", f, x=25 * s)', 'rot("RightArm", f, x=90 + 26 * s)'),
    ('rot("LeftForeArm", f, x=-15)', 'rot("LeftForeArm", f, x=-18)'),
    ('rot("RightForeArm", f, x=-15)', 'rot("RightForeArm", f, x=-18)'),
    # 5. Run 垂臂大摆
    ('rot("LeftArm", f, x=-40 * s)', 'rot("LeftArm", f, x=-90 + 38 * s)'),
    ('rot("RightArm", f, x=40 * s)', 'rot("RightArm", f, x=90 + 38 * s)'),
    # 6. Attack 新轴（垂下->后摆蓄力->前劈->回）
    ('(134, -100, -20, -60, -22)', '(134, -135, 0, -70, -20)'),
    ('(141, 45, 25, -10, 28)', '(141, 15, 0, -10, 26)'),
    ('(152, 30, 10, -30, 10)', '(152, -30, 0, -40, 12)'),
    ('(125, 0, 0, 0, 0)', '(125, -90, 0, 0, 0)'),
    ('(160, 0, 0, 0, 0)', '(160, -90, 0, -20, 0)'),
]
for old, new in pairs:
    if old in c:
        c = c.replace(old, new)
        n += 1
    else:
        print("MISS:", old[:50])
p.write_text(c, encoding="utf-8")
print("synced", n, "/", len(pairs))
