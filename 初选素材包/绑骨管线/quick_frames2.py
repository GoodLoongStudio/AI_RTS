# -*- coding: utf-8 -*-
# Blender headless: 关键帧快渲 v2 - 手臂垂下基准 + 地面
import bpy, sys, math
from math import radians, sin, cos, pi
from mathutils import Euler, Vector
from pathlib import Path
import bmesh

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUTD = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\抽帧2")
OUTD.mkdir(parents=True, exist_ok=True)
argv = sys.argv
frames = [1, 15, 30, 45, 70, 80, 90, 110, 118, 134, 141, 150, 175, 190, 208]
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
sc.frame_start = 1
sc.frame_end = 208
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

def rot(n, f, x=0.0, y=0.0, z=0.0):
    b = pb.get(n)
    if b:
        b.rotation_euler = Euler((radians(x), radians(y), radians(z)), "XYZ")
        b.keyframe_insert("rotation_euler", frame=f)

def hz(f, dz):
    h = pb["Hips"]
    h.location = Vector((0.0, 0.0, dz))
    h.keyframe_insert("location", frame=f)

LA, RA = -90.0, 90.0

# Idle 1-60: 垂臂微摆 + 呼吸
for f in range(1, 62):
    t = (f - 1) / 60.0 * 2 * pi
    s = sin(t)
    rot("LeftArm", f, x=LA, z=6 * s)
    rot("RightArm", f, x=RA, z=-6 * s)
    rot("LeftForeArm", f, x=-12 - 4 * s)
    rot("RightForeArm", f, x=-12 + 4 * s)
    rot("Spine", f, x=2.0 * sin(t))
    rot("Hips", f, x=1.2 * sin(t))
    rot("Head", f, z=4 * sin(t / 2))

# Walk 61-100: 垂臂前后摆(延迟2帧) + 腿摆膝弯 + 骨盆扭
for f in range(61, 102):
    t = (f - 61) / 40.0 * 2 * pi
    s = sin(t)
    s2 = sin((f - 63) / 40.0 * 2 * pi)
    rot("LeftUpLeg", f, x=36 * s)
    rot("RightUpLeg", f, x=-36 * s)
    rot("LeftLeg", f, x=max(0.0, -28 * cos(t)))
    rot("RightLeg", f, x=max(0.0, 28 * cos(t)))
    rot("LeftArm", f, x=LA, x=-26 * s2)
    rot("RightArm", f, x=RA, x=26 * s2)
    rot("LeftForeArm", f, x=-18)
    rot("RightForeArm", f, x=-18)
    rot("Hips", f, z=3.5 * s)
    hz(f, 0.018 * abs(s) - 0.009)
print("PART1_OK")
# Run 101-124: 大步 + 前倾 + 屈臂摆 + 腾空
for f in range(101, 125):
    t = (f - 101) / 24.0 * 2 * pi
    s = sin(t)
    rot("LeftUpLeg", f, x=52 * s - 12)
    rot("RightUpLeg", f, x=-52 * s - 12)
    rot("LeftLeg", f, x=max(0.0, -48 * cos(t)))
    rot("RightLeg", f, x=max(0.0, 48 * cos(t)))
    rot("LeftArm", f, x=LA, x=-38 * s)
    rot("RightArm", f, x=RA, x=38 * s)
    rot("LeftForeArm", f, x=-72)
    rot("RightForeArm", f, x=-72)
    rot("Spine2", f, x=14)
    hz(f, 0.032 * abs(s))

# Attack 125-160: 垂臂后摆蓄力 -> 前劈 -> 缓冲
for f, ax, fy, sz in [(125, 90, -20, 0),
                      (134, 45, -60, -20),
                      (141, -25, -10, 26),
                      (150, 65, -40, 12),
                      (160, 90, -20, 0)]:
    rot("RightArm", f, x=ax)
    rot("RightForeArm", f, x=fy)
    rot("Spine2", f, z=sz)

# Death 161-208: 后仰倒地(下沉贴地) + 四肢延迟摊开
for f in range(161, 209):
    t = min(1.0, max(0.0, (f - 163) / 22.0))
    e = t * t * (3 - 2 * t)
    rot("Hips", f, x=-86 * e)
    hz(f, -0.52 * e)
    rot("LeftUpLeg", f, x=28 * e)
    rot("RightUpLeg", f, x=14 * e)
    ta = min(1.0, max(0.0, (f - 168) / 20.0))
    ea = ta * ta * (3 - 2 * ta)
    rot("LeftArm", f, x=LA, x=-52 * ea, z=34 * ea)
    rot("RightArm", f, x=RA, x=-38 * ea, z=-34 * ea)

for f in frames:
    sc.frame_set(f)
    sc.render.filepath = str(OUTD / ("q%03d.png" % f))
    bpy.ops.render.render(write_still=True)
print("QUICK2_FRAMES_DONE", frames)
