extends Node

## 步兵骨骼动画驱动：原厂 50 骨架的七段剪辑（Infantry_native_v3.glb
## 内嵌 AnimationPlayer）按实际开火事件 + 实际位移速度映射播放。
## 剪辑清单（单角色基线，全部携枪）：循环 Idle/Run/Crawl，
## 单发 Hit(快速中弹)/HitHeavy(爆炸击飞死亡)/Fire(射击)/Death(普通死亡)。
## 致死爆炸由独立视觉节点播完 HitHeavy；存活受击使用短促 Hit。
## Crawl 暂无对应玩法状态，作为资产保留待"匍匐指令"接入。
## 死亡时只复制 Geometry，单位仍立即退出战斗；视觉播完后自动清理。

## 速度阈值需高于 RVO 避让的往复微抖速度（实测抖动可到 0.4 m/s 左右）
const MOVE_SPEED_EPSILON := 0.6
## 开火事件等待表现的有效窗口：站定发射时速度滤波可能仍残留几帧，
## 窗口内衰减过阈值即播；被避让推挤等被动位移拖住超窗则丢弃。
## "发射时是否被命令移动"已在事件入口判定（见 _on_attack_fired），
## 因此窗口不会再把移动开火补播成站姿射击。
const FIRE_PENDING_WINDOW := 0.25
## 单物理帧位移超过"最高移速×该倍率"视为瞬移（出生对齐吸附/导航 clamp），
## 不计入奔跑速度。真实移速（3.5 m/s）在 60Hz 下每帧仅约 0.06m。
const TELEPORT_SPEED_FACTOR := 4.0
## 位移速度低通滤波系数：每物理帧向瞬时速度收敛的比例。
const SPEED_SMOOTHING := 0.5
## 动作资源缺失时的受击覆盖兜底；正常播放以剪辑实际长度为准。
const HIT_OVERLAY_MSEC := 300
const DEATH_HOLD_SECONDS := 1.0
const LOOP_CLIPS := ["Idle", "Run", "Crawl"]

var _player: AnimationPlayer
var _unit: Node
var _last_position := Vector3.INF
var _speed := 0.0
var _hit_overlay_remaining := 0.0
var _fire_pending := false
var _fire_pending_window := 0.0
var _fire_active := false
var _hit_clip := "Hit"
var _last_hp = null
var _death_started := false


func _ready() -> void:
	_unit = get_parent()
	_player = _unit.find_child("AnimationPlayer", true, false)
	if _player == null:
		push_warning("InfantryAnimationDriver: 未找到 AnimationPlayer，动画驱动停用")
		set_process(false)
		set_physics_process(false)
		return
	for clip in LOOP_CLIPS:
		if _player.has_animation(clip):
			_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	if _unit.has_signal("hp_changed"):
		_unit.hp_changed.connect(_on_hp_changed)
	if _unit.has_signal("attack_fired"):
		_unit.attack_fired.connect(_on_attack_fired)
	_player.animation_finished.connect(_on_animation_finished)
	_play("Idle")


func _process(delta: float) -> void:
	_hit_overlay_remaining = maxf(0.0, _hit_overlay_remaining - delta * absf(_player.speed_scale))
	if _unit.hp != null:
		_last_hp = _unit.hp
	_fire_pending_window = maxf(0.0, _fire_pending_window - delta)
	# 当前资产是全身站姿射击；中弹立即丢弃待播开火（受击优先且不补播）。
	if _hit_overlay_remaining > 0.0:
		_fire_pending = false
		_fire_active = false
	elif _speed > MOVE_SPEED_EPSILON:
		_fire_active = false
		# 挂起中的开火只会来自"发射时已无移动意图"（站定/刹停第一枪），
		# 速度滤波衰减过阈值即播；被动位移（避让推挤）拖住超过窗口则丢弃。
		if _fire_pending and _fire_pending_window <= 0.0:
			_fire_pending = false
	elif _fire_pending:
		_fire_pending = false
		_fire_active = true
		# 同名剪辑也从冲击首帧重启，连射不会吞掉新的发射事件。
		_player.stop()
		_player.play("Fire", 0.015)
		_player.advance(0.0)
	_play(_desired_clip())


## 位移只在物理帧真实发生：本地单位由 Movement 的 velocity_computed 移动，
## 联机木偶由 NetSync._client_interp_tick 在物理帧插值。渲染帧率与物理帧率
## 不一致时逐渲染帧位移会周期性为 0 或翻倍，直接按渲染 delta 除法会让
## Run/Idle 阈值判断闪切，因此采样固定在物理帧并做低通滤波。
func _physics_process(delta: float) -> void:
	if _player == null or _death_started:
		return
	var position: Vector3 = _unit.global_position
	if _last_position == Vector3.INF:
		_last_position = position
		return
	var displacement := position - _last_position
	displacement.y = 0.0
	_last_position = position
	var instant_speed := displacement.length() / maxf(delta, 0.0001)
	# 出生对齐吸附、导航 clamp 等瞬移不应被当成奔跑。
	if instant_speed > maxf(_unit.movement_speed, 4.0) * TELEPORT_SPEED_FACTOR:
		_speed = 0.0
		return
	# 低通滤波同时抑制 RVO 避让的往复微抖（约 0.4 m/s，低于阈值但会抖动）。
	_speed = lerpf(_speed, instant_speed, SPEED_SMOOTHING)


