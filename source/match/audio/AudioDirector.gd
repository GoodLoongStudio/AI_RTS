extends Node

const MANIFEST_PATH := "res://config/presentation/audio.manifest.v1.json"
const POOL_SIZE := 12
const MUSIC_PATHS := {
	"menu": "res://assets/audio/music/menu_theme.wav",
	"match": "res://assets/audio/music/match_theme.wav",
}
const MUSIC_FADE_SECONDS := 0.8
const MUSIC_BASE_DB := -4.0

var _cues := {}
var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _last_play_msec := {}
var _music_a: AudioStreamPlayer
var _music_b: AudioStreamPlayer
var _music_front: AudioStreamPlayer
var _music_context := ""


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_manifest()
	_build_pool()
	_build_music_players()
	call_deferred("_sync_music_from_scene")
	if MatchSignals != null:
		MatchSignals.unit_selected.connect(_on_unit_selected)
		MatchSignals.unit_died.connect(_on_unit_died)
		MatchSignals.unit_construction_finished.connect(_on_construction_finished)


func _exit_tree():
	_release_all()


## 按清单播放一条自制音效；无资源或超限时静默跳过。
func play(cue_id: String) -> void:
	if not _cues.has(cue_id):
		return
	var cue: Dictionary = _cues[cue_id]
	var stream: AudioStream = _streams.get(cue_id)
	if stream == null:
		return
	var now := Time.get_ticks_msec()
	var min_interval := int(cue.get("minIntervalMs", 0))
	if now - int(_last_play_msec.get(cue_id, 0)) < min_interval:
		return
	var max_voices := int(cue.get("maxVoices", 1))
	if _count_playing(cue_id) >= max_voices:
		return
	var player := _acquire()
	if player == null:
		return
	player.bus = _resolve_bus(str(cue.get("bus", "Sfx")))
	player.volume_db = float(cue.get("volumeDb", 0.0))
	player.stream = stream
	player.set_meta("cue_id", cue_id)
	player.play()
	_last_play_msec[cue_id] = now


func _on_unit_selected(_unit) -> void:
	play("unit_select")


func _on_unit_died(_unit) -> void:
	play("unit_death")


func _on_construction_finished(_unit) -> void:
	play("construction_complete")


## 菜单与对局切换循环 BGM；同上下文重复调用会被忽略。
func set_music_context(context: String) -> void:
	if context == _music_context:
		return
	_music_context = context
	var path := str(MUSIC_PATHS.get(context, ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("背景音乐缺失：%s" % context)
		return
	var stream = load(path)
	if not stream is AudioStream:
		push_warning("背景音乐无法加载：%s" % path)
		return
	_crossfade_to(_prepare_loop(stream))


func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("音频清单不存在：%s" % MANIFEST_PATH)
		return
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		push_warning("无法读取音频清单")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("音频清单格式无效")
		return
	var cues: Variant = parsed.get("cues", {})
	if typeof(cues) != TYPE_DICTIONARY:
		return
	for cue_id in cues.keys():
		var cue: Variant = cues[cue_id]
		if typeof(cue) != TYPE_DICTIONARY:
			continue
		var path := str(cue.get("path", ""))
		if path.is_empty() or not ResourceLoader.exists(path):
			push_warning("音效缺失：%s -> %s" % [cue_id, path])
			continue
		var stream = load(path)
		if stream is AudioStream:
			_cues[str(cue_id)] = cue
			_streams[str(cue_id)] = stream


func _build_music_players() -> void:
	_music_a = _make_music_player()
	_music_b = _make_music_player()
	_music_front = _music_a


func _make_music_player() -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = _resolve_bus("Music")
	player.volume_db = -40.0
	add_child(player)
	return player


func _prepare_loop(stream: AudioStream) -> AudioStream:
	var prepared: AudioStream = stream.duplicate()
	if prepared is AudioStreamWAV:
		var wav := prepared as AudioStreamWAV
		var length := wav.get_length()
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		if length > 0.0:
			wav.loop_end = int(round(length * float(wav.mix_rate)))
		else:
			wav.loop_end = -1
	elif prepared is AudioStreamMP3:
		prepared.loop = true
	elif prepared is AudioStreamOggVorbis:
		prepared.loop = true
	return prepared


func _crossfade_to(stream: AudioStream) -> void:
	var incoming: AudioStreamPlayer = _music_b if _music_front == _music_a else _music_a
	var outgoing := _music_front
	incoming.stop()
	incoming.stream = stream
	incoming.play()
	if outgoing == null or not outgoing.playing:
		incoming.volume_db = MUSIC_BASE_DB
		_music_front = incoming
		return
	incoming.volume_db = -40.0
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(incoming, "volume_db", MUSIC_BASE_DB, MUSIC_FADE_SECONDS)
	tween.parallel().tween_property(outgoing, "volume_db", -40.0, MUSIC_FADE_SECONDS)
	tween.tween_callback(outgoing.stop)
	_music_front = incoming


func _sync_music_from_scene() -> void:
	if _music_context != "":
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	if str(scene.name) == "Match":
		set_music_context("match")
	else:
		set_music_context("menu")


func _build_pool() -> void:
	for _i in POOL_SIZE:
		var player := AudioStreamPlayer.new()
		player.finished.connect(_on_player_finished.bind(player))
		add_child(player)
		_players.append(player)


func _acquire() -> AudioStreamPlayer:
	for player in _players:
		if not player.playing:
			return player
	return null


func _count_playing(cue_id: String) -> int:
	var count := 0
	for player in _players:
		if player.playing and str(player.get_meta("cue_id", "")) == cue_id:
			count += 1
	return count


func _resolve_bus(bus_name: String) -> String:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return bus_name
	return "Master"


func _on_player_finished(player: AudioStreamPlayer) -> void:
	player.set_meta("cue_id", "")


func _release_all() -> void:
	for player in _players:
		if not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
		player.set_meta("cue_id", "")
	for player in [_music_a, _music_b]:
		if player == null or not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
