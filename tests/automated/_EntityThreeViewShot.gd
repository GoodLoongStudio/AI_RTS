extends Node

## 实体三视图检查场景（提示词 §2）：单个实体 + 米制网格 + 坐标轴 + 分色层，出俯视/侧视/游戏视角三张图。
## 分色：绿=近地几何投影、黄=CollisionShape3D 真实形状、蓝=Movement 个人空间半径、
##       红=MovementObstacle carve（半径+agent）、紫=建造 footprint（配表，存在时）。
## 每张图带 Label3D：实体名 / 姿态 yaw / 各层数值 / 场景资源 hash。

const ENTITIES := [
	"CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret",
	"Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Scout",
	"Infantry", "Rocketeer", "Sniper", "Helicopter", "Drone",
	"ResourceA", "ResourceB",
]
const OUT_DIR := "res://agent/runs/2026-10-01-per-unit-collider-clearance/screenshots/"
const VIEWS := ["top", "side", "game"]
var _index := 0
var _values: Array = []


func _ready():
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	await _render_next()


func _render_next() -> void:
	if _index >= ENTITIES.size():
		var vpath: String = OUT_DIR + "threeview-values.json"
	var vf := FileAccess.open(ProjectSettings.globalize_path(vpath), FileAccess.WRITE)
	vf.store_string(JSON.stringify({"generated_at": Time.get_datetime_string_from_system(), "entities": _values}, "  "))
	vf.close()
	print("[3VIEW] 数值 JSON 已写 %s（%d 实体）" % [vpath, _values.size()])
	print("[3VIEW] 完成，共 %d 个实体" % ENTITIES.size())
		get_tree().quit(0)
		return
	var entity: String = ENTITIES[_index]
	_index += 1
	await _render_entity(entity)
	await _render_next()


func _render_entity(entity_name: String) -> void:
	# 清场
	for child in get_children():
		child.queue_free()
	await get_tree().process_frame
	# 光照 + 地面
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, 35, 0)
	light.light_energy = 1.1
	add_child(light)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.35, 0.33, 0.3)
	ground.material_override = gm
	add_child(ground)
	# 米制网格（每 1m 一条，10m 范围）
	var grid := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	grid.mesh = im
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.1, 0.6, 0.1, 0.6)
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid.material_override = gmat
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(-5, 6):
		im.surface_add_vertex(Vector3(float(i), 0.02, -5.0))
		im.surface_add_vertex(Vector3(float(i), 0.02, 5.0))
		im.surface_add_vertex(Vector3(-5.0, 0.02, float(i)))
		im.surface_add_vertex(Vector3(5.0, 0.02, float(i)))
	im.surface_end()
	add_child(grid)
	# 实体
	var path := "res://source/match/units/" + entity_name + ".tscn"
	if entity_name in ["ResourceA", "ResourceB"]:
		path = "res://source/match/units/non-player/" + entity_name + ".tscn"
	var inst: Node3D = (load(path) as PackedScene).instantiate()
	add_child(inst)
	for _f in range(40):
		await get_tree().physics_frame
	# 各层几何
	var cs := inst.find_child("CollisionShape3D", true, false) as CollisionShape3D
	var collision_half := -1.0
	var collision_kind := "无"
	if cs != null and cs.shape != null:
		collision_kind = cs.shape.get_class()
		if cs.shape is CylinderShape3D:
			collision_half = (cs.shape as CylinderShape3D).radius
		elif cs.shape is BoxShape3D:
			collision_half = maxf((cs.shape as BoxShape3D).size.x, (cs.shape as BoxShape3D).size.z) * 0.5
		elif cs.shape is CapsuleShape3D:
			collision_half = (cs.shape as CapsuleShape3D).radius
		if collision_half > 0.0:
			_draw_cylinder(Vector3.ZERO, collision_half, 0.4, Color(0.95, 0.85, 0.1, 0.35))
	var logic: float = float(inst.get("radius")) if inst.get("radius") != null else -1.0
	if logic > 0.0:
		_draw_cylinder(Vector3(0, 0.05, 0), logic, 0.05, Color(0.2, 0.5, 1.0, 0.5))
	var obstacle: Node = inst.find_child("MovementObstacle", true, false)
	var carve := 0.0
	var agent := _agent_radius()
	if obstacle != null and bool(obstacle.get("affect_navigation_mesh")):
		var r: float = float(obstacle.get("radius")) if obstacle.get("radius") != null else 0.0
		carve = (r + agent) if bool(obstacle.get("carve_from_collision_bounds")) == false else (r + agent)
		_draw_cylinder(Vector3(0, 0.08, 0), carve, 0.06, Color(0.95, 0.15, 0.15, 0.45))
	# 标签（数值写在图里）
	var label := Label3D.new()
	label.text = "%s  yaw=%.0f°
碰撞=%s half=%.2f
逻辑r=%.2f
carve=%.2f(agent %.1f)
%s" % [
		entity_name, inst.rotation_degrees.y, collision_kind, collision_half, logic, carve, agent, path.get_file()]
	label.font_size = 64
	label.pixel_size = 0.006
	label.position = Vector3(0, 4.2, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	# 三视图
	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	for view in VIEWS:
		if view == "top":
			cam.position = Vector3(0, 14, 0.01)
			cam.rotation_degrees = Vector3(-90, 0, 0)
		elif view == "side":
			cam.position = Vector3(0, 1.6, 9)
			cam.rotation_degrees = Vector3(-6, 0, 0)
		else:
			cam.position = Vector3(6, 6, 9)
			cam.look_at(Vector3.ZERO)
		for _f in range(4):
			await get_tree().process_frame
		var img: Image = get_viewport().get_texture().get_image()
		var out: String = OUT_DIR + entity_name + "_" + view + ".png"
		img.save_png(out)
		print("[3VIEW] 已存 %s" % out)
	_values.append({
		"entity": entity_name,
		"scene_path": path,
		"collision_shape": collision_kind,
		"collision_half_m": collision_half,
		"movement_logic_radius_m": logic,
		"carve_clearance_m": carve,
		"agent_radius_m": agent,
		"has_obstacle": obstacle != null,
		"affect_navigation": bool(obstacle.get("affect_navigation_mesh")) if obstacle != null else false,
	})
	_flush_values()
	await get_tree().process_frame


func _flush_values() -> void:
	# 增量落盘：进程被截断也不至于丢失已测实体的数值（上一版写在最后，一次截断就全丢 ✗）
	var vf := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "threeview-values.json"), FileAccess.WRITE)
	if vf != null:
		vf.store_string(JSON.stringify({"generated_at": Time.get_datetime_string_from_system(), "entities": _values}, "  "))
		vf.close()


func _agent_radius() -> float:
	# 孤立场景里没有 NavigationRegion ⇒ 回退到权威常量（TerrainNavigation 的烘焙守卫用的就是它）。
	var maps := get_tree().root.find_children("*", "NavigationRegion3D", true, false)
	for m in maps:
		var mesh = (m as NavigationRegion3D).navigation_mesh
		if mesh != null:
			return mesh.agent_radius
	return Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS


func _draw_cylinder(at: Vector3, radius: float, height: float, color: Color) -> void:
	# 侧视可读：给分色层一个最小可见厚度（否则薄片在侧视图里看不见）
	height = maxf(height, 0.35)
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = maxf(height, 0.02)
	mi.mesh = cyl
	mi.position = at
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)
