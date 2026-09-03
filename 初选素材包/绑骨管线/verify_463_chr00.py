# Blender headless: 验证绑骨——弯曲手臂/抬起大腿，渲染骨架+姿态图
import bpy
import math
from mathutils import Euler
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\463\绑定\Chr_00_rigged.fbx"
OUT_DIR = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\463\绑定")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

scene = bpy.context.scene
arm = next((o for o in scene.objects if o.type == "ARMATURE"), None)
mesh = next((o for o in scene.objects if o.type == "MESH"), None)
assert arm and mesh, "armature/mesh missing"
print("ARMATURE", arm.name, "bones=", len(arm.data.bones))

arm.visible_camera = True
arm.display_type = "WIRE"

bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
pb = arm.pose.bones
def rot(name, x, y, z):
    b = pb.get(name)
    if b:
        b.rotation_mode = "XYZ"
        b.rotation_euler = Euler((math.radians(x), math.radians(y), math.radians(z)), "XYZ")
        print("POSE", name)
rot("mixamorig:RightForeArm", 0, 75, 0)
rot("mixamorig:LeftUpLeg", -60, 0, 0)
rot("mixamorig:Head", 0, 0, -25)
bpy.ops.object.mode_set(mode="OBJECT")

scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "OBJECT"
mesh.color = (0.85, 0.55, 0.2, 1.0)
arm.color = (0.2, 0.5, 1.0, 1.0)
scene.display.shading.show_xray = True
scene.display.shading.xray_alpha = 0.55
scene.render.resolution_x = 800
scene.render.resolution_y = 800
scene.render.filepath = str(OUT_DIR / "Chr_00_pose_test.png")
cam_data = bpy.data.cameras.new("Cam")
cam_obj = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam_obj)
cam_obj.location = (2.6, -3.2, 1.28)
cam_obj.rotation_euler = Euler((math.radians(78), 0, math.radians(39)), "XYZ")
scene.camera = cam_obj
bpy.ops.render.render(write_still=True)
print("POSE_TEST_DONE")
