extends Node

## 最小"真实对局 + 场景内截图"探针（2026-10-07）。
##
## 目的：把"截图到底能不能拿到"从 DCS/TCP 路径里剥离出来单独判定。
## **逐字沿用** `tests/performance/SmallArmyPerformanceProbe.gd` 已经跑通的写法：
##   root.add_child.call_deferred(_match) → await process_frame → current_scene = _match
##   → await create_timer(...) → await RenderingServer.frame_post_draw
##   → get_viewport().get_texture().get_image().save_png(...)
## 差别只有：地图用**实例**（`Match._set_map` 直接 add_child）、场景自己 `current_scene`、
## 不连网络、三种取图时机各试一次（分辨"哪种时机在本机可行"）。
##
## marker: `SHOT PROBE completed: <n> png, <m> failure(s)`

const OUT_DIR := "res://agent/runs/2026-10-07-adjutant-continuity-fix/round-03/shotprobe"
const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

var _match: Node = null
var _failures := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.local_player_index = 0

	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await get_tree().process_frame
	get_tree().current_scene = _match
	# 与已验证探针同样的等待节奏（地图实例化 + 导航烘焙 + 初始单位生成）。
	await get_tree().create_timer(8.0).timeout
	get_tree().current_scene = _match
	print("[SHOT] units=%d  local_player=%s" % [
		get_tree().get_nodes_in_group("units").size(),
		str(_match.get_local_player() != null)])

	var camera = _match.get_node_or_null("IsometricCamera3D")
	if camera != null:
		camera.edge_scroll_enabled = false
		if camera.has_method("set_size_safely"):
			camera.set_size_safely(120.0)
		if camera.has_method("set_position_safely") and _match.get_local_player() != null:
			var players: Node = _match.get_node_or_null("Players")
			var focus := Vector3(40, 0, 28)
			if players != null and players.get_child_count() > 0 \
					and players.get_child(0).get_child_count() > 0:
				var unit = players.get_child(0).get_child(0)
				if unit is Node3D:
					focus = (unit as Node3D).global_position
			camera.set_position_safely(focus + Vector3(-15, 0, -15))
		print("[SHOT] camera positioned")

	var written := 0
	for index in range(3):
		await get_tree().create_timer(2.0).timeout
		if index == 0:
			await get_tree().process_frame
		elif index == 1:
			await RenderingServer.frame_post_draw
		else:
			await RenderingServer.frame_post_draw
			for _i in range(5):
				await get_tree().process_frame
		var path := "%s/shot_%02d.png" % [OUT_DIR, index]
		var started := Time.get_ticks_msec()
		var image: Image = get_viewport().get_texture().get_image()
		var elapsed := Time.get_ticks_msec() - started
		if image == null:
			print("[SHOT] #%d image=null after %dms" % [index, elapsed])
			_failures += 1
			continue
		var err := image.save_png(ProjectSettings.globalize_path(path))
		print("[SHOT] #%d %dx%d save_png=%d in %dms" % [index, image.get_width(),
			image.get_height(), err, elapsed])
		if err == OK:
			written += 1
		else:
			_failures += 1

	print("SHOT PROBE completed: %d png, %d failure(s)" % [written, _failures])
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)
