# -*- coding: utf-8 -*-
"""临时性能场景生成器（2026-09-26 索敌优化第一轮，性能报告数据源）。

以 tests/manual/TestUnitsFightingEachOther.tscn 为模板做文本手术：
保留 Match 实例、迷雾材质覆盖、小地图接线（保证节点 owned 语义正确），
替换玩家与单位列表。生成：
  PerfGridIdle100/200/400.tscn - N 个我方单位散开，无敌人（纯待机索敌）
  PerfGridBattle200.tscn       - 100v100 真实互殴（可死亡 → 回到索敌）
  PerfGridMove200.tscn         - 200 个我方单位（HoldFire + 攻击移动，运行时下发）
uid 只从场景文件首行提取（旧格式场景头无 uid，全文搜索会误抓体内
ext_resource 的 uid —— 2026-09-25 实测教训）。"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEMPLATE = os.path.join(ROOT, "tests", "manual", "TestUnitsFightingEachOther.tscn")
OUT_DIR = os.path.join(ROOT, "tests", "perfgrid")
UNIT_PREFIX = "res://source/match/units/"
ROSTER_MIX = ["Tank", "Tank", "HeavyTank", "Infantry", "Infantry", "APC", "Sniper"]


def unit_uid(unit_name):
    path = os.path.join(ROOT, "source", "match", "units", unit_name + ".tscn")
    with open(path, encoding="utf-8") as fh:
        first_line = fh.readline()
    m = re.search(r'uid="([^"]+)"', first_line)
    return m.group(1) if m else ""


def build_scene(units_human, units_enemy, map_path="res://source/match/maps/PlainAndSimple.tscn",
                with_enemy=None):
    with open(TEMPLATE, encoding="utf-8") as fh:
        src = fh.read()
    if map_path != "res://source/match/maps/PlainAndSimple.tscn":
        src = src.replace('path="res://source/match/maps/PlainAndSimple.tscn"',
                          'path="%s"' % map_path)
    if with_enemy is None:
        with_enemy = bool(units_enemy)
    lines = src.splitlines(True)
    out = []
    node_section = False
    for ln in lines:
        if ln.startswith("[node "):
            node_section = True
        if not node_section and ln.startswith("[ext_resource "):
            if any(p in ln for p in ("AntiAirTurret.tscn", "Helicopter.tscn",
                                     "Drone.tscn", "SimpleClairvoyantAI.tscn")):
                continue
        out.append(ln)
    src = "".join(out)

    keep = []
    for block in re.split(r"(?=\[node )", src):
        if not block.startswith("[node "):
            keep.append(block)
            continue
        header = block.split("\n", 1)[0]
        m = re.search(r'\[node name="([^"]+)" parent="([^"]*)"', header)
        if not m:
            keep.append(block)
            continue
        name, parent = m.groups()
        if parent == "Players/Human" and name.startswith("AntiAirTurret"):
            continue
        if parent == "Players" and name == "SimpleClairvoyantAI":
            continue
        if parent.startswith("Players/SimpleClairvoyantAI"):
            continue
        if name == "HUD" and parent == ".":
            continue  # 去掉模板的 HUD 隐藏覆盖，性能测试保持真实 HUD
        keep.append(block)
    src = "".join(keep)

    all_units = sorted({u[0] for u in units_human} | {u[0] for u in units_enemy})
    ext_lines = []
    unit_ids = {}
    for i, unit_name in enumerate(all_units):
        ext_id = "pg_unit_%d" % i
        unit_ids[unit_name] = ext_id
        uid = unit_uid(unit_name)
        uid_attr = ' uid="%s"' % uid if uid else ""
        ext_lines.append('[ext_resource type="PackedScene"%s path="%s%s.tscn" id="%s"]'
                         % (uid_attr, UNIT_PREFIX, unit_name, ext_id))
    ext_lines.append('[ext_resource type="Script" path="res://source/match/players/Player.gd" id="pg_enemy"]')
    last_ext = re.search(r"^\[ext_resource [^\n]*\]\s*$", src, re.M)
    src = src[:last_ext.end()] + "\n" + "\n".join(ext_lines) + src[last_ext.end():]

    ext_count = len(re.findall(r"^\[ext_resource ", src, re.M))
    sub_count = len(re.findall(r"^\[sub_resource ", src, re.M))
    src = re.sub(r"load_steps=\d+", "load_steps=%d" % (ext_count + sub_count + 1), src, count=1)

    tail = []
    if with_enemy:
        tail.append(
            '[node name="Enemy" type="Node3D" parent="Players" index="1"]\n'
            'script = ExtResource("pg_enemy")\n'
            "color = Color(1, 0.3, 0.3, 1)\n\n")
    for i, (unit_name, x, z) in enumerate(units_human):
        tail.append(
            '[node name="%s%d" parent="Players/Human" instance=ExtResource("%s")]\n'
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.3f, 0, %.3f)\n\n"
            % (unit_name, i + 1, unit_ids[unit_name], x, z))
    for i, (unit_name, x, z) in enumerate(units_enemy):
        tail.append(
            '[node name="%s%d" parent="Players/Enemy" instance=ExtResource("%s")]\n'
            "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %.3f, 0, %.3f)\n\n"
            % (unit_name, i + 1, unit_ids[unit_name], x, z))
    return src.rstrip() + "\n" + "".join(tail)


def grid_positions(count, center, spacing, span):
    per_row = max(1, int(span / spacing))
    rows = -(-count // per_row)  # ceil
    pos = []
    used = 0
    for r in range(rows):
        for c in range(per_row):
            if used >= count:
                return pos
            x = center[0] + (c - (per_row - 1) / 2.0) * spacing
            z = center[1] + (r - (rows - 1) / 2.0) * spacing
            pos.append((ROSTER_MIX[used % len(ROSTER_MIX)], x, z))
            used += 1
    return pos


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for count in (100, 200, 400):
        units = grid_positions(count, (50, 50), 4.0, 88.0)
        path = os.path.join(OUT_DIR, "PerfGridIdle%d.tscn" % count)
        open(path, "w", encoding="utf-8", newline="\n").write(build_scene(units, []))
        print("Idle%d: %d units" % (count, len(units)))

    half = 100
    left = grid_positions(half, (36, 50), 2.4, 30.0)
    right = grid_positions(half, (63, 50), 2.4, 30.0)
    open(os.path.join(OUT_DIR, "PerfGridBattle200.tscn"), "w", encoding="utf-8", newline="\n").write(
        build_scene(left, right))
    print("Battle200: %d units" % (len(left) + len(right)))

    movers = grid_positions(200, (16, 50), 3.0, 40.0)
    open(os.path.join(OUT_DIR, "PerfGridMove200.tscn"), "w", encoding="utf-8", newline="\n").write(
        build_scene(movers, []))
    print("Move200: %d units" % len(movers))

    # ---- G4 生成地图（seed_35，256x256）：真实"单位多会卡"的环境 ----
    # 单位全部由 PerfGridRunner 在运行时经真实出场入口 _setup_and_spawn_unit
    # 生成（自带贴地校正），出生锚定地图自带 SpawnPoints 标记。
    # tscn 只承载 Match/地图/玩家（with_enemy 供战斗场景）。
    G4 = "res://source/match/maps/generated/seed_35.tscn"
    for count in (200, 400):
        path = os.path.join(OUT_DIR, "PerfGridG4Idle%d.tscn" % count)
        write_scene(path, build_scene([], [], G4))
        print("G4Idle%d: players-only (units spawned at runtime)" % count)

    write_scene(os.path.join(OUT_DIR, "PerfGridG4Battle200.tscn"),
                build_scene([], [], G4, with_enemy=True))
    print("G4Battle200: players-only (units spawned at runtime)")

    write_scene(os.path.join(OUT_DIR, "PerfGridG4Move200.tscn"), build_scene([], [], G4))
    print("G4Move200: players-only (units spawned at runtime)")


def write_scene(path, content):
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(content)


if __name__ == "__main__":
    main()
