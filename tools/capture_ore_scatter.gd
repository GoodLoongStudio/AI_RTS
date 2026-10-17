extends Node

## 散矿素材与矿场外观的**实机截图取证**（提示词 §8.1 / §8.4 / §6「散矿素材」行）。
##
## 必须有窗口才能出图（headless 拿不到帧，存出来全黑），窗口移到屏幕外不抢前台：
##   Godot_v4.7.1-stable_mono_win64_console.exe --path G:/AIRTS/AI_RTS \
##     --position -4000,-4000 --resolution 1280x720 res://tools/capture_ore_scatter.tscn
##
## 出图口径（每张都标了状态，不接受"资源文件在"当证据）：
##   1. 矿点余量四态：丰富 / 稀疏 / 采空（留地表痕迹）/ 再生后恢复；
##   2. 散矿整体观感 + 工人到矿采集站位；
##   3. 矿场新外观（A 同包工业件 + B 散矿语汇）的完工态与施工半透明态；
##   4. 手摆图（TestAllUnits）与生成图各一组，避免只验一个入口。
##
## 相机走游戏自己的 Camera3D（ RTS 实战机位），不新建相机——副官/玩家的镜头高度
## 看到什么，取证就该是什么；新建相机会拍出一个现实中看不到的角度。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const RefineryScene = preload("res://source/match/units/OreRefinery.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
## 【2026-09-29】夹具图 16-0-2057e4a0b4 是旧规则产物，已随"坏地图清理"删除；
## 改用当前 5 张合格图之一（布局 47，矿点全部落在干地）。
const GeneratedMapScene = preload("res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn")

const SHOT_DIR := "res://tmp_ui_shots/ore_scatter"
## RTS 实战机位：镜头高度与俯角按游戏内默认相机口径（约 28m 高、55° 俯角）。
const CAMERA_HEIGHT := 28.0
const CAMERA_PITCH_DEGREES := 55.0

