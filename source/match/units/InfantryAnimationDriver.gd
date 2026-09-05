extends Node

## 步兵骨骼动画驱动（v2）：绑骨管线烘焙的九段剪辑（Infantry_anim_v2.glb 内嵌
## AnimationPlayer）按 Unit.action 类型 + 实际位移速度映射播放；受击时短暂
## 覆盖为 Hit。取代期 2 Step10 的程序化摆骨骼方案（_pose_idle/_pose_walk 等）。
## 剪辑清单：循环 Idle/Walk/Run/Gather/Build，单发 Attack/Fire/Hit/Death
## （剪辑名 "-loop" 后缀在 glTF 导入时已转为循环标志）。
## 未接入：Death——单位死亡由 Unit._handle_unit_death 立即 queue_free，
## 播放死亡动画需延迟销毁（玩法逻辑改动），待单独批准。

const ATTACK_ACTION_SUFFIXES := [
	"OrdinaryAttacking.gd",
	"AutoAttacking.gd",
	"AttackingWhileInRange.gd",
	"ExplicitForceAttacking.gd",
]
const BUILD_ACTION_SUFFIXES := [
	"ConstructingWhileInRange.gd",
]
const COLLECTING_SCRIPT_SUFFIX := "CollectingResourcesSequentially.gd"
const COLLECTING_STATE := 2  # CollectingResourcesSequentially.State.COLLECTING
## 速度阈值需高于 RVO 避让的往复微抖速度（实测抖动可到 0.4 m/s 左右）
const MOVE_SPEED_EPSILON := 0.6
## 走/跑分界：步兵巡航速度 3.5 m/s，低于该值视为走
const RUN_SPEED_MIN := 2.6
## 受击覆盖时长：Hit 剪辑全长约 0.67s，覆盖窗口略短便于衔接下一状态
const HIT_OVERLAY_MSEC := 500
const LOOP_CLIPS := ["Idle", "Walk", "Run", "Gather", "Build"]

var _player: AnimationPlayer
var _unit: Node
var _last_position := Vector3.INF
var _speed := 0.0
var _hit_overlay_until := -1


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


func _process(_delta: float) -> void:
	_update_speed(_delta)
	_play(_desired_clip())


func _on_hp_changed() -> void:
	# 单位初始化时 hp 仍为 null 即会发 hp_changed，需防 Nil
	if _unit.hp != null and _unit.hp > 0:
		_hit_overlay_until = Time.get_ticks_msec() + HIT_OVERLAY_MSEC


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
	if Time.get_ticks_msec() < _hit_overlay_until:
		return "Hit"
	var action = _unit.get("action")
	var script_path := ""
	if action != null and action.get_script() != null:
		script_path = str(action.get_script().resource_path)
	if _has_suffix(script_path, ATTACK_ACTION_SUFFIXES):
		return "Fire"
	if _has_suffix(script_path, BUILD_ACTION_SUFFIXES):
		return "Build"
	if _is_collecting(action, script_path):
		return "Gather"
	if _speed > MOVE_SPEED_EPSILON:
		return "Run" if _speed >= RUN_SPEED_MIN else "Walk"
	return "Idle"


func _has_suffix(path: String, suffixes: Array) -> bool:
	for suffix in suffixes:
		if path.ends_with(suffix):
			return true
	return false


## 采集判定：直接采集动作处于 COLLECTING 态，或自动采集包装器的子动作在采集态
func _is_collecting(action, script_path: String) -> bool:
	if script_path.ends_with(COLLECTING_SCRIPT_SUFFIX):
		return int(action.get("_state")) == COLLECTING_STATE
	if script_path.ends_with("AutoGatheringResources.gd"):
		var sub = action.get("_sub_action")
		if sub != null and sub.get_script() != null \
				and str(sub.get_script().resource_path).ends_with(COLLECTING_SCRIPT_SUFFIX):
			return int(sub.get("_state")) == COLLECTING_STATE
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
