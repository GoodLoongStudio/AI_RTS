# -*- coding: utf-8 -*-
"""临时性能测试场景生成器（2026-09-25 性能诊断专用，用完即删）。

以 tests/manual/TestUnitsFightingEachOther.tscn 为模板做文本手术：
保留 Match 实例、迷雾材质覆盖、小地图接线，替换玩家与单位列表。
生成三个固定场景：
  PerfSmall.tscn  - PlainAndSimple（100x100），7 个单位，安静开局
  PerfBattle.tscn - PlainAndSimple，88 个作战单位，两军相接自动开战
  PerfLarge.tscn  - generated/seed_35（256x256 大地图），29 个单位
"""
import re
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # AI_RTS/
TEMPLATE = os.path.join(ROOT, "tests", "manual", "TestUnitsFightingEachOther.tscn")
OUT_DIR = os.path.join(ROOT, "tests", "perf")

UNIT_SCENE_PREFIX = "res://source/match/units/"


def unit_uid(unit_name):
    """从单位 tscn 首行提取 uid（旧格式场景头无 uid，不能全文搜索，
    否则会误抓文件体内第一个 ext_resource 的 uid —— 2026-09-25 实测教训）。"""
    path = os.path.join(ROOT, "source", "match", "units", unit_name + ".tscn")
    with open(path, encoding="utf-8") as fh:
        first_line = fh.readline()
    m = re.search(r'uid="([^"]+)"', first_line)
    return m.group(1) if m else ""


def build_scene(map_path, map_id, human_units, enemy_units, hide_hud=False):
    """human_units/enemy_units: [(unit_scene_name, x, z), ...]"""
    with open(TEMPLATE, encoding="utf-8") as fh:
        src = fh.read()

    # 1. 收集模板里要丢弃的 ext_resource（旧单位 + 电脑 AI）与节点段
    drop_paths = [
        "res://source/match/units/AntiAirTurret.tscn",
        "res://source/match/units/Helicopter.tscn",
        "res://source/match/units/Drone.tscn",
        "res://source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.tscn",
    ]
    lines = src.splitlines(True)
    out = []
    node_section_started = False
    dropped_unit_ext_ids = set()
    for ln in lines:
        if ln.startswith("[node "):
            node_section_started = True
        if not node_section_started and ln.startswith("[ext_resource "):
            if any(p in ln for p in drop_paths):
                m = re.search(r'id="([^"]+)"', ln)
                if m:
                    dropped_unit_ext_ids.add(m.group(1))
                continue  # 丢弃该 ext_resource
        out.append(ln)
    src = "".join(out)

    # 2. 丢弃模板的单位/AI 节点，保留 Match/Map/Human/覆盖节点
    keep_nodes = []
    for node_block in re.split(r"(?=\[node )", src):
        if not node_block.startswith("[node "):
            keep_nodes.append(node_block)
            continue
        header = node_block.split("\n", 1)[0]
        m = re.search(r'\[node name="([^"]+)" parent="([^"]*)"', header)
        if not m:
            keep_nodes.append(node_block)
            continue
        name, parent = m.groups()
        if parent == "Players/Human" and name.startswith("AntiAirTurret"):
            continue
        if parent == "Players" and name == "SimpleClairvoyantAI":
            continue
        if parent.startswith("Players/SimpleClairvoyantAI"):
            continue
        if name == "HUD" and parent == "." and hide_hud:
            continue
        keep_nodes.append(node_block)
    src = "".join(keep_nodes)

    # 3. 换地图
    if map_path != "res://source/match/maps/PlainAndSimple.tscn":
        src = src.replace(
            'path="res://source/match/maps/PlainAndSimple.tscn"',
            'path="%s"' % map_path,
        )

    # 4. 追加新的 ext_resource：单位场景 + 敌方 Player 脚本
    all_units = [u[0] for u in human_units] + [u[0] for u in enemy_units]
    ext_lines = []
    unit_ids = {}
    for i, unit_name in enumerate(sorted(set(all_units))):
        ext_id = "p_unit_%d" % i
        unit_ids[unit_name] = ext_id
        uid = unit_uid(unit_name)
        uid_attr = ' uid="%s"' % uid if uid else ""
        ext_lines.append(
            '[ext_resource type="PackedScene"%s path="%s%s.tscn" id="%s"]'
            % (uid_attr, UNIT_SCENE_PREFIX, unit_name, ext_id)
        )
    ext_lines.append(
        '[ext_resource type="Script" path="res://source/match/players/Player.gd" id="p_enemy"]'
    )
    # 插到最后一个 ext_resource 行之后
    last_ext = re.search(r"^\[ext_resource [^\n]*\]\s*$", src, re.M)
    insert_at = last_ext.end()
    src = src[:insert_at] + "\n" + "\n".join(ext_lines) + src[insert_at:]

    # 5. load_steps 修正
    ext_count = len(re.findall(r"^\[ext_resource ", src, re.M))
    sub_count = len(re.findall(r"^\[sub_resource ", src, re.M))
    src = re.sub(
        r"load_steps=\d+",
        "load_steps=%d" % (ext_count + sub_count + 1),
        src,
        count=1,
    )

    # 6. 追加节点
    def unit_node(idx, unit_name, x, z, parent):
        return (
            '[node name="%s%d" parent="%s" instance=ExtResource("%s")]\n'
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.3f, 0, %.3f)\n\n"
            % (unit_name, idx, parent, unit_ids[unit_name], x, z)
        )

    tail = []
    # 敌方玩家（纯 Player，不带 AI 大脑，保证可重复）
    tail.append(
        '[node name="Enemy" type="Node3D" parent="Players" index="1"]\n'
        'script = ExtResource("p_enemy")\n'
        "color = Color(1, 0.3, 0.3, 1)\n\n"
    )
    for i, (unit_name, x, z) in enumerate(human_units):
        tail.append(unit_node(i + 1, unit_name, x, z, "Players/Human"))
    for i, (unit_name, x, z) in enumerate(enemy_units):
        tail.append(unit_node(i + 1, unit_name, x, z, "Players/Enemy"))
    src = src.rstrip() + "\n" + "".join(tail)
    return src


