extends RefCounted

## 冒烟测试通用预热工具。
##
## 注意：这里**不使用** `class_name`。headless 运行不会重新扫描项目来注册全局类名
## （需要 `--editor` 导入），未注册时测试脚本会直接 `Parse Error: Identifier ... not declared`。
## 各测试请用 `const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")`。
##
## 运行时导航网格是**异步烘焙**的：`Match._ready` 会 `await navigation.setup(map)`，
## 之后才执行 `_setup_player_units()`，把场景里预置的单位加入 `units` 组。
## 在那一刻之前下发命令 / 设置火力策略，单位在域模型里已存在、命令也会被 Accepted，
## 但 GDScript 侧 Action 取不到 `units` 组祖先，表现为「命令成功但单位永久站桩」，
## 并伴随 `Nonexistent function ... in base 'Nil'` 错误。
##
## 因此所有会在开局立刻操作单位的冒烟测试都必须先调用这里的等待，
## 否则测试会假通过或永久挂起（曾经造成 LocalAvoidance/EntityForceMove 超时）。

const DEFAULT_MAX_PROCESS_FRAMES := 4000


## 等待 `units` 组至少有 min_count 个单位，且数量连续 stable_frames 帧不变。
static func wait_for_units(
	tree: SceneTree, min_count := 1, stable_frames := 2, max_process_frames := DEFAULT_MAX_PROCESS_FRAMES
) -> bool:
	var last_count := -1
	var stable := 0
	for _frame in range(max_process_frames):
		var count := tree.get_nodes_in_group("units").size()
		if count >= min_count and count == last_count:
			stable += 1
			if stable >= stable_frames:
				await tree.physics_frame
				return await _wait_for_usable_navigation(tree)
		else:
			stable = 0
		last_count = count
		await tree.process_frame
	push_error("SmokeTestWarmup.wait_for_units timed out (last count=%d, expected>=%d)" % [last_count, min_count])
	return false


## 单位登记进 units 组之后，导航网格仍可能处于异步烘焙/区域同步阶段：
## 此时下发命令会拿到空路径，单位在最初的几百毫秒里纹丝不动（实测会让
## "固定等待 0.25~0.4s 后断言已位移"的用例随机假失败）。
## 这里等到导航地图对第一个可移动单位的实际位置可用为止。
static func _wait_for_usable_navigation(tree: SceneTree, max_frames := 900) -> bool:
	var units := tree.get_nodes_in_group("units")
	for unit in units:
		if unit == null or not is_instance_valid(unit):
			continue
		var movement = unit.find_child("Movement")
		if movement == null:
			continue
		for _frame in range(max_frames):
			var nav_map: RID = movement.get_navigation_map()
			if nav_map.is_valid() and NavigationServer3D.map_get_closest_point_owner(
				nav_map, unit.global_position
			).is_valid():
				await tree.physics_frame
				return true
			await tree.physics_frame
		return false
	return true


## 等待导航地图对给定位置可用（closest-point owner 有效）。
static func wait_for_navigation(
	tree: SceneTree, movement: Node, position: Vector3, max_frames := 900
) -> bool:
	for _frame in range(max_frames):
		var nav_map: RID = movement.get_navigation_map()
		if nav_map.is_valid() and NavigationServer3D.map_get_closest_point_owner(
			nav_map, position
		).is_valid():
			return true
		await tree.physics_frame
	push_error("SmokeTestWarmup.wait_for_navigation timed out at %s" % str(position))
	return false
