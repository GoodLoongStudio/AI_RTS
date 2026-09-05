extends Node

# 临时验证：蓝/红两阵营步兵特写对比。用完删除。

func _tint(unit: Node, color: Color) -> void:
	var found := 0
	for binder in unit.find_child("Geometry", true, false).find_children("*", "Node", true, false):
		if binder.has_method("apply_team_tint"):
			found += 1
			binder.apply_team_tint(color)
	print("[TINT] _tint found binders=", found)


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

	# 在坦克旁空地生成两个步兵：左蓝右红（远离测试图预置单位）
	var base: Vector3 = tank.global_position + Vector3(2.0, 0, 3.0)
	var blue_soldier = infantry.instantiate()
	blue_soldier.global_transform = Transform3D(Basis(), base + Vector3(-0.6, 0, 0))
	human.add_child(blue_soldier)
	MatchSignals.setup_and_spawn_unit.emit(blue_soldier, blue_soldier.global_transform, human)
	var red_soldier = infantry.instantiate()
	red_soldier.global_transform = Transform3D(Basis(), base + Vector3(0.6, 0, 0))
	human.add_child(red_soldier)
	MatchSignals.setup_and_spawn_unit.emit(red_soldier, red_soldier.global_transform, human)

	# 等 Unit._setup_color 完成（它用 player.color=白 覆盖一遍）后再注入阵营色
	for i in range(15):
		await get_tree().physics_frame
	_tint(blue_soldier, Color("66b1ff"))
	_tint(red_soldier, Color("ff5c73"))

	var cam := Camera3D.new()
	match_instance.add_child(cam)
	cam.global_position = base + Vector3(0, 0.8, 2.4)
	cam.look_at(base + Vector3(0, 0.35, 0))
	cam.current = true
	for i in range(120):
		await get_tree().physics_frame
	# 数值诊断：直接读两个步兵 mesh 的 override 与 shader 参数
	for unit in [blue_soldier, red_soldier]:
		print("[DIAG] geo children at diag: ", unit.find_child("Geometry", true, false).get_children())
		for mi in unit.find_child("Geometry", true, false).find_children("*", "MeshInstance3D", true, false):
			var ov = mi.material_override
			if ov != null and ov is ShaderMaterial:
				print("[DIAG] ", unit.name, " mesh=", mi.name,
					" team_color=", ov.get_shader_parameter("team_color"),
					" team_mix=", ov.get_shader_parameter("team_mix"))
			else:
				print("[DIAG] ", unit.name, " mesh=", mi.name, " override=", ov)
	var image := get_viewport().get_texture().get_image()
	image.save_png("res://repro_faction.png")
	print("FACTION_SHOT saved")
	get_tree().quit()
