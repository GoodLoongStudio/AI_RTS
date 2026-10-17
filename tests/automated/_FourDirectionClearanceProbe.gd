extends Node

## 四方向贴边/穿越探针：把"空气墙"量成米。
## 做法：放一栋建筑，把待测单位放在 4 个方向（+X/-X/+Z/-Z）外侧，命令它往**建筑中心**走，
## 跑到停住为止，量：中心距、单位地面半宽、建筑地面半宽 ⇒ hull-to-hull 表面间隙；
## 再对比三层候选解释（Movement.radius 个人空间 / carve 净空 = 半径+agent / 到达容差），
## 给出"第一限制层"。每方向重复 3 次。
## 输出：agent/runs/2026-10-01-per-unit-collider-clearance/four-direction-probe.json

const OUT_PATH := "res://agent/runs/2026-10-01-per-unit-collider-clearance/four-direction-probe.json"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const OBSTACLES := ["Barracks"]
const UNITS := ["Worker", "Tank"]


func _ready():
	get_tree().create_timer(280.0).timeout.connect(func() -> void:
		push_error("[4DIR] 超时兜底退出")
		get_tree().quit(2))
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(160):
		await get_tree().physics_frame
	var player: Node = m.get_node("Players").get_children()[0]

	var results: Array = []
	# 测试点用**地图内网格**（地图 208×208）：上一版 z 一直累加会跑出地图，
	# 单位被出生逻辑甩到几十米外，读数无效。
	var run_index := 0
	for obstacle_name in OBSTACLES:
		for unit_name in UNITS:
			for dir_i in range(1):
				var dirs: Array = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
				var dir: Vector3 = dirs[dir_i]
				for rep in range(1):
					# 【2026-10-01】必须远离地图自带的玩家基地：上一版放在 (40,40)，读数被主基地的 stand_off(5.09m) 污染。
					var base := Vector3(112.0 + float(run_index % 4) * 22.0, 0.0, 112.0 + float(run_index / 4) * 22.0)
					var row: Dictionary = await _one_run(m, player, base, obstacle_name, unit_name, dir, rep)
					if row.get("spawn_mismatch", false):
						print("[4DIR] %s←%s dir=%s rep=%d 跳过：出生落点偏移 %.2fm（被出生位移推走）" % [
							unit_name, obstacle_name, str(dir), rep, row.get("spawn_offset_m", -1.0)])
						results.append(row)
						run_index += 1
						continue
					results.append(row)
					print("[4DIR] %s←%s dir=%s rep=%d 中心距=%.2f 单位半宽=%.2f 建筑半宽=%.2f 表面间隙=%.2f 限制层=%s" % [
						unit_name, obstacle_name, str(dir), rep, row.center_distance_m,
						row.unit_ground_half_m, row.obstacle_ground_half_m, row.hull_to_hull_gap_m, row.first_limiting_layer])
					run_index += 1
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"schema": "four-direction-probe/v1", "generated_at": Time.get_datetime_string_from_system(), "rows": results}, "  "))
		f.close()
		print("[4DIR] 已写入 %s（%d 行）" % [OUT_PATH, results.size()])
	get_tree().quit(0)


