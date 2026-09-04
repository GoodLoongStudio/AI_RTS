# Blender headless: 只渲染指定关键帧（快速迭代用）
# 用法: blender -b -P quick_frames.py -- <帧号,逗号分隔>
import bpy
import sys
import math
from math import radians, sin, cos, pi
from mathutils import Euler, Vector
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUTD = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\抽帧")
OUTD.mkdir(parents=True, exist_ok=True)

# 解析帧号参数（-- 之后）
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
cam_d = bpy.data.cameras.new("Cam")
cam = bpy.data.objects.new("Cam", cam_d)
sc.collection.objects.link(cam)
cam.location = (cx + 3.0, cy + 0.35, 1.30)
cam.rotation_euler = Euler((radians(85), 0, radians(90)), "XYZ")
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


# ===== 动画定义（可调参数区）=====
P = {
    "idle_arm_z": 10, "idle_forearm": 8, "idle_spine": 2.5, "idle_hip": 1.5,
    "walk_leg": 38, "walk_knee": 30, "walk_arm": 30, "walk_bob": 0.02,
    "run_leg": 55, "run_knee": 50, "run_arm": 40, "run_forearm": -70,
    "run_lean": 14, "run_bob": 0.035, "run_lift": 10,
    "atk_windup": -100, "atk_strike": 45, "atk_settle": 25,
    "death_body": -88, "death_drop": 0.42,
}

# Idle 1-60
for f in range(1, 62):
    t = (f - 1) / 60.0 * 2 * pi
    rot("Hips", f, x=P["idle_hip"] * sin(t))
    rot("Spine", f, x=P["idle_spine"] * sin(t))
    rot("LeftArm", f, z=P["idle_arm_z"] * sin(t))
    rot("RightArm", f, z=P["idle_arm_z"] * sin(t))
    rot("LeftForeArm", f, x=P["idle_forearm"] * sin(t))
    rot("RightForeArm", f, x=-P["idle_forearm"] * sin(t))
    rot("Head", f, z=5 * sin(t / 2))

# Walk 61-100：腿摆 + 膝弯 + 手臂反相(延迟2帧) + 重心起伏 + 骨盆扭动
for f in range(61, 102):
    t = (f - 61) / 40.0 * 2 * pi
    s = sin(t)
    rot("LeftUpLeg", f, x=P["walk_leg"] * s)
    rot("RightUpLeg", f, x=-P["walk_leg"] * s)
    rot("LeftLeg", f, x=max(0.0, -P["walk_knee"] * cos(t)))
    rot("RightLeg", f, x=max(0.0, P["walk_knee"] * cos(t)))
    t2 = (f - 61 - 2) / 40.0 * 2 * pi  # 手臂延迟 2 帧
    s2 = sin(t2)
    rot("LeftArm", f, x=-P["walk_arm"] * s2)
    rot("RightArm", f, x=P["walk_arm"] * s2)
    rot("LeftForeArm", f, x=-15)
    rot("RightForeArm", f, x=-15)
    rot("Hips", f, z=3 * s)
    hz(f, P["walk_bob"] * abs(s) - P["walk_bob"] / 2)

# Run 101-124：更大步幅 + 前倾 + 屈臂 + 腾空抬升
for f in range(101, 125):
    t = (f - 101) / 24.0 * 2 * pi
    s = sin(t)
    rot("LeftUpLeg", f, x=P["run_leg"] * s - P["run_lift"])
    rot("RightUpLeg", f, x=-P["run_leg"] * s - P["run_lift"])
    rot("LeftLeg", f, x=max(0.0, -P["run_knee"] * cos(t)))
    rot("RightLeg", f, x=max(0.0, P["run_knee"] * cos(t)))
    rot("LeftArm", f, x=-P["run_arm"] * s)
    rot("RightArm", f, x=P["run_arm"] * s)
    rot("LeftForeArm", f, x=P["run_forearm"])
    rot("RightForeArm", f, x=P["run_forearm"])
    rot("Spine2", f, x=P["run_lean"])
    hz(f, P["run_bob"] * abs(s))

# Attack 125-160：蓄力(125-134) → 爆发(134-141) → 缓冲(141-160)
for f, ay, az, fy, sz in [(125, 0, 0, 0, 0),
                          (134, P["atk_windup"], -15, -35, -18),
                          (141, P["atk_strike"], 20, -15, 25),
                          (152, P["atk_settle"], 10, -25, 10),
                          (160, 0, 0, 0, 0)]:
    rot("RightArm", f, y=ay, z=az)
    rot("RightForeArm", f, y=fy)
    rot("Spine2", f, z=sz)

# Death 161-208：后仰倒地 + 四肢延迟摊开
for f in range(161, 209):
    t = min(1.0, max(0.0, (f - 163) / 22.0))
    e = t * t * (3 - 2 * t)
    rot("Hips", f, x=P["death_body"] * e)
    hz(f, -P["death_drop"] * e)
    rot("LeftUpLeg", f, x=30 * e)
    rot("RightUpLeg", f, x=15 * e)
    ta = min(1.0, max(0.0, (f - 168) / 20.0))
    ea = ta * ta * (3 - 2 * ta)
    rot("LeftArm", f, x=-60 * ea, z=30 * ea)
    rot("RightArm", f, x=-40 * ea, z=-30 * ea)

for f in frames:
    sc.frame_set(f)
    sc.render.filepath = str(OUTD / ("q%03d.png" % f))
    bpy.ops.render.render(write_still=True)
print("QUICK_FRAMES_DONE", frames)
