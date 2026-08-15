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

	enemy.global_position = Vector3(29, 0, 29)
	var normal_hidden = runtime.ScanCircle(
		standard_session,
		enemy.global_position,
		1.0,
		FIELD_ALL
	)
	var debug_hidden = runtime.ScanCircle(
		debug_session,
		enemy.global_position,
		1.0,
		FIELD_ALL
	)
	_check(normal_hidden["entities"].is_empty(), "普通会话不得看到视野外敌方建筑")
	_check(debug_hidden["entities"].size() == 1,
		"全知调试会话应看到同一视野外敌方建筑")

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
	push_error(message)
