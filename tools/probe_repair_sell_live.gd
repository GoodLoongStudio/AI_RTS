extends Node

## 实机验收探针（带窗口，屏幕外运行，不抢前台）：
## 走**真实输入链路**验证红警式维修/出售 ——
##   1) 按 RA3 侧栏「维修」按钮（真实 pressed 信号）
##   2) 断言 CommandCursor 切到扳手光标 + 侧栏按钮进入按下态
##   3) 用真实 InputEventMouseButton 左键点建筑（走 _unhandled_input + 射线兜底）
##   4) 断言建筑进入维修且**模式保持**（红警式持续模式）
##   5) 出售同理，并截图存 tmp_logs/
##
## 注意：**必须用场景方式跑**，不能 `--script`（那样 Autoload 不注册，MatchSignals 找不到）；
## 也必须带窗口（headless 下 HUD 不创建、viewport 纹理为空）。
##   godot_console.exe --path . --resolution 1600x900 --position -4000,-4000 \
##     res://tools/probe_repair_sell_live.tscn

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const SHOT_DIR := "res://tmp_logs/"

var _failures := 0
var _finished := false
var _match = null
var _sidebar = null
var _cursor = null
var _controller = null
var _human = null


func _ready():
	_run()


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("[PROBE][FAIL] ", message)


