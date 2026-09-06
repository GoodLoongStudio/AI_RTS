extends Node

## 步兵战斗动画人工验收场景：真实 Match、导航、命令网关与投射物运行时。
## 全部伤害走真实投射物命中链；按钮"移动/攻击/停止"走 UnitCommandGateway。
## 标注"调试"的按钮会修改血量或传送靶子，仅用于验收准备，不属于玩法改动。
## 命令行附加 --smoke 可无头自检（逐个触发与按钮相同的处理函数）。

const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const PlayerScript = preload("res://source/match/players/Player.gd")
const SmokeTestExitScript = preload("res://tests/automated/SmokeTestExit.gd")

const INFANTRY_SPAWN := Vector3(10, 0, 2)
const TARGET_SPAWN := Vector3(12.3, 0, 2)
const TARGET_FAR_SPAWN := Vector3(10, 0, 24)
## 调试准备：靶子默认血量，足够承受连射观察，不代表平衡数值。
const TARGET_DEBUG_HP := 1000.0
## 调试准备：连射观察时步兵的临时血量。
const INFANTRY_DEBUG_HP := 50.0
const MOVE_DISTANCE := 6.0
## 本次验收截图输出目录：换新批次目录，旧目录（anim_verify）全部保留不混用。
const SCREENSHOT_DIR := "G:/AIRTS/tmp_logs/anim_verify_r2/"

var _match: Node
var _human: Node
var _gateway: Node
var _runtime: Node
var _match_camera: Camera3D
var _enemy_player: Node3D
var _infantry: Node3D
var _infantry_anim: AnimationPlayer
var _target: Node3D
var _blast_tank: Node3D
var _follow_camera: Camera3D
var _follow_focus := INFANTRY_SPAWN
var _fire_count := 0
var _last_command_text := "无"
var _move_flip := false
var _status_accum := 0.0
var _reset_token := 0
## 部署/重置进行中标志：期间一切战斗按钮安全拒绝，避免对半初始化单位下命令。
var _deploying := true
var _stage_text := "初始化"

var _buttons := {}
var _status_label: Label
var _review_panel: PanelContainer
var _smoke_failures := 0


func _ready() -> void:
	_match = get_node("Match")
	_human = _match.get_node("Players/Human")
	_gateway = _human.get_node("UnitCommandGateway")
	_runtime = _match.get_node("ProjectileRuntime")
	_match_camera = _match.get_node("IsometricCamera3D")
	_build_ui()
	# 与自动测试相同：Match 的场景单位在导航等异步子系统就绪后才入组，
	# 必须等分组齐了再下发停火，否则命令会以 EmptyUnitSet 被整体拒绝。
	await _wait_for_scene_units()
	_setup_fire_isolation()
	_ensure_enemy_player()
	await _spawn_review_units()
	if "--smoke" in OS.get_cmdline_user_args():
		_run_smoke()


func _process(delta: float) -> void:
	_update_follow_camera()
	_status_accum += delta
	if _status_accum < 0.2:
		return
	_status_accum = 0.0
	_status_label.text = _build_status_text()


# ---------------------------------------------------------------- 部署与隔离

func _wait_for_scene_units() -> void:
	var count := func(): return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.get_parent() == _human).size()
	var deadline := Time.get_ticks_msec() + 15000
	while count.call() < 9 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


## 无关单位全部停火，验收动作之外的自动索敌一律不参与。
func _setup_fire_isolation() -> void:
	var units := get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.get_parent() == _human)
	var result = _gateway.SetFirePolicy(units, "HoldFire", _human)
	if result.get("status") != "Accepted":
		push_warning("基线场景停火策略未完全接受：%s" % result.get("status"))


func _ensure_enemy_player() -> void:
	if is_instance_valid(_enemy_player):
		return
	var enemy := Node3D.new()
	enemy.name = "ReviewEnemy"
	enemy.set_script(PlayerScript)
	enemy.set("color", Color.RED)
	enemy.add_to_group("players")
	_match.get_node("Players").add_child(enemy)
	_enemy_player = enemy


