# -*- coding: utf-8 -*-
# 隔离探测: Soldier.glb 的 Idle 动作在源帧 0..20 的左手世界坐标 (排除管线因素)
import bpy

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap\Soldier.glb")
srcA = next(o for o in bpy.data.objects if o.type == "ARMATURE")
for o in list(bpy.data.objects):
    if o.type == "MESH":
        bpy.data.objects.remove(o, do_unlink=True)

print("IDLE_RANGE", tuple(bpy.data.actions["Idle"].frame_range))
ad = srcA.animation_data or srcA.animation_data_create()
ad.action = bpy.data.actions["Idle"]
if bpy.data.actions["Idle"].slots:
    ad.action_slot = bpy.data.actions["Idle"].slots[0]

hand = srcA.pose.bones["mixamorig:LeftHand"]
sc = bpy.context.scene
for f in range(0, 21, 2):
    sc.frame_set(f)
    bpy.context.view_layer.update()
    w = (srcA.matrix_world @ hand.matrix).to_translation()
    print("HAND f=%d (%.4f, %.4f, %.4f)" % (f, w.x, w.y, w.z))
print("IDLE_PROBE_DONE")
