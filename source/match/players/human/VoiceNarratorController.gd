extends Node

const Structure = preload("res://source/match/units/Structure.gd")

const UNDER_ATTACK_NOTIFICATION_THRESHOLD_MS = 10 * 1000
const PRIORITY_TRAINING = 0
const PRIORITY_NORMAL = 10
const PRIORITY_ALERT = 40
const PRIORITY_COMPLETION = 60
const PRIORITY_TERMINAL = 100

var _last_event_handled = null
var _last_under_attack_notification_timestamp = 0
var _current_priority := PRIORITY_NORMAL
var _active_production_chains := {}

@onready var _audio_player = find_child("AudioStreamPlayer")
@onready var _player = get_parent()


func _ready():
	MatchSignals.match_started.connect(
		_handle_event.bind(Constants.Match.VoiceNarrator.Events.MATCH_STARTED, PRIORITY_NORMAL)
	)
	MatchSignals.match_aborted.connect(
		_handle_event.bind(Constants.Match.VoiceNarrator.Events.MATCH_ABORTED, PRIORITY_TERMINAL)
	)
	MatchSignals.match_finished_with_victory.connect(
		_handle_event.bind(
			Constants.Match.VoiceNarrator.Events.MATCH_FINISHED_WITH_VICTORY,
			PRIORITY_TERMINAL
		)
	)
	MatchSignals.match_finished_with_defeat.connect(
		_handle_event.bind(
			Constants.Match.VoiceNarrator.Events.MATCH_FINISHED_WITH_DEFEAT,
			PRIORITY_TERMINAL
		)
	)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.unit_died.connect(_on_unit_died)
	MatchSignals.unit_production_started.connect(_on_production_started)
	MatchSignals.unit_production_finished.connect(_on_production_finished)
	MatchSignals.unit_production_queue_became_empty.connect(_on_production_queue_became_empty)
	MatchSignals.not_enough_resources_for_production.connect(_on_not_enough_resources)
	MatchSignals.not_enough_resources_for_construction.connect(_on_not_enough_resources)
	MatchSignals.unit_construction_finished.connect(_on_construction_finished)
	_audio_player.finished.connect(_on_audio_finished)


## 按稳定优先级播放旁白；高优先级完成提示可打断 training，反向覆盖则被拒绝。
func _handle_event(event, priority: int = PRIORITY_NORMAL):
	if (
		_audio_player.playing
		and (
			_last_event_handled
			in [
				Constants.Match.VoiceNarrator.Events.MATCH_FINISHED_WITH_VICTORY,
				Constants.Match.VoiceNarrator.Events.MATCH_FINISHED_WITH_DEFEAT
			]
		)
	):
		return
	if _audio_player.playing and priority < _current_priority:
		return
	_last_event_handled = event
	_current_priority = priority
	_audio_player.stream = Constants.Match.VoiceNarrator.EVENT_TO_ASSET_MAPPING[event]
	_audio_player.play()


## 音频自然结束后恢复普通优先级，避免旧事件影响下一次独立播报。
func _on_audio_finished():
	_current_priority = PRIORITY_NORMAL


func _on_unit_damaged(unit):
	if unit.player != _player:
		return
	var current_timestamp = Time.get_ticks_msec()
	if (
		current_timestamp - _last_under_attack_notification_timestamp
		> UNDER_ATTACK_NOTIFICATION_THRESHOLD_MS
	):
		_handle_event(
			(
				Constants.Match.VoiceNarrator.Events.BASE_UNDER_ATTACK
				if unit is Structure
				else Constants.Match.VoiceNarrator.Events.UNIT_UNDER_ATTACK
			),
			PRIORITY_ALERT
		)
	_last_under_attack_notification_timestamp = current_timestamp


func _on_unit_died(unit):
	if unit.is_in_group("controlled_units"):
		_handle_event(Constants.Match.VoiceNarrator.Events.UNIT_LOST, PRIORITY_ALERT)


func _on_production_started(_unit_prototype, producer_unit):
	if producer_unit.player != _player or producer_unit in _active_production_chains:
		return
	_active_production_chains[producer_unit] = true
	_handle_event(
		Constants.Match.VoiceNarrator.Events.UNIT_PRODUCTION_STARTED,
		PRIORITY_TRAINING
	)


func _on_production_finished(_unit, producer_unit):
	if producer_unit.player == _player:
		_handle_event(
			Constants.Match.VoiceNarrator.Events.UNIT_PRODUCTION_FINISHED,
			PRIORITY_COMPLETION
		)


## 队列真正清空后结束连续生产链；下一次新入队才重新播放 training。
func _on_production_queue_became_empty(producer_unit):
	_active_production_chains.erase(producer_unit)


func _on_construction_finished(unit):
	if unit.player == _player:
		_handle_event(
			Constants.Match.VoiceNarrator.Events.UNIT_CONSTRUCTION_FINISHED,
			PRIORITY_COMPLETION
		)


func _on_not_enough_resources(player):
	if player == get_parent():
		_handle_event(Constants.Match.VoiceNarrator.Events.NOT_ENOUGH_RESOURCES)
