extends Node

const MatchScene = preload("res://tests/manual/TestCombatPolicies.tscn")

const FIELD_POSITION := 1
const FIELD_TYPE := 2
const FIELD_RELATION := 4
const FIELD_HEALTH := 8
const FIELD_ALL := FIELD_POSITION | FIELD_TYPE | FIELD_RELATION | FIELD_HEALTH

var _failures := 0


## 验证 Match 查询组合根、显式空集合、己方准确数据和普通/全知视野差异。
func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().process_frame

	var human = match_instance.get_node("Players/Human")
	var own_tank = human.get_node("Tank")
	var enemy = match_instance.get_node("Players/PolicyTestEnemy/TargetCommandCenter")
	var runtime = match_instance.get_node("WorldQueryRuntime")
	var standard_session: String = runtime.GetStandardSessionForTests(human)
	var debug_session: String = runtime.GetDebugSessionForTests(human)
	_check(not standard_session.is_empty(), "Match 组合根应为 Human 签发标准查询会话")
	_check(not debug_session.is_empty(), "调试构建应为测试签发独立全知会话")

	var own_forces = runtime.GetOwnForces(standard_session, FIELD_ALL)
	_check(own_forces["status"] == "Accepted", "己方单位查询应成功")
	_check(own_forces.has("entities") and own_forces["entities"].size() == 1,
		"TestCombatPolicies 应准确返回一辆己方 Tank")
	_check(own_forces["entities"][0]["current_health"] == own_tank.hp,
		"己方生命值应与权威单位状态一致")

	var own_reference = runtime.GetOwnEntityReferenceForTests(own_tank, human)
	var own_inspection = runtime.InspectOwnEntity(
		standard_session,
		own_reference["kind"],
		own_reference["id"],
		FIELD_POSITION | FIELD_HEALTH
	)
	_check(own_inspection["status"] == "Accepted", "按 ID 查询己方单位应成功")
	_check(own_inspection["entity"]["state"] == "Owned", "己方查询应标记 Owned")
	_check(runtime.GetOwnEntityReferenceForTests(enemy, human).is_empty(),
		"桥接入口不得为敌军生成可直接查询的己方引用")

	var empty_scan = runtime.ScanCircle(
		standard_session,
		Vector3(2, 0, 2),
		0.5,
		FIELD_TYPE
	)
	_check(empty_scan["status"] == "Accepted", "合法空范围应返回成功")
	_check(empty_scan.has("entities") and empty_scan["entities"].is_empty(),
		"合法空范围必须保留 entities 键和空数组")

	var enemy_position: Vector3 = enemy.global_position
	var initially_visible = runtime.ScanCircle(
		standard_session,
		enemy_position,
		1.0,
		FIELD_ALL
	)
	_check(initially_visible["entities"].size() == 1,
		"敌方建筑进入范围查询时应建立当前观察")
	var enemy_id: String = initially_visible["entities"][0]["id"]
	own_tank.global_position = Vector3(2, 0, 2)
	await get_tree().physics_frame
	var normal_hidden = runtime.ScanCircle(
		standard_session,
		enemy_position,
		1.0,
		FIELD_ALL
	)
	var debug_hidden = runtime.ScanCircle(
		debug_session,
		enemy_position,
		1.0,
		FIELD_ALL
	)
	_check(normal_hidden["entities"].size() == 1,
		"普通会话应保留曾观察敌方建筑的 LastKnown")
	_check(normal_hidden["entities"][0]["state"] == "LastKnown",
		"普通会话不得把视野外敌方建筑标记为实时可见")
	_check(debug_hidden["entities"].size() == 1,
		"全知调试会话应看到同一视野外敌方建筑")
	_check(debug_hidden["entities"][0]["state"] == "VisibleNow",
		"全知调试会话应返回实时而非残影状态")
	_check(
		normal_hidden["entities"][0]["observed_revision"]
		< normal_hidden["observation_revision"],
		"LastKnown 应区分最后观察版本和当前查询版本"
	)

	enemy.queue_free()
	await get_tree().process_frame
	var destroyed_while_hidden = runtime.ScanCircle(
		standard_session,
		enemy_position,
		1.0,
		FIELD_TYPE
	)
	_check(destroyed_while_hidden["entities"].size() == 1,
		"敌方建筑在视野外被摧毁时不应立即泄漏并清除残影")
	own_tank.global_position = enemy_position
	await get_tree().physics_frame
	var reobserved_empty = runtime.ScanCircle(
		standard_session,
		enemy_position,
		1.0,
		FIELD_TYPE
	)
	_check(not reobserved_empty["entities"].any(
		func(entity): return entity["id"] == enemy_id
	),
		"重新获得最后位置视野并确认建筑不存在后应清除残影")

	var economy = runtime.GetOwnEconomy(standard_session)
	_check(economy["status"] == "Accepted", "己方经济查询应成功")
	_check(economy["economy"].has("balances"), "经济成功结果必须显式包含余额")

	print("World query runtime smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


## 累计断言失败并输出可定位原因。
func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error(message)
