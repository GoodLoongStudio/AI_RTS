# -*- coding: utf-8 -*-
# 直接读烘焙成品数据: Idle-loop 动作前 12 帧的左手/右手世界坐标
# 正确 idle: 手在腰/胯高度 (z≈0.9-1.0); T-pose/rest: 手在肩以上 (z>1.3)
import bpy
from mathutils import Vector

bpy.ops.wm.open_mainfile(filepath=r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\retargeted_baked.blend")
dst_arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
sc = bpy.context.scene
dpb = dst_arm.pose.bones
ad = dst_arm.animation_data or dst_arm.animation_data_create()

act = bpy.data.actions.get("Idle-loop")
print("RANGE", tuple(round(v, 2) for v in act.frame_range), "slots", [s.identifier for s in act.slots])
ad.action = act
ad.action_slot = act.slots[0]

lh = dpb["LeftHand"]
rh = dpb["RightHand"]
for f in range(1, 13):
    sc.frame_set(f)
    bpy.context.view_layer.update()
    wl = (dst_arm.matrix_world @ lh.matrix).to_translation()
    wr = (dst_arm.matrix_world @ rh.matrix).to_translation()
    print("f%02d L=(%.3f, %.3f, %.3f) R=(%.3f, %.3f, %.3f)" % (
        f, wl.x, wl.y, wl.z, wr.x, wr.y, wr.z))

# 对照: 无动作时的 rest 手位
ad.action = None
sc.frame_set(1)
bpy.context.view_layer.update()
wl = (dst_arm.matrix_world @ lh.matrix).to_translation()
print("REST L=(%.3f, %.3f, %.3f)" % (wl.x, wl.y, wl.z))
print("BAKED_IDLE_PROBE_DONE")
