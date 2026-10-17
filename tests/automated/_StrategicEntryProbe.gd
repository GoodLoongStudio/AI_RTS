extends Node

## 战前讨论室入口探针（RSI round-01 ✓）：
## 用两张**不同**的具体地图实例化 StrategicSandboxPage，断言 map_path / 标题 / 出生点概览确实随地图变化 ✓；
## 并断言全程**没有创建 Match**（提示词硬约束 ✓）。

const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"
# 用**4 人图**（与设置页筛选口径一致 ✓）动态取前两张，避免选到 8 出生点的大图 ✗
static func _pick_maps() -> Array:
	var paths: Array = MatchSetupShared.map_paths()
	return [str(paths[0]), str(paths[1])] if paths.size() >= 2 else paths

var _failures := 0


func _process(_delta: float) -> void:
	# 菜单场景在失焦时也会暂停 ⇒ 探针必须持续解除暂停，否则 await 永远不返回 ✗
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		push_error("[ENTRY] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var maps := _pick_maps()
	var results := []
	for mp in maps:
		var page: Node = load(PAGE).instantiate()
		page.set("map_path", mp)
		add_child(page)
		get_tree().current_scene = page
		for _f in range(30):
			await get_tree().process_frame
		var intel: Variant = page.get("_intel")
		# 标签是代码创建、**未命名**的 ⇒ 只能按页面成员变量取 ✓
		var name_label: Variant = page.get("_map_name_label")
		var size_label: Variant = page.get("_map_size_label")
		var spawns := 0
		var first_spawn := {}
		if intel is Dictionary:
			var d: Dictionary = intel
			spawns = (d.get("spawn_points", []) as Array).size()
			var sp: Array = d.get("spawn_points", [])
			if sp.size() > 0:
				first_spawn = sp[0]
		var row := {
			"map_path_in": mp,
			"map_path_on_page": str(page.get("map_path")),
			"intel_map_path": str(intel.get("map_path", "")) if intel is Dictionary else "<none>",
			"map_name": str(intel.get("map_name", "")) if intel is Dictionary else "",
			"title_text": name_label.text if name_label is Label else "<no label>",
			"size_text": size_label.text if size_label is Label else "<no label>",
			"spawn_count": spawns,
			"spawn1": first_spawn,
			"match_node_present": get_tree().root.find_child("Match", true, false) != null,
		}
		results.append(row)
		print("[ENTRY] map=%s ⇒ page.map_path=%s intel=%s 标题=%s 出生点=%d 首个=%s Match存在=%s" % [
			mp.get_file(), row["map_path_on_page"].get_file(), str(row["intel_map_path"]).get_file(),
			row["title_text"], spawns, str(first_spawn), str(row["match_node_present"])])
		page.queue_free()
		for _f in range(6):
			await get_tree().process_frame
	# 断言 ✓
	var a: Dictionary = results[0]
	var b: Dictionary = results[1]
	_check(a["map_path_on_page"] == str(maps[0]), "页面必须收到传入的地图路径（实际 %s）" % a["map_path_on_page"])
	_check(b["map_path_on_page"] == str(maps[1]), "第二张地图同样要收到（实际 %s）" % b["map_path_on_page"])
	_check(a["intel_map_path"] != b["intel_map_path"], "两张地图的情报路径必须不同")
	_check(a["title_text"] != b["title_text"] or a["size_text"] != b["size_text"], "两张地图的标题或尺寸必须不同（%s vs %s）" % [a["title_text"], b["title_text"]])
	_check(a["spawn_count"] == 4 and b["spawn_count"] == 4, "两张地图都必须解析出 4 个出生点（实际 %d / %d）" % [a["spawn_count"], b["spawn_count"]])
	_check(not a["match_node_present"] and not b["match_node_present"], "全程不得创建 Match 节点")
	var payload := {"probe": "strategic-entry", "results": results, "failures": _failures}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-prebattle-map-passing/"))
	var f := FileAccess.open(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-prebattle-map-passing/entry-probe.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	print("Strategic entry probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[ENTRY] OK: " + msg)
	else:
		_failures += 1
		push_error("[ENTRY] FAIL: " + msg)
