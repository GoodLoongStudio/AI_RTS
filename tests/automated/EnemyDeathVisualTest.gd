extends Node

## 窗口化实局目视验证：玩家部队在敌方基地，亲眼看着敌方建筑被打掉。
## 截图 + 全树扫描双输出——截图看"用户看到什么"，扫描看"场景树里剩什么"。
## 2026-09-23 五轮：用户两轮报告"敌方死亡的建筑还在"，前三轮测试全部证实
## 场景树无残留，需要一次真实的、带渲染的、相机对准敌方的目视确认。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")

const OUT_DIR := "user://tmp_logs/enemy_death_visual"
const OUT_PNG := "user://tmp_logs/enemy_death_visual/after_destroy.png"
const OUT_BEFORE_PNG := "user://tmp_logs/enemy_death_visual/before_destroy.png"

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)
	get_tree().current_scene = a_match

	var deadline := Time.get_ticks_msec() + 90000
	var ready := false
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		var players: Node = a_match.get_node_or_null("Players")
		if players != null and players.get_child_count() >= 2:
			var ok := true
			for p in players.get_children():
				if p.get_child_count() == 0:
					ok = false
			if ok:
				ready = true
				break
	_check(ready, "对局应就绪")
	if not ready:
		_finish()
		return
	for _frame in range(240):
		await get_tree().physics_frame

	var players: Node = a_match.get_node("Players")
	var human_player = players.get_child(0)
	var ai_player = players.get_child(1)

	# 等规则 AI 多建几座建筑（真实敌方基地）
	var ai_structures: Array = []
	var wait_deadline := Time.get_ticks_msec() + 150000
	while Time.get_ticks_msec() < wait_deadline:
		await get_tree().physics_frame
		ai_structures = _structures_of(ai_player)
		if ai_structures.size() >= 3:
			break
	print("[INFO] 敌方建筑数 = ", ai_structures.size())
	_check(ai_structures.size() >= 2, "敌方应至少建成 2 座建筑")
	if ai_structures.size() < 2:
		_finish()
		return

	# 人类部队前出到敌方基地旁（用户视角：人在现场）
	var ai_center := Vector3.ZERO
	for s in ai_structures:
		ai_center += (s as Node3D).global_position
	ai_center /= float(ai_structures.size())
	print("[INFO] 敌方基地中心 = ", ai_center)
	for child in human_player.get_children():
		if child is Node3D and child.is_in_group("units"):
			(child as Node3D).global_position = ai_center + Vector3(10, 0, 10)
	for _frame in range(80):
		await get_tree().physics_frame

	# 相机对准敌方基地（用户视角：镜头就在这）
	var camera: Camera3D = a_match.get_viewport().get_camera_3d()
	if camera == null:
		camera = a_match.find_child("IsometricCamera3D", true, false) as Camera3D
	_check(camera != null, "应有相机")
	if camera != null:
		camera.global_position = ai_center + Vector3(28, 34, 28)
		camera.look_at(ai_center, Vector3.UP)
	for _frame in range(90):
		await get_tree().physics_frame

	var visible_count := 0
	for s in ai_structures:
		if (s as Node3D).visible:
			visible_count += 1
	print("[INFO] 部队到场后可见的敌方建筑数 = ", visible_count, "/", ai_structures.size())
	_check(visible_count >= 2, "部队到场后敌方建筑应可见（玩家看得见才谈得上'怎么还在'）")

	# 记录每座建筑死亡位置与死亡前网格数
	var targets: Array = []
	for s in ai_structures:
		if (s as Node3D).visible:
			targets.append({"node": s, "pos": (s as Node3D).global_position})
		if targets.size() >= 3:
			break
	var before_total := 0
	for t in targets:
		before_total += _meshes_near(a_match, t["pos"], 3.0).size()
	print("[INFO] 摧毁前目标位置网格总数 = ", before_total)

	await _capture(OUT_BEFORE_PNG)
	print("[INFO] 已存摧毁前截图 ", OUT_BEFORE_PNG)

	# 逐个摧毁（相机始终对准，玩家全程看着）
	for t in targets:
		var node: Node3D = t["node"]
		if is_instance_valid(node):
			node.hp = 0
		for _frame in range(45):
			await get_tree().physics_frame

	for _frame in range(120):
		await get_tree().physics_frame

	await _capture(OUT_PNG)
	print("[INFO] 已存摧毁后截图 ", OUT_PNG)

	# 扫描：每个死亡位置 3m 内不应再有该建筑的网格
	var leftover_total := 0
	for t in targets:
		var pos: Vector3 = t["pos"]
		var meshes := _meshes_near(a_match, pos, 3.0)
		var own := _owning_unit_paths(a_match, pos, 3.0)
		print("[INFO] 死亡位置 ", pos, " 剩余网格=", meshes.size())
		for m in meshes:
			print("[INFO]   left: ", m)
		# 只统计"还挂在某个已存在单位节点下"的（邻居建筑/单位属正常）
		leftover_total += own.size()
	print("[INFO] 死亡位置仍挂在存活单位下的网格总数 = ", leftover_total)
	_check(leftover_total == 0,
		"死亡位置不应再有挂在存活单位上的网格（实际 %d）" % leftover_total)

	var ghosts := _all_ghosts(a_match)
	print("[INFO] 全 Match 残影网格数 = ", ghosts.size())
	for g in ghosts:
		print("[INFO]   ghost: ", g)
	_check(ghosts.is_empty(), "整个 Match 不应再有任何迷雾残影（实际 %d）" % ghosts.size())

	_finish()


