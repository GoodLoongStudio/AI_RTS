extends Node3D

enum BlueprintPositionValidity {
	VALID,
	COLLIDES_WITH_OBJECT,
	NOT_NAVIGABLE,
	NOT_ENOUGH_RESOURCES,
	OUT_OF_MAP,
	NOT_VISIBLE,
	NOT_ADJACENT,
	CONSTRUCTION_IN_PROGRESS,
	BLOCKS_PASSAGE,
}

const ROTATION_BY_KEY_STEP = 45.0
const ROTATION_DEAD_ZONE_DISTANCE = 0.1

const EscapeRouter = preload("res://source/ui/EscapeRouter.gd")
const BuildPlacementArea = preload("res://source/match/players/human/BuildPlacementArea3D.gd")

const MATERIALS_ROOT = "res://source/match/resources/materials/"
const BLUEPRINT_VALID_PATH = MATERIALS_ROOT + "blueprint_valid.material.tres"
const BLUEPRINT_INVALID_PATH = MATERIALS_ROOT + "blueprint_invalid.material.tres"

var _active_blueprint_node = null
var _pending_structure_prototype = null
var _pending_construction_workers := []
var _blueprint_rotating = false
var _local_input_bound := false

@onready var _player = get_parent()
@onready var _match = find_parent("Match")
@onready var _feedback_label = find_child("FeedbackLabel3D")
@onready var _placement_runtime = _match.find_child("StructurePlacementRuntime")
@onready var _balance_runtime = _match.find_child("BalanceConfigRuntime")
@onready var _input_runtime = _match.get_node("InputBindingRuntime")


func _ready():
	_feedback_label.hide()
	if not _match.is_node_ready():
		await _match.ready
	if not MatchSignals.match_started.is_connected(_on_match_started_for_input):
		MatchSignals.match_started.connect(_on_match_started_for_input, CONNECT_ONE_SHOT)
	call_deferred("_bind_local_input")


func _on_match_started_for_input():
	call_deferred("_bind_local_input")


func _bind_local_input():
	if _local_input_bound or not is_inside_tree():
		return
	if _match.get_local_player() != _player:
		return
	_local_input_bound = true
	if MatchSignals.match_started.is_connected(_on_match_started_for_input):
		MatchSignals.match_started.disconnect(_on_match_started_for_input)
	MatchSignals.place_structure.connect(_on_structure_placement_request)
	_input_runtime.connect("ActionPressed", _on_input_action_pressed)


