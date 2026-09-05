extends Node

# 临时验证：蓝/红两阵营步兵特写对比（轮询等待 _setup_color 完成后再切色）。用完删除。

func _spawn(player, scene: PackedScene, pos: Vector3) -> Node:
	var unit = scene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), pos), player)
	return unit


func _wait_tinted(unit: Node, timeout_ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var geometry = unit.find_child("Geometry", true, false)
		if geometry == null:
			continue
		var has_override := false
		for mi in geometry.find_children("*", "MeshInstance3D", true, false):
			if mi.material_override != null:
				has_override = true
				break
		if has_override:
			return true
	return false


func _ready() -> void:
	var match_instance = preload("res://tests/manual/TestAllUnits.tscn").instantiate()
	get_tree().root.add_child.call_deferred(match_instance)
	await get_tree().process_frame
	get_tree().current_scene = match_instance
	for i in range(60):
		await get_tree().physics_frame
	var human = match_instance.get_node("Players/Human")
	var tank = human.get_node("Tank")
	var infantry = preload("res://source/match/units/Infantry.tscn")

	# 蓝方：设玩家色 → 生成 → 轮询等待着色完成
	human.color = Color("2979ff")
	var base: Vector3 = tank.global_position + Vector3(2.0, 0, 3.0)
	var blue_soldier = _spawn(human, infantry, base + Vector3(-0.6, 0, 0))
	var blue_ok := await _wait_tinted(blue_soldier)
	print("[FACTION] blue tinted=", blue_ok)

	# 红方：切换玩家色 → 生成 → 轮询等待
	human.color = Color("ff5252")
	var red_soldier = _spawn(human, infantry, base + Vector3(0.6, 0, 0))
	var red_ok := await _wait_tinted(red_soldier)
	print("[FACTION] red tinted=", red_ok)

	var cam := Camera3D.new()
	match_instance.add_child(cam)
	cam.global_position = base + Vector3(0, 0.8, 2.4)
	cam.look_at(base + Vector3(0, 0.35, 0))
	cam.current = true
	for i in range(120):
		await get_tree().physics_frame
	var image := get_viewport().get_texture().get_image()
	var blue_px: Color = image.get_pixelv(
		cam.unproject_position(blue_soldier.global_position + Vector3(0, 0.3, 0))
	)
	var red_px: Color = image.get_pixelv(
		cam.unproject_position(red_soldier.global_position + Vector3(0, 0.3, 0))
	)
	print(
		"[PIXEL] blue=(%.2f %.2f %.2f) red=(%.2f %.2f %.2f)"
		% [blue_px.r, blue_px.g, blue_px.b, red_px.r, red_px.g, red_px.b]
	)
	image.save_png("res://repro_faction.png")
	print("FACTION_SHOT saved")
	get_tree().quit()