func _spawn_review_units() -> void:
	_reset_token += 1
	var token := _reset_token
	_deploying = true
	_stage_text = "部署中"
	_fire_count = 0
	_infantry_anim = null
	_infantry = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		_infantry, Transform3D(Basis(), INFANTRY_SPAWN), _human)
	_target = InfantryScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		_target, Transform3D(Basis(), TARGET_SPAWN), _enemy_player)
	# 爆炸源：真实坦克 + 真实炮弹，平时停火，仅"致死爆炸"按钮手动发射。
	_blast_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		_blast_tank, Transform3D(Basis(), TARGET_SPAWN + Vector3(4, 0, 0)), _enemy_player)
	# spawn 管线会把单位强制改名为 Unit_N（Match.gd），入树后再覆盖为验收
	# 专用名，供残留/重复检测与基线单位区分。
	_infantry.name = "ReviewInfantry"
	_target.name = "ReviewTarget"
	_blast_tank.name = "ReviewBlastTank"
	await get_tree().process_frame
	await get_tree().process_frame
	if token != _reset_token:
		return
	if is_instance_valid(_target):
		_target.hp = TARGET_DEBUG_HP
		_gateway.SetFirePolicy([_target], "HoldFire", _enemy_player)
	if is_instance_valid(_blast_tank):
		_gateway.SetFirePolicy([_blast_tank], "HoldFire", _enemy_player)
	if is_instance_valid(_infantry):
		_infantry_anim = _infantry.find_child("AnimationPlayer", true, false)
		_infantry.attack_fired.connect(_on_infantry_fired)
		# 部署后先停火：开火一律由按钮显式开启，避免自动射击污染调试血量。
		_gateway.SetFirePolicy([_infantry], "HoldFire", _human)
	_deploying = false
	_stage_text = "已部署"
	_last_command_text = "部署完成（步兵 / 靶子 / 爆炸坦克）"
	_refresh_status_now()


func _on_infantry_fired() -> void:
	_fire_count += 1


## 战斗按钮统一前置检查：部署/重置进行中、步兵已阵亡都安全拒绝。
func _combat_ready() -> bool:
	if _deploying:
		_last_command_text = "部署/重置进行中，请稍候"
		_refresh_status_now()
		return false
	if not is_instance_valid(_infantry):
		_last_command_text = "步兵已阵亡，请先点击 [重置场景]"
		_refresh_status_now()
		return false
	return true


## 依赖靶子存活的按钮（连续受击/普通死亡）的额外检查。
func _target_alive() -> bool:
	if is_instance_valid(_target):
		return true
	_last_command_text = "靶子已失效，请先点击 [重置场景]"
	_refresh_status_now()
	return false


## 打断靶子对步兵的持续攻击，恢复隔离状态。
func _pacify_target() -> void:
	if not is_instance_valid(_target):
		return
	_gateway.StopUnits([_target], _enemy_player)
	_gateway.SetFirePolicy([_target], "HoldFire", _enemy_player)


# ---------------------------------------------------------------- 按钮动作

func _on_reset_pressed() -> void:
	_reset_token += 1
	var token := _reset_token
	_deploying = true
	_stage_text = "重置中"
	_disable_follow_camera()
	for node in [_infantry, _target, _blast_tank]:
		if is_instance_valid(node):
			node.queue_free()
	_infantry = null
	_target = null
	_blast_tank = null
	_infantry_anim = null
	# 上一轮的独立死亡视觉与飞行中投射物不属于任何单位引用，
	# 必须在此显式回收，否则会混入新一轮表现（旧尸体/幽灵弹道）。
	for visual in get_tree().get_nodes_in_group("infantry_death_visuals"):
		if is_instance_valid(visual):
			visual.queue_free()
	var projectiles = _match.get_node_or_null("Projectiles")
	if projectiles != null:
		for projectile in projectiles.get_children():
			# 只回收真实投射物节点（持有 attack_id），不误删容器内的无关对象；
			# 投射物退出场景树时 ProjectileRuntime 会同步 Forget 其活动记录。
			if is_instance_valid(projectile) and projectile.get("attack_id") != null:
				projectile.queue_free()
	_last_command_text = "重置中…"
	_refresh_status_now()
	# 等旧对象真正退出场景树后再重新部署：queue_free 在帧末生效。
	# 连点重置由令牌丢弃过期部署，不会产生重复单位或悬空引用。
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if _review_leftovers() == 0:
			break
	if token != _reset_token:
		return
	await _spawn_review_units()


