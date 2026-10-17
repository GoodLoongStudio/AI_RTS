extends Node

## 战前讨论室视觉取证（窗口模式 ✓，照 tools/capture_system_ui.gd 的既有做法）：
## 用法：godot --path . --position -4000,-4000 res://tools/capture_strategic_prebattle.tscn
## 为什么不用 headless：headless 的 Viewport 拿不到已绘制帧（存出来全黑 ✗）。

const OUT_DIR := "res://agent/runs/2026-10-06-strategic-prebattle-ui-map/screenshots"
const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"

var _map_a := "res://source/match/maps/PlainAndSimple.tscn"
var _map_b := ""


func _process(_delta: float) -> void:
	# 窗口失焦时项目会暂停场景树 ⇒ 取证会卡在 await 上 ✗（本仓库实测）
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")


func _run() -> void:
	get_window().size = Vector2i(1600, 900)
	for _i in range(6):
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var paths: Array = MatchSetupShared.map_paths()
	for mp in paths:
		if str(mp).contains("generated"):
			_map_b = str(mp)
			break
	if _map_b == "":
		_map_b = _map_a
	# ① 布局修复后的地图 A 讨论室（未选点 ✓）
	await _capture("07_map_a_layout_fixed", _map_a, -1)
	# ② 选中出生点 1 后（右栏启用 + 欢迎语 ✓）
	await _capture("08_map_a_spawn1_selected", _map_a, 0)
	# ③ 地图 B（换图后名字/预览/出生点都不同 ✓）
	await _capture("09_map_b_layout_fixed", _map_b, -1)
	print("[CAPTURE-STRAT] done dir=%s" % OUT_DIR)
	SmokeTestExit.request(get_tree(), 0)


func _capture(name: String, map_path: String, spawn_index: int) -> void:
	var page: Control = load(PAGE).instantiate()
	page.set("map_path", map_path)
	get_tree().root.add_child(page)
	get_tree().current_scene = page
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	for _i in range(24):
		await get_tree().process_frame
	if spawn_index >= 0:
		page.call("_on_spawn_selected", spawn_index)
		for _i in range(10):
			await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name])
	var err := img.save_png(path)
	print("[CAPTURE-STRAT] %s err=%d size=%s" % [name, err, str(img.get_size())])
	page.queue_free()
	for _i in range(6):
		await get_tree().process_frame
