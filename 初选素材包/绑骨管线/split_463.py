# Blender headless: 拆分 463 角色合集为单角色 FBX
# 运行: blender.exe -b -P split_463.py
import bpy
from pathlib import Path

SRC = r"G:\AIRTS\AI_RTS\初选素材包\提炼_科幻战争与角色\人物角色\463_幸存者与僵尸\Characters.fbx"
OUT = Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\463\拆分")
OUT.mkdir(parents=True, exist_ok=True)

# 清场
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=SRC)

scene = bpy.context.scene
meshes = [o for o in scene.objects if o.type == "MESH"]
print("MESH_COUNT", len(meshes))

total_w = 0.0
for m in meshes:
    total_w += 1.0

imported = []
for idx, keep in enumerate(meshes):
    others = [o for o in scene.objects if o.type == "MESH" and o != keep]
    for o in others:
        scene.collection.objects.unlink(o)
    # 干净名
    keep.name = f"Chr_{idx:02d}"
    bbox = keep.bound_box
    xs = [v[0] for v in bbox]
    ys = [v[1] for v in bbox]
    zs = [v[2] for v in bbox]
    size = (max(xs) - min(xs), max(ys) - min(ys), max(zs) - min(zs))
    out = OUT / f"{keep.name}_{meshes.index(keep):02d}.fbx"
    bpy.ops.export_scene.fbx(
        filepath=str(out),
        use_selection=True,
        add_leaf_bones=False,
        bake_anim=False,
        object_types={"MESH"},
    )
    imported.append(out.name)
    print("EXPORTED", out.name, "size=%.2fx%.2fx%.2f" % size)
    for o in others:
        scene.collection.objects.link(o)

print("SPLIT_DONE", len(imported))
