# Blender headless: 4006 科幻角色批量拆分+绑骨+贴图嵌入
# 运行: blender.exe -b -P batch_rig_4006.py
import bpy
import math
from mathutils import Vector, Euler
from pathlib import Path

ROLE_DIR = Path(r"G:\AIRTS\AI_RTS\初选素材包\提炼_科幻战争与角色\人物角色\4006_科幻角色")
OUT_DIR = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\4006")
TEX_DIR = Path(r"G:\AIRTS\AI_RTS\初选素材包\提炼_科幻战争与角色\贴图图集\4006_科幻世界")

# 4006 材质/mesh 级贴图映射（来自 unitypackage 解析 + 实验）
MATERIAL_TEX = {
    "Scifi_1a9": TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_01_A.png",
    "ScifiWorlds_MAT": TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_03_C.png",
}
MESH_TEX = {
    "SpaceSuit_Alien": TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_02_C.png",
    "Scavenger_02": TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_03_C.png",
    "Scavenger_03": TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_03_C.png",
}
DEFAULT_TEX = TEX_DIR / "PolygonSciFiWorlds/Models/PolygonScifiWorlds_Texture_01_A.png"

# Mixamo 标准人形骨架（Z-up，身高比例 0..1）
SKELETON = [
    ("Hips",              None,    0.000,  0.000, 0.555),
    ("Spine",             "Hips",  0.000,  0.000, 0.622),
    ("Spine1",            "Spine", 0.000,  0.000, 0.700),
    ("Spine2",            "Spine1", 0.000, 0.000, 0.778),
    ("Neck",              "Spine2", 0.000, 0.000, 0.845),
    ("Head",              "Neck",  0.000,  0.000, 0.900),
    ("HeadTop_End",       "Head",  0.000,  0.000, 1.000),
    ("LeftShoulder",      "Spine2", -0.044, 0.000, 0.817),
    ("LeftArm",           "LeftShoulder", -0.106, 0.000, 0.800),
    ("LeftForeArm",       "LeftArm", -0.244, 0.000, 0.800),
    ("LeftHand",          "LeftForeArm", -0.383, 0.000, 0.800),
    ("RightShoulder",     "Spine2", 0.044, 0.000, 0.817),
    ("RightArm",          "RightShoulder", 0.106, 0.000, 0.800),
    ("RightForeArm",      "RightArm", 0.244, 0.000, 0.800),
    ("RightHand",         "RightForeArm", 0.383, 0.000, 0.800),
    ("LeftUpLeg",         "Hips",  -0.055, 0.000, 0.528),
    ("LeftLeg",           "LeftUpLeg", -0.055, 0.000, 0.289),
    ("LeftFoot",          "LeftLeg", -0.055, 0.000, 0.050),
    ("LeftToeBase",       "LeftFoot", -0.055, 0.044, 0.011),
    ("RightUpLeg",        "Hips",  0.055,  0.000, 0.528),
    ("RightLeg",          "RightUpLeg", 0.055, 0.000, 0.289),
    ("RightFoot",         "RightLeg", 0.055,  0.000, 0.050),
    ("RightToeBase",      "RightFoot", 0.055, 0.044, 0.011),
]
LEAF_TAIL = {
    "HeadTop_End": Vector((0, 0, 0.03)),
    "LeftHand": Vector((-0.05, 0, 0)),
    "RightHand": Vector((0.05, 0, 0)),
    "LeftToeBase": Vector((0, 0.03, 0)),
    "RightToeBase": Vector((0, 0.03, 0)),
}


