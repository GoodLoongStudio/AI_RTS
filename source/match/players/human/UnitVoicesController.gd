extends Node

const Structure = preload("res://source/match/units/Structure.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")

var _last_ack_event = 0

@onready var _audio_player = find_child("AudioStreamPlayer")
@onready var _player = get_parent()


func _ready() -> void:
	MatchSignals.unit_selected.connect(_on_unit_selected)
	MatchSignals.unit_targeted.connect(_on_unit_action_requsted)
	MatchSignals.terrain_targeted.connect(_on_unit_action_requsted)


func _exit_tree():
	_release_audio_playback()


func _handle_event(event):
	if _audio_player.playing:
		return
	_play_stream(Constants.Match.VoiceNarrator.EVENT_TO_ASSET_MAPPING[event])


## 播放指定音频流（全局旁白与按单位语音共用同一播放器与占用规则）。
func _play_stream(stream: AudioStream):
	if _audio_player.playing or stream == null:
		return
	_audio_player.stream = stream
	_audio_player.play()


func _on_unit_selected(unit):
	if unit.player != _player:
		return
	if unit is ResourceUnit:
		return
	if unit is Structure:
		# 建筑也有各自专属的中文播报（原 TODO 已落地）。
		_play_stream(Constants.Match.VoiceNarrator.STRUCTURE_HELLO_MAPPING.get(unit.unit_type_id))
		return
	_play_stream(
		Constants.Match.VoiceNarrator.unit_voice(
			unit.unit_type_id, Constants.Match.VoiceNarrator.Events.UNIT_HELLO
		)
	)


func _on_unit_action_requsted(_ignore, _target_position = Vector3.INF):
	var units := get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return not unit is Structure and unit.player == _player
	)
	if units.is_empty():
		return
	# 以第一个选中单位的类型播对应的确认语音（每个单位台词/音色独特）。
	var ack_event = (
		Constants.Match.VoiceNarrator.Events.UNIT_ACK_1
		if _last_ack_event == 0
		else Constants.Match.VoiceNarrator.Events.UNIT_ACK_2
	)
	_play_stream(Constants.Match.VoiceNarrator.unit_voice(units[0].unit_type_id, ack_event))
	_last_ack_event = (_last_ack_event + 1) % 2


## 在场景卸载前停止并释放当前单位语音流，避免播放对象跨越场景生命周期。
func _release_audio_playback():
	if not is_instance_valid(_audio_player):
		return
	_audio_player.stop()
	_audio_player.stream = null