func _unhandled_input(event):
	if not _structure_placement_started():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_lmb_down_event(event)
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		_handle_lmb_up_event(event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_handle_rmb_event(event)
	if event is InputEventMouseMotion:
		_handle_mouse_motion_event(event)


func _handle_lmb_down_event(_event):
	get_viewport().set_input_as_handled()
	_start_blueprint_rotation()


func _handle_lmb_up_event(_event):
	get_viewport().set_input_as_handled()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	if blueprint_position_validity == BlueprintPositionValidity.VALID:
		_finish_structure_placement()
	elif (
		blueprint_position_validity == BlueprintPositionValidity.COLLIDES_WITH_OBJECT
		or blueprint_position_validity == BlueprintPositionValidity.NOT_NAVIGABLE
		or blueprint_position_validity == BlueprintPositionValidity.OUT_OF_MAP
		or blueprint_position_validity == BlueprintPositionValidity.NOT_ADJACENT
	):
		# 【2026-09-29 用户三次实报"建筑造不下去"】点击落点不合规时自动就近吸附。
		# 此前吸附写在 `_finish_structure_placement` 的权威分支里，而该函数只在
		# "位置已合法"时才被调用——吸附是永远走不到的死代码（三局实测点击无反应）。
		# 现在空间类拒绝先吸附、再走同一条提交路径；吸附只用只读 Evaluate/FindAutoSpot，
		# 任何拓扑都在转发之前完成，最终合法性仍由权威复核。
		var snapped = _snap_transform_if_possible()
		if snapped != null:
			_active_blueprint_node.global_transform = snapped
			_finish_structure_placement()
	elif blueprint_position_validity == BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
		MatchSignals.not_enough_resources_for_construction.emit(_player)
	elif blueprint_position_validity == BlueprintPositionValidity.CONSTRUCTION_IN_PROGRESS:
		# 蓝图不撤：玩家可以悬停等当前工地完工/取消，ghost 每次移动都会重新评估。
		MatchSignals.construction_slot_busy.emit(_player)
	_finish_blueprint_rotation()


func _handle_rmb_event(event):
	get_viewport().set_input_as_handled()
	if event.pressed:
		_finish_blueprint_rotation()
		_cancel_structure_placement()


func _handle_mouse_motion_event(_event):
	get_viewport().set_input_as_handled()
	if _blueprint_rotation_started():
		_rotate_blueprint_towards_mouse_pos()
	else:
		_set_blueprint_position_based_on_mouse_pos()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	_update_feedback_label(blueprint_position_validity)
	_update_blueprint_color(blueprint_position_validity == BlueprintPositionValidity.VALID)


func _structure_placement_started():
	return _active_blueprint_node != null


func _blueprint_rotation_started():
	return _blueprint_rotating == true


func _calculate_blueprint_position_validity():
	var evaluation = _placement_runtime.Evaluate(
		_player,
		_pending_structure_prototype,
		_active_blueprint_node.global_transform,
		{}  # ECO-007B：Legacy 参数保留兼容，权威成本由 C# Catalog 查询。
	)
	match evaluation["primary_issue"]:
		"", "BlocksPassage":
			# 窄缝允许放下。历史问题码不再涂红、不再写英文提示。
			return BlueprintPositionValidity.VALID
		"NotVisible":
			return BlueprintPositionValidity.NOT_VISIBLE
		"NotAdjacent":
			return BlueprintPositionValidity.NOT_ADJACENT
		"OutOfBounds":
			return BlueprintPositionValidity.OUT_OF_MAP
		"InsufficientResources":
			return BlueprintPositionValidity.NOT_ENOUGH_RESOURCES
		"Occupied", "FriendlyDisplacementUnavailable":
			return BlueprintPositionValidity.COLLIDES_WITH_OBJECT
		"ConstructionInProgress":
			# 「一次只能建造一个建筑」：C# 权威校验（同一玩家仅一个 Active 工地）。
			return BlueprintPositionValidity.CONSTRUCTION_IN_PROGRESS
		_:
			return BlueprintPositionValidity.NOT_NAVIGABLE


func _update_feedback_label(blueprint_position_validity):
	_feedback_label.visible = (blueprint_position_validity != BlueprintPositionValidity.VALID)
	match blueprint_position_validity:
		BlueprintPositionValidity.COLLIDES_WITH_OBJECT:
			_feedback_label.text = tr("BLUEPRINT_COLLIDES_WITH_OBJECT")
		BlueprintPositionValidity.NOT_NAVIGABLE:
			_feedback_label.text = tr("BLUEPRINT_NOT_NAVIGABLE")
		BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
			_feedback_label.text = tr("BLUEPRINT_NOT_ENOUGH_RESOURCES")
		BlueprintPositionValidity.OUT_OF_MAP:
			_feedback_label.text = tr("BLUEPRINT_OUT_OF_MAP")
		BlueprintPositionValidity.NOT_VISIBLE:
			_feedback_label.text = tr("BLUEPRINT_NOT_VISIBLE")
		BlueprintPositionValidity.NOT_ADJACENT:
			_feedback_label.text = tr("BLUEPRINT_NOT_ADJACENT")
		BlueprintPositionValidity.CONSTRUCTION_IN_PROGRESS:
			_feedback_label.text = tr("BLUEPRINT_CONSTRUCTION_IN_PROGRESS")


## 待放置原型与新请求是否为同一个建筑（同资源路径即视为同一个）。
##
## 用资源路径而不是 `==`：`load()` 与 `preload()` 虽然共用资源缓存，但一旦缓存被释放、
## 或调用方分别用路径字符串/PackedScene 传入，引用比较就会误判成"换了建筑"，
## 于是重复点同一个图标也会重建蓝图 —— 把玩家已经摆好的位置与朝向抖掉。
func _is_same_pending_prototype(candidate) -> bool:
	if _pending_structure_prototype == null or candidate == null:
		return false
	if _pending_structure_prototype == candidate:
		return true
	if not (_pending_structure_prototype is Resource) or not (candidate is Resource):
		return false
	var pending_path: String = _pending_structure_prototype.resource_path
	return pending_path != "" and pending_path == candidate.resource_path


func _start_structure_placement(structure_prototype):
	if _structure_placement_started():
		# 【2026-09-28 用户报障修复·勿回退】放置模式已激活时再点另一个建筑图标，
		# 必须把待放置蓝图**换成新建筑**（红警式：点哪个就摆哪个）。
		# 此前这里无条件 `return`，请求被静默丢弃：玩家先点机场、改主意点对空炮，
		# 蓝图仍是机场、界面也没有任何提示 —— 表现就是"点了没反应 / 没有切换"。
		# 同一建筑重复点保持现状：不重建节点，免得把已摆好的位置与朝向抖掉。
		if _is_same_pending_prototype(structure_prototype):
			return
		_cancel_structure_placement()
	_pending_structure_prototype = structure_prototype
	_pending_construction_workers = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.has_method("request_legacy_construct")
			)
	)
	var blueprint_path = _balance_runtime.GetBlueprintScenePath(structure_prototype)
	assert(not blueprint_path.is_empty(), "structure is missing blueprint asset mapping")
	_active_blueprint_node = load(blueprint_path).instantiate()
	# 【2026-09-30 用户报"蓝图显示尺寸 ≠ 实际建造尺寸"】
	# 蓝图资产 = structure-geometries/*，也就是建筑那个 **Visual 子场景本身**。
	# 【世界米制归一化后】UnitRoot scale 恒为 1，美术缩放搬进了 Visual；
	# 所以这里要乘的是 **Visual 节点的缩放**（建筑 3.0 / 炮塔类 1.0），不是根缩放。
	# 这样"蓝图看到的尺寸 = 建成后的尺寸 = 碰撞/占地半径口径"三者一致。
	var blueprint_scale := Vector3.ONE
	if structure_prototype is PackedScene:
		var prototype_probe: Node3D = (structure_prototype as PackedScene).instantiate()
		var prototype_visual: Node = prototype_probe.get_node_or_null("Geometry")
		if prototype_visual == null:
			prototype_visual = prototype_probe.get_node_or_null("DetachTransform/Geometry")
		if prototype_visual is Node3D:
			blueprint_scale = (prototype_visual as Node3D).scale
		prototype_probe.free()
	var blueprint_origin = Vector3(-999, 0, -999)
	var camera_direction_yless = (
		(get_viewport().get_camera_3d().project_ray_normal(Vector2(0, 0)) * Vector3(1, 0, 1))
		. normalized()
	)
	var rotate_towards = blueprint_origin + camera_direction_yless.rotated(Vector3.UP, PI * 0.75)
	_active_blueprint_node.global_transform = Transform3D(Basis(), blueprint_origin).looking_at(
		rotate_towards, Vector3.UP
	)
	# 注意顺序：上面整支写 global_transform 会把基（含缩放）重置成 1，所以缩放必须在**之后**设。
	if not blueprint_scale.is_equal_approx(Vector3.ONE):
		_active_blueprint_node.scale = blueprint_scale
	add_child(_active_blueprint_node)
	_input_runtime.SetContextActive("BuildPlacement", true)
	_show_build_range_rings()


