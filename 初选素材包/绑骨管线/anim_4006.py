import bpy, math
from math import radians, sin, cos, pi
from mathutils import Euler, Vector
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\Characters\Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx"
OUTD = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006\动画帧")
OUTD.mkdir(parents=True, exist_ok=True)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "TEXTURE"
sc.render.resolution_x = 360
sc.render.resolution_y = 480
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
w = bpy.data.worlds.new("W")
w.color = (0.78, 0.78, 0.80)
sc.world = w
g_mesh = bpy.data.meshes.new("G")
g_obj = bpy.data.objects.new("G", g_mesh)
sc.collection.objects.link(g_obj)
import bmesh
bm = bmesh.new()
bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=4.0)
bm.to_mesh(g_mesh)
bm.free()
g_mat = bpy.data.materials.new("GM")
g_mat.use_nodes = True
next(n2 for n2 in g_mat.node_tree.nodes if n2.type == "BSDF_PRINCIPLED").inputs["Base Color"].default_value = (0.62, 0.60, 0.57, 1)
g_obj.data.materials.append(g_mat)
g_obj.location = (cx, cy, -0.001)
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

# Idle 1-60
for f in range(1, 62):
    t = (f - 1) / 60.0 * 2 * pi
    rot("Hips", f, x=1.5 * sin(t))
    rot("Spine", f, x=2.5 * sin(t))
    rot("LeftArm", f, z=10 * sin(t))
    rot("RightArm", f, z=10 * sin(t))
    rot("LeftForeArm", f, x=8 * sin(t))
    rot("RightForeArm", f, x=-8 * sin(t))
    rot("Head", f, z=5 * sin(t / 2))

# Walk 61-100
for f in range(61, 102):
    t = (f - 61) / 40.0 * 2 * pi
    s = sin(t)
    rot("LeftUpLeg", f, x=38 * s)
    rot("RightUpLeg", f, x=-38 * s)
    rot("LeftLeg", f, x=max(0.0, -30 * cos(t)))
    rot("RightLeg", f, x=max(0.0, 30 * cos(t)))
    rot("LeftArm", f, x=-30 * s)
    rot("RightArm", f, x=30 * s)
    rot("LeftForeArm", f, x=-18)
    rot("RightForeArm", f, x=-18)
    hz(f, 0.02 * abs(s) - 0.01)

# Run 101-124
for f in range(101, 125):
    t = (f - 101) / 24.0 * 2 * pi
    s = sin(t)
    rot("LeftUpLeg", f, x=55 * s - 10)
    rot("RightUpLeg", f, x=-55 * s - 10)
    rot("LeftLeg", f, x=max(0.0, -50 * cos(t)))
    rot("RightLeg", f, x=max(0.0, 50 * cos(t)))
    rot("LeftArm", f, x=-30 * s)
    rot("RightArm", f, x=30 * s)
    rot("LeftForeArm", f, x=-70)
    rot("RightForeArm", f, x=-70)
    rot("Spine2", f, x=14)
    hz(f, 0.035 * abs(s))

# Attack 125-160
for f, ay, az, fy, sz in [(125,0,0,0,0),(134,-100,-15,-35,-18),(141,45,20,-15,25),(152,25,10,-25,10),(160,0,0,0,0)]:
    rot("RightArm", f, y=ay, z=az)
    rot("RightForeArm", f, y=fy)
    rot("Spine2", f, z=sz)

# Death 161-208
for f in range(161, 209):
    t = min(1.0, max(0.0, (f - 163) / 22.0))
    e = t * t * (3 - 2 * t)
    rot("Hips", f, x=-88 * e)
    hz(f, -0.42 * e)
    rot("LeftUpLeg", f, x=30 * e)
    rot("RightUpLeg", f, x=15 * e)
    rot("LeftArm", f, x=-60 * e, z=30 * e)
    rot("RightArm", f, x=-40 * e, z=-30 * e)

for f in range(1, 209):
    sc.frame_set(f)
    sc.render.filepath = str(OUTD / ("f%03d.png" % f))
    bpy.ops.render.render(write_still=True)
print("ANIM_FRAMES_DONE")