def build_armature(mesh, out_fbx: Path):
    scene = bpy.context.scene
    bpy.context.view_layer.objects.active = mesh
    mesh.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    corners = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
    xs = [c.x for c in corners]
    ys = [c.y for c in corners]
    zs = [c.z for c in corners]
    cx = (max(xs) + min(xs)) / 2.0
    cy = (max(ys) + min(ys)) / 2.0
    z_min, z_max = min(zs), max(zs)
    h = z_max - z_min
    if h < 0.3 or h > 3.5:
        print("SKIP_SIZE", mesh.name, "h=%.2f" % h)
        return None

    arm_data = bpy.data.armatures.new("HumanoidRig")
    arm = bpy.data.objects.new("HumanoidRig", arm_data)
    scene.collection.objects.link(arm)
    arm.location = (cx, cy, z_min)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    ebs = arm_data.edit_bones
    eb_map = {}
    for name, parent, px, py, pz in SKELETON:
        eb = ebs.new(name)
        eb.head = Vector((cx + px * h, cy + py * h, z_min + pz * h))
        eb_map[name] = eb
    for name, parent, px, py, pz in SKELETON:
        eb = eb_map[name]
        children = [c for c in SKELETON if c[1] == name]
        if children:
            eb.tail = eb_map[children[0][0]].head.copy()
        else:
            off = LEAF_TAIL.get(name, Vector((0, 0, 0.03)))
            eb.tail = eb.head + off
        if parent:
            eb.parent = eb_map[parent]
            eb.use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")

    bpy.ops.object.select_all(action="DESELECT")
    mesh.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")

    unw = sum(1 for v in mesh.data.vertices if len(v.groups) == 0)
    print("SKIN", mesh.name, "verts=%d unweighted=%d bones=%d" % (
        len(mesh.data.vertices), unw, len(arm_data.bones)))

    # 材质贴图：按材质名/mesh 名挂 albedo
    for slot in mesh.material_slots:
        mat = slot.material
        if mat is None or not mat.use_nodes:
            continue
        tex_path = None
        for key, tp in MESH_TEX.items():
            if key in mesh.name:
                tex_path = tp
                break
        if tex_path is None:
            tex_path = MATERIAL_TEX.get(mat.name, DEFAULT_TEX)
        if not Path(str(tex_path)).exists():
            tex_path = DEFAULT_TEX
        bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf is None:
            continue
        img = bpy.data.images.load(str(tex_path), check_existing=True)
        tex_node = mat.node_tree.nodes.new("ShaderNodeTexImage")
        tex_node.image = img
        mat.node_tree.links.new(tex_node.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs['Roughness'].default_value = 0.9
    return arm


def export_rigged(mesh, arm, out_fbx: Path):
    bpy.ops.object.select_all(action="DESELECT")
    mesh.select_set(True)
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.export_scene.fbx(
        filepath=str(out_fbx),
        use_selection=True,
        add_leaf_bones=False,
        bake_anim=False,
        object_types={"ARMATURE", "MESH"},
        path_mode="COPY",
        embed_textures=True,
        mesh_smooth_type="OFF",
    )


def process_collection(fbx_path: Path):
    scene = bpy.context.scene
    for o in list(scene.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.import_scene.fbx(filepath=str(fbx_path))
    meshes = [o for o in scene.objects if o.type == "MESH"]
    print("COLLECTION", fbx_path.name, "meshes=", len(meshes))
    out_sub = OUT_DIR / fbx_path.stem
    out_sub.mkdir(parents=True, exist_ok=True)
    ok, skip = 0, 0
    for keep in meshes:
        others = [o for o in scene.objects if o.type == "MESH" and o != keep]
        for o in others:
            scene.collection.objects.unlink(o)
        keep.name = "Chr_" + keep.name
        arm = build_armature(keep, out_sub / (keep.name + "_rigged.fbx"))
        if arm is not None:
            export_rigged(keep, arm, out_sub / (keep.name + "_rigged.fbx"))
            ok += 1
        else:
            skip += 1
        if arm is not None:
            arm_data_ref = arm.data
            mesh_data_ref = keep.data
            bpy.data.objects.remove(arm, do_unlink=True)
            bpy.data.armatures.remove(arm_data_ref)
            bpy.data.objects.remove(keep, do_unlink=True)
            bpy.data.meshes.remove(mesh_data_ref)
        else:
            mesh_data_ref = keep.data
            bpy.data.objects.remove(keep, do_unlink=True)
            bpy.data.meshes.remove(mesh_data_ref)
        for o in others:
            scene.collection.objects.link(o)
    print("COLLECTION_DONE", fbx_path.name, "ok=", ok, "skip=", skip)


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for fbx in [ROLE_DIR / "Characters.fbx", ROLE_DIR / "BR_Characters.fbx"]:
        if fbx.exists():
            process_collection(fbx)
    print("BATCH_DONE")


main()
