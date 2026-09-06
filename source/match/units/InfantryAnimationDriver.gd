extends Node

## 步兵骨骼动画驱动：原厂 50 骨架的七段剪辑（Infantry_native_v3.glb
## 内嵌 AnimationPlayer）按 Unit.action 类型 + 实际位移速度映射播放。
## 剪辑清单（单角色基线，全部携枪）：循环 Idle/Run/Crawl，
## 单发 Hit(快速中弹)/HitHeavy(爆炸击飞死亡)/Fire(射击)/Death(普通死亡)。
## 致死爆炸由独立视觉节点播完 HitHeavy；存活受击使用短促 Hit。
## Crawl 暂无对应玩法状态，作为资产保留待"匍匐指令"接入。
## 死亡时只复制 Geometry，单位仍立即退出战斗；视觉播完后自动清理。

const ATTACK_ACTION_SUFFIXES := [
	"OrdinaryAttacking.gd",
	"AutoAttacking.gd",
	"AttackingWhileInRange.gd",
	"ExplicitForceAttacking.gd",
]
## 速度阈值需高于 RVO 避让的往复微抖速度（实测抖动可到 0.4 m/s 左右）
const MOVE_SPEED_EPSILON := 0.6
## 动作资源缺失时的受击覆盖兜底；正常播放以剪辑实际长度为准。
const HIT_OVERLAY_MSEC := 300
const DEATH_HOLD_SECONDS := 1.0
const LOOP_CLIPS := ["Idle", "Run", "Crawl"]

var _player: AnimationPlayer
var _unit: Node
var _last_position := Vector3.INF
var _speed := 0.0
var _hit_overlay_remaining := 0.0
var _hit_clip := "Hit"
var _last_hp = null
var _death_started := false


func _ready() -> void:
	_unit = get_parent()
	_player = _unit.find_child("AnimationPlayer", true, false)
	if _player == null:
		push_warning("InfantryAnimationDriver: 未找到 AnimationPlayer，动画驱动停用")
		set_process(false)
		return
	for clip in LOOP_CLIPS:
		if _player.has_animation(clip):
			_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	if _unit.has_signal("hp_changed"):
		_unit.hp_changed.connect(_on_hp_changed)
	_play("Idle")


func _process(delta: float) -> void:
	_hit_overlay_remaining = maxf(0.0, _hit_overlay_remaining - delta * absf(_player.speed_scale))
	_update_speed(delta)
	if _unit.hp != null:
		_last_hp = _unit.hp
	_play(_desired_clip())


func _on_hp_changed() -> void:
	# 单位初始化时 hp 仍为 null 即会发 hp_changed，需防 Nil
	if _unit.hp == null or _death_started:
		return
	var loss := float(_last_hp - _unit.hp) if _last_hp != null else 0.0
	_last_hp = _unit.hp
	if loss <= 0.0:
		return
	if _unit.hp <= 0:
		_death_started = true
		_spawn_death_visual()
		set_process(false)
		return
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
	visual.set_meta("death_clip", clip)
	var cleanup := visual.create_tween()
	cleanup.tween_interval(death_player.get_animation(clip).length / maxf(absf(death_player.speed_scale), 0.001) + DEATH_HOLD_SECONDS)
	cleanup.tween_callback(visual.queue_free)


func _update_speed(delta: float) -> void:
	var position: Vector3 = _unit.global_position
	if _last_position == Vector3.INF:
		_last_position = position
		return
	var displacement := position - _last_position
	displacement.y = 0.0
	_speed = displacement.length() / maxf(delta, 0.0001)
	_last_position = position


func _desired_clip() -> String:
	if _hit_overlay_remaining > 0.0:
		return _hit_clip
	var action = _unit.get("action")
	var script_path := ""
	if action != null and action.get_script() != null:
		script_path = str(action.get_script().resource_path)
	if _has_suffix(script_path, ATTACK_ACTION_SUFFIXES):
		return "Fire"
	if _speed > MOVE_SPEED_EPSILON:
		return "Run"
	return "Idle"


func _has_suffix(path: String, suffixes: Array) -> bool:
	for suffix in suffixes:
		if path.ends_with(suffix):
			return true
	return false


## 单发剪辑播完且状态未变时重播（如持续攻击时的 Fire 循环）；
## 同名循环剪辑播放中不重启。
func _play(clip: String) -> void:
	if not _player.has_animation(clip):
		return
	if _player.current_animation == clip:
		var one_shot := not LOOP_CLIPS.has(clip)
		if not one_shot or _player.is_playing():
			return
	_player.play(clip, 0.2)
