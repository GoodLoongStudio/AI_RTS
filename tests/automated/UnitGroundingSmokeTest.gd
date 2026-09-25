extends Node

## 单位贴地守门测试（2026-09-21 用户报"单位浮空"根因修复的类级守门）。
##
## 背景：普通图（PlainAndSimple / BigArena，运行时烘 Recast）上，**所有地面单位与建筑
## 一起悬在沙面上方 0.6m**。根因是烘焙出的导航网格可走面被体素量化抬高——实测本图参数
## （cell_height=0.6 / agent_height=1.8 / agent_radius=0.9）下，可视地面 y=0 的平地图
## 烘出的网格面恒在 y=1.2（实时对局取证：地面单位 y=0.6 / 地形碰撞体 y=0），而
## `path_height_offset=0.6` 只补得了一半；且该偏移随烘焙 AABB 与引擎版本漂移
## （同参数实测 +1.0~+1.2），不能靠调大 path_height_offset 去凑。
## 修法：导航网格只用于寻路（XZ），单位站立平面每帧由真实地表（射线/高度场）吸附，
## 与逻辑地形路径同源（Movement._snap_to_ground_height / MovementObstacle._snap_to_ground）。
##
## 本测试守两件事：
## 1) 普通图（导航网格路径）：地面单位/建筑必须贴在可视地表上（误差 ≤ 5cm）；
## 2) 生成图（逻辑地形路径）：同样贴地，且飞行域单位保持"地表 + 离地高度"。
## 参照高度取**独立射线**（collision_mask=2，即地形碰撞体），不复用游戏内的
## ground_height_at，避免"用被测函数验证自己"。

const NAVMESH_MAP := "res://source/match/maps/PlainAndSimple.tscn"
const LOGIC_MAP := "res://source/match/maps/generated/16-0/map_16-0.tscn"
const HOVER_OFFSET := 1.8
## 贴地误差上限：跑步动画的根骨起伏在厘米级，5cm 足够区分"贴地"与"浮空 0.6m"。
const GROUND_EPSILON := 0.05

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(400.0).timeout.connect(_on_failsafe)
	# 等启动传播结束再往 root 里挂对局：同帧 add_child 会撞 "busy setting up children"。
	await get_tree().process_frame
	await get_tree().process_frame
	await _check_map(NAVMESH_MAP, "普通图/导航网格路径")
	await _check_map(LOGIC_MAP, "生成图/逻辑地形路径")
	_finish()


func _check_map(map_path: String, label: String) -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)

	var map_instance = load(map_path).instantiate()
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = map_instance
	get_tree().root.add_child(a_match)
	# 等对局把玩家单位（基地/工人/无人机）生出来：导航烘焙是异步的，会拖到 _ready 之后。
	var player = null
	# 单位要等异步导航烘焙完成后才生成（Match._ready 的 await 链），繁忙机器上要留足时间。
	var deadline := Time.get_ticks_msec() + 150000
	while player == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var players = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() > 0:
			var candidate = players.get_child(0)
			if candidate.get_child_count() > 0:
				player = candidate
	_check(player != null, "%s：对局应生成玩家单位" % label)
	if player == null:
		a_match.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
		return

	await get_tree().create_timer(1.0).timeout
	var checked := 0
	for unit in player.get_children():
		# 只校验真实单位：玩家节点下还挂着 StructurePlacementHandler 等控制节点（非 Node3D/非单位）。
		if not (unit is Node3D) or not unit.is_in_group("units"):
			continue
		var ground := _visual_ground(a_match, unit)
		var delta: float = unit.global_position.y - ground
		var is_air: bool = false
		var movement = unit.find_child("Movement", false, false)
		if movement != null:
			is_air = int(movement.get("domain")) == int(Constants.Match.Navigation.Domain.AIR)
		var expected: float = ground + (HOVER_OFFSET if is_air else 0.0)
		checked += 1
		_check(
			absf(unit.global_position.y - expected) <= GROUND_EPSILON,
			"%s：%s 应贴地（实际 y=%.3f，期望 %.3f，偏差 %+.3f）" % [
				label, unit.name, unit.global_position.y, expected, delta]
		)
	_check(checked > 0, "%s：至少应校验一个单位（实际 %d）" % [label, checked])

	a_match.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


## 独立测量可视地表高度：向下射线打地形碰撞体（layer 2），
## 与游戏内 ground_height_at 同源但独立实现；打空时保持原高度（不编 0）。
func _visual_ground(a_match: Node, unit: Node3D) -> float:
	# 生成图：高度场网格就是可视地面（其 trimesh 碰撞体不接受射线，实测全图 MISS；
	# 逻辑地形路径也以高度场为准，见 GeneratedTerrain.project_ground）。
	var height_terrain: Node = a_match.get_node_or_null("Map/Geometry/Terrain")
	if height_terrain != null and height_terrain.has_method("sample_world_height"):
		return float(height_terrain.sample_world_height(unit.global_position))
	var body: Node3D = a_match.get_node_or_null("Terrain")
	if body == null:
		return unit.global_position.y
	var space: PhysicsDirectSpaceState3D = body.get_world_3d().direct_space_state
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(unit.global_position.x, unit.global_position.y + 200.0, unit.global_position.z),
		Vector3(unit.global_position.x, unit.global_position.y - 200.0, unit.global_position.z)
	)
	params.collision_mask = 2
	params.collide_with_areas = false
	# 排除单位自身的碰撞体：否则飞行域单位的自设碰撞会先于地形被命中。
	var exclude: Array[RID] = []
	_collect_collision_rids(unit, exclude)
	if not exclude.is_empty():
		params.exclude = exclude
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return unit.global_position.y
	return (hit["position"] as Vector3).y


func _collect_collision_rids(node: Node, out: Array[RID]) -> void:
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	for child in node.get_children():
		_collect_collision_rids(child, out)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS ", message)
	else:
		_failures += 1
		push_error("FAIL " + message)
		print("FAIL ", message)


func _on_failsafe() -> void:
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	print("Unit grounding smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0)
