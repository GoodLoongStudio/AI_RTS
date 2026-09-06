extends Node

## 步兵骨骼动画驱动：原厂 50 骨架的七段剪辑（Infantry_native_v3.glb
## 内嵌 AnimationPlayer）按 Unit.action 类型 + 实际位移速度映射播放。
## 剪辑清单（单角色基线，全部携枪）：循环 Idle/Run/Crawl，
## 单发 Hit(轻击)/HitHeavy(较强站立受击)/Fire(射击)/Death(死亡)。
## 受击按掉血量分级覆盖：单次损失 >= 30 或 >= 30% 上限 播 HitHeavy，否则 Hit。
## Crawl 暂无对应玩法状态，作为资产保留待"匍匐指令"接入。
## 未接入：Death——单位死亡由 Unit._handle_unit_death 立即 queue_free，
## 播放死亡动画需延迟销毁（玩法逻辑改动），待单独批准。

const ATTACK_ACTION_SUFFIXES := [
	"OrdinaryAttacking.gd",
	"AutoAttacking.gd",
	"AttackingWhileInRange.gd",
	"ExplicitForceAttacking.gd",
]
## 速度阈值需高于 RVO 避让的往复微抖速度（实测抖动可到 0.4 m/s 左右）
const MOVE_SPEED_EPSILON := 0.6
## 动作资源缺失时的受击覆盖兜底；正常播放以剪辑实际长度为准。
const HIT_OVERLAY_MSEC := 500
## 重击分界：单次掉血达到该值播 HitHeavy（爆炸类伤害），否则播 Hit
const HEAVY_DAMAGE_MIN := 30.0
const LOOP_CLIPS := ["Idle", "Run", "Crawl"]

var _player: AnimationPlayer
var _unit: Node
var _last_position := Vector3.INF
var _speed := 0.0
var _hit_overlay_remaining := 0.0
var _hit_clip := "Hit"
var _hp_max_cache := 0.0
var _last_hp = null


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
	_hit_overlay_remaining = maxf(0.0, _hit_overlay_remaining - delta)
	_update_speed(delta)
	if _unit.hp != null:
		_last_hp = _unit.hp
	_play(_desired_clip())


func _on_hp_changed() -> void:
	# 单位初始化时 hp 仍为 null 即会发 hp_changed，需防 Nil
	if _unit.hp == null or _unit.hp <= 0:
		return
	if _unit.hp_max != null:
		_hp_max_cache = float(_unit.hp_max)
	# 单次掉血 >= HEAVY_DAMAGE_MIN 或 >= 30% 上限 视为重击(爆炸)
	var loss := float(_last_hp - _unit.hp) if _last_hp != null else 0.0
	if loss <= 0.0:
		return
	_hit_clip = "HitHeavy" if (
		loss >= HEAVY_DAMAGE_MIN or (_hp_max_cache > 0 and loss >= _hp_max_cache * 0.3)
	) else "Hit"
	var duration_msec := HIT_OVERLAY_MSEC
	if _player != null and _player.has_animation(_hit_clip):
		duration_msec = ceili(_player.get_animation(_hit_clip).length * 1000.0)
	# Use animation/game time so speed-up does not hold a completed hit pose.
	_hit_overlay_remaining = float(duration_msec) / 1000.0 / maxf(absf(_player.speed_scale), 0.001)
	_last_hp = _unit.hp


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
