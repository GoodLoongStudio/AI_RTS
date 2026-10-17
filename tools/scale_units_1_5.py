# -*- coding: utf-8 -*-
"""炮塔三型 + 步兵三型 ×1.5（2026-09-30 用户口径）。

本脚本是**这次改动的可复现记录 + 幂等校验器**，不是"正则批量替换器"：
每一处改动都是一条**精确字符串**（含节点名/属性名上下文），逐条 apply/check。

用法：
    python tools/scale_units_1_5.py --check    # 校验工作树是否已是 ×1.5 状态（CI/复核用）
    python tools/scale_units_1_5.py --apply    # 对尚未生效的条目逐条精确替换（幂等）

四口径（视觉/碰撞/逻辑/carve）在同一张表里，避免只改一半：
  视觉   Geometry 根（含 DetachTransform 下的 Geometry —— PositionSynchronizer 是
         update_scale=false，缩放必须写在 Geometry 节点上）；
         步兵：Geometry 根 1.35 → 2.025；炮塔：给 Geometry 实例加 transform 1.5。
  碰撞   CollisionShape3D 的**形状资源** radius/height ×1.5（局部值；节点 scale 仍为 1），
         并给 sub_resource 加 resource_local_to_scene=true 唯一化（防止同场景多实例共享）。
  逻辑   Movement.radius / MovementObstacle.radius ×1.5（= E1 契约：本地碰撞 × root scale == 世界 footprint）。
  选圈   Highlight / Selection / Targetability 的 radius 与节点 origin ×1.5；
         HealthBar size 与 origin ×1.5；根级 Marker 锚点 origin ×1.5。
  例外   Geometry 子树内的 Marker（ProjectileOrigin/MuzzleL/MuzzleR）与世界米制的
         AnimationDriver.muzzle_offset：前者随父缩放自动 ×1.5，**不要**再乘一次；
         后者在 root 空间=世界米，需要显式 ×1.5（仅 Sniper 非零）。
"""
from __future__ import annotations

import argparse
import os
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
UNITS = "source/match/units"

# 步兵三型共用同一张表（Sniper 额外一条 muzzle_offset）。
INFANTRY = [
    ('[sub_resource type="CylinderShape3D" id="CylinderShape3D_inf"]\nheight = 1.08\nradius = 1.35',
     '[sub_resource type="CylinderShape3D" id="CylinderShape3D_inf"]\nresource_local_to_scene = true\nheight = 1.62\nradius = 2.025'),
    ('[node name="Geometry" type="Node3D" parent="."]\ntransform = Transform3D(1.35, 0, 0, 0, 1.35, 0, 0, 0, 1.35, 0, 0, 0)',
     '[node name="Geometry" type="Node3D" parent="."]\ntransform = Transform3D(2.025, 0, 0, 0, 2.025, 0, 0, 0, 2.025, 0, 0, 0)'),
    ('[node name="SelectionAnchor" type="Marker3D" parent="."]\ntransform = Transform3D(1.35, 0, 0, 0, 1.35, 0, 0, 0, 1.35, 0, 0.0675, 0)',
     '[node name="SelectionAnchor" type="Marker3D" parent="."]\ntransform = Transform3D(2.025, 0, 0, 0, 2.025, 0, 0, 0, 2.025, 0, 0.10125, 0)'),
    ('[node name="HealthBarAnchor" type="Marker3D" parent="."]\ntransform = Transform3D(1.35, 0, 0, 0, 1.35, 0, 0, 0, 1.35, 0, 1.08, 0)',
     '[node name="HealthBarAnchor" type="Marker3D" parent="."]\ntransform = Transform3D(2.025, 0, 0, 0, 2.025, 0, 0, 0, 2.025, 0, 1.62, 0)'),
    ('[node name="CollisionShape3D" type="CollisionShape3D" parent="."]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.27, 0)',
     '[node name="CollisionShape3D" type="CollisionShape3D" parent="."]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.405, 0)'),
    ('radius = 0.2835', 'radius = 0.42525'),
    ('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.0675, 0)',
     'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.10125, 0)'),
    ('radius = 1.35\nneighbor_distance = 2.0', 'radius = 2.025\nneighbor_distance = 2.0'),
    ('[node name="HealthBar" parent="." instance=ExtResource("5_healthbar")]\ntransform = Transform3D(1.35, 0, 0, 0, 1.35, 0, 0, 0, 1.35, 0, 1.08, 0)\nsize = Vector2(120, 8)',
     '[node name="HealthBar" parent="." instance=ExtResource("5_healthbar")]\ntransform = Transform3D(2.025, 0, 0, 0, 2.025, 0, 0, 0, 2.025, 0, 1.62, 0)\nsize = Vector2(180, 12)'),
]

