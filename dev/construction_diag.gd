extends SceneTree

# 建筑施工材质诊断：复刻 spawn→施工→完工 链路，打印每个阶段网格的 material_override。
# 用法: godot --headless --path . -s res://dev/construction_diag.gd

var _frame := 0
var _match: Node
var _factory: Node3D
var _turret: Node3D


func _initialize():
	_match = load("res://tests/manual/TestOneUnit.tscn").instantiate()
	root.add_child(_match)


func _process(_delta) -> bool:
	_frame += 1
	match _frame:
		10:
			_spawn_factory()
			_spawn_turret()
		12:
			_dump("施工标记后", _factory)
			_dump("施工标记后", _turret)
		14:
			_advance_work(_factory)
			_advance_work(_turret)
		16:
			_dump("工作量拉满+完工后", _factory)
			_dump("工作量拉满+完工后", _turret)
			return true
	return false


func _spawn_unit(scene_path: String) -> Node3D:
	var human = _match.get_node("Players/Human")
	var unit: Node3D = load(scene_path).instantiate()
	# 手动复刻 Match._setup_and_spawn_unit 的关键顺序（-s 模式无 MatchSignals 自动加载）：
	# 先 mark_as_under_construction，再 add_child 入树（binder _ready 在入树时触发）。
	unit.global_transform = Transform3D(Basis.IDENTITY, Vector3(10, 0, 10))
	unit.mark_as_under_construction()
	unit.add_to_group("units")
	human.add_child(unit)
	return unit


func _spawn_factory() -> void:
	_factory = _spawn_unit("res://source/match/units/VehicleFactory.tscn")


func _spawn_turret() -> void:
	_turret = _spawn_unit("res://source/match/units/AntiGroundTurret.tscn")


func _advance_work(unit: Node3D) -> void:
	unit.apply_authoritative_construction_work(10, 10)
	var completed: bool = unit.complete_authoritative_construction()
	print("[DIAG] %s complete -> %s  is_constructed=%s" % [
		unit.name, completed, unit.is_constructed()])


func _dump(label: String, unit: Node3D) -> void:
	print("==== %s : %s ====" % [label, unit.name])
	print("is_constructed=", unit.is_constructed(),
		"  is_under_construction=", unit.is_under_construction())
	var geometry = unit.find_child("Geometry")
	for mesh_instance in geometry.find_children("*", "MeshInstance3D", true, false):
		var override = mesh_instance.material_override
		var desc := "null"
		if override != null:
			desc = override.get_class()
			if override is StandardMaterial3D:
				desc += "(transparent=%s alpha=%.2f)" % [override.transparency, override.albedo_color.a]
		print("  mesh=", mesh_instance.name, "  override=", desc)
