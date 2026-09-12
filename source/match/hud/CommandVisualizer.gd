extends Node3D

## 指挥官命令可视化（纯表现层，2026-09-10）
##
## 收到 `MatchSignals.order_visualized` 后：在命令目标点放一个信标（地面双环 + 光柱 + 动作标签），
## 并从每个受令单位当前位置画一条到目标点的路径（优先走导航网格的真实路线，取不到则退化为直线）。
##
## 设计约束：
## - **不参与任何玩法判定**：只读 payload 与导航地图，生成的节点全部由本节点自持，数秒后淡出自毁。
## - **不依赖新资源**：环用既有 `faded_circle.gdshader`，光柱/路径为代码创建的 mesh + 材质，
##   避免新资源缺少 .godot/imported 产物导致 `load()` 静默返回 null。
## - 默认只显示副官（source="adjutant"）的指令；把 `show_player_orders` 打开后玩家自己的命令也会显示。
##
## payload（由权威端 NetSync.broadcast_order_visual 下发）：
##   {action: String, units: Array[String], target: [x, z], source: "adjutant"|"player", tick: int}

const LIFETIME := 5.0
const FADE_TIME := 1.2
const BEACON_RAISE_TIME := 0.3

#: 信标尺寸。2026-09-11 用户实测反馈"信标太大了"：原先光柱 9m 高、外环直径 6.8m，
#: 一次命令就把基地和半个屏幕盖住 → 整体缩到约 40%（3.2m 高 / 外环直径 3m），
#: 保留"看得见"但不再遮挡战场。
const BEACON_HEIGHT := 3.2
const BEACON_PILLAR_ALPHA := 0.22
const RING_Y := 0.06
const PATH_Y := 0.12
const PATH_WIDTH := 0.32
const PATH_ALPHA := 0.7

const FADED_CIRCLE_SHADER := preload("res://source/shaders/3d/faded_circle.gdshader")

## 动作 → 信标配色 / 中文标签。
const ACTION_COLORS := {
	"move": Color(0.35, 0.95, 1.0),
	"attack_move": Color(1.0, 0.62, 0.25),
	"gather": Color(1.0, 0.85, 0.25),
	"build": Color(0.45, 0.75, 1.0),
	"produce": Color(0.5, 1.0, 0.6),
	"attack": Color(1.0, 0.35, 0.3),
}
const ACTION_LABELS := {
	"move": "机动",
	"attack_move": "攻击移动",
	"gather": "采集",
	"build": "建造",
	"produce": "生产",
	"attack": "交战",
}
const DEFAULT_COLOR := Color(0.6, 0.9, 1.0)

@export var show_player_orders := false

var _match: Node = null


func _ready() -> void:
	_match = get_parent()
	MatchSignals.order_visualized.connect(_on_order_visualized)


func _on_order_visualized(payload) -> void:
	if not (payload is Dictionary):
		return
	var source := str(payload.get("source", "player"))
	if source != "adjutant" and not show_player_orders:
		return
	var target := _to_ground(payload.get("target", []))
	if not target.is_finite():
		return
	var action := str(payload.get("action", "move"))
	var unit_names: Array = payload.get("units", [])
	print("[VIS] order action=%s source=%s units=%s target=%s" % [
		action, source, str(unit_names), str(target)])
	_spawn_pulse(action, unit_names, target)


## 一次命令的表现：信标 + 各单位到目标的路径，随后整体淡出自毁。
func _spawn_pulse(action: String, unit_names: Array, target: Vector3) -> void:
	var color: Color = ACTION_COLORS.get(action, DEFAULT_COLOR)
	var pulse := Node3D.new()
	pulse.name = "OrderPulse"
	add_child(pulse)
	pulse.global_position = target

	var materials: Array = []
	_add_beacon(pulse, color, action, unit_names, materials)
	for unit_name in unit_names:
		var unit := _find_unit(str(unit_name))
		if unit == null or not is_instance_valid(unit):
			continue
		_add_path(pulse, unit.global_position, target, color, materials)
	_start_lifetime(pulse, materials)


# ---------- 信标 ----------