## 统计尚未退出的验收残留（死亡视觉 + 飞行中投射物），0 表示场景已干净。
func _review_leftovers() -> int:
	var leftovers := 0
	for visual in get_tree().get_nodes_in_group("infantry_death_visuals"):
		if is_instance_valid(visual):
			leftovers += 1
	var projectiles = _match.get_node_or_null("Projectiles")
	if projectiles != null:
		for child in projectiles.get_children():
			if is_instance_valid(child) and child.get("attack_id") != null:
				leftovers += 1
	return leftovers


func _on_move_pressed() -> void:
	if not _combat_ready():
		return
	_stage_text = "移动"
	_move_flip = not _move_flip
	var offset := Vector3(MOVE_DISTANCE, 0, 0) if _move_flip else Vector3(-MOVE_DISTANCE, 0, 0)
	var destination: Vector3 = _infantry.global_position + offset
	_log_command("移动", _gateway.ForceMoveUnits([_infantry], destination, _human))


## 调试：先把靶子传送到远处（避免手动点选），再下真实攻击命令触发追击。
func _on_chase_pressed() -> void:
	if not _combat_ready() or not _target_alive():
		return
	_stage_text = "追击"
	_pacify_target()
	_target.global_position = TARGET_FAR_SPAWN
	_target.reset_physics_interpolation()
	_gateway.SetFirePolicy([_infantry], "FireAtWill", _human)
	_log_command("射程外攻击与追击", _gateway.AttackUnits([_infantry], _target, _human))


func _on_stop_pressed() -> void:
	if not _combat_ready():
		return
	_stage_text = "停止"
	_pacify_target()
	_log_command("停止并停火", _gateway.StopUnits([_infantry], _human))
	_gateway.SetFirePolicy([_infantry], "HoldFire", _human)


## 调试：临时提高步兵血量，让靶子真实连射且不会致死，观察连续受击。
## 先停止步兵先前的攻击/移动，保证受检条件只来自靶子的真实子弹。
func _on_repeat_hits_pressed() -> void:
	if not _combat_ready() or not _target_alive():
		return
	_stage_text = "连续受击"
	_gateway.StopUnits([_infantry], _human)
	_gateway.SetFirePolicy([_infantry], "HoldFire", _human)
	_infantry.hp = INFANTRY_DEBUG_HP
	_gateway.SetFirePolicy([_target], "FireAtWill", _enemy_player)
	_log_command(
		"连续子弹命中（靶子射击步兵）",
		_gateway.AttackUnits([_target], _infantry, _enemy_player))


## 调试：把步兵血量压到一发步枪可致死，由靶子真实子弹触发普通死亡。
## 先停止步兵先前的攻击/移动，保证致死判定不受步兵自身动作干扰。
func _on_normal_death_pressed() -> void:
	if not _combat_ready() or not _target_alive():
		return
	_stage_text = "普通死亡"
	_gateway.StopUnits([_infantry], _human)
	_gateway.SetFirePolicy([_infantry], "HoldFire", _human)
	_infantry.hp = 0.25
	_gateway.SetFirePolicy([_target], "FireAtWill", _enemy_player)
	_log_command(
		"普通死亡（真实步枪）",
		_gateway.AttackUnits([_target], _infantry, _enemy_player))


## 调试：把步兵血量压到 1，由真实坦克炮弹触发致死爆炸（击飞死亡视觉）。
## 先停止步兵先前动作并让靶子停火：切换到爆炸测试前必须隔离步枪弹，
#  避免靶子残余连射抢先致死、污染爆炸表现。
func _on_explosion_death_pressed() -> void:
	if not _combat_ready():
		return
	if not is_instance_valid(_blast_tank):
		_last_command_text = "爆炸坦克已失效，请重置场景"
		_refresh_status_now()
		return
	_stage_text = "致死爆炸"
	_pacify_target()
	_gateway.StopUnits([_infantry], _human)
	_gateway.SetFirePolicy([_infantry], "HoldFire", _human)
	_infantry.hp = 1.0
	_runtime.LaunchEntity(_blast_tank, _infantry)
	_log_command("致死爆炸（真实炮弹）",
		{"status": "Launched", "unit_results": []})


func _on_follow_pressed() -> void:
	if is_instance_valid(_follow_camera) and _follow_camera.current:
		_disable_follow_camera()
		_last_command_text = "近景观察关闭（回到战术相机）"
		return
	if not is_instance_valid(_follow_camera):
		_follow_camera = Camera3D.new()
		_follow_camera.fov = 50.0
		add_child(_follow_camera)
	if is_instance_valid(_infantry):
		_follow_focus = _infantry.global_position
	_follow_camera.current = true
	_last_command_text = "近景观察开启（跟随步兵）"


