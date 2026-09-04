import bpy, math
from mathutils import Vector, Euler
from pathlib import Path
SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\BR_Characters\Chr_SM_Chr_ScifiWorlds_AlienChef_01_rigged.fbx"
OUT = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\AlienChef_preview.png")
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)
scene = bpy.context.scene
mesh = next(o for o in scene.objects if o.type == "MESH")
bpy.context.view_layer.objects.active = mesh
mesh.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
zs = [c.z for c in corners]
z_min, z_max = min(zs), max(zs)
h = z_max - z_min
cx = sum(c.x for c in corners) / 8.0
cy = sum(c.y for c in corners) / 8.0
arm = next(o for o in scene.objects if o.type == "ARMATURE")
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
b = arm.pose.bones.get("RightForeArm")
b.rotation_mode = "XYZ"
b.rotation_euler = Euler((0, math.radians(-80), 0), "XYZ")
bpy.ops.object.mode_set(mode="OBJECT")
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "TEXTURE"
scene.render.resolution_x = 700
scene.render.resolution_y = 700
scene.render.filepath = str(OUT)
cam_data = bpy.data.cameras.new("Cam")
cam_obj = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam_obj)
cam_obj.location = (cx + 1.9, cy - 2.3, z_min + h * 0.68)
cam_obj.rotation_euler = Euler((math.radians(76), 0, math.radians(39)), "XYZ")
scene.camera = cam_obj
bpy.ops.render.render(write_still=True)
print("PREVIEW_DONE")