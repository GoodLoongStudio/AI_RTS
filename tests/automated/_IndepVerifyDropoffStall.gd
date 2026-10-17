extends Node

## 独立验证探针（本轮新增，只读）：矿车在交货点附近被顶死时，**引擎自己的停滞检测为什么不动**。
##
## 背景（实测数字）：`_RefineryJamProbe` 在 gap=2/6/10/14 四档都是
## `交付=0 卡住次数=3（全部 drop_overlap）卡住秒数≈126~171`，而引擎侧
## `stall_detections / repaths / escapes / pocket_escapes` **全为 0**。
## 独立测量（3s 窗口净位移 < 0.5m）说"卡住了"，引擎说"没检测到停滞" —— 两者必有一个口径不对。
## `Movement._begin_recovery()` 的第一道门槛是 `_recovery_mode != "" or _committed_target == null`
## 就 return，所以这里直接把卡住单位的内部状态打出来，判断到底是
## ① 没有 committed target（永远不会进脱困），还是
## ② 有 committed target 但停滞判据本身没触发。
##
## 本探针不修改产品代码，只复用现成复现场景并读它的单位。

const JAM_SCENE := "res://tests/automated/_RefineryJamProbe.tscn"
const DUMP_AT := [6.0, 12.0, 18.0, 26.0]

var _elapsed := 0.0
var _dump_index := 0


func _ready():
	# 复现场景自己决定摆放与时长；这里给一个够短又足够卡住的窗口。
	OS.set_environment("AIRTS_JAM_SECONDS", "30")
	add_child(load(JAM_SCENE).instantiate())
	get_tree().create_timer(0.5).timeout.connect(_tick)


func _tick():
	_elapsed += 0.5
	if _dump_index < DUMP_AT.size() and _elapsed >= DUMP_AT[_dump_index]:
		_dump(_dump_index)
		_dump_index += 1
	if _elapsed >= 40.0:
		print("[DROPSTALL] done")
		get_tree().quit(0)
		return
	get_tree().create_timer(0.5).timeout.connect(_tick)


func _dump(index: int) -> void:
	var workers := []
	for node in get_tree().get_nodes_in_group("units"):
		if node != null and is_instance_valid(node) and str(node.get("unit_type_id")) == "worker":
			workers.append(node)
	print("=== [DROPSTALL] t=%.0fs workers=%d ===" % [_elapsed, workers.size()])
	var all_types := {}
	for node in get_tree().get_nodes_in_group("units"):
		if node != null and is_instance_valid(node):
			var tid := str(node.get("unit_type_id"))
			all_types[tid] = int(all_types.get(tid, 0)) + 1
	print("  all_units=%s" % JSON.stringify(all_types))
	for worker in workers:
		var action = worker.get("action")
		var action_name := "<null>"
		if action != null and action.get_script() != null:
			action_name = str(action.get_script().resource_path).get_file()
		var movement = worker.get_node_or_null("Movement") if worker is Node else null
		var committed = worker.get("_committed_target")
		var path_size = -1
		if movement != null and movement.has_method("get_current_path"):
			path_size = (movement.get_current_path() as Array).size()
		print(("  %s action=%s committed=%s target_pos=%s recovery_mode='%s' rounds=%s "
			+ "vel=%.2f path=%d resource_a=%s") % [
			str(worker.name), action_name,
			str(committed) if committed != null else "NULL",
			str(worker.get("target_position")),
			str(worker.get("_recovery_mode")),
			str(worker.get("_recovery_rounds")),
			float(worker.get("velocity").length()) if worker.get("velocity") != null else -1.0,
			path_size, str(worker.get("resource_a")),
		])
	var stats = null
	for worker in workers:
		if worker.get("recovery_stats") != null:
			stats = worker.get("recovery_stats")
			break
	if stats is Dictionary:
		var interesting := {}
		for key in ["stall_detections", "repaths", "escapes", "pocket_escapes", "budget_skips",
			"give_up_limit", "unreachable", "soft_phase_enters"]:
			interesting[key] = int(stats.get(key, -1))
		print("  recovery_stats=%s" % JSON.stringify(interesting))