var _failures := 0
var _match: Node = null
var _camera: Camera3D = null
var _worker = null


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(_on_timeout)
	await _run()
	print("Ore scatter capture completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _run():
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_match = MatchScene.instantiate()
	add_child(_match)
	await _settle(90)
	_camera = _find_game_camera()
	if _camera == null:
		_fail("对局里找不到游戏相机，无法按实战机位取证")
		return
	# IsometricCamera3D 每帧都会按自己的状态重写位置与朝向，直接改 transform 会被立刻覆盖
	# （旧实现因此拍出一堆"镜头根本没对准矿群"的空画面）。取证期间把它的处理停掉：
	# 只借用它的正交投影/俯角/高度档位，机位由本工具指定。
	_camera.set_process(false)
	_camera.set_process_unhandled_input(false)
	_camera.set_process_input(false)

	# 选一片"有多个矿点挨着"的矿区当焦点：散矿要验的是成片观感，单点看不出来。
	var focus = _pick_ore_cluster_center(24.0)
	if focus == null:
		_fail("夹具自检：手摆图上应存在 24m 内至少 3 颗的矿点群")
		return
	print("[CAPTURE] 手摆图矿群焦点 %s" % str(focus))

	# 1) 余量四态（同一批矿点，只改存量与状态，机位不动 → 可直接横向比较）。
	var patch := _nodes_within(focus, 24.0)
	await _shoot_state(patch, "abundant", 1.0, false)
	await _shoot_state(patch, "sparse", 0.25, false)
	await _shoot_state(patch, "depleted", 0.0, true)
	await _shoot_state(patch, "regenerated", 0.5, false)

	# 2) 工人到矿采集站位（真挂上自动采集，不是摆个坐标）。
	var gather_node = patch[0] if patch.size() > 0 else null
	if gather_node != null:
		_worker = WorkerScene.instantiate()
		_match.call(
			"_setup_and_spawn_unit",
			_worker,
			Transform3D(Basis.IDENTITY, gather_node.global_position + Vector3(2.5, 0.6, 0.0)),
			_match.get_node("Players/Human"),
			false
		)
		await _settle(30)
		if _worker.has_method("request_legacy_start_auto_gather"):
			_worker.request_legacy_start_auto_gather()
		await _settle(180)
		_aim_at(gather_node.global_position)
		await _save("handmap_worker_gathering.png")

	# 3) 矿场新外观：完工态与施工半透明态各一张。
	var refinery_spot = focus + Vector3(9.0, 0.0, 0.0)
	var refinery = RefineryScene.instantiate()
	_match.call(
		"_setup_and_spawn_unit",
		refinery,
		Transform3D(Basis.IDENTITY, refinery_spot),
		_match.get_node("Players/Human"),
		false
	)
	await _settle(60)
	_aim_at(refinery_spot)
	await _save("handmap_refinery_constructed.png")
	# 施工态走产品自己的入口（`mark_as_under_construction` 会同时换上施工半透明材质），
	# 不手改字段——否则拍出来的"施工表现"和玩家实际看到的不是同一套东西。
	refinery.mark_as_under_construction()
	await _settle(30)
	await _save("handmap_refinery_under_construction.png")

	# 4) 生成图入口：同一套矿点素材在真实生成图上的成片观感。
	await _capture_generated_map()


## 把一片矿点设成指定余量并出图。`depleted` 走矿点自己的状态迁移，不手改字段。
func _shoot_state(patch: Array, slug: String, ratio: float, emptied: bool):
	for node in patch:
		if not is_instance_valid(node):
			continue
		var capacity_value = node.get("ore_capacity")
		if capacity_value == null:
			# 组里混进了没有矿点脚本的节点：打印出来，别让 int(null) 打断整轮取证。
			print("[CAPTURE] 跳过非矿点节点 %s (%s)" % [node.name, node.get_class()])
			continue
		var capacity := int(capacity_value)
		if capacity <= 0:
			continue
		# A/B 两种矿点持有的属性名不同：写死 resource_a 会让 B 矿拿到 null，
		# 后面的 int(null) 直接打断本函数（旧实现因此永远拍不出 abundant/sparse）。
		var property_name := ""
		if "resource_a" in node:
			property_name = "resource_a"
		elif "resource_b" in node:
			property_name = "resource_b"
		if property_name.is_empty():
			continue
		node.set(property_name, int(round(capacity * ratio)))
		if emptied and node.has_method("mark_depleted"):
			node.mark_depleted()
		elif not emptied and node.has_method("mark_ready") and int(node.get(property_name)) > 0:
			node.mark_ready()
		if node.has_method("_refresh_depletion_presentation"):
			node._refresh_depletion_presentation()
	await _settle(45)
	var center := _nodes_center(patch)
	_aim_at(center)
	await _save("handmap_ore_%s.png" % slug)


func _capture_generated_map():
	if not ResourceLoader.exists(GeneratedMapScene.resource_path):
		_fail("生成图入口缺失：%s" % GeneratedMapScene.resource_path)
		return
	var holder := Node3D.new()
	add_child(holder)
	# 【为什么要自己架灯和环境】上一版生成图那张直接是全黑：手摆图跑在 Match 场景里，
	# 光与 WorldEnvironment 由对局自己提供；生成图这里只挂了一个裸地图子树，
	# 没有任何光源 ⇒ 渲染出来只有 UI，3D 视图一片黑。
	# 判据是"RTS 镜头下能看清这片散矿"，黑屏不算出图。
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color("c9a883")
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.68, 0.55)
	e.ambient_light_energy = 0.7
	env.environment = e
	holder.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 34.0, 0.0)
	sun.light_energy = 1.05
	sun.shadow_enabled = true
	holder.add_child(sun)
	var map: Node3D = GeneratedMapScene.instantiate()
	holder.add_child(map)
	await _settle(240)
	var focus = _pick_ore_cluster_center_on(map, 26.0)
	if focus == null:
		_fail("生成图上找不到成片矿点（散矿布局未覆盖生成入口）")
		return
	print("[CAPTURE] 生成图矿群焦点 %s" % str(focus))
	# 生成图不带 Match 上下文，相机只能自己架在矿群上方（同样 28m/55°）。
	# 但必须是**正交 + 游戏同一档 size**：默认透视 fov75 在 28m 高、竖跨 ~43m，
	# 3m 的矿场只剩几个像素，整张就是一片糊棕（上一版出图即此）。
	var cam := Camera3D.new()
	holder.add_child(cam)
	cam.current = true
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 21.25  # 游戏开局档（IsometricCamera3D.OPENING_SIZE）
	cam.near = 0.05
	cam.far = 400.0
	_aim_with(cam, focus)
	await _settle(60)
	await _save_with(cam, "generatedmap_ore_scatter.png")
	holder.queue_free()