def grid(center_x, center_z, cols, rows, spacing, roster):
    """roster: [unit_name,...] 按 (cols x rows) 逐格填充。"""
    units = []
    i = 0
    for r in range(rows):
        for c in range(cols):
            if i >= len(roster):
                break
            x = center_x + (c - (cols - 1) / 2.0) * spacing
            z = center_z + (r - (rows - 1) / 2.0) * spacing
            units.append((roster[i], x, z))
            i += 1
    return units


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # ---- 场景 A：安静开局，7 个单位 ----
    human_a = [("CommandCenter", 40, 40), ("Worker", 37, 38), ("Worker", 37, 42),
               ("Tank", 44, 40), ("Tank", 44, 44)]
    enemy_a = [("Infantry", 70, 40), ("Infantry", 70, 44)]
    open(os.path.join(OUT_DIR, "PerfSmall.tscn"), "w", encoding="utf-8", newline="\n").write(
        build_scene("res://source/match/maps/PlainAndSimple.tscn", "small", human_a, enemy_a))

    # ---- 场景 B：88 个作战单位会战 ----
    roster_h = ["Tank"] * 14 + ["HeavyTank"] * 8 + ["Infantry"] * 12 + ["APC"] * 6
    roster_e = ["Tank"] * 14 + ["HeavyTank"] * 8 + ["Infantry"] * 12 + ["Sniper"] * 6
    human_b = grid(39, 46, 10, 4, 2.2, roster_h)
    human_b += [("Helicopter", 41, 53), ("Helicopter", 44, 53),
                ("Helicopter", 47, 53), ("Helicopter", 38, 53)]
    enemy_b = grid(60, 46, 10, 4, 2.2, roster_e)
    enemy_b += [("Helicopter", 56, 53), ("Helicopter", 59, 53),
                ("Helicopter", 62, 53), ("Helicopter", 65, 53)]
    open(os.path.join(OUT_DIR, "PerfBattle.tscn"), "w", encoding="utf-8", newline="\n").write(
        build_scene("res://source/match/maps/PlainAndSimple.tscn", "battle", human_b, enemy_b))

    # ---- 场景 C：256x256 大地图（seed_35），29 个单位，不接战 ----
    human_c = [("CommandCenter", 62.4, 95.5), ("Worker", 58, 92), ("Worker", 58, 99),
               ("Worker", 66, 92), ("Worker", 66, 99)]
    human_c += grid(62, 103, 6, 2, 2.5, ["Tank"] * 8 + ["HeavyTank"] * 4)
    enemy_c = grid(150, 64, 6, 2, 2.5, ["Tank"] * 8 + ["HeavyTank"] * 4)
    open(os.path.join(OUT_DIR, "PerfLarge.tscn"), "w", encoding="utf-8", newline="\n").write(
        build_scene("res://source/match/maps/generated/seed_35.tscn", "large", human_c, enemy_c))

    for name in ("PerfSmall", "PerfBattle", "PerfLarge"):
        p = os.path.join(OUT_DIR, name + ".tscn")
        with open(p, encoding="utf-8") as fh:
            body = fh.read()
        print(name, "ext=%d sub=%d nodes=%d bytes=%d" % (
            len(re.findall(r"^\[ext_resource ", body, re.M)),
            len(re.findall(r"^\[sub_resource ", body, re.M)),
            len(re.findall(r"^\[node ", body, re.M)),
            len(body)))


if __name__ == "__main__":
    main()