## 建造范围指示（2026-09-30 用户要求「出现蓝图的时候也要能显示一下建造范围」）。
## 半径与放置判据**同源**：由 C# 的 StructurePlacementRuntime.BuildRangeMeters() 提供，
## 不在 GDScript 里再写一个常量（两处各写一份必然漂移）。
var _build_range_rings: MeshInstance3D = null


func _show_build_range_rings() -> void:
	_clear_build_range_rings()
	var area := BuildPlacementArea.new()
	area.name = "BuildPlacementArea"
	_match.add_child(area)
	_build_range_rings = area
	area.configure(_match, _player, _placement_runtime, _pending_structure_prototype)
	area.set_blueprint_yaw(_active_blueprint_node.global_transform.basis.get_euler().y)


func _process(_delta: float) -> void:
	if _structure_placement_started() and is_instance_valid(_build_range_rings):
		_build_range_rings.set_blueprint_yaw(_active_blueprint_node.global_transform.basis.get_euler().y)


func _exit_tree() -> void:
	_clear_build_range_rings()


func _clear_build_range_rings() -> void:
	if _build_range_rings != null and is_instance_valid(_build_range_rings):
		_build_range_rings.hide()
		_build_range_rings.set_process(false)
		_build_range_rings.queue_free()
	_build_range_rings = null


func _set_blueprint_position_based_on_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	_active_blueprint_node.global_transform.origin = mouse_pos_3d
	_feedback_label.global_transform.origin = mouse_pos_3d


