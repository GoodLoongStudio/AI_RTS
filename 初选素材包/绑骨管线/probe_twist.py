# -*- coding: utf-8 -*-
# 膝角对比: 烘焙成品(retargeted_baked.blend 的 Attack) vs UAL 源自身同动作
import bpy, math
from mathutils import Vector

BLEND = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\retargeted_baked.blend"
bpy.ops.wm.open_mainfile(filepath=BLEND)
dst_arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
sc = bpy.context.scene
dpb = dst_arm.pose.bones

def knee(up_name, lo_name):
    up = dpb[up_name]
    lo = dpb[lo_name]
    vu = (up.matrix.to_3x3() @ Vector((0, 1, 0))).normalized()
    vl = (lo.matrix.to_3x3() @ Vector((0, 1, 0))).normalized()
    return math.degrees(vu.angle(vl)), vu.cross(vl)

ad = dst_arm.animation_data or dst_arm.animation_data_create()
act = bpy.data.actions.get("Attack")
ad.action = act
if act.slots:
    ad.action_slot = act.slots[0]

print("### 烘焙成品 Attack 膝角 (源自身为 52~90° 深弯) ###")
for f in range(1, 37, 6):
    sc.frame_set(f)
    bpy.context.view_layer.update()
    aL, nL = knee("LeftUpLeg", "LeftLeg")
    aR, nR = knee("RightUpLeg", "RightLeg")
    nLz = (dst_arm.matrix_world.to_3x3() @ nL).z if nL.length > 0.1 else 0
    nRz = (dst_arm.matrix_world.to_3x3() @ nR).z if nR.length > 0.1 else 0
    print("f%-3d L 弯%.0f° | R 弯%.0f°" % (f, aL, aR))

# 左臂肘角 (参考)
print("### 肘角 ###")
for f in range(1, 37, 6):
    sc.frame_set(f)
    bpy.context.view_layer.update()
    for side in ("Left", "Right"):
        up = dpb[side + "Arm"]
        lo = dpb[side + "ForeArm"]
        vu = (up.matrix.to_3x3() @ Vector((0, 1, 0))).normalized()
        vl = (lo.matrix.to_3x3() @ Vector((0, 1, 0))).normalized()
        print("f%-3d %s肘弯%.0f°" % (f, side, math.degrees(vu.angle(vl))))
print("BAKED_KNEE_DIAG_DONE")