func _run():
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().process_frame
	await get_tree().create_timer(1.2).timeout

	var hud = _match.get_node_or_null("HUD")
	_sidebar = hud.get_node_or_null("Ra3Sidebar") if hud != null else null
	_cursor = hud.get_node_or_null("CommandCursor") if hud != null else null
	_human = _match.get_node_or_null("Players/Human")
	_controller = _human.find_child("UnitActionsController", true, false) if _human != null else null
	print("[PROBE] sidebar=", _sidebar, " cursor=", _cursor, " controller=", _controller)
	print("[PROBE] sidebar rect=", _sidebar.get_global_rect() if _sidebar != null else "n/a")
	_check(_sidebar != null, "RA3 侧栏应存在于 HUD 下")
	_check(_cursor != null, "CommandCursor 应挂载到 HUD 下")
	_check(_controller != null, "应能找到 UnitActionsController")
	if _sidebar == null or _cursor == null or _controller == null:
		_finish()
		return

	var waited := 0.0
	while waited < 10.0 and _human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	_human.add_resources({"resource_a": 9000}, "ScriptedAdjustment")

	# 把两座兵营摆在相机正前方，保证屏幕上可见。
	var camera := _find_camera()
	_check(camera != null, "应能找到相机")
	if camera == null:
		_finish()
		return
	# 直接把建筑摆到"希望的屏幕位置"对应的地面点上，避免落到屏幕外或侧栏底下。
	var view_size: Vector2 = get_viewport().get_visible_rect().size
	var target_a := Vector2(view_size.x * 0.22, view_size.y * 0.62)
	var target_b := Vector2(view_size.x * 0.46, view_size.y * 0.72)
	var ground_a := _screen_to_ground(camera, target_a)
	var ground_b := _screen_to_ground(camera, target_b)
	print("[PROBE] view=", view_size, " ground_a=", ground_a, " ground_b=", ground_b)

	var barracks_a: Node = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_a, Transform3D(Basis.IDENTITY, ground_a), _human, false
	)
	var barracks_b: Node = BarracksScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		barracks_b, Transform3D(Basis.IDENTITY, ground_b), _human, false
	)
	await get_tree().process_frame
	await get_tree().create_timer(0.8).timeout
	barracks_a.set_hp_without_damage(barracks_a.hp_max * 0.5)
	barracks_b.set_hp_without_damage(barracks_b.hp_max * 0.5)
	await get_tree().create_timer(0.4).timeout

	var pos_a: Vector2 = camera.unproject_position(barracks_a.global_position + Vector3(0, 1.5, 0))
	var pos_b: Vector2 = camera.unproject_position(barracks_b.global_position + Vector3(0, 1.5, 0))
	print("[PROBE] screen pos A=", pos_a, " B=", pos_b)
	_check(
		pos_a.y > 0.0 and pos_a.y < view_size.y and pos_a.x > 0.0 and pos_a.x < view_size.x,
		"建筑 A 必须落在视口内（探针摆位正确性）"
	)
	_check(
		pos_b.y > 0.0 and pos_b.y < view_size.y and pos_b.x > 0.0 and pos_b.x < view_size.x,
		"建筑 B 必须落在视口内（探针摆位正确性）"
	)

	# ---------------------------------------------------------- 维修
	var repair_button: Button = _sidebar.get("_repair_button")
	_check(repair_button != null, "应能找到维修按钮")
	if repair_button != null:
		print("[PROBE] repair button text='", repair_button.text, "' toggle=", repair_button.toggle_mode)
		repair_button.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.get_active_command_targeting() == "Repair", "按维修按钮后应进入维修模式")
	_check(_cursor.get_active_command() == "Repair", "CommandCursor 应切到维修（扳手）光标")
	_check(_cursor.has_custom_cursor(), "应已向引擎下发自定义光标")
	print(
		"[PROBE] after repair press: mode='",
		_controller.get_active_command_targeting(),
		"' cursor='",
		_cursor.get_active_command(),
		"' custom=",
		_cursor.has_custom_cursor()
	)

	# Tab 切到 AI 副官：必须取消进行中的指定模式并恢复光标
	# （RA3 布局下命令面板被侧栏收编，Match.gd 曾用 $HUD.get_node_or_null 取它 ⇒ 恒 null
	#  ⇒ 切副官时模式不取消、扳手光标挂在副官面板上。2026-09-14 修复，这里做回归。）
	var input_runtime = _match.get_node_or_null("InputBindingRuntime")
	_check(input_runtime != null, "应能找到 InputBindingRuntime")
	if input_runtime != null:
		input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
		await get_tree().process_frame
		await get_tree().process_frame
		_check(
			_controller.get_active_command_targeting() == "",
			"Tab 切 AI 副官应取消维修指定模式"
		)
		_check(not _cursor.has_custom_cursor(), "Tab 切 AI 副官应恢复系统光标")
		print(
			"[PROBE] after Tab: mode='",
			_controller.get_active_command_targeting(),
			"' custom=",
			_cursor.has_custom_cursor()
		)
		# 切回普通 HUD，继续后面的点击验证
		input_runtime.emit_signal("ActionPressed", "global.toggle_ai_hud")
		await get_tree().process_frame
		await get_tree().process_frame
		repair_button.pressed.emit()
		await get_tree().process_frame
		await get_tree().process_frame
		_check(_controller.get_active_command_targeting() == "Repair", "切回后应能重新进入维修模式")

	# 真实左键点击建筑 A（走 _unhandled_input → 射线兜底）
	await _click(pos_a)
	await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	_check(barracks_a.is_repairing(), "真实左键点建筑应进入维修")
	_check(not barracks_b.is_repairing(), "未被点的建筑不应进入维修")
	_check(_controller.get_active_command_targeting() == "Repair", "点建筑后维修模式应保持")
	await _shot("probe_repair_mode.png")

	# 再点建筑 B —— 红警式连续操作
	await _click(pos_b)
	await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	_check(barracks_b.is_repairing(), "持续模式下应能接着点第二座建筑")
	await _shot("probe_repair_continuous.png")

	# 右键退出
	await _send_mouse(MOUSE_BUTTON_RIGHT, pos_a)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.get_active_command_targeting() == "", "右键应退出维修模式")
	_check(not _cursor.has_custom_cursor(), "退出后应恢复系统光标")
	_check(not repair_button.button_pressed, "退出后按钮应回弹")
	print("[PROBE] after right click: mode='", _controller.get_active_command_targeting(), "'")

	barracks_a.set_repairing(false)
	barracks_b.set_repairing(false)

	# ---------------------------------------------------------- 出售
	var funds_before: int = _human.resource_a
	var sell_button: Button = _sidebar.get("_sell_button")
	_check(sell_button != null, "应能找到出售按钮")
	if sell_button != null:
		sell_button.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_cursor.get_active_command() == "Sell", "CommandCursor 应切到出售（金币）光标")
	if sell_button != null:
		_check(sell_button.button_pressed, "侧栏出售按钮应进入按下态")
	await _shot("probe_sell_mode.png")

	await _click(pos_a)
	await get_tree().process_frame
	await get_tree().create_timer(0.8).timeout
	var sold: bool = (not is_instance_valid(barracks_a)) or barracks_a.hp == 0.0
	_check(sold, "真实左键点建筑应完成出售")
	_check(_controller.get_active_command_targeting() == "Sell", "出售后模式应保持（可连卖第二座）")
	_check(_human.resource_a > funds_before, "出售应返还资源")
	print(
		"[PROBE] after sell click: sold=",
		sold,
		" mode='",
		_controller.get_active_command_targeting(),
		"' funds ",
		funds_before,
		" -> ",
		_human.resource_a
	)

	await _click(pos_b)
	await get_tree().process_frame
	await get_tree().create_timer(0.8).timeout
	var sold_b: bool = (not is_instance_valid(barracks_b)) or barracks_b.hp == 0.0
	_check(sold_b, "持续模式下应能接着卖第二座建筑")
	print("[PROBE] after second sell click: sold_b=", sold_b)

	await _send_mouse(MOUSE_BUTTON_RIGHT, pos_b)
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_controller.get_active_command_targeting() == "", "右键应退出出售模式")

	print("[PROBE] live acceptance finished: %d failure(s)" % _failures)
	_finish()


