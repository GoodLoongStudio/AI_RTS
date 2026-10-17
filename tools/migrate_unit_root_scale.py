#!/usr/bin/env python3
"""World-metric / root-scale normalization migrator (2026-09-30).

把单位场景从"根节点 scale = N，子节点用 1/N 补偿"迁移到新契约：
  UnitRoot scale = 1；美术缩放只留在 Visual（Geometry）分支；
  CollisionShape / Highlight / Selection / Targetability 直接用世界米；
  MovementObstacle.radius 本就是世界米（去掉 1/N 补偿）。

规则（保证世界值不变）：
  root.scale = N            -> 删除（= 1）
  Geometry.transform        -> basis × N，origin × N        （视觉世界缩放不变）
  CollisionShape3D          -> origin × N；shape 的 radius/height × N（世界米）
  Highlight/Selection/Targetability -> origin × N；radius × N（世界米）
  MovementObstacle/Movement -> 删除 scale 行（半径已是世界米）
  HealthBar/RallyPoint      -> origin × N，scale × N        （表现节点保持世界外观）
  其它 Node3D               -> origin × N，scale × N        （保持世界值，并打印以便复核）

用法: python tools/migrate_unit_root_scale.py <scene.tscn> [--dry-run]
"""
import re
import sys
from pathlib import Path

try:  # Windows 控制台默认 GBK，直接 print ✓/×/中文会 UnicodeEncodeError
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

WORLD_NODES = {"CollisionShape3D", "Highlight", "Selection", "Targetability"}
DROP_SCALE = {"MovementObstacle", "Movement"}
KEEP_APPEARANCE = {"HealthBar", "RallyPoint"}
VISUAL = {"Geometry"}


def mul_basis(tokens, n):
    # Transform3D(xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz)
    vals = [float(t) for t in tokens]
    for i in range(9):
        vals[i] *= n
    for i in range(9, 12):
        vals[i] *= n
    return ", ".join(("%g" % v) for v in vals)


def parse_transform(line):
    m = re.match(r"^transform = Transform3D\(([^)]*)\)\s*$", line.strip())
    if not m:
        return None
    return [t.strip() for t in m.group(1).split(",")]


def migrate(path: Path, dry: bool):
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    # 1) 找根节点 scale
    root_idx = None
    root_scale = None
    for i, line in enumerate(lines):
        if line.startswith("[node ") and root_idx is None:
            root_idx = i
            continue
        if root_idx is not None and i > root_idx:
            if line.startswith("[node "):
                break
            m = re.match(r"^scale = Vector3\(([-\d.]+), ", line)
            if m:
                root_scale = float(m.group(1))
                del lines[i]
                break
    if root_scale is None or abs(root_scale - 1.0) < 1e-6:
        print(f"  {path.name}: 根缩放已是 1，跳过")
        return False
    n = root_scale

    shape_factor = n
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r'^\[node name="([^"]+)"(.*)\]$', line)
        if not m:
            out.append(line)
            i += 1
            continue
        name, rest = m.group(1), m.group(2)
        # 收集本节点块
        block = [line]
        j = i + 1
        while j < len(lines) and not lines[j].startswith("[node "):
            block.append(lines[j])
            j += 1
        body = block[1:]
        # 找 transform
        t_idx = next((k for k, b in enumerate(body) if b.startswith("transform = ")), None)
        tokens = parse_transform(body[t_idx]) if t_idx is not None else None

        changed = []
        if name in VISUAL:
            if tokens is None:
                body.insert(0, "transform = Transform3D(%s)" % mul_basis(
                    ["1", "0", "0", "0", "1", "0", "0", "0", "1", "0", "0", "0"], n))
            else:
                body[t_idx] = "transform = Transform3D(%s)" % mul_basis(tokens, n)
            changed.append("visual×%g" % n)
        elif name in WORLD_NODES:
            # 这些节点必须"直接用世界米"：基向量归一到 1，只缩 origin；
            # 数值属性（radius / shape radius+height）乘上它原本承担的缩放因子
            # factor = 父链 n × 自己的 local scale。
            local_scale = float(tokens[0]) if tokens is not None else 1.0
            factor = n * local_scale
            if tokens is not None:
                ox, oy, oz = (float(t) * n for t in tokens[9:12])
                body[t_idx] = (
                    "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %g, %g, %g)" % (ox, oy, oz)
                )
                changed.append("origin×%g,basis→1" % n)
            for k, b in enumerate(body):
                mm = re.match(r"^radius = ([-\d.]+)$", b)
                if mm:
                    body[k] = "radius = %g" % (float(mm.group(1)) * factor)
                    changed.append("radius×%g" % factor)
            if name == "CollisionShape3D":
                shape_factor = factor
        elif name in DROP_SCALE:
            body = [b for b in body if not b.startswith("scale = ")]
            changed.append("scale 行删除")
        elif name in KEEP_APPEARANCE:
            if tokens is not None:
                body[t_idx] = "transform = Transform3D(%s)" % mul_basis(tokens, n)
            else:
                body.insert(0, "scale = Vector3(%g, %g, %g)" % (n, n, n))
            changed.append("保外观×%g" % n)
        else:
            if tokens is not None:
                body[t_idx] = "transform = Transform3D(%s)" % mul_basis(tokens, n)
                changed.append("保持世界值×%g" % n)
        if changed:
            print(f"  {path.name}: {name} -> {', '.join(changed)}")
        out.append("\n".join(block[:1] + body))
        i = j

    text_new = "\n".join(out)
    # 3) CollisionShape3D 的 shape 子资源：radius/height × factor（父链 n × 碰撞节点 local scale）
    n = shape_factor if 'shape_factor' in dir() else n
    if "CollisionShape3D" in text_new:
        for m in re.finditer(r'^shape = SubResource\("([^"]+)"\)$', text_new, re.M):
            sid = m.group(1)
            blk = re.search(r'\[sub_resource type="(CylinderShape3D|BoxShape3D|SphereShape3D)" id="%s"\](.*?)(?=\n\[|\Z)' % re.escape(sid), text_new, re.S)
            if not blk:
                continue
            seg = blk.group(0)
            new_seg = seg
            for prop in ("radius", "height"):
                mm = re.search(r"^%s = ([-\d.]+)$" % prop, seg, re.M)
                if mm:
                    new_seg = new_seg.replace(mm.group(0), "%s = %g" % (prop, float(mm.group(1)) * n))
            if new_seg != seg:
                text_new = text_new.replace(seg, new_seg)
                print(f"  {path.name}: shape {sid} radius/height ×{n:g}")

    if dry:
        print(f"  [dry-run] {path.name} 未写入")
        return True
    path.write_text(text_new, encoding="utf-8")
    print(f"  ✓ {path.name} 已写入（root {n:g} -> 1）")
    return True


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    for a in args:
        p = Path(a)
        if p.exists():
            print(f"== {p.name} ==")
            migrate(p, dry)
        else:
            print(f"  未找到 {a}")