func _disable_follow_camera() -> void:
	if is_instance_valid(_follow_camera):
		_follow_camera.current = false
	if is_instance_valid(_match_camera):
		_match_camera.current = true


func _update_follow_camera() -> void:
	if not is_instance_valid(_follow_camera) or not _follow_camera.current:
		return
	if is_instance_valid(_infantry):
		_follow_focus = _infantry.global_position
	_follow_camera.global_position = _follow_focus + Vector3(2.2, 1.7, -2.8)
	_follow_camera.look_at(_follow_focus + Vector3(0, 0.55, 0))


# ---------------------------------------------------------------- UI 与状态

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ReviewUI"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.name = "ReviewPanel"
	_review_panel = panel
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 12.0
	panel.offset_right = 356.0
	panel.offset_top = 12.0
	panel.offset_bottom = -12.0
	layer.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.name = "Actions"
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "步兵战斗动画验收"
	title.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title)

	var definitions := [
		["重置场景", _on_reset_pressed],
		["移动", _on_move_pressed],
		["射程外攻击与追击（调试：传送靶子）", _on_chase_pressed],
		["停止并停火", _on_stop_pressed],
		["连续子弹命中（调试：提高步兵血量）", _on_repeat_hits_pressed],
		["普通死亡（调试：步兵血量=0.25）", _on_normal_death_pressed],
		["致死爆炸（调试：步兵血量=1）", _on_explosion_death_pressed],
		["近景观察 开/关", _on_follow_pressed],
	]
	for definition in definitions:
		var button := Button.new()
		button.text = definition[0]
		button.pressed.connect(definition[1])
		vbox.add_child(button)
		_buttons[definition[0]] = button

	_status_label = Label.new()
	_status_label.text = "初始化中…"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_status_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(_status_label)


func _build_status_text() -> String:
	var lines := PackedStringArray()
	lines.append("阶段: %s" % _stage_text)
	if is_instance_valid(_infantry):
		lines.append("步兵: 存活 HP=%s/%s  位置=%s" % [
			_infantry.hp, _infantry.hp_max,
			_snapped_position(_infantry.global_position)])
		lines.append("Action: %s" % _describe_action(_infantry))
		if is_instance_valid(_infantry_anim):
			lines.append("动画: %s  %.2f/%.2fs  速度=%.2f" % [
				_infantry_anim.current_animation if _infantry_anim.is_playing()
					else _infantry_anim.assigned_animation + "（停）",
				_infantry_anim.current_animation_position,
				_infantry_anim.current_animation_length,
				_infantry_anim.speed_scale])
	else:
		var visuals := get_tree().get_nodes_in_group("infantry_death_visuals")
		lines.append("步兵: 已阵亡（死亡视觉 %d 个播放中）" % visuals.size())
	if is_instance_valid(_target):
		lines.append("靶子: HP=%s  位置=%s" % [
			_target.hp, _snapped_position(_target.global_position)])
	lines.append("开火事件: %d" % _fire_count)
	lines.append("最近命令: %s" % _last_command_text)
	return "\n".join(lines)


func _describe_action(unit: Node3D) -> String:
	if unit.action == null:
		return "无（待命）"
	var text := _script_file_name(unit.action)
	var sub_action = unit.action.get("_sub_action")
	if sub_action != null and sub_action.get_script() != null:
		text += " → " + _script_file_name(sub_action)
	return text


func _script_file_name(node: Node) -> String:
	var script = node.get_script()
	return script.resource_path.get_file() if script != null else node.name


