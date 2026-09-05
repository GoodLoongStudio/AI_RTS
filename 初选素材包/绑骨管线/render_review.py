# -*- coding: utf-8 -*-
# 九段动画审核渲染 v2: 直接渲染烘焙成品 (retargeted_baked.blend 的关键帧数据,
# 即 Godot 实际播放的内容) —— 修正关节扭转后的权威审核媒介。
# 输出: 4006/审核帧/<剪辑名>/f###.png -> make_review_gif.py 组装 GIF
import bpy, math, os
from mathutils import Vector

BLEND = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\retargeted_baked.blend"
OUT_ROOT = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\审核帧"
CLIPS = ["Idle-loop", "Walk-loop", "Run-loop", "Attack", "Fire",
         "Gather-loop", "Build-loop", "Hit", "Death"]

bpy.ops.wm.open_mainfile(filepath=BLEND)
dst_arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
sc = bpy.context.scene
dpb = dst_arm.pose.bones
ad = dst_arm.animation_data or dst_arm.animation_data_create()

sc.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in dir(bpy.types) else "BLENDER_EEVEE"
sc.render.resolution_x, sc.render.resolution_y = 400, 520
w = bpy.data.worlds.new("W"); w.color = (0.78, 0.78, 0.80); sc.world = w
for lname, loc, energy in (("K1", (3, -3, 4), 800), ("K2", (-4, 2, 3), 400), ("K3", (0, 3, 5), 300)):
    ld = bpy.data.lights.new(lname, "POINT"); ld.energy = energy
    lo = bpy.data.objects.new(lname, ld); sc.collection.objects.link(lo); lo.location = loc
cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
sc.collection.objects.link(cam); sc.camera = cam
import bmesh as _bm
gm = bpy.data.meshes.new("Ground"); go = bpy.data.objects.new("Ground", gm)
sc.collection.objects.link(go)
bm = _bm.new(); _bm.ops.create_grid(bm, x_segments=1, y_segments=1, size=8.0); bm.to_mesh(gm); bm.free()
gmat = bpy.data.materials.new("GroundMat"); gmat.use_nodes = True
next(n for n in gmat.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)
go.data.materials.append(gmat)
ang = math.radians(126)

for on in CLIPS:
    act = bpy.data.actions.get(on)
    if act is None:
        print("MISSING", on)
        continue
    n = int(act.frame_range[1] - act.frame_range[0]) + 1
    ad.action = act
    if act.slots:
        ad.action_slot = act.slots[0]
    vdir = os.path.join(OUT_ROOT, on.replace("-loop", ""))
    os.makedirs(vdir, exist_ok=True)
    for k in range(n):
        f = act.frame_range[0] + k
        sc.frame_set(int(f))
        bpy.context.view_layer.update()
        hip = (dst_arm.matrix_world @ dpb["Hips"].matrix).to_translation()
        dist = 4.5 if on == "Death" else 3.0
        cam.location = (hip.x + dist * math.cos(ang), hip.y + dist * math.sin(ang),
                        max(hip.z + 0.3, 1.1))
        cam.rotation_euler = (Vector((hip.x, hip.y, hip.z)) - cam.location).to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = os.path.join(vdir, "f%03d.png" % (k + 1))
        bpy.ops.render.render(write_still=True)
    print("RENDERED", on, n, "frames")
print("REVIEW_RENDER_DONE")