# 炮塔三型：Geometry 实例的 ext_resource id、形状 id/半径、MovementObstacle 半径各不相同。
def turret_pairs(geometry_ext_id: str, shape_id: str, shape_radius_old: str, shape_radius_new: str,
                 obstacle_old: str, obstacle_new: str) -> list:
    return [
        ('id="%s"]\nheight = 3.2\nradius = %s\n' % (shape_id, shape_radius_old),
         'id="%s"]\nresource_local_to_scene = true\nheight = 4.8\nradius = %s\n' % (shape_id, shape_radius_new)),
        ('[node name="Geometry" parent="DetachTransform" instance=ExtResource("%s")]\n' % geometry_ext_id,
         '[node name="Geometry" parent="DetachTransform" instance=ExtResource("%s")]\ntransform = Transform3D(1.5, 0, 0, 0, 1.5, 0, 0, 0, 1.5, 0, 0, 0)\n' % geometry_ext_id),
        ('[node name="CollisionShape3D" type="CollisionShape3D" parent="."]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.8, 0)',
         '[node name="CollisionShape3D" type="CollisionShape3D" parent="."]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.2, 0)'),
        ('radius = 1.2', 'radius = 1.8'),
        ('transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.1, 0)',
         'transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0.15, 0)'),
        ('size = Vector2(110, 10)', 'size = Vector2(165, 15)'),
        ('transform = Transform3D(2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 2.2, 0)',
         'transform = Transform3D(3, 0, 0, 0, 3, 0, 0, 0, 3, 0, 3.3, 0)'),
        ('radius = %s\nvertices' % obstacle_old, 'radius = %s\nvertices' % obstacle_new),
    ]


TARGETS = {
    "Infantry.tscn": INFANTRY,
    "Rocketeer.tscn": INFANTRY,
    "Sniper.tscn": INFANTRY + [("muzzle_offset = Vector3(0, 0.16, 0)", "muzzle_offset = Vector3(0, 0.24, 0)")],
    "AntiGroundTurret.tscn": turret_pairs("2_tlome", "CylinderShape3D_7usmv", "2.2", "3.3", "2.20", "3.30"),
    "AntiAirTurret.tscn": turret_pairs("2_bhouy", "CylinderShape3D_xa2u4", "2", "3", "2.00", "3.00"),
    "MachineGunTurret.tscn": turret_pairs("2_tlome", "CylinderShape3D_7usmv", "2", "3", "2.00", "3.00"),
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="逐条精确替换（幂等）")
    parser.add_argument("--check", action="store_true", help="只校验是否已是 ×1.5 状态")
    args = parser.parse_args()
    if not (args.apply or args.check):
        parser.error("需要 --apply 或 --check")
    pending = 0
    done = 0
    for name, pairs in TARGETS.items():
        path = os.path.join(REPO, UNITS, name)
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
        for old, new in pairs:
            # 先看"新形态是否已在"：部分条目的 old 是新形态的**前缀**（如给节点加一行属性），
            # 已生效时 old 仍然作为子串存在，必须先判 new。
            if new in text:
                done += 1
                continue
            if old in text:
                if args.apply:
                    text = text.replace(old, new)
                    done += 1
                else:
                    pending += 1
                    print("[PENDING] %s :: %s" % (name, old.splitlines()[-1].strip()))
            else:
                pending += 1
                print("[MISSING] %s :: 既没有旧值也没有新值 -> %s" % (name, new.splitlines()[-1].strip()))
        if args.apply:
            with open(path, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(text)
    print("[scale_units_1_5] 已生效条目=%d 待处理=%d（%s）" % (done, pending, "apply" if args.apply else "check"))
    return 0 if pending == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
