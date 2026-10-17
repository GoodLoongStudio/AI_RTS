extends Node3D

## 碰撞体积可视化（2026-09-30 用户要求：「把建筑和单位的碰撞体积可视化了，方便我来测试和纠正」）。
##
## 开关：
##   · 启动即开：环境变量 AIRTS_DEBUG_COLLIDERS=1
##   · 运行时切换：get_tree().current_scene.get_node("CollisionVolumeOverlay").set_enabled(true)
##   · 按键：F9
##
## 每个单位画三类口径（世界米）：
##   黄 = 碰撞包围网格（CollisionShape3D 的世界 XZ AABB）
##   红 = carve 洞（碰撞包围盒外扩导航 agent_radius）—— 导航真正挖掉的范围
##   青 = 逻辑半径（unit.radius，索敌/采集/贴合判定用）
## 并在单位上方挂 Label3D 打印数值，便于逐项核对与纠正。

const REFRESH_INTERVAL := 0.35
const COLOR_COLLISION := Color(1.0, 0.85, 0.2, 0.5)
const COLOR_CARVE := Color(1.0, 0.28, 0.28, 0.4)
const COLOR_LOGIC := Color(0.3, 0.9, 1.0, 0.45)
const LABEL_COLOR := Color(1.0, 0.95, 0.7)

var _enabled := false
var _holder: Node3D = null
var _elapsed := 0.0


func _ready() -> void:
	_holder = Node3D.new()
	_holder.name = "Colliders"
	add_child(_holder)
	if OS.get_environment("AIRTS_DEBUG_COLLIDERS").strip_edges() == "1":
		set_enabled(true)


func _input(event) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F9:
		set_enabled(not _enabled)


func set_enabled(value: bool) -> void:
	_enabled = value
	_holder.visible = value
	if value:
		_rebuild()
	print("[COLLIDERS] ", "开" if value else "关")


func _process(delta: float) -> void:
	if not _enabled:
		return
	_elapsed += delta
	if _elapsed < REFRESH_INTERVAL:
		return
	_elapsed = 0.0
	_rebuild()


func _rebuild() -> void:
	for child in _holder.get_children():
		child.queue_free()
	var agent_radius := _agent_radius()
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit) or not (unit is Node3D):
			continue
		_draw_unit(unit, agent_radius)


func _agent_radius() -> float:
	var match_node := get_parent()
	var region: Node = null
	if match_node != null:
		region = match_node.get_node_or_null("Navigation/Terrain/NavigationRegion3D")
	if region == null:
		return 2.8
	var mesh = region.get("navigation_mesh")
	if mesh == null:
		return 2.8
	return float(mesh.get("agent_radius"))


func _draw_unit(unit: Node3D, agent_radius: float) -> void:
	var origin := unit.global_position
	var logic_radius := float(unit.get("radius")) if unit.get("radius") != null else 0.0
	var collision_bounds := _collision_bounds(unit)
	var collision_height := 0.0
	if collision_bounds.size.length_squared() > 0.0:
		collision_height = collision_bounds.size.y
		_add_box_volume(collision_bounds, COLOR_COLLISION)
	# 【2026-10-01 修复可视化"撒谎"】洞只在障碍**真的参与导航烘焙**时才存在：
	# affect_navigation_mesh=false（例如金矿 —— RA3 语义：矿是地面资源，单位/矿车可开上去）
	# ⇒ 不画红盒、carve 报 0。旧写法只看"有没有 MovementObstacle"，于是把已经关掉烘焙的矿
	# 也画成 4m 红洞 —— 这正是 F9 里"金矿碰撞盒过大"的假象来源
	# （独立复核已在导航层直测：矿点处 map_get_closest_point 距离 0.000，确实无洞）。
	var obstacle := unit.find_child("MovementObstacle", true, false)
	var carves: bool = obstacle != null and bool(obstacle.get("affect_navigation_mesh"))
	var carve_radius := 0.0
	if carves:
		# 【2026-10-01 独立复检收口】红盒必须画**真正被烘进导航的那套几何**：
		#   carve_from_collision_bounds=true  ⇒ 洞 = 碰撞形状包围面 + agent（方盒）
		#   carve_from_collision_bounds=false ⇒ 洞 = radius 生成的 16 段圆 + agent（圆）
		# 旧写法一律按"碰撞盒 + agent"画，于是 barracks z 向画大 0.905m、
		# aircraft_factory x 向画小 1.77m（复核方实测：barracks 处最近点 4.800 符合 radius 口径 5.0，
		# 不符合碰撞盒口径 5.905）。已全部改为按实际口径绘制。
		var from_bounds := true
		if obstacle.get("carve_from_collision_bounds") != null:
			from_bounds = bool(obstacle.get("carve_from_collision_bounds"))
		var obstacle_radius := 0.0
		if obstacle.get("radius") != null:
			obstacle_radius = float(obstacle.get("radius"))
		var carve_margin := 0.0
		if obstacle.has_method("effective_carve_margin"):
			carve_margin = float(obstacle.effective_carve_margin())
		if from_bounds and collision_bounds.size.length_squared() > 0.0:
			var carve_bounds := _expand_xz(collision_bounds, agent_radius + carve_margin)
			carve_radius = maxf(carve_bounds.size.x, carve_bounds.size.z) * 0.5
			_add_box_volume(carve_bounds, COLOR_CARVE)
		elif obstacle_radius > 0.01:
			carve_radius = obstacle_radius + carve_margin + agent_radius
			_add_volume(origin, carve_radius, maxf(collision_height, 1.0), COLOR_CARVE)
	if logic_radius > 0.01 and absf(logic_radius - carve_radius) > 0.05:
		_add_volume(origin, logic_radius, _unit_height(unit, collision_height), COLOR_LOGIC)
	_add_label(origin + Vector3(0, maxf(collision_height, 2.0) * 0.5 + 1.6, 0),
		"%s\n碰撞包围盒=%.2f×%.2f×%.2f\n逻辑 r=%.2f  %s" % [
			str(unit.get("unit_type_id")),
			collision_bounds.size.x, collision_bounds.size.y, collision_bounds.size.z,
			logic_radius,
			("carve=%.2f(hole)" % carve_radius) if carves else "不参与导航烘焙(无洞)"])