func _on_attack_fired() -> void:
	if _death_started or _hit_overlay_remaining > 0.0 or _player == null or not _player.has_animation("Fire"):
		return
	# 移动开火直接丢弃：当前资产是全身站姿射击，且发射后哪怕立刻停下，
	# 也不能把陈旧射击补播成 Fire（否则"移动中开火→100ms 后停止"会假开火）。
	# 追击刹停的第一枪不同：FollowingToReachDistance 到达、stop() 清除移动
	# 意图、攻击动作首发事件发生在同一帧链内，到达此处时意图已被同步清除，
	# 因此用"是否仍被命令移动"判据可精确区分两者；速度只用于挂起后的消费。
	if _is_moving_by_intent():
		return
	_fire_pending = true
	_fire_pending_window = FIRE_PENDING_WINDOW


## 单位是否仍被命令移动（Movement 持有导航目标即视为移动意图存在）。
## 注意不能用瞬时速度判据：stop() 发生在 idle 帧链，位移采样滞后一个
## 物理帧，刹停第一枪发射瞬间"瞬时速度"仍是移动值，会误杀正常表现。
## 联机木偶不经 Movement 移动，意图恒为空，此时退化为纯速度观察窗口。
func _is_moving_by_intent() -> bool:
	var movement = _unit.get_node_or_null("Movement")
	return movement != null and movement.target_position != Vector3.INF


func _on_animation_finished(clip: StringName) -> void:
	if clip == &"Fire":
		# 由实际播放结束收尾，暂停和 speed_scale 都由 AnimationPlayer 处理。
		_fire_active = false


func _on_hp_changed() -> void:
	# 单位初始化时 hp 仍为 null 即会发 hp_changed，需防 Nil
	if _unit.hp == null or _death_started:
		return
	# 死亡判定必须先于掉血分级：出生当帧即被击杀时 _last_hp 仍为 null，
	# 若先按掉血量 early-return 会丢失整段死亡表现。
	if _unit.hp <= 0:
		_death_started = true
		_spawn_death_visual()
		set_process(false)
		set_physics_process(false)
		return
	var loss := float(_last_hp - _unit.hp) if _last_hp != null else 0.0
	_last_hp = _unit.hp
	if loss <= 0.0:
		return
	_fire_pending = false
	_fire_active = false
	_hit_clip = "Hit"
	var duration_msec := HIT_OVERLAY_MSEC
	if _player != null and _player.has_animation(_hit_clip):
		duration_msec = ceili(_player.get_animation(_hit_clip).length * 1000.0)
	_hit_overlay_remaining = float(duration_msec) / 1000.0
	# 每次命中都从冲击首帧重启，连续子弹不会被同名动画吞掉。
	_player.stop()
	_player.play(_hit_clip, 0.015)
	_player.advance(0.0)


func _spawn_death_visual() -> void:
	var geometry: Node3D = _unit.get_node_or_null("Geometry")
	var match_root: Node3D = _unit.find_parent("Match")
	if geometry == null or match_root == null:
		return
	var context = _unit.get_meta("damage_presentation", {})
	var explosion: bool = context is Dictionary and context.get("reaction", "") == "explosion"
	var clip := "HitHeavy" if explosion else "Death"
	var visual: Node3D = geometry.duplicate()
	visual.name = "InfantryDeathVisual"
	visual.add_to_group("infantry_death_visuals")
	match_root.add_child(visual)
	visual.global_transform = geometry.global_transform
	visual.visible = _unit.is_visible_in_tree()
	# 只转动死亡视觉，使炸飞方向背离爆点；无伤害/碰撞/导航副作用。
	if explosion:
		var direction: Vector3 = context.get("direction", Vector3.ZERO)
		direction.y = 0.0
		if direction.is_finite() and direction.length_squared() > 0.0001:
			visual.global_basis = Basis.looking_at(-direction.normalized(), Vector3.UP).scaled(
				geometry.global_basis.get_scale())
	var death_player: AnimationPlayer = visual.find_child("AnimationPlayer", true, false)
	if death_player == null or not death_player.has_animation(clip):
		visual.queue_free()
		return
	geometry.hide()
	death_player.stop()
	death_player.play(clip, 0.0)
	death_player.advance(0.0)
	# 定格帧不受原单位播放速度影响，清理节奏完全由本视觉自己决定。
	death_player.speed_scale = 1.0
	visual.set_meta("death_clip", clip)
	# 清理链必须绑定在视觉节点自身：驱动所属单位此刻即被 queue_free，
	# 任何依赖驱动回调/闭包的清理都会随对象失效。视觉强制 1.0 速率，
	# 播放时长可预算：剪辑长度 + 定格 DEATH_HOLD_SECONDS 后回收。
	# tween 随场景树暂停，暂停期间不会提前清掉定格尸体。
	var cleanup := visual.create_tween()
	cleanup.tween_interval(death_player.get_animation(clip).length + DEATH_HOLD_SECONDS)
	cleanup.tween_callback(visual.queue_free)


func _desired_clip() -> String:
	if _hit_overlay_remaining > 0.0:
		return _hit_clip
	if _speed > MOVE_SPEED_EPSILON:
		return "Run"
	if _fire_active:
		return "Fire"
	return "Idle"


## 状态切换只启动不同剪辑；单发重启只能来自新的开火/受击事件。
func _play(clip: String) -> void:
	if not _player.has_animation(clip):
		return
	if _player.assigned_animation == clip:
		return
	_player.play(clip, 0.2)
