extends Node

## 新单位模型阵容截图（2026-09-11）：
## 一排生成全部新单位 + 坦克参照，相机俯瞰截图到 res://new_units_lineup.png，
## 同时验证机场可生产运输机（修复页签错放导致无法训练的问题）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const APCScene = preload("res://source/match/units/APC.tscn")
const RocketArtilleryScene = preload("res://source/match/units/RocketArtillery.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const HoverBikeScene = preload("res://source/match/units/HoverBike.tscn")
const DropShipScene = preload("res://source/match/units/DropShip.tscn")
const ArmyTruckScene = preload("res://source/match/units/ArmyTruck.tscn")
const AmbulanceScene = preload("res://source/match/units/Ambulance.tscn")

var _failures := 0
var _produced_drop_ships: Array = []


func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")

	# 机场生产运输机（页签修复后的关键验证）
	var aircraft_factory = human.get_node("AircraftFactory")
	var waited := 0.0
	while waited < 10.0 and human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")
	var item = aircraft_factory.production_queue.produce(DropShipScene)
	_check(item != null, "机场应可入队生产运输机")
	var produce_waited := 0.0
	while _produced_drop_ships.is_empty() and produce_waited < 40.0:
		await get_tree().create_timer(0.25).timeout
		produce_waited += 0.25
	_check(
		_produced_drop_ships.size() == 1,
		"运输机应在 40s 内从机场部署（实际 %d）" % _produced_drop_ships.size()
	)

	# 逐单位生成渲染图标（仅新单位；既有单位图标不动）
	# 位置用已验证的空地 z=8 一带（TestAllUnits 建筑区之外）
	var roster = [
		["apc", APCScene],
		["rocket", RocketArtilleryScene],
		["heavy_tank", HeavyTankScene],
		["hover_bike", HoverBikeScene],
		["drop_ship", DropShipScene],
		["army_truck", ArmyTruckScene],
		["ambulance", AmbulanceScene],
	]
	# 用独立 SubViewport 渲染图标：共享 3D 世界但不带 HUD/侧栏
	var sub = SubViewport.new()
	sub.size = Vector2i(128, 128)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = true
	sub.own_world_3d = true
	match_instance.add_child(sub)
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.4
	sub.add_child(light)
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.2
	sub.add_child(camera)
	for entry in roster:
		var unit = entry[1].instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis.IDENTITY, Vector3(12, 0, 12)), human, false
		)
		await get_tree().process_frame
		await get_tree().create_timer(0.4).timeout
		if not is_instance_valid(unit):
			continue
		var geometry = unit.find_child("Geometry", true, false)
		if geometry == null:
			unit.queue_free()
			continue
		# 只把网格拷进隔离世界渲染，规避地图建筑/导航漂移干扰
		var copy = geometry.duplicate()
		sub.add_child(copy)
		camera.look_at_from_position(
			Vector3(0.0, 1.1, 2.6), Vector3(0.0, 0.4, 0.0), Vector3.UP
		)
		await RenderingServer.frame_post_draw
		var image = sub.get_texture().get_image()
		image.save_png("res://source/match/hud/ra3/icons/%s.png" % entry[0])
		print("[ICON] saved ", entry[0])
		copy.queue_free()
		unit.queue_free()
		await get_tree().process_frame
		await get_tree().create_timer(0.2).timeout
	print("[ICON] all icons rendered")

	print("New units lineup test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, producer):
	if producer.name == "AircraftFactory" and unit.scene_file_path == DropShipScene.resource_path:
		_produced_drop_ships.append(unit)


## 在地图上找一个离所有单位/建筑至少 4 米的空位，保证图标里没有杂物。
func _find_free_spot() -> Vector3:
	var all_units = get_tree().get_nodes_in_group("units")
	for z in [12.0, 14.0, 10.0, 8.0]:
		for x in [4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0]:
			var candidate = Vector3(x, 0, z)
			var free := true
			for u in all_units:
				if is_instance_valid(u) and u.global_position.distance_to(candidate) < 4.0:
					free = false
					break
			if free:
				return candidate
	return Vector3(12, 0, 12)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("New units lineup assertion failed: %s" % message)