func _snapped_position(position: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [position.x, position.y, position.z]


## 立即刷新状态面板：按钮反馈与截图前同步，不等 0.2s 节流。
func _refresh_status_now() -> void:
	if _status_label != null:
		_status_label.text = _build_status_text()


## 截图瞬间的权威状态快照（阶段/动画名/动画时间/开火计数/死亡视觉），与图像一一对应入日志。
func _log_state_snapshot(shot_path: String) -> void:
	var anim_text := "无"
	var anim_pos := -1.0
	if is_instance_valid(_infantry_anim):
		anim_text = _infantry_anim.current_animation if _infantry_anim.is_playing() \
			else _infantry_anim.assigned_animation + "(停)"
		anim_pos = _infantry_anim.current_animation_position
	var death_text := ""
	for visual in get_tree().get_nodes_in_group("infantry_death_visuals"):
		if not is_instance_valid(visual):
			continue
		var death_player: AnimationPlayer = visual.find_child("AnimationPlayer", true, false)
		if death_player != null:
			death_text += " death[%s]=%s(%.2f/%.2f)" % [
				visual.get_meta("death_clip", "?"),
				death_player.current_animation if death_player.is_playing()
					else death_player.assigned_animation + "(停)",
				death_player.current_animation_position,
				death_player.current_animation_length]
	print("STATE_SNAPSHOT stage=%s anim=%s anim_t=%.2f fires=%d%s shot=%s" % [
		_stage_text, anim_text, anim_pos, _fire_count, death_text, shot_path.get_file()])


func _log_command(action_text: String, result) -> void:
	var status := str(result.get("status", "?")) if result is Dictionary else str(result)
	var accepted := 0
	var total := 0
	if result is Dictionary:
		var unit_results = result.get("unit_results", [])
		total = unit_results.size()
		for item in unit_results:
			if item.get("accepted", false):
				accepted += 1
	_last_command_text = "%s → %s（接受 %d/%d）" % [action_text, status, accepted, total]


# ---------------------------------------------------------------- 冒烟自检

## --smoke：无头依次触发与按钮完全相同的处理函数，验证场景逻辑闭环。
## 窗口模式额外输出关键帧截图（追击/开火/轻击/爆炸四段连续帧）+ 状态快照日志。
func _run_smoke() -> void:
	await get_tree().create_timer(1.5).timeout
	_check(is_instance_valid(_infantry) and _infantry.is_in_group("units"), "步兵已部署并入组")
	_check(is_instance_valid(_target) and _target.hp == TARGET_DEBUG_HP, "靶子已部署且为调试血量")
	_check(_gateway.GetFirePolicy(_infantry) == "HoldFire", "步兵部署后先停火（由按钮开启开火）")

	_on_follow_pressed()
	_check(is_instance_valid(_follow_camera) and _follow_camera.current, "近景相机可开启")
	_on_follow_pressed()
	_check(not _follow_camera.current and _match_camera.current, "近景相机关闭后回到战术相机")

	_on_move_pressed()
	# 注意：lambda 实参不能跨行，复杂条件先落成独立 Callable。
	var moved := func():
		return is_instance_valid(_infantry) and _infantry.global_position.distance_to(INFANTRY_SPAWN) > 1.0
	_check(await _wait_until(moved, 4.0), "移动命令产生实际位移")
	_on_stop_pressed()
	_check(await _wait_until(_infantry_standing, 3.0), "停止后回到站立状态")

	# 连点重置：第一次重置的部署被令牌丢弃，最终只保留最后一组单位。
	_on_reset_pressed()
	_on_reset_pressed()
	var double_reset_done := await _wait_until(_deployment_settled, 6.0)
	_check(double_reset_done, "连点重置后部署收敛")
	var counts := _deployed_unit_counts()
	_check(_review_units_unique(counts), "连点重置不产生重复单位（实际 %s）" % [counts])

	_on_chase_pressed()
	var fired := await _wait_until(func(): return _fire_count > 0, 10.0)
	_check(fired, "射程外追击后由真实投射物触发开火事件")
	if fired and DisplayServer.get_name() != "headless":
		# 追击途中 Run 关键帧（若已到位切剪则跳过，不代表失败）。
		var in_run := func():
			return (
				is_instance_valid(_infantry_anim)
				and _infantry_anim.current_animation == "Run"
				and _infantry_anim.is_playing()
			)
		if in_run.call() and is_instance_valid(_infantry):
			await _capture(SCREENSHOT_DIR + "review_chase_run.png", _infantry.global_position)
		# 实际开火截图：必须确认 AnimationPlayer 正在播放 Fire，不能只等 attack_fired。
		var fire_check := func():
			return (
				is_instance_valid(_infantry_anim)
				and _infantry_anim.current_animation == "Fire"
				and _infantry_anim.is_playing()
			)
		var fire_visible := await _wait_until(fire_check, 2.5)
		_check(fire_visible, "追击到位首发展现为站姿 Fire（AnimationPlayer 实际播放中）")
		if fire_visible and is_instance_valid(_infantry):
			await _capture(SCREENSHOT_DIR + "review_chase_fire.png", _infantry.global_position)
			await get_tree().create_timer(0.15).timeout
			if fire_check.call() and is_instance_valid(_infantry):
				await _capture(SCREENSHOT_DIR + "review_chase_fire_2.png", _infantry.global_position)
	_on_stop_pressed()
	_pacify_target()

	_on_repeat_hits_pressed()
	# 等待真实投射物在飞（Projectiles 容器出现持有 attack_id 的子弹节点）。
	var shots_flying := await _wait_until(_projectiles_present, 6.0)
	_check(shots_flying, "连续受击阶段应有真实投射物在飞")
	# 诊断轮询：不用 lambda，避免跨行实参与闭包捕获语义陷阱。
	var hit_seen := false
	var dist_at_end := -1.0
	var policy_at_end := "?"
	var cmd_at_end := ""
	for _i in range(20):
		await get_tree().create_timer(0.2).timeout
		if is_instance_valid(_infantry_anim) and _infantry_anim.current_animation == "Hit":
			hit_seen = true
			break
		if is_instance_valid(_infantry) and is_instance_valid(_target):
			dist_at_end = _infantry.global_position_yless.distance_to(
				_target.global_position_yless)
			policy_at_end = str(_gateway.GetFirePolicy(_target))
	cmd_at_end = _last_command_text
	_check(hit_seen, "真实子弹连射触发存活受击 Hit（cmd=%s dist=%.2f policy=%s）" % [
		cmd_at_end, dist_at_end, policy_at_end])
	if hit_seen and DisplayServer.get_name() != "headless":
		var in_hit := func():
			return (
				is_instance_valid(_infantry_anim)
				and _infantry_anim.current_animation == "Hit"
				and is_instance_valid(_infantry)
			)
		if in_hit.call():
			await _capture(SCREENSHOT_DIR + "review_hit.png", _infantry.global_position)
	# 子弹仍在飞行期间直接重置：验证飞行中投射物与 ProjectileRuntime 活动记录正确释放。
	_on_reset_pressed()
	var redeployed := await _wait_until(_deployment_settled, 6.0)
	_check(redeployed, "子弹飞行期间重置后重新部署完成")
	_check(_review_leftovers() == 0, "子弹飞行期间重置后无投射物/死亡视觉残留")
	counts = _deployed_unit_counts()
	_check(_review_units_unique(counts), "子弹飞行期间重置后单位唯一")

	_on_normal_death_pressed()
	var died := await _wait_until(func(): return not is_instance_valid(_infantry), 5.0)
	_check(died, "真实步枪致死移除战斗单位")
	# 死亡视觉出现即处于定格计时中，立刻重置验证尸体回收路径。
	var visual_up := await _wait_until(_death_visual_present, 3.0)
	_check(visual_up, "普通死亡应产生死亡视觉（定格中）")
	var death_visuals := get_tree().get_nodes_in_group("infantry_death_visuals")
	_check(death_visuals.size() == 1 and death_visuals[0].get_meta("death_clip") == "Death",
		"普通致死应使用 Death 视觉")
	_on_reset_pressed()
	var respawned := await _wait_until(_deployment_settled, 6.0)
	_check(respawned, "尸体定格期间重置后重新部署完成")
	_check(_fire_count == 0, "重置后开火计数清零")
	_check(_review_leftovers() == 0, "尸体定格期间重置后无死亡视觉/投射物残留")
	counts = _deployed_unit_counts()
	_check(_review_units_unique(counts), "尸体定格期间重置后单位唯一")

	_on_explosion_death_pressed()
	# 爆炸按钮内部必须先让靶子停火：切换到致死爆炸前隔离步枪弹，避免抢先致死。
	_check(_gateway.GetFirePolicy(_target) == "HoldFire", "致死爆炸前靶子已停止持续射击")
	var blasted := await _wait_until(func(): return not is_instance_valid(_infantry), 5.0)
	_check(blasted, "真实炮弹致死移除战斗单位")
	var blast_visuals := get_tree().get_nodes_in_group("infantry_death_visuals")
	_check(blast_visuals.size() == 1 and blast_visuals[0].get_meta("death_clip") == "HitHeavy",
		"致死爆炸应产生唯一的 HitHeavy 视觉（场景已隔离）")
	if DisplayServer.get_name() != "headless" and blast_visuals.size() == 1:
		var blast_visual: Node3D = blast_visuals[0]
		# 关键帧：起飞 → 腾空 → 落地 → 定格，全部聚焦受检单位的唯一死亡视觉。
		# 起飞帧等 0.12s 截（避开剪辑起始的站立过渡，呈现已后仰离地的击飞姿态）。
		await get_tree().create_timer(0.12).timeout
		if is_instance_valid(blast_visual):
			await _capture(SCREENSHOT_DIR + "review_blast_launch.png", blast_visual.global_position)
		await get_tree().create_timer(0.3).timeout
		if is_instance_valid(blast_visual):
			await _capture(SCREENSHOT_DIR + "review_blast_airborne.png", blast_visual.global_position)
		await get_tree().create_timer(0.35).timeout
		if is_instance_valid(blast_visual):
			await _capture(SCREENSHOT_DIR + "review_blast_landing.png", blast_visual.global_position)
		# 按真实剪辑长度等待播放结束进入定格，不硬编码固定等待。
		var blast_player: AnimationPlayer = blast_visual.find_child("AnimationPlayer", true, false)
		if blast_player != null:
			await get_tree().create_timer(blast_player.get_animation("HitHeavy").length + 0.15).timeout
		if is_instance_valid(blast_visual):
			await _capture(SCREENSHOT_DIR + "review_blast_hold.png", blast_visual.global_position)

	print("InfantryCombatReviewSmoke completed: %d failure(s)" % _smoke_failures)
	SmokeTestExitScript.request(get_tree(), 1 if _smoke_failures > 0 else 0)


func _deployment_settled() -> bool:
	return not _deploying and is_instance_valid(_infantry) and _infantry.is_in_group("units")


func _projectiles_present() -> bool:
	var projectiles = _match.get_node_or_null("Projectiles")
	if projectiles == null:
		return false
	for child in projectiles.get_children():
		if is_instance_valid(child) and child.get("attack_id") != null:
			return true
	return false


func _death_visual_present() -> bool:
	return not get_tree().get_nodes_in_group("infantry_death_visuals").is_empty()


## 统计验收创建的单位数（按 Review 前缀命名，不含基线场景单位）。
## 同类 >1 说明重置产生了重复单位；=1 为正常部署；=0 为已阵亡/未部署。
func _deployed_unit_counts() -> Dictionary:
	var counts := {"infantry": 0, "target": 0, "blast": 0}
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		var unit_name := String(unit.name)
		if unit_name.begins_with("ReviewInfantry"):
			counts.infantry += 1
		elif unit_name.begins_with("ReviewTarget"):
			counts.target += 1
		elif unit_name.begins_with("ReviewBlastTank"):
			counts.blast += 1
	return counts


## 部署收敛后三类验收单位都应恰好各 1 个：0 表示丢失，>1 表示重复。
func _review_units_unique(counts: Dictionary) -> bool:
	return counts.infantry == 1 and counts.target == 1 and counts.blast == 1


## 窗口模式下用固定正交近景相机对焦目标截屏；headless 自动跳过。
## 截图前同步刷新状态面板并输出状态快照；期间隐藏验收面板和游戏 HUD，
## 避免把 UI 当成动画内容或遮挡受检角色。
func _capture(path: String, focus: Vector3) -> void:
	_refresh_status_now()
	_log_state_snapshot(path)
	var camera := Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.global_position = focus + Vector3(2.0, 1.8, -2.6)
	camera.look_at(focus + Vector3(0, 0.55, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.0
	camera.current = true
	var canvas_visibility: Array[Dictionary] = []
	for canvas in get_tree().root.find_children("*", "CanvasLayer", true, false):
		if not is_instance_valid(canvas):
			continue
		canvas_visibility.append({"node": canvas, "visible": canvas.visible})
		canvas.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	print("REVIEW_SCREENSHOT_SAVED ", path)
	for item in canvas_visibility:
		var canvas = item.get("node")
		if is_instance_valid(canvas):
			canvas.visible = bool(item.get("visible", true))
	if is_instance_valid(_match_camera):
		_match_camera.current = true
	camera.queue_free()


func _infantry_standing() -> bool:
	if not is_instance_valid(_infantry_anim):
		return false
	var clip := _infantry_anim.current_animation
	return clip == "Idle" or clip == "Fire"


func _check(condition: bool, message: String) -> void:
	if condition:
		print("SMOKE_PASS ", message)
	else:
		_smoke_failures += 1
		push_error("SMOKE_FAIL " + message)
		print("SMOKE_FAIL ", message)


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await get_tree().process_frame
	return condition.call()