func _structures_of(player: Node) -> Array:
	var out: Array = []
	for child in player.get_children():
		if child is Node3D and child.is_in_group("units") and child.has_method("is_under_construction"):
			out.append(child)
	return out


## 死亡位置附近、且节点路径仍指向某个**存活**玩家单位的网格（真正的残留）。
func _owning_unit_paths(a_match: Node, pos: Vector3, within: float) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D and (node as GeometryInstance3D).visible:
			var node_pos: Vector3 = node.global_position
			if Vector2(node_pos.x, node_pos.z).distance_to(Vector2(pos.x, pos.z)) > within:
				continue
			# 沿祖先链找 Units 根：若该单位已不在场景树里（被释放），就是残留
			var path := str(node.get_path())
			if path.find("/Players/") < 0:
				continue
			var unit_path := path.substr(0, path.find("/", path.find("/Players/") + 9))
			var unit_node: Node = a_match.get_node_or_null(unit_path)
			if unit_node == null or not is_instance_valid(unit_node):
				out.append("%s (path=%s)" % [node.name, path])
	return out


## 整个 Match 下所有挂在 UnitVisibilityHandler 上的可见网格（迷雾残影）。
func _all_ghosts(a_match: Node) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D and (node as GeometryInstance3D).visible:
			var path := str(node.get_path())
			if path.find("UnitVisibilityHandler") >= 0:
				out.append("%s (path=%s)" % [node.name, path])
	return out


## 扫描 Match 子树下所有 GeometryInstance3D，返回距 pos 多近距离内的可见网格描述。
func _meshes_near(a_match: Node, pos: Vector3, within: float) -> Array:
	var out: Array = []
	var stack: Array[Node] = [a_match]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is GeometryInstance3D:
			var geo := node as GeometryInstance3D
			if not geo.visible:
				continue
			var node_pos: Vector3 = geo.global_position
			if Vector2(node_pos.x, node_pos.z).distance_to(Vector2(pos.x, pos.z)) <= within:
				out.append("%s @ %s (path=%s)" % [node.name,
					str(Vector2(node_pos.x, node_pos.z).round()), node.get_path()])
	return out


func _capture(path: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var abs := path.replace("user://", OS.get_user_data_dir() + "/")
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	image.save_png(abs)
	print("[INFO] screenshot saved: ", abs)


func _finish() -> void:
	if _failures == 0:
		print("Enemy death visual: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Enemy death visual: %d failure(s)" % _failures)
		get_tree().quit(1)