func _update_blueprint_color(blueprint_position_is_valid):
	var material_to_set = (
		preload(BLUEPRINT_VALID_PATH)
		if blueprint_position_is_valid
		else preload(BLUEPRINT_INVALID_PATH)
	)
	for child in _active_blueprint_node.find_children("*"):
		if "material_override" in child:
			child.material_override = material_to_set


func _cancel_structure_placement():
	_clear_build_range_rings()
	if _structure_placement_started():
		_feedback_label.hide()
		_active_blueprint_node.queue_free()
		_active_blueprint_node = null
	_pending_construction_workers = []
	_input_runtime.SetContextActive("BuildPlacement", false)


## 【2026-09-29 用户实报"造不下去"】点击落点不合规时的自动吸附搜索半径。
## 大建筑（矿场 9.8m）的可建环带被矿点 carve 与相邻规则切得很碎，10m 足够
## 从"贴着基地点的位置"跨到真正的可建环带（16.8~22.8m）。
const SNAP_SEARCH_MAX_RADIUS_M := 10.0
## 全场吸附（以己方建筑网络为锚）的最大搜索半径：比局部吸附大，覆盖
## "环带被矿点整条堵死、合法点在别的方位"的情况。
const AUTO_SPOT_MAX_RADIUS_M := 28.0


## 只有"空间类"失败才值得吸附；余额不足/已有在建工地/未授权是确定性拒绝，吸了也没用。
func _should_snap_to_valid_spot(result: Dictionary) -> bool:
	var primary: String = str(result.get("primary_issue", ""))
	return primary in ["Occupied", "NotAdjacent", "SurfaceNotBuildable", "OutOfBounds", "ValidationUnavailable"]


func _snap_transform_if_possible():
	var evaluation = _placement_runtime.Evaluate(_player, _pending_structure_prototype, _active_blueprint_node.global_transform, {})
	var primary := str(evaluation.get("primary_issue", ""))
	if not primary in ["Occupied", "NotAdjacent", "SurfaceNotBuildable", "OutOfBounds"]:
		return null
	var snapped: Transform3D = _find_nearest_valid_spot(
		_active_blueprint_node.global_transform.origin, SNAP_SEARCH_MAX_RADIUS_M)
	if snapped == Transform3D.IDENTITY:
		return null
	print("[PLACE] 点击位置不合法（%s），自动吸附到合法落点 (%s)" % [primary, str(snapped.origin)])
	return snapped


## 以点击点为圆心、逐环逐方位找**最近**合法落点（保持蓝图当前朝向）。
## 返回 Transform3D.IDENTITY 表示没找到；调用方据此放弃吸附。
func _find_nearest_valid_spot(center: Vector3, max_radius: float) -> Transform3D:
	var basis: Basis = _active_blueprint_node.global_transform.basis
	var cost: Dictionary = {}
	if _balance_runtime != null and _balance_runtime.has_method("GetConstructionCost"):
		cost = _balance_runtime.GetConstructionCost(_pending_structure_prototype)
	var step := 1.0
	var radius := 1.0
	while radius <= max_radius:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var candidate := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var probe = _placement_runtime.Evaluate(
				_player, _pending_structure_prototype, Transform3D(basis, candidate), cost
			)
			if probe is Dictionary and bool(probe.get("accepted", false)):
				return Transform3D(basis, candidate)
		radius += step
	return Transform3D.IDENTITY


