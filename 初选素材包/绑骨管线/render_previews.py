# Blender headless: batch render 4006 rigged characters (texture + pose)
import bpy
import math
from mathutils import Vector, Euler
from pathlib import Path

ROOT = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006")
OUT = ROOT / "效果预览"
OUT.mkdir(parents=True, exist_ok=True)
TARGETS = [
    (ROOT / "Characters" / "Chr_SM_Chr_ScifiWorlds_Soldier_Male_01_rigged.fbx", "Soldier_Male"),
    (ROOT / "Characters" / "Chr_SM_Chr_ScifiWorlds_SpaceSuit_Male_01_rigged.fbx", "SpaceSuit_Male"),
    (ROOT / "Characters" / "Chr_SM_Chr_ScifiWorlds_Scavenger_01_rigged.fbx", "Scavenger"),
    (ROOT / "BR_Characters" / "Chr_SM_Chr_ScifiWorlds_AlienChef_01_rigged.fbx", "AlienChef"),
]


def render_one(fbx, tag, idx):
    scene = bpy.context.scene
    for o in list(scene.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.import_scene.fbx(filepath=str(fbx))
    mesh = next(o for o in scene.objects if o.type == "MESH")
    arm = next(o for o in scene.objects if o.type == "ARMATURE")

    bpy.context.view_layer.objects.active = mesh
    mesh.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
    zs = [c.z for c in corners]
    xs = [c.x for c in corners]
    ys = [c.y for c in corners]
    z_min, z_max = min(zs), max(zs)
    h = z_max - z_min
    cx = (max(xs) + min(xs)) / 2.0
    cy = (max(ys) + min(ys)) / 2.0

    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="POSE")
    pb = arm.pose.bones
    def rot(name, x, y, z):
        b = pb.get(name)
        if b:
            b.rotation_mode = "XYZ"
            b.rotation_euler = Euler((math.radians(x), math.radians(y), math.radians(z)), "XYZ")
    rot("RightArm", -50, 0, 0)
    
    
    rot("LeftForeArm", 0, -25, 0)
    rot("Head", 0, 0, -12)
    bpy.ops.object.mode_set(mode="OBJECT")

    arm.visible_camera = True

    scene.render.engine = "BLENDER_WORKBENCH"
    scene.display.shading.light = "STUDIO"
    scene.display.shading.color_type = "TEXTURE"
    scene.render.resolution_x = 720
    scene.render.resolution_y = 720
    scene.render.filepath = str(OUT / (str(idx).zfill(2) + "_" + tag + ".png"))
    cam_data = bpy.data.cameras.new("Cam")
    cam_obj = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam_obj)
    cam_obj.location = (cx + 1.7, cy - 2.1, z_min + h * 0.66)
    cam_obj.rotation_euler = (Vector((cx, cy, z_min + h * 0.55)) - cam_obj.location).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam_obj
    bpy.ops.render.render(write_still=True)
    print("RENDERED", tag)


def main():
    for i, (fbx, tag) in enumerate(TARGETS):
        if fbx.exists():
            render_one(fbx, tag, i + 1)
        else:
            print("MISSING", fbx.name)
    print("ALL_PREVIEW_DONE")


main()