func _find_game_camera() -> Camera3D:
	for node in get_tree().get_nodes_in_group("cameras"):
		if node is Camera3D:
			return node
	var direct := _match.get_node_or_null("Camera3D")
	if direct is Camera3D:
		return direct
	for node in _match.find_children("*", "Camera3D", true, false):
		return node
	return null


func _pick_ore_cluster_center(min_spacing: float):
	return _pick_ore_cluster_center_on(_match, min_spacing)


func _resource_nodes(scope: Node) -> Array:
	"""取**这棵子树里**的矿点节点。

	【为什么不能用 group】干跑时生成图那一步返回的焦点坐标和手摆图一模一样——
	`get_tree().get_nodes_in_group("resource_units")` 是全局的，手摆图还挂在树上，
	于是"生成图入口"量的其实是手摆图的矿点。取证口径错了比不出图更糟。
	"""
	var out: Array = []
	for node in scope.find_children("*", "Node3D", true, false):
		if node.get("resource_a") != null or node.get("resource_b") != null:
			out.append(node)
	return out


func _pick_ore_cluster_center_on(scope: Node, min_spacing: float):
	var positions: Array = []
	for node in _resource_nodes(scope):
		positions.append(node.global_position)
	var best_center = null
	var best_count := 0
	for candidate in positions:
		var count := 0
		for other in positions:
			if Vector2(candidate.x - other.x, candidate.z - other.z).length() <= min_spacing:
				count += 1
		if count > best_count:
			best_count = count
			best_center = candidate
	# 【阈值为什么是 2 而不是 3】mapgen 的配额就是"每家 2×A 近矿 + 扩张 1×A+1×B"
	# （docs/mapgen/plan/4p-seeded-mapgen-plan.md:222），要求 3 颗挤在一起会把
	# **合格的散矿布局**误判成"图上没有成片矿点"。取证工具的判据错比不出图更糟。
	if best_count < 2:
		print("[CAPTURE] 最大矿群只有 %d 颗（min_spacing=%.0fm）" % [best_count, min_spacing])
		return null
	print("[CAPTURE] 最大矿群 %d 颗（间距 %.0fm）" % [best_count, min_spacing])
	return best_center


func _nodes_within(center: Vector3, radius: float) -> Array:
	var out: Array = []
	for node in _resource_nodes(_match):
		if not is_instance_valid(node):
			continue
		if Vector2(center.x - node.global_position.x,
				center.z - node.global_position.z).length() <= radius:
			out.append(node)
	return out


func _nodes_center(patch: Array) -> Vector3:
	# 采集过程中矿点可能被回收（耗尽的旧语义/再生驱动器），必须重新校验，
	# 否则取中心时会撞上 'previously freed' 而打断整个取证流程。
	var sum := Vector3.ZERO
	var count := 0
	for node in patch:
		if not is_instance_valid(node):
			continue
		sum += node.global_position
		count += 1
	return sum / max(1, count)


func _aim_at(target: Vector3) -> void:
	_aim_with(_camera, target)


func _aim_with(cam: Camera3D, target: Vector3) -> void:
	var pitch := deg_to_rad(CAMERA_PITCH_DEGREES)
	var horizontal := CAMERA_HEIGHT / tan(pitch)
	cam.global_position = target + Vector3(0.0, CAMERA_HEIGHT, horizontal)
	cam.rotation_degrees = Vector3(-CAMERA_PITCH_DEGREES, 0.0, 0.0)
	cam.current = true


func _save(file_name: String) -> void:
	await _save_with(_camera, file_name)


func _save_with(cam: Camera3D, file_name: String) -> void:
	cam.current = true
	await _settle(12)
	var image := get_viewport().get_texture().get_image()
	if image == null:
		_fail("拿不到视口纹理（窗口未就绪？）：%s" % file_name)
		return
	var path := "%s/%s" % [SHOT_DIR, file_name]
	var error := image.save_png(path)
	if error != OK:
		_fail("存图失败 %s：%d" % [path, error])
	else:
		print("[CAPTURE] 已出图 %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _settle(frames: int):
	for _i in range(frames):
		await get_tree().process_frame


func _fail(message: String) -> void:
	_failures += 1
	print("FAIL: %s" % message)


func _on_timeout() -> void:
	print("FAIL: 看门狗超时——截图流程中断未收尾")
	print("Ore scatter capture completed: %d failure(s)" % (_failures + 1))
	get_tree().quit(1)