func _finish_structure_placement():
	if NetSession.should_forward_commands():
		_clear_build_range_rings()
		# 联机傀儡端：放置必须转发到权威服务器（此前只在本地产出建筑, 服务器毫不知情）。
		var match_node := find_parent("Match")
		var sync := match_node.get_node_or_null("NetSync") if match_node != null else null
		if sync != null:
			var transform: Transform3D = _active_blueprint_node.global_transform
			sync.forward_command(
				"place_structure",
				_pending_construction_workers,
				transform.origin,
				null,
				_player,
				_pending_structure_prototype.resource_path
				+ "|"
				+ str(transform.basis.get_euler().y)
			)
			_pending_construction_workers = []
			_input_runtime.SetContextActive("BuildPlacement", false)
			_active_blueprint_node.queue_free()
			_active_blueprint_node = null
			return
	var result = _placement_runtime.Place(
		_player,
		_pending_structure_prototype,
		_active_blueprint_node.global_transform,
		{}  # ECO-007B：Legacy 参数保留兼容，权威成本由 C# Catalog 查询。
	)
	# 【2026-09-29 用户三次实报"建筑造不下去"】玩家点的位置经常只差几米就是合法的
	# （大建筑的可建环带被矿点/相邻规则切得很碎，肉眼找不到）。放置失败且原因是
	# 空间类（占用/不相邻/地形）时，以**点击点为圆心**搜最近合法落点，把蓝图挪过去
	# 再放一次 —— RTS 标准的"自动就近落位"，比让玩家对着红字猜位置可用得多。
	if not result["accepted"] and _should_snap_to_valid_spot(result):
		# 两级吸附：① 先以点击点为圆心找最近的（10m 内，保持玩家意图）；
		# ② 找不到再退到"以己方建筑网络为锚"的全场搜索（矿场 9.8m 的可建环带
		#    可能被矿点整条堵死，此时最近合法点在完全不同的方位）。
		var snapped: Transform3D = _find_nearest_valid_spot(
			_active_blueprint_node.global_transform.origin, SNAP_SEARCH_MAX_RADIUS_M
		)
		if snapped == Transform3D.IDENTITY:
			var reply = _placement_runtime.FindAutoSpot(
				_player, _pending_structure_prototype, "base",
				_active_blueprint_node.global_transform.origin, AUTO_SPOT_MAX_RADIUS_M
			)
			if reply is Dictionary and bool(reply.get("found", false)):
				snapped = Transform3D(
					_active_blueprint_node.global_transform.basis,
					reply["pos"]
				)
		if snapped != Transform3D.IDENTITY and snapped.origin != Vector3.INF:
			print("[PLACE] 点击位置不合法（%s），自动吸附到合法落点 (%s)" % [
				str(result.get("primary_issue", "")), str(snapped.origin)
			])
			_active_blueprint_node.global_transform = snapped
			result = _placement_runtime.Place(
				_player,
				_pending_structure_prototype,
				_active_blueprint_node.global_transform,
				{}
			)
	if result["accepted"]:
		_placement_runtime.AssignBuilders(
			_pending_construction_workers,
			result["structure"],
			_player,
			result["displaced_unit_ids"]
		)
		_cancel_structure_placement()
	elif result["primary_issue"] == "InsufficientResources":
		MatchSignals.not_enough_resources_for_construction.emit(_player)
	elif result["primary_issue"] == "ConstructionInProgress":
		# 释放瞬间的复评与拖动预览之间存在窗口（另一端完工/取消不会发生，但转发/
		# 同帧竞态仍可能翻脸），兜底发同一信号；蓝图保留等待下一次评估。
		MatchSignals.construction_slot_busy.emit(_player)


func _start_blueprint_rotation():
	_blueprint_rotating = true


func _try_rotating_blueprint_by(degrees):
	if not _structure_placement_started():
		return
	_active_blueprint_node.global_transform.basis = (
		_active_blueprint_node.global_transform.basis.rotated(Vector3.UP, deg_to_rad(degrees))
	)


func _rotate_blueprint_towards_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	var mouse_pos_yless = mouse_pos_3d * Vector3(1, 0, 1)
	var blueprint_pos_3d = _active_blueprint_node.global_transform.origin
	var blueprint_pos_yless = blueprint_pos_3d * Vector3(-999, 0, -999)
	if mouse_pos_yless.distance_to(blueprint_pos_yless) < ROTATION_DEAD_ZONE_DISTANCE:
		return
	var rotation_target = Vector3(mouse_pos_yless.x, blueprint_pos_3d.y, mouse_pos_yless.z)
	if rotation_target.is_equal_approx(_active_blueprint_node.global_transform.origin):
		return
	_active_blueprint_node.global_transform = _active_blueprint_node.global_transform.looking_at(
		rotation_target, Vector3.UP
	)


func _finish_blueprint_rotation():
	_blueprint_rotating = false


func _on_structure_placement_request(structure_prototype):
	_start_structure_placement(structure_prototype)


func _on_input_action_pressed(action_id: String):
	if action_id == "build.rotate":
		_try_rotating_blueprint_by(ROTATION_BY_KEY_STEP)
		return
	if action_id == "global.cancel" and _structure_placement_started():
		_finish_blueprint_rotation()
		_cancel_structure_placement()
		# 认领本次 ESC：取消放置优先于菜单兜底唤出（见 EscapeRouter 不变式）。
		EscapeRouter.claim()
