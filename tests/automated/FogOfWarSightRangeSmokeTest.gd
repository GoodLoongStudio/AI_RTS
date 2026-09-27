extends Node

## 第二轮任务 B 的回归哨兵：FogOfWar 遇到 sight_range == null 的单位
## （= 没拿到平衡目录定义的单位）必须
##   ① 不逐帧抛 "Invalid operands 'Nil' and 'int'"（旧行为：一次测试 2 万+ 条），
##   ② 按单位种类只警告一次，
##   ③ 不能因此中断本轮同步——其余单位的迷雾圈仍要正常建立/更新。
## 做法：起真对局夹具，塞一个假单位进 revealed_units 组（sight_range 保持 null），
## 连跑两次 _sync_revealed_circles，断言上述三点。
## 错误日志是否刷屏由套件的 forbidden_output_patterns 在进程输出侧把关（SCRIPT ERROR 即判失败）。

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const FakeUnitScene = preload("res://tests/automated/FogOfWarNullSightFakeUnit.gd")

var _failures := 0


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[PASS] " + message)
		return
	_failures += 1
	print("[FAIL] " + message)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame
	var match_instance: Node = MatchScene.instantiate()
	add_child(match_instance)

	var fog: Node = await _await_node(match_instance, "FogOfWar", 30.0)
	if fog == null:
		_check(false, "夹具里应能找到 FogOfWar 节点")
		await _finish(match_instance)
		return
	# 夹具可能按地图尺寸/可见性关掉迷雾运行时；被测路径要求它开着。
	fog.call("set_runtime_enabled", true)

	var real_unit: Node = await _await_revealed_unit(match_instance, 20.0)
	if real_unit == null:
		_check(false, "应存在带 sight_range 的己方/敌方可见单位")
		await _finish(match_instance)
		return

	fog.call("_sync_revealed_circles")
	var mapping: Dictionary = fog.get("_unit_to_circles_mapping")
	_check(mapping.has(real_unit), "正常单位的迷雾圈应先被建立（否则本测试无法证明未被打断）")

	# 塞入缺 sight_range 的假单位，模拟"平衡目录未命中"。
	var fake := Node3D.new()
	fake.name = "NullSightFake"
	fake.set_script(FakeUnitScene)
	match_instance.add_child(fake)
	fake.add_to_group("revealed_units")

	fog.call("_sync_revealed_circles")
	var warned: Dictionary = fog.get("_missing_sight_range_warned")
	_check(not warned.is_empty(), "缺 sight_range 的单位应触发一次警告（不得静默吞掉）")
	_check(not fog.get("_unit_to_circles_mapping").has(fake),
		"缺 sight_range 的单位不得进入迷雾圈映射")
	_check(fog.get("_unit_to_circles_mapping").has(real_unit),
		"跳过坏单位后，其余单位的迷雾圈映射必须保留（旧行为会中断整个循环）")

	# 第二次同步：警告必须按种类去重，映射不得被反复建立/清理。
	fog.call("_sync_revealed_circles")
	warned = fog.get("_missing_sight_range_warned")
	_check(warned.size() == 1,
		"同一类缺 sight_range 单位只警告一次（实际 %d 条）" % warned.size())
	_check(fog.get("_unit_to_circles_mapping").has(real_unit),
		"第二次同步后正常单位映射仍在")

	fake.queue_free()
	await get_tree().process_frame
	await _finish(match_instance)


func _finish(match_instance: Node) -> void:
	print("FogOfWar sight range smoke test completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _await_node(root_node: Node, node_name: String, timeout_s: float) -> Node:
	var waited := 0.0
	while waited < timeout_s:
		var found: Node = root_node.find_child(node_name, true, false)
		if found != null:
			return found
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return null


## 等一个"在 revealed_units 组里且 sight_range 已有值"的单位出现。
func _await_revealed_unit(match_instance: Node, timeout_s: float) -> Node:
	var waited := 0.0
	while waited < timeout_s:
		for unit in get_tree().get_nodes_in_group("revealed_units"):
			if is_instance_valid(unit) and unit.get("sight_range") != null:
				return unit
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return null
