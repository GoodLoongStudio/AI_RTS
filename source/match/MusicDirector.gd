extends Node
class_name MusicDirector

## 对局背景音乐导演（2026-09-08 换官方音乐包）：和平曲 ↔ 战斗曲自动切换。
## 战斗判定：任意己方单位受击（unit_damaged）刷新战斗计时；
## 计时归零后回到和平曲。切换用 2s 交叉淡入淡出。
## 音源：assets/music/command_*.ogg（循环在运行时打开，OGG 用 loop 属性）。

const TRACKS := {
	"peace": "res://assets/music/command_battle_bed.ogg",
	"battle": "res://assets/music/command_battle_full.ogg",
}
const BATTLE_HOLD_SECONDS := 7.0
const FADE_SECONDS := 2.0
const MUSIC_DB := -10.0

var _players := {}
var _current := ""
var _battle_hold := 0.0
var _started := false


func _ready():
	for key in TRACKS:
		var player := AudioStreamPlayer.new()
		player.name = "Music_" + key
		var stream = load(TRACKS[key])
		_enable_loop(stream)
		player.stream = stream
		player.volume_db = -60.0
		player.bus = "Master"
		add_child(player)
		_players[key] = player
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.match_started.connect(_on_match_started, CONNECT_ONE_SHOT)


## 按流类型打开无缝循环：OGG 用 loop 属性，WAV 用 FORWARD 循环段。
static func _enable_loop(stream) -> void:
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		# 16-bit 立体声：帧数 = 字节数 / (2 字节 × 2 声道)
		stream.loop_end = stream.data.size() / 4


func _process(delta):
	if not _started:
		return
	_battle_hold = maxf(0.0, _battle_hold - delta)
	if _battle_hold <= 0.0 and _current != "peace":
		play_track("peace")


func _on_match_started():
	_started = true
	play_track("peace")


func _on_unit_damaged(_unit):
	if not _started:
		return
	_battle_hold = BATTLE_HOLD_SECONDS
	if _current != "battle":
		play_track("battle")


## 淡出当前曲目并淡入目标曲目（重复调用同一曲目为 no-op）。
func play_track(key: String):
	if _current == key or not _players.has(key):
		return
	var incoming: AudioStreamPlayer = _players[key]
	if _current != "":
		var outgoing: AudioStreamPlayer = _players[_current]
		var tween_out = create_tween()
		tween_out.tween_property(outgoing, "volume_db", -60.0, FADE_SECONDS)
		tween_out.tween_callback(outgoing.stop)
	incoming.volume_db = -60.0
	incoming.play()
	var tween_in = create_tween()
	tween_in.tween_property(incoming, "volume_db", MUSIC_DB, FADE_SECONDS)
	_current = key
