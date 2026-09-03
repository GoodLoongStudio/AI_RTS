# Blender headless: 试点角色自动绑骨（Mixamo 标准骨架 + 热权重蒙皮）
# 运行: blender.exe -b -P rig_463_chr00.py
import bpy
import math
from mathutils import Vector
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\463\拆分\Chr_00_00.fbx"
OUT_DIR = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\463\绑定")
OUT_DIR.mkdir(parents=True, exist_ok=True)
OUT_FBX = OUT_DIR / "Chr_00_rigged.fbx"
OUT_PNG = OUT_DIR / "Chr_00_preview.png"

# 清场
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

scene = bpy.context.scene
meshes = [o for o in scene.objects if o.type == "MESH"]
assert len(meshes) == 1, f"expect 1 mesh, got {len(meshes)}"
mesh = meshes[0]

# 应用变换（把 Y-up→Z-up 的旋转烘焙进网格数据，网格变成世界坐标 Z-up、米、原点对齐）
bpy.context.view_layer.objects.active = mesh
mesh.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# 世界包围盒
corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
xs = [c.x for c in corners]
ys = [c.y for c in corners]
zs = [c.z for c in corners]
cx = (max(xs) + min(xs)) / 2.0
cy = (max(ys) + min(ys)) / 2.0
z_min, z_max = min(zs), max(zs)
H = z_max - z_min  # 身高
print("BBOX center=(%.2f,%.2f) H=%.3f arm_span=%.3f" % (cx, cy, H, max(xs) - min(xs)))

# Meshamo 标准骨架模板（T-pose，身高 1.8m，Z-up，米）
# (bone_name, parent_name, head_x, head_y, head_z)  相对 1.8m 高
T = [
    ("Hips",              None,   0.000,  0.000, 0.555),
    ("Spine",             "Hips", 0.000,  0.000, 0.622),
    ("Spine1",            "Spine", 0.000, 0.000, 0.700),
    ("Spine2",            "Spine1", 0.000, 0.000, 0.778),
    ("Neck",              "Spine2", 0.000, 0.000, 0.845),
    ("Head",              "Neck", 0.000,  0.000, 0.900),
    ("HeadTop_End",       "Head", 0.000,  0.000, 1.000),
    ("LeftShoulder",      "Spine2", -0.044, 0.000, 0.817),
    ("LeftArm",           "LeftShoulder", -0.106, 0.000, 0.800),
    ("LeftForeArm",       "LeftArm", -0.244, 0.000, 0.800),
    ("LeftHand",          "LeftForeArm", -0.383, 0.000, 0.800),
    ("RightShoulder",     "Spine2", 0.044, 0.000, 0.817),
    ("RightArm",          "RightShoulder", 0.106, 0.000, 0.800),
    ("RightForeArm",      "RightArm", 0.244, 0.000, 0.800),
    ("RightHand",         "RightForeArm", 0.383, 0.000, 0.800),
    ("LeftUpLeg",         "Hips", -0.055, 0.000, 0.528),
    ("LeftLeg",           "LeftUpLeg", -0.055, 0.000, 0.289),
    ("LeftFoot",          "LeftLeg", -0.055, 0.000, 0.050),
    ("LeftToeBase",       "LeftFoot", -0.055, 0.044, 0.011),
    ("RightUpLeg",        "Hips", 0.055, 0.000, 0.528),
    ("RightLeg",          "RightUpLeg", 0.055, 0.000, 0.289),
    ("RightFoot",         "RightLeg", 0.055, 0.000, 0.050),
    ("RightToeBase",      "RightFoot", 0.055, 0.044, 0.011),
]

scale = H / 1.0  # 模板 z 已按 1.0 表（表中 z 直接是身高比例）
arm_data = bpy.data.armatures.new("HumanoidRig")
arm_obj = bpy.data.objects.new("HumanoidRig", arm_data)
scene.collection.objects.link(arm_obj)
arm_obj.location = (cx, cy, z_min)  # 骨架原点对齐网格脚底中心

bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.mode_set(mode="EDIT")
edit_bones = arm_data.edit_bones
name_to_eb = {}
for bone_name, parent_name, px, py, pz in T:
    eb = edit_bones.new(bone_name)
    # 模板 z 是身高比例(0..1)，乘 H；x/y 是绝对比例乘 H
    hx = cx + px * H
    hy = cy + py * H
    hz = z_min + pz * H
    eb.head = Vector((hx, hy, hz))
    name_to_eb[bone_name] = eb

# 设置 tail 与父子（head=自身，tail=子级或延伸方向）
LEAF_TAIL = {
    "HeadTop_End": Vector((0, 0, 0.03)),
    "LeftHand": Vector((-0.05, 0, 0)),
    "RightHand": Vector((0.05, 0, 0)),
    "LeftToeBase": Vector((0, 0.03, 0)),
    "RightToeBase": Vector((0, 0.03, 0)),
}
for bone_name, parent_name, px, py, pz in T:
    eb = name_to_eb[bone_name]
    children = [c for c in T if c[1] == bone_name]
    if children:
        cname = children[0][0]
        eb.tail = name_to_eb[cname].head.copy()
    else:
        off = LEAF_TAIL.get(bone_name, Vector((0, 0, 0.03 * H / 1.0)))
        eb.tail = eb.head + Vector((off.x * H / 1.0, off.y * H / 1.0, off.z * H / 1.0))
    if parent_name:
        eb.parent = name_to_eb["" + parent_name] if not parent_name.startswith("mixamorig") else name_to_eb[parent_name]
        # 用 connect 时 tail 会被吸附，这里保持手动位置
        eb.use_connect = False

bpy.ops.object.mode_set(mode="OBJECT")

# 热权重蒙皮：选 mesh，active=armature，parent_set AUTO
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
arm_obj.select_set(True)
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.object.parent_set(type="ARMATURE_AUTO")

# 统计权重
vg_no_weights = 0
total_vg = 0
for v in mesh.data.vertices:
    if len(v.groups) == 0:
        vg_no_weights += 1
    total_vg += 1
print("SKIN total_verts=%d unweighted=%d (%.1f%%)" % (total_vg, vg_no_weights, 100.0 * vg_no_weights / total_vg))
print("BONES", len(arm_data.bones))

# 导出绑定 FBX（Y-up 转换自动）
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
arm_obj.select_set(True)
bpy.context.view_layer.objects.active = arm_obj
bpy.ops.export_scene.fbx(
    filepath=str(OUT_FBX),
    use_selection=True,
    add_leaf_bones=False,
    bake_anim=False,
    object_types={"ARMATURE", "MESH"},
    mesh_smooth_type="OFF",
)
print("RIG_EXPORTED", OUT_FBX)

# 渲染预览图（Workbench，显示骨架）
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "SINGLE"
scene.display.shading.show_xray = True
scene.display.shading.xray_alpha = 0.7
scene.render.resolution_x = 800
scene.render.resolution_y = 800
scene.render.filepath = str(OUT_PNG)
# 相机
cam_data = bpy.data.cameras.new("Cam")
cam_obj = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam_obj)
cam_obj.location = (cx + 2.6, cy - 3.2, z_min + H * 0.72)
cam_obj.rotation_euler = (math.radians(78), 0, math.radians(39))
scene.camera = cam_obj
bpy.ops.render.render(write_still=True)
print("PREVIEW", OUT_PNG)
print("RIG_DONE")