func _find_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam
	return _match.find_child("Camera3D", true, false) as Camera3D


## 屏幕点 → 地面（y=0）世界点：保证建筑基座正好出现在该屏幕位置。
func _screen_to_ground(camera: Camera3D, screen_position: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return origin
	var t := -origin.y / direction.y
	return origin + direction * t


func _click(screen_position: Vector2):
	await _send_mouse(MOUSE_BUTTON_LEFT, screen_position)


## 先把**真实**鼠标 warp 到目标点再推事件：游戏里 ArealUnitSelectionHandler /
## RectangularSelection3D 读的是 `get_viewport().get_mouse_position()`（真实鼠标），
## 不 warp 就会出现"事件坐标在建筑上、框选却按旧鼠标位置结算"的假象。
func _send_mouse(button_index: int, screen_position: Vector2):
	Input.warp_mouse(screen_position)
	await get_tree().process_frame
	await get_tree().process_frame
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = true
	event.position = screen_position
	event.global_position = screen_position
	get_viewport().push_input(event)
	await get_tree().process_frame
	var release := InputEventMouseButton.new()
	release.button_index = button_index
	release.pressed = false
	release.position = screen_position
	release.global_position = screen_position
	get_viewport().push_input(release)
	await get_tree().process_frame


func _shot(file_name: String):
	await get_tree().process_frame
	await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	if image == null:
		print("[PROBE][FAIL] 截图失败：viewport texture 为空（要用带窗口模式跑）")
		_failures += 1
		return
	var path := SHOT_DIR + file_name
	var err := image.save_png(path)
	print("[PROBE] shot -> ", ProjectSettings.globalize_path(path), " err=", err)
	# 顺带裁一张侧栏按钮特写（按钮很小，全图看不清激活态）。
	var crop_rect := Rect2i(1620, 108, 300, 120)
	if image.get_width() >= crop_rect.end.x and image.get_height() >= crop_rect.end.y:
		var crop := image.get_region(crop_rect)
		var crop_path := SHOT_DIR + file_name.replace(".png", "_sidebar.png")
		crop.save_png(crop_path)
		print("[PROBE] shot -> ", ProjectSettings.globalize_path(crop_path))


func _finish():
	if _finished:
		return
	_finished = true
	get_tree().quit(0 if _failures == 0 else 1)
