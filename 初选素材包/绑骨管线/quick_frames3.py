# -*- coding: utf-8 -*-
# v3: 逐帧直接设 pose 渲染(不用 keyframe, 规避 Blender5.0 slotted action 求值问题)
import bpy, sys, math
from math import radians, sin, cos, pi
from mathutils import Euler, Vector
from pathlib import Path
import bmesh

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUTD = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\抽帧3")
OUTD.mkdir(parents=True, exist_ok=True)
frames = [1, 15, 30, 45, 70, 80, 90, 110, 118, 134, 141, 150, 175, 190, 208]
argv = sys.argv
if "--" in argv:
    tail = argv[argv.index("--") + 1:]
    if tail:
        frames = [int(x) for x in tail[0].split(",")]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "TEXTURE"
sc.render.resolution_x = 400
sc.render.resolution_y = 520
arm = next(o for o in sc.objects if o.type == "ARMATURE")
mesh = next(o for o in sc.objects if o.type == "MESH")
corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
cx = sum(c.x for c in corners) / 8.0
cy = sum(c.y for c in corners) / 8.0
w = bpy.data.worlds.new("W")
w.color = (0.78, 0.78, 0.80)
sc.world = w
g_mesh = bpy.data.meshes.new("Ground")
g_obj = bpy.data.objects.new("Ground", g_mesh)
sc.collection.objects.link(g_obj)
bm = bmesh.new()
bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=4.0)
bm.to_mesh(g_mesh)
bm.free()
g_mat = bpy.data.materials.new("GroundMat")
g_mat.use_nodes = True
next(n for n in g_mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)
g_obj.data.materials.append(g_mat)
g_obj.location = (cx, cy, -0.001)
cam_d = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_d)
sc.collection.objects.link(cam)
cam.location = (cx + 2.4, cy - 2.9, 1.15)
cam.rotation_euler = (Vector((cx, cy, 0.95)) - cam.location).to_track_quat("-Z", "Y").to_euler()
sc.camera = cam

bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
pb = arm.pose.bones
for b in pb:
    b.rotation_mode = "XYZ"

LA_DOWN = -90.0
RA_DOWN = -90.0

def pose_at(f):
    d = {}
    def R(n, x=0.0, y=0.0, z=0.0):
        d[n] = (x, y, z)
    if f <= 60:
        t = (f - 1) / 60.0 * 2 * pi
        s = sin(t)
        R("LeftArm", x=LA_DOWN, z=8 * s)
        R("RightArm", x=RA_DOWN, z=-8 * s)
        R("LeftForeArm", x=-12 - 4 * s)
        R("RightForeArm", x=-12 + 4 * s)
        R("Spine", x=2.0 * sin(t))
        R("Hips", x=1.2 * sin(t))
        R("Head", z=4 * sin(t / 2))
        return d, 0.0
    elif f <= 100:
        t = (f - 61) / 40.0 * 2 * pi
        s = sin(t)
        s2 = sin((f - 63) / 40.0 * 2 * pi)
        R("LeftUpLeg", x=36 * s)
        R("RightUpLeg", x=-36 * s)
        R("LeftLeg", x=max(0.0, -28 * cos(t)))
        R("RightLeg", x=max(0.0, 28 * cos(t)))
        R("LeftArm", x=LA_DOWN + 26 * s2)
        R("RightArm", x=RA_DOWN + 26 * s2)
        R("LeftForeArm", x=-18)
        R("RightForeArm", x=-18)
        R("Hips", z=3.5 * s)
        return d, 0.018 * abs(s) - 0.009
    elif f <= 124:
        t = (f - 101) / 24.0 * 2 * pi
        s = sin(t)
        R("LeftUpLeg", x=52 * s - 12)
        R("RightUpLeg", x=-52 * s - 12)
        R("LeftLeg", x=max(0.0, -48 * cos(t)))
        R("RightLeg", x=max(0.0, 48 * cos(t)))
        R("LeftArm", x=LA_DOWN + 38 * s)
        R("RightArm", x=RA_DOWN + 38 * s)
        R("LeftForeArm", x=-72)
        R("RightForeArm", x=-72)
        R("Spine2", x=14)
        return d, 0.032 * abs(s)
    elif f <= 160:
        for fa, fb in [(125, 134), (134, 141), (141, 150), (150, 160)]:
            pass
        ATK = [(125, -90, -20, 0), (134, -135, -70, -20), (141, 15, -10, 26), (150, -30, -40, 12), (160, -90, -20, 0)]
        best = ATK[0]
        for a, b2 in zip(ATK, ATK[1:]):
            if a[0] <= f <= b2[0]:
                tt = (f - a[0]) / (b2[0] - a[0])
                best = tuple(a[i] + (b2[i] - a[i]) * tt for i in range(4))
                break
        R("RightArm", x=best[1])
        R("RightForeArm", x=best[2])
        R("Spine2", z=best[3])
        return d, 0.0
    else:
        t = min(1.0, max(0.0, (f - 163) / 22.0))
        e = t * t * (3 - 2 * t)
        R("Hips", x=-86 * e)
        R("LeftUpLeg", x=28 * e)
        R("RightUpLeg", x=14 * e)
        ta = min(1.0, max(0.0, (f - 168) / 20.0))
        ea = ta * ta * (3 - 2 * ta)
        R("LeftArm", x=LA_DOWN - 52 * ea, z=34 * ea)
        R("RightArm", x=RA_DOWN - 38 * ea, z=-34 * ea)
        return d, -0.52 * e


for f in frames:
    d, hz = pose_at(f)
    for n, (x, y, z) in d.items():
        b = pb.get(n)
        if b:
            b.rotation_euler = Euler((radians(x), radians(y), radians(z)), "XYZ")
    h = pb["Hips"]
    h.location = Vector((0.0, 0.0, hz))
    sc.frame_set(f)
    sc.render.filepath = str(OUTD / ("v%03d.png" % f))
    bpy.ops.render.render(write_still=True)
print("V3_FRAMES_DONE", frames)
