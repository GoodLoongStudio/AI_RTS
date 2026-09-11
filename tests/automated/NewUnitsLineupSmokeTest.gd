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

	# 逐单位生成渲染图标：替代此前直接拷贝贴图集的占位图标
	var roster = [
		["tank", preload("res://source/match/units/Tank.tscn")],
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
	sub.own_world_3d = false
	match_instance.add_child(sub)
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.2
	sub.add_child(camera)
	for entry in roster:
		var unit = entry[1].instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis.IDENTITY, Vector3(30.0, 0, 30.0)), human, false
		)
		await get_tree().process_frame
		await get_tree().create_timer(0.4).timeout
		if not is_instance_valid(unit):
			continue
		camera.look_at_from_position(
			Vector3(30.0, 2.2, 31.8), Vector3(30.0, 0.5, 30.0), Vector3.UP
		)
		await RenderingServer.frame_post_draw
		var image = sub.get_texture().get_image()
		image.save_png("res://source/match/hud/ra3/icons/%s.png" % entry[0])
		print("[ICON] saved ", entry[0])
		unit.queue_free()
		await get_tree().process_frame
		await get_tree().create_timer(0.2).timeout
	print("[ICON] all icons rendered")

	print("New units lineup test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, producer):
	if producer.name == "AircraftFactory" and unit.scene_file_path == DropShipScene.resource_path:
		_produced_drop_ships.append(unit)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("New units lineup assertion failed: %s" % message)
