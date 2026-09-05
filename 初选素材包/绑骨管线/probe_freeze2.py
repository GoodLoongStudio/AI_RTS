# -*- coding: utf-8 -*-
# 最小复现: 管线 Pass1 求值中 Idle 段是否冻结 (打印每帧左手世界坐标与绑定状态)
import bpy, math

MOCAP = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\mocap"
UAL_GLB = MOCAP + r"\ual_extract\UAL_Mannequin_skinned.glb"
FBX = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=MOCAP + r"\Soldier.glb")
srcA = next(o for o in bpy.data.objects if o.type == "ARMATURE")
for o in list(bpy.data.objects):
    if o.type == "MESH":
        bpy.data.objects.remove(o, do_unlink=True)
bpy.ops.import_scene.fbx(filepath=FBX)
dst_arm = next(o for o in bpy.data.objects if o.type == "ARMATURE" and o is not srcA)
pre = set(o.name for o in bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=UAL_GLB)
un = set(o.name for o in bpy.data.objects if o.name not in pre)
for o in [o for o in bpy.data.objects if o.name in un and o.type == "MESH"]:
    bpy.data.objects.remove(o, do_unlink=True)
srcC = next(o for o in bpy.data.objects if o.name in un and o.type == "ARMATURE")
srcC.rotation_quaternion = (bpy.types.bpy_prop_array if False else __import__("mathutils").Quaternion((0, 0, 1), math.pi)) @ srcC.rotation_quaternion

sc = bpy.context.scene
sc.frame_set(1)
dpb = dst_arm.pose.bones

def add_copy(pb, t, st, with_location=True):
    c1 = None
    if with_location:
        c1 = pb.constraints.new("COPY_LOCATION"); c1.target = t; c1.subtarget = st
    c2 = pb.constraints.new("COPY_ROTATION"); c2.target = t; c2.subtarget = st
    return c1, c2

con_a, con_c = {}, {}
for b in ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "LeftShoulder", "RightShoulder",
          "LeftArm", "RightArm", "LeftForeArm", "RightForeArm", "LeftHand", "RightHand",
          "LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg", "LeftFoot", "RightFoot"]:
    sn = "mixamorig:" + b
    if sn in srcA.pose.bones and b in dpb:
        con_a[b] = add_copy(dpb[b], srcA, sn)
U_MAP = {"Hips": "Hips", "Chest": "Spine", "UpperChest": "Spine1", "Neck": "Neck", "Head": "Head",
         "LeftShoulder": "LeftShoulder", "RightShoulder": "RightShoulder",
         "LeftUpperArm": "LeftArm", "RightUpperArm": "RightArm",
         "LeftLowerArm": "LeftForeArm", "RightLowerArm": "RightForeArm",
         "LeftHand": "LeftHand", "RightHand": "RightHand",
         "LeftUpperLeg": "LeftUpLeg", "RightUpperLeg": "RightUpLeg",
         "LeftLowerLeg": "LeftLeg", "RightLowerLeg": "RightLeg",
         "LeftFoot": "LeftFoot", "RightFoot": "RightFoot"}
cpbC = srcC.pose.bones
for un2, dn in U_MAP.items():
    if un2 in cpbC and dn in dpb:
        con_c[dn] = add_copy(dpb[dn], srcC, un2, with_location=(dn == "Hips"))
for c1, c2 in con_a.values():
    c1.influence, c2.influence = 1.0, 1.0
for c1, c2 in con_c.values():
    if c1: c1.influence = 0.0
    c2.influence = 0.0

adA = srcA.animation_data or srcA.animation_data_create()

act = bpy.data.actions.get("Idle")
adA.action = act
if act.slots:
    adA.action_slot = act.slots[0]

hand = dpb["LeftHand"]
for f in range(1, 17):
    sc.frame_set(f - 1)
    bpy.context.view_layer.update()
    w = (dst_arm.matrix_world @ hand.matrix).to_translation()
    print("F %02d srcframe=%d hand=(%.4f, %.4f, %.4f) act=%s slot=%s" % (
        f, f - 1, w.x, w.y, w.z, adA.action.name if adA.action else None,
        "OK" if adA.action_slot else "None"))
print("REPRO_DONE")