func _one_run(m: Node, player: Node, base: Vector3, obstacle_name: String, unit_name: String, dir: Vector3, rep: int) -> Dictionary:
	var obstacle: Node3D = (load("res://source/match/units/" + obstacle_name + ".tscn") as PackedScene).instantiate()
	m.call("_setup_and_spawn_unit", obstacle, Transform3D(Basis.IDENTITY, base), player, false)
	var unit: Node3D = (load("res://source/match/units/" + unit_name + ".tscn") as PackedScene).instantiate()
	m.call("_setup_and_spawn_unit", unit, Transform3D(Basis.IDENTITY, base + dir * 18.0), player, false)
	# 给导航重烘留时间（贴盒 carve 只在重烘后生效）
	for _f in range(180):
		await get_tree().physics_frame
	var start: Vector3 = unit.global_position
	var requested: Vector3 = base + dir * 18.0
	var spawn_offset := Vector2(start.x - requested.x, start.z - requested.z).length()
	var movement: Node = unit.find_child("Movement", true, false)
	movement.call("move", base)
	var prev := start
	var stable := 0
	var frames := 0
	while frames < 420:
		await get_tree().physics_frame
		frames += 1
		var cur: Vector3 = unit.global_position
		if Vector2(cur.x - prev.x, cur.z - prev.z).length() < 0.01:
			stable += 1
		else:
			stable = 0
		prev = cur
		if stable > 30:
			break
	# ---------- 测量 ----------
	var obstacle_now: Vector3 = obstacle.global_position
	var obstacle_offset := Vector2(obstacle_now.x - base.x, obstacle_now.z - base.z).length()
	var unit_half: float = _ground_half(unit, dir)
	var obstacle_half: float = _ground_half(obstacle, dir)
	var center_distance: float = Vector2(prev.x - obstacle_now.x, prev.z - obstacle_now.z).length()
	var logic_radius: float = float(unit.get("radius")) if unit.get("radius") != null else -1.0
	var clearance: float = Utils.Match.Unit.Movement.carve_clearance_of(obstacle)
	var mv_node: Node = unit.find_child("Movement", true, false)
	var domain: Variant = mv_node.get("domain") if mv_node != null else null
	var is_air: bool = domain != null and int(domain) == int(Constants.Match.Navigation.Domain.AIR)
	# 限制层归因：与三种候选口径比对，取最接近者；差 >0.6m 则如实标注，不猜
	var candidates := {
		"carve(障碍半径+agent)": clearance,
		"carve+个人空间": clearance + logic_radius,
		"贴体(两 hull 相切)": unit_half + obstacle_half,
	}
	var best_name := "无法归因"
	var best_diff := 1.0e9
	for k in candidates:
		var d: float = absf(center_distance - float(candidates[k]))
		if d < best_diff:
			best_diff = d
			best_name = str(k)
	var layer := ("%s（差 %.2fm）" % [best_name, best_diff]) if best_diff <= 0.6 else ("未知：中心距 %.2fm 与候选口径均不符" % center_distance)
	var out := {
		"unit": unit_name,
		"obstacle": obstacle_name,
		"direction": [dir.x, dir.z],
		"repeat": rep,
		"is_air_unit": is_air,
		"spawn_offset_m": spawn_offset,
		"spawn_mismatch": spawn_offset > 0.8,
		"obstacle_spawn_offset_m": obstacle_offset,
		"start_distance_m": Vector2(start.x - obstacle_now.x, start.z - obstacle_now.z).length(),
		"center_distance_m": center_distance,
		"unit_ground_half_m": unit_half,
		"obstacle_ground_half_m": obstacle_half,
		"hull_to_hull_gap_m": center_distance - unit_half - obstacle_half,
		"unit_logic_radius_m": logic_radius,
		"obstacle_carve_clearance_m": clearance,
		"frames": frames,
		"settled": stable > 30,
		"first_limiting_layer": layer,
	}
	unit.queue_free()
	obstacle.queue_free()
	for _f in range(25):
		await get_tree().physics_frame
	return out


## 沿 dir 轴的真实地面半宽（近地几何投影）
func _ground_half(node: Node3D, dir: Vector3) -> float:
	var out := 0.0
	var origin: Vector3 = node.global_position
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var p := str(gi.get_path())
		if p.contains("Selection") or p.contains("Highlight") or p.contains("Targetability") or p.contains("HealthBar"):
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > 0.6:
				continue
			var planar := Vector2(pt.x - origin.x, pt.z - origin.z)
			out = maxf(out, absf(planar.dot(Vector2(dir.x, dir.z).normalized())))
	return out
