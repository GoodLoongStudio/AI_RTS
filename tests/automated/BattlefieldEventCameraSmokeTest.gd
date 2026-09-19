extends Node

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")
const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")

var _failures := 0


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	# ⚠️ `Match._ready()` 是异步的：单位约 0.3 秒后才进 `units`/`controlled_units` 组并绑上
	# `player`。只等两帧时 tank 尚未注册 ⇒ 阵亡事件在 IsOwnedByHuman 处被否、日志一条不记。
	await SmokeTestWarmup.wait_for_units(get_tree(), 1)

	var camera = match_instance.get_node("IsometricCamera3D")
	var events = match_instance.get_node("BattlefieldEventRuntime")
	var input_runtime = match_instance.get_node("InputBindingRuntime")
	# ⚠️ headless 下 `IsometricCamera3D._ready()` 提前 return（无头/专用服没有玩家输入）：
	# 既不接 `ActionPressed`、也关掉了 `_process`。所以"按键 → 跳转"链路只能在带窗口时测；
	# headless 退化为直接驱动被测函数，其余断言照常。
	var via_input: bool = input_runtime.is_connected("ActionPressed", camera._on_input_action_pressed)

	var start_position: Vector3 = camera.global_position
	_check(events.GetEventCount() == 0, "开局不应存在可跳转战场事件")
	_check(not camera.focus_latest_battlefield_event(), "没有事件时 Space 不得移动镜头")
	_check(camera.global_position.is_equal_approx(start_position), "空日志跳转后镜头应保持原位")

	var original_extents: Vector2 = camera._map_extents
	camera.set_map_bounds(Vector2(256, 256))
	_check(camera.bounding_planes.size() >= 4, "镜头包围面应为四面")
	_check(
		is_equal_approx(camera.bounding_planes[1].d, -256.0),
		"大图右边界必须写进 bounding_planes，不能停在场景默认 50"
	)
	_check(
		is_equal_approx(camera.bounding_planes[3].d, -256.0),
		"大图南边界必须写进 bounding_planes"
	)
	camera.set_map_bounds(original_extents if original_extents != Vector2.ZERO else Vector2(50, 50))

	# ⚠️ 事件坐标必须落在镜头的**合法中心范围**内。镜头把中心夹进
	# `[视野半宽, 地图尺寸 − 视野半宽]`，而 50×50 的测试图上这个范围只有约 12×20 米；
	# 原先写死的 (12,0,-8) 与 (-6,0,10) 四项全部落在范围外 ⇒ 双双被夹到同一个角
	# ⇒ 第二次跳转结果与第一次逐位相同（"Space 应跳到更新的事件位置"恒红）。
	# 这里从镜头自身派生两点，地图/视野再变也不会重新踩坑。
	var half: Vector2 = camera._view_half_extents_on_ground()
	var extents: Vector2 = camera._map_extents
	var legal_lo := half + Vector2(1.0, 1.0)
	var legal_hi := extents - half - Vector2(1.0, 1.0)
	_check(
		legal_hi.x > legal_lo.x and legal_hi.y > legal_lo.y,
		"测试地图应给镜头留出可移动的中心范围"
	)

	var first_event := Vector3(legal_lo.x, 0.0, legal_lo.y)
	events.RecordImportant("OwnUnitUnderAttack", first_event)
	_check(events.GetEventCount() == 1, "受击事件应写入日志")
	_focus_latest(camera, input_runtime, via_input)
	var camera_after_first: Vector3 = camera.global_position
	_check(not camera_after_first.is_equal_approx(start_position), "Space 应将镜头跳离原位置")

	var later_position := Vector3(legal_hi.x, 0.0, legal_hi.y)
	events.RecordImportant("VisibleHostileLost", later_position)
	_focus_latest(camera, input_runtime, via_input)
	_check(not camera.global_position.is_equal_approx(camera_after_first), "Space 应跳到更新的事件位置")

	var tank: Node3D = match_instance.get_node("Players/Human/Tank")
	var death_position: Vector3 = tank.global_position
	_check(death_position.length() > 1.0, "测试坦克应远离世界原点")
	tank.hp = 0
	await get_tree().process_frame
	await get_tree().process_frame
	var death_focus: Dictionary = events.TryGetLatestImportantFocus()
	_check(not death_focus.is_empty(), "己方单位阵亡应写入可跳转事件")
	_check(str(death_focus.get("kind", "")) == "OwnUnitLost", "阵亡应覆盖为最新跳转事件")
	var recorded: Vector3 = death_focus["position"]
	_check(recorded.distance_to(death_position) < 1.0, "阵亡事件必须使用离树前的世界坐标")
	_check(not recorded.is_equal_approx(Vector3.ZERO), "阵亡坐标不得退化成原点")
	_focus_latest(camera, input_runtime, via_input)
	_check(not camera.global_position.is_equal_approx(Vector3.ZERO), "Space 不得因阵亡跳回原点")

	print("Battlefield event camera smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 走真实按键链路（带窗口）；headless 下按键未接线，直接驱动被测函数。
func _focus_latest(camera: Node, input_runtime: Node, via_input: bool) -> void:
	if via_input:
		input_runtime.emit_signal("ActionPressed", "camera.focus_latest_event")
	else:
		camera.focus_latest_battlefield_event()


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Battlefield event camera assertion failed: %s" % message)