func _collision_bounds(unit: Node3D) -> AABB:
	var result := AABB()
	var found := false
	for child in unit.find_children("*", "CollisionShape3D", true, false):
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null:
			continue
		var local := _shape_local_aabb(shape_node.shape)
		if local.size.length_squared() <= 0.0:
			continue
		var world := shape_node.global_transform * local
		result = world if not found else result.merge(world)
		found = true
	if found:
		return result
	var fallback := float(unit.get("radius")) if unit.get("radius") != null else 0.0
	return AABB(
		unit.global_position - Vector3(fallback, fallback, fallback),
		Vector3.ONE * fallback * 2.0
	)


func _shape_local_aabb(shape: Shape3D) -> AABB:
	if shape is CylinderShape3D:
		var cylinder := shape as CylinderShape3D
		return AABB(
			Vector3(-cylinder.radius, -cylinder.height * 0.5, -cylinder.radius),
			Vector3(cylinder.radius * 2.0, cylinder.height, cylinder.radius * 2.0)
		)
	if shape is SphereShape3D:
		var sphere := shape as SphereShape3D
		return AABB(
			Vector3(-sphere.radius, -sphere.radius, -sphere.radius),
			Vector3.ONE * sphere.radius * 2.0
		)
	if shape is BoxShape3D:
		var box := shape as BoxShape3D
		return AABB(-box.size * 0.5, box.size)
	if shape is CapsuleShape3D:
		var capsule := shape as CapsuleShape3D
		return AABB(
			Vector3(-capsule.radius, -capsule.height * 0.5, -capsule.radius),
			Vector3(capsule.radius * 2.0, capsule.height, capsule.radius * 2.0)
		)
	return AABB()


## NavigationObstacle3D 外扩 agent_radius 后的世界包围网格。
func _expand_xz(bounds: AABB, amount: float) -> AABB:
	var expanded := bounds
	expanded.position.x -= amount
	expanded.position.z -= amount
	expanded.size.x += amount * 2.0
	expanded.size.z += amount * 2.0
	return expanded


## 单位高度：优先用碰撞体高度，其次用视觉包围盒，最后给个 2m 兜底。
func _unit_height(unit: Node3D, fallback: float) -> float:
	if fallback > 0.2:
		return fallback
	var best := 0.0
	for gi in unit.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") or path.contains("HealthBar"):
			continue
		var aabb: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and aabb.size.length() < 0.01:
			aabb = (gi as MeshInstance3D).mesh.get_aabb()
		best = maxf(best, aabb.size.y * absf((gi as Node3D).global_transform.basis.get_scale().y))
	return maxf(best, 2.0)


## 碰撞和 carve 都用半透明实心 BoxMesh，直接对应包围网格；逻辑半径仍保留圆柱，
## 因为它是距离查询口径，不是物理阻挡口径。
func _add_box_volume(bounds: AABB, color: Color) -> void:
	if bounds.size.length_squared() <= 0.0001:
		return
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = bounds.size
	body.mesh = box
	body.material_override = _material(Color(color.r, color.g, color.b, color.a * 0.45))
	_holder.add_child(body)
	body.global_position = bounds.position + bounds.size * 0.5


func _add_volume(at: Vector3, radius: float, height: float, color: Color) -> void:
	if radius <= 0.01:
		return
	var h: float = maxf(height, 0.6)
	var body := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = h
	body.mesh = cylinder
	var body_material := _material(Color(color.r, color.g, color.b, color.a * 0.45))
	body.material_override = body_material
	_holder.add_child(body)
	body.global_position = Vector3(at.x, at.y + h * 0.5, at.z)
	for y in [0.05, h]:
		var edge := MeshInstance3D.new()
		var ring := CylinderMesh.new()
		ring.top_radius = radius
		ring.bottom_radius = radius
		ring.height = 0.08
		edge.mesh = ring
		edge.material_override = _material(Color(color.r, color.g, color.b, minf(1.0, color.a * 2.2)))
		_holder.add_child(edge)
		edge.global_position = Vector3(at.x, at.y + y, at.z)


func _add_label(at: Vector3, text: String) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 96
	label.pixel_size = 0.014
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = LABEL_COLOR
	label.outline_size = 20
	_holder.add_child(label)
	label.global_position = at


func _material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
