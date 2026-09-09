extends SceneTree

# 验证菜单 panel 在 viewport 内不溢出（带窗口模式，移到屏外渲染）。
#
# 用法：godot --path . --script res://tools/verify_menu_panel.gd -- <scenes> <resolutions>
# 例：godot --path . --script res://tools/verify_menu_panel.gd -- Options 1920x1080 1280x720 800x600
#     godot --path . --script res://tools/verify_menu_panel.gd -- ALL 1920x1080 1280x720
#
# 退出码：0 = 全部通过；1 = 有失败。
#
# 关键纪律：绝不能遍历 root.get_children() 批量 free——会把 Autoload (Globals 等) 一起
# free，新场景 _ready 访问 Globals.options 会炸 "previously freed"。务必用单独变量
# 持有上一轮 instance，仅 free 它。

const OUTPUT_DIR := "res://tmp_logs/ui_fit"

const SCENES := {
	"Options": "res://source/main-menu/Options.tscn",
	"Main": "res://source/main-menu/Main.tscn",
	"Online": "res://source/main-menu/Online.tscn",
	"Play": "res://source/main-menu/Play.tscn",
	"Credits": "res://source/main-menu/Credits.tscn",
}

var _failures := 0
var _scenes := []
var _resolutions: Array[Vector2i] = []
var _last_inst: Node = null


func _initialize() -> void:
	_parse_args()
	if _scenes.is_empty():
		print("用法: -- <scene_name_or_ALL> <WxH>...")
		quit(1)
		return
	if _resolutions.is_empty():
		_resolutions = [Vector2i(1920, 1080)]

	# 屏外渲染，不抢用户前台
	var win := root.get_window()
	if win != null:
		win.position = Vector2i(-10000, -10000)
		win.mode = Window.MODE_WINDOWED

	for scene_name in _scenes:
		for res in _resolutions:
			await _check(scene_name, res)

	if _failures > 0:
		push_error("FAIL: %d case(s) have overflowing panel" % _failures)
		quit(1)
	else:
		print("PASS: %d scenes x %d resolutions, all panel fits viewport" % [_scenes.size(), _resolutions.size()])
		quit(0)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "ALL":
			_scenes = SCENES.keys()
		elif SCENES.has(arg):
			_scenes.append(arg)
		elif "x" in arg and arg.length() > 3:
			var parts := arg.split("x")
			if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
				_resolutions.append(Vector2i(int(parts[0]), int(parts[1])))


func _check(scene_name: String, res: Vector2i) -> void:
	var scene_path: String = SCENES[scene_name]

	# 调整窗口大小
	var win := root.get_window()
	if win != null:
		win.size = res

	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("[%s @ %dx%d] 无法加载场景" % [scene_name, res.x, res.y])
		_failures += 1
		return
	# 只 free 上一轮挂的场景实例，绝不能 free root.get_children()——会把 Autoload 一起 free
	if is_instance_valid(_last_inst):
		_last_inst.queue_free()
		await process_frame
	_last_inst = packed.instantiate()
	root.add_child(_last_inst)

	# 等 _ready + 动态构建 + clamp 全部完成
	for i in range(8):
		await process_frame

	var panel_paths := ["PanelContainer", "CenterContainer/PanelContainer"]
	var panel: Control = null
	for p in panel_paths:
		panel = _last_inst.get_node_or_null(p) as Control
		if panel != null:
			break
	if panel == null:
		push_error("[%s @ %dx%d] 找不到 panel" % [scene_name, res.x, res.y])
		_failures += 1
		return

	var viewport_rect: Rect2 = root.get_viewport().get_visible_rect()
	var panel_rect: Rect2 = panel.get_global_rect()
	var fits: bool = (
		panel_rect.position.x >= viewport_rect.position.x - 0.5
		and panel_rect.position.y >= viewport_rect.position.y - 0.5
		and panel_rect.end.x <= viewport_rect.end.x + 0.5
		and panel_rect.end.y <= viewport_rect.end.y + 0.5
	)
	print("[%s @ %dx%d] viewport=%s panel=%s %s" % [
		scene_name, res.x, res.y, viewport_rect.size, panel_rect, "OK" if fits else "OVERFLOW"
	])

	# 截图存档
	RenderingServer.force_draw(true)
	await process_frame
	await process_frame
	var tex := root.get_viewport().get_texture()
	if tex != null:
		var img := tex.get_image()
		if img != null:
			var out_dir := ProjectSettings.globalize_path(OUTPUT_DIR)
			DirAccess.make_dir_recursive_absolute(out_dir)
			var path := "%s/%s_%dx%d.png" % [out_dir, scene_name.to_lower(), res.x, res.y]
			img.save_png(path)
			print("  screenshot: %s" % path)

	if not fits:
		_failures += 1