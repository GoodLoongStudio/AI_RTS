# -*- coding: utf-8 -*-
import bpy, math
from math import radians
from mathutils import Euler, Vector
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUTD = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\轴诊断")
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "TEXTURE"
sc.render.resolution_x = 300
sc.render.resolution_y = 400
w = bpy.data.worlds.new("W")
w.color = (0.78, 0.78, 0.80)
sc.world = w
g_mesh = bpy.data.meshes.new("G")
g_obj = bpy.data.objects.new("G", g_mesh)
sc.collection.objects.link(g_obj)
import bmesh
bm = bmesh.new()
bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=3.0)
bm.to_mesh(g_mesh)
bm.free()
arm = next(o for o in sc.objects if o.type == "ARMATURE")
mesh = next(o for o in sc.objects if o.type == "MESH")
corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
cx = sum(c.x for c in corners) / 8.0
cy = sum(c.y for c in corners) / 8.0
g_obj.location = (cx, cy, -0.001)
cam_d = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_d)
sc.collection.objects.link(cam)
cam.location = (cx + 2.2, cy - 2.6, 1.2)
cam.rotation_euler = (Vector((cx, cy, 0.95)) - cam.location).to_track_quat("-Z", "Y").to_euler()
sc.camera = cam
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
pb = arm.pose.bones
for b in pb:
    b.rotation_mode = "XYZ"
la = pb["LeftArm"]
TESTS = [("neg90", (-90.0, 0.0, 0.0)), ("neg90_z8", (-90.0, 0.0, 8.0)), ("pos90", (90.0, 0.0, 0.0))]
for tag, eul in TESTS:
    la.rotation_euler = Euler((radians(eul[0]), radians(eul[1]), radians(eul[2])), "XYZ")
    sc.frame_set(1)
    sc.render.filepath = str(OUTD / ("d3_%s.png" % tag))
    bpy.ops.render.render(write_still=True)
    print("D3", tag)
print("DIAG3_DONE")