func _add_beacon(pulse: Node3D, color: Color, action: String, unit_names: Array,
		materials: Array) -> void:
	for ring in [
		{"radius": 1.5, "width": 6.0, "alpha": 0.4},
		{"radius": 0.7, "width": 8.0, "alpha": 0.7},
	]:
		var ring_node := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(ring["radius"], ring["radius"]) * 2.0
		ring_node.mesh = plane
		var ring_material := ShaderMaterial.new()
		ring_material.shader = FADED_CIRCLE_SHADER
		ring_material.render_priority = 2
		ring_material.set_shader_parameter("color", Color(color.r, color.g, color.b, ring["alpha"]))
		ring_material.set_shader_parameter("width_pixels", ring["width"])
		ring_material.set_shader_parameter("inner_edge_width_pixels", 1.0)
		ring_material.set_shader_parameter("outer_edge_width_pixels", 1.0)
		ring_node.material_override = ring_material
		ring_node.position.y = RING_Y
		pulse.add_child(ring_node)
		materials.append({"material": ring_material, "base": ring["alpha"], "shader": true,
			"color": color})
		# 落下展开：从 0.4 倍缩放到 1 倍，命令落点有"砸下去"的指示感。
		ring_node.scale = Vector3(0.4, 1.0, 0.4)
		create_tween().tween_property(ring_node, "scale", Vector3.ONE, BEACON_RAISE_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	var pillar := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.12
	cylinder.bottom_radius = 0.5
	cylinder.height = BEACON_HEIGHT
	cylinder.radial_segments = 20
	cylinder.rings = 1
	pillar.mesh = cylinder
	var pillar_material := StandardMaterial3D.new()
	pillar_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	pillar_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pillar_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	pillar_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	pillar_material.no_depth_test = true
	pillar_material.albedo_color = Color(color.r, color.g, color.b, BEACON_PILLAR_ALPHA)
	pillar.material_override = pillar_material
	pillar.position.y = BEACON_HEIGHT * 0.5
	pillar.scale = Vector3(1.0, 0.06, 1.0)
	pulse.add_child(pillar)
	materials.append({"material": pillar_material, "base": BEACON_PILLAR_ALPHA, "shader": false,
		"color": color})
	create_tween().tween_property(pillar, "scale", Vector3.ONE, BEACON_RAISE_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	var label := Label3D.new()
	label.text = _label_text(action, unit_names)
	# 字号跟着信标一起收小（原 42/16 在缩放前尺寸下才合适）。
	label.font_size = 30
	label.outline_size = 10
	label.pixel_size = 0.018
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1.0, 1.0, 1.0, 0.95)
	label.outline_modulate = Color(0.05, 0.05, 0.08, 0.85)
	label.position.y = BEACON_HEIGHT + 0.8
	pulse.add_child(label)


func _label_text(action: String, unit_names: Array) -> String:
	# 文案纪律（用户明确要求）：中文、简单易懂。副官的命令标签只写动作与**数量**，
	# 不列 `Unit_3` 这类内部单位名（对玩家没意义，还会把标签撑得又宽又乱）。
	var title: String = "副官：" + str(ACTION_LABELS.get(action, "行动"))
	if unit_names.is_empty():
		return title
	return "%s\n%d 个单位" % [title, unit_names.size()]


# ---------- 路径 ----------

func _add_path(pulse: Node3D, from_position: Vector3, to_position: Vector3, color: Color,
		materials: Array) -> void:
	var points := _navigation_points(from_position, to_position)
	if points.size() < 2:
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var half_width := PATH_WIDTH * 0.5
	for index in points.size():
		var point := points[index]
		var forward: Vector3
		if index == 0:
			forward = points[1] - points[0]
		elif index == points.size() - 1:
			forward = points[index] - points[index - 1]
		else:
			forward = points[index + 1] - points[index - 1]
		forward.y = 0.0
		if forward.length() < 0.001:
			forward = Vector3.FORWARD
		var side: Vector3 = forward.normalized().cross(Vector3.UP).normalized() * half_width
		var local_point := pulse.to_local(point)
		mesh.surface_add_vertex(local_point - side)
		mesh.surface_add_vertex(local_point + side)
	mesh.surface_end()

	var path_node := MeshInstance3D.new()
	path_node.name = "OrderPath"
	path_node.mesh = mesh
	var path_material := StandardMaterial3D.new()
	path_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	path_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	path_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	path_material.no_depth_test = true
	path_material.albedo_color = Color(color.r, color.g, color.b, PATH_ALPHA)
	path_node.material_override = path_material
	pulse.add_child(path_node)
	materials.append({"material": path_material, "base": PATH_ALPHA, "shader": false,
		"color": color})


## 取导航网格上的真实路线；取不到（客户端导航未就绪 / 目标在网格外）时退化为直线。
func _navigation_points(from_position: Vector3, to_position: Vector3) -> PackedVector3Array:
	var points := PackedVector3Array()
	var map_rid := RID()
	if is_inside_tree():
		map_rid = get_world_3d().navigation_map
	var start := from_position
	var end := to_position
	start.y = PATH_Y
	end.y = PATH_Y
	if map_rid.is_valid():
		var path := NavigationServer3D.map_get_path(map_rid, start, end, true)
		if path.size() >= 2:
			for point in path:
				point.y = PATH_Y
				points.append(point)
			return points
	points.append(start)
	points.append(end)
	return points


# ---------- 生命周期 ----------

func _start_lifetime(pulse: Node3D, materials: Array) -> void:
	var tween := create_tween()
	tween.tween_interval(maxf(0.0, LIFETIME - FADE_TIME))
	tween.tween_method(_apply_alpha.bind(materials), 1.0, 0.0, FADE_TIME)
	tween.tween_callback(pulse.queue_free)


func _apply_alpha(factor: float, materials: Array) -> void:
	for entry in materials:
		var material = entry["material"]
		if material == null:
			continue
		var color: Color = entry["color"]
		var alpha: float = float(entry["base"]) * factor
		if bool(entry["shader"]):
			material.set_shader_parameter("color", Color(color.r, color.g, color.b, alpha))
		else:
			material.albedo_color = Color(color.r, color.g, color.b, alpha)


# ---------- 工具 ----------

func _to_ground(raw) -> Vector3:
	if raw is Vector3:
		return Vector3(raw.x, 0.0, raw.z)
	if raw is Array and raw.size() >= 2:
		return Vector3(float(raw[0]), 0.0, float(raw[1]))
	return Vector3.INF


func _find_unit(unit_name: String) -> Node:
	if unit_name.is_empty() or not is_inside_tree():
		return null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit != null and is_instance_valid(unit) and unit.name == unit_name:
			return unit
	return null
