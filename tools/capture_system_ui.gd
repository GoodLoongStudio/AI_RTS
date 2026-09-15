extends Node

## 系统 UI 视觉取证：**必须带窗口**才能出图（headless 拿不到帧）。
##
## 用法（窗口移到屏幕外，不抢前台）：
##   godot --path . --resolution 1600x900 --position -4000,-4000 res://tools/capture_system_ui.tscn
## 输出：res://tmp_ui_shots/*.png
##
## 为什么不用 headless：`Viewport.get_texture()` 在 headless 下拿不到已绘制的帧，
## 存出来是全黑；本仓库既有对照（capture_promo / probe_resolution 的带窗口分支）。

const SHOT_DIR := "res://tmp_ui_shots"

var _shot_dir := SHOT_DIR
const PAGES := [
	["01_main", "res://source/main-menu/Main.tscn"],
	["02_play", "res://source/main-menu/Play.tscn"],
	["03_online", "res://source/main-menu/Online.tscn"],
	["04_growth", "res://source/main-menu/Growth.tscn"],
	["05_growth_upgrades", "res://source/main-menu/GrowthUpgrades.tscn"],
	["06_player_profile", "res://source/main-menu/PlayerProfile.tscn"],
	["07_options", "res://source/main-menu/Options.tscn"],
	["09_map_generation", "res://source/main-menu/MapGeneration.tscn"],
]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var spec := _requested_resolution()
	if not spec.is_empty():
		# 注意：带窗口运行时 `--resolution` 对本项目**不生效**（project 里设了
		# viewport 1920x1080 且没有 window override），所以必须在这里显式改窗口尺寸，
		# 否则 1280x720 的取证永远拿不到（会静静出成 1920x1080）。
		var size := _parse_size(spec)
		if size != Vector2i.ZERO:
			get_window().size = size
			for _i in range(3):
				await get_tree().process_frame
	var dir := SHOT_DIR if spec.is_empty() else "%s/%s" % [SHOT_DIR, spec]
	DirAccess.make_dir_recursive_absolute(dir)
	_shot_dir = dir
	for entry in PAGES:
		await _capture(str(entry[0]), str(entry[1]))
	await _capture_empty_profile()
	print("[CAPTURE] >>> done | display=%s viewport=%s dir=%s" % [
		DisplayServer.get_name(), str(get_viewport().get_visible_rect().size), dir,
	])
	SmokeTestExit.request(get_tree(), 0)


func _requested_resolution() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--res="):
			return arg.substr("--res=".length())
	return ""


func _parse_size(spec: String) -> Vector2i:
	var parts := spec.split("x", false)
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


func _capture(name: String, path: String) -> void:
	var page := await _open(path)
	if page == null:
		return
	await _shoot(name)
	page.queue_free()
	await get_tree().process_frame


func _capture_empty_profile() -> void:
	## 空快照态单独取证：GrowthStore 首次运行会播种 demo 档案，
	## 不临时清空就看不出"无 Hermes 画像快照"的空状态长什么样。
	var backup: Dictionary = GrowthStore.profile.duplicate(true)
	GrowthStore.profile = {}
	var page := await _open("res://source/main-menu/PlayerProfile.tscn")
	if page != null:
		if page.has_method("_bind"):
			page.call("_bind")
		await _shoot("08_player_profile_empty")
		page.queue_free()
		await get_tree().process_frame
	GrowthStore.profile = backup


func _open(path: String) -> Node:
	if not ResourceLoader.exists(path):
		print("[CAPTURE] 缺场景：%s" % path)
		return null
	var page := (load(path) as PackedScene).instantiate()
	add_child(page)
	for _i in range(4):
		await get_tree().process_frame
	return page


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var out := "%s/%s.png" % [_shot_dir, name]
	var err := image.save_png(out)
	print("[CAPTURE] %s -> %s (err=%d size=%s)" % [name, out, err, str(image.get_size())])
