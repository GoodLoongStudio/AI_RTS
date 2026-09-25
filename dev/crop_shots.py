# -*- coding: utf-8 -*-
"""裁剪 before/after 截图的小地图区域并放大，便于目视对比。"""
import os
import sys

from PIL import Image

base = os.path.join(os.environ["APPDATA"], "Godot", "app_userdata", "Open RTS",
                    "tmp_logs", "enemy_death_visual")
before = Image.open(os.path.join(base, "before_destroy.png")).convert("RGB")
after = Image.open(os.path.join(base, "after_destroy.png")).convert("RGB")
print("size:", before.size)

# 小地图在右上角侧栏顶部：按比例取右上区域
w, h = before.size
# 侧栏约占右侧 30%；小地图在侧栏顶部
box = (int(w * 0.70), int(h * 0.02), int(w * 0.99), int(h * 0.20))
crop_b = before.crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.NEAREST)
crop_a = after.crop(box).resize(((box[2] - box[0]) * 2, (box[3] - box[1]) * 2), Image.NEAREST)
crop_b.save(os.path.join(base, "minimap_before.png"))
crop_a.save(os.path.join(base, "minimap_after.png"))

# 整幅世界区域（左侧 70%）也裁一份放大对比
world_box = (0, int(h * 0.10), int(w * 0.68), int(h * 0.85))
wb = before.crop(world_box)
wa = after.crop(world_box)
wb.save(os.path.join(base, "world_before.png"))
wa.save(os.path.join(base, "world_after.png"))
print("saved crops")
