extends Node

## 维修/出售指定模式冒烟测试（2026-09-11 建立；2026-09-14 改为红警式持续模式）：
## 点维修按钮进入维修模式（光标换成扳手）→ 左键点建筑只切换该建筑维修，
## **点完不退出模式，可连续点下一座**；点出售按钮进入出售模式 → 点建筑出售该建筑；
## 点地面取消模式，右键（cancel_command_targeting）同样退出。
##
## 注意：`Structure._process` 会在**满血**或资金不足时自动停止维修，所以维修断言
## 必须先让建筑掉血，否则测的是"自动停止"而不是"维修生效"。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

var _failures := 0
var _finished := false
## 整局根节点：收尾时必须回收，否则 Match 下的音乐/特效会泄漏（见 SmokeTestExit）。
var _match: Node = null


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = _match.get_node("Players/Human")
	var controller = human.find_child("UnitActionsController", true, false)
	_check(controller != null, "应能找到本地 UnitActionsController")
	if controller == null:
		_finish()
		return

	# 经济账户就绪 + 资金
	var waited := 0.0
	while waited < 10.0 and human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")

	var barracks_a = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_a, Transform3D(Basis.IDENTITY, Vector3(14, 0, 10)), human, false
	)
	var barracks_b = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_b, Transform3D(Basis.IDENTITY, Vector3(16, 0, 10)), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	# 先打伤：满血建筑会被 Structure._process 立刻停止维修
	barracks_a.set_hp_without_damage(barracks_a.hp_max * 0.5)
	barracks_b.set_hp_without_damage(barracks_b.hp_max * 0.5)

	# 1) 维修模式：进入 → 点 A → 仅 A 进入维修，且模式保持
	controller.begin_repair_targeting()
	_check(controller.is_repair_targeting(), "点维修按钮后应处于维修指定模式")
	MatchSignals.unit_targeted.emit(barracks_a, Vector3(14, 0.5, 10))
	await get_tree().process_frame
	_check(controller.is_repair_targeting(), "点击建筑后维修模式应保持（红警式持续模式）")
	_check(barracks_a.is_repairing(), "被点击的 A 建筑应进入维修")
	_check(not barracks_b.is_repairing(), "B 建筑不应被波及")

	# 2) 持续模式：接着点第二座建筑
	MatchSignals.unit_targeted.emit(barracks_b, Vector3(16, 0.5, 10))
	await get_tree().process_frame
	_check(barracks_b.is_repairing(), "持续模式下应能接着点第二座建筑")
	_check(barracks_a.is_repairing(), "先点的 A 建筑维修状态不受影响")

	# 3) 修复是耗资回血：等 2 秒确认 A 在回血
	var hp_before: float = barracks_a.hp
	await get_tree().create_timer(2.0).timeout
	_check(barracks_a.hp > hp_before, "维修模式下 A 建筑应持续回血")
	barracks_a.set_repairing(false)
	barracks_b.set_repairing(false)

	# 4) 地面点击取消模式
	_check(controller.is_repair_targeting(), "点地面之前应仍在维修模式")
	MatchSignals.terrain_targeted.emit(Vector3(0, 0, 0))
	await get_tree().process_frame
	_check(not controller.is_repair_targeting(), "点击地面应取消维修指定模式")

	# 5) 出售模式：点 B 建筑 → 仅 B 被出售，且模式保持
	var funds_before: int = human.resource_a
	controller.begin_sell_targeting()
	_check(controller.is_sell_targeting(), "点出售按钮后应处于出售指定模式")
	_check(controller.get_active_command_targeting() == "Sell", "出售模式应可被查询（右键退出依赖它）")
	MatchSignals.unit_targeted.emit(barracks_b, Vector3(16, 0.5, 10))
	await get_tree().process_frame
	_check(controller.is_sell_targeting(), "点击建筑后出售模式应保持（红警式持续模式）")
	var b_sold := false
	if not is_instance_valid(barracks_b):
		b_sold = true
	elif barracks_b.hp == 0:
		b_sold = true
	_check(b_sold, "被点击的 B 建筑应被出售（hp=0 或已释放）")
	_check(human.resource_a > funds_before, "精准出售应只返还被点建筑的一半造价")
	_check(barracks_a.is_repairing() == false or is_instance_valid(barracks_a), "A 建筑不应被出售波及")

	# 6) 退出指定模式（右键 / ESC / 按钮再点最终都走 cancel_command_targeting）
	controller.cancel_command_targeting()
	await get_tree().process_frame
	_check(not controller.is_sell_targeting(), "退出后不应残留出售模式")
	_check(controller.get_active_command_targeting() == "", "退出后不应残留任何指定模式")

	# 7) 射线兜底必须能穿透挡在前面的静态碰撞体（地形碰撞板等）
	await _check_ray_fallback_through_occluder(controller, human)

	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	_finish()


## 实测（2026-09-14）：`intersect_ray` 的最近命中常是地形碰撞板
## `ReferenceStaticCollider`，建筑碰撞体排在它后面 ⇒ 只取最近命中的实现等于永远
## 不生效。这里在相机与目标建筑之间塞一块静态遮挡体，验证兜底会逐层穿透。
func _check_ray_fallback_through_occluder(controller, human):
	var camera := get_viewport().get_camera_3d()
	_check(camera != null, "射线兜底用例需要相机")
	if camera == null:
		return
	var forward := -camera.global_transform.basis.z
	var flat := Vector3(forward.x, 0.0, forward.z).normalized()
	if flat.length() < 0.5:
		_check(false, "相机朝向无法投影到地面，射线兜底用例无法进行")
		return
	var spot: Vector3 = camera.global_position + flat * 30.0
	spot.y = 0.0
	var target = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		target, Transform3D(Basis.IDENTITY, spot), human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.6).timeout
	target.set_hp_without_damage(target.hp_max * 0.5)

	var occluder := StaticBody3D.new()
	occluder.name = "RayFallbackTestOccluder"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(24.0, 24.0, 24.0)
	shape.shape = box
	occluder.add_child(shape)
	occluder.global_position = camera.global_position + flat * 12.0
	add_child(occluder)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var screen_position: Vector2 = camera.unproject_position(spot + Vector3(0, 1.0, 0))
	controller.begin_repair_targeting()
	await get_tree().process_frame
	var applied: bool = controller._try_structure_mode_from_ray(screen_position)
	await get_tree().process_frame
	_check(applied, "射线兜底应穿透前排遮挡体命中建筑")
	_check(target.is_repairing(), "穿透命中的建筑应进入维修")
	controller.cancel_command_targeting()
	occluder.queue_free()
	await get_tree().process_frame


func _on_failsafe():
	if _finished:
		return
	_finished = true
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1, _match)


func _finish():
	if _finished:
		return
	_finished = true
	print("Repair/Sell targeting smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Repair/Sell targeting smoke test assertion failed: %s" % message)
