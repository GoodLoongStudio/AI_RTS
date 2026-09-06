extends SceneTree

# 建筑施工材质诊断：复刻 spawn→施工→完工 链路，打印每个阶段网格的 material_override。
# 用法: godot --headless --path . -s res://dev/construction_diag.gd

var _frame := 0
var _match: Node
var _factory: Node3D


func _initialize():
	_match = load("res://tests/manual/TestOneUnit.tscn").instantiate()
	root.add_child(_match)


func _process(_delta) -> bool:
	_frame += 1
	match _frame:
		10:
			_spawn_factory()
		12:
			_dump("施工标记后")
		14:
			_advance_work()
		16:
			_dump("工作量拉满+完工后")
			return true
	return false


func _spawn_factory() -> void:
	var human = _match.get_node("Players/Human")
	_factory = load("res://source/match/units/VehicleFactory.tscn").instantiate()
	# 手动复刻 Match._setup_and_spawn_unit 的关键顺序（-s 模式无 MatchSignals 自动加载）：
	# 先 mark_as_under_construction，再 add_child 入树（binder _ready 在入树时触发）。
	_factory.global_transform = Transform3D(Basis.IDENTITY, Vector3(10, 0, 10))
	_factory.mark_as_under_construction()
	_factory.add_to_group("units")
	human.add_child(_factory)


func _advance_work() -> void:
	_factory.apply_authoritative_construction_work(10, 10)
	var completed: bool = _factory.complete_authoritative_construction()
	print("[DIAG] complete_authoritative_construction -> ", completed,
		"  is_constructed=", _factory.is_constructed())


func _dump(label: String) -> void:
	print("==== %s ====" % label)
	print("is_constructed=", _factory.is_constructed(),
		"  is_under_construction=", _factory.is_under_construction())
	var geometry = _factory.find_child("Geometry")
	for mesh_instance in geometry.find_children("*", "MeshInstance3D", true, false):
		var override = mesh_instance.material_override
		var desc := "null"
		if override != null:
			desc = "%s(transparent=%s)" % [override.get_class(), override.transparency]
		print("  mesh=", mesh_instance.name, "  override=", desc)
	var binder = geometry.find_children("*", "", true, false).filter(
		func(n): return n.get_script() != null and str(n.get_script().resource_path).ends_with("SyntyMaterialBinder.gd")
	)
	print("  binder count=", binder.size())
