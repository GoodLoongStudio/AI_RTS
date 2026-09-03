# -*- coding: utf-8 -*-
# 骨名去 mixamorig: 前缀（Godot SkeletonProfileHumanoid 标准裸名）
import pathlib

p = pathlib.Path(r"G:\AIRTS\AI_RTS\初选素材包\绑骨管线\rig_463_chr00.py")
c = p.read_text(encoding="utf-8")
c = c.replace('"mixamorig:', '"')
old_parent = 'eb.parent = name_to_eb["mixamorig:" + parent_name] if not parent_name.startswith("mixamorig") else name_to_eb[parent_name]'
c = c.replace(old_parent, "eb.parent = name_to_eb[parent_name]")
c = c.replace("MixamoRig", "HumanoidRig")
p.write_text(c, encoding="utf-8")
left = c.count("mixamorig:")
print("patched, mixamorig 残留:", left)
