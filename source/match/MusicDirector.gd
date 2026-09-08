extends Node
class_name MusicDirector

## 对局背景音乐导演：和平曲 ↔ 战斗曲自动切换。
## 战斗判定：任意己方单位受击（unit_damaged）刷新战斗计时；
## 计时归零后回到和平曲。切换用 2s 交叉淡入淡出。
## 2026-09-08：对局曲池暂空——用户待提供对局 BGM 音频；
## 主菜单音乐（menu_theme.ogg）由 Main.gd 直接挂载，与本导演无关。
## 用户补音频后：把 TRACKS["peace"] 与 BATTLE_TRACKS 填上即可恢复切换逻辑。

const TRACKS := {}
const BATTLE_TRACKS := []
const BATTLE_HOLD_SECONDS := 7.0
const FADE_SECONDS := 2.0
const MUSIC_DB := -10.0

var _players := {}
var _current := ""
var _battle_hold := 0.0
var _started := false
var _last_battle_path := ""


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
	if not BATTLE_TRACKS.is_empty():
		# 战斗曲播放器：流在每次切入战斗时随机指定
		var battle_player := AudioStreamPlayer.new()
		battle_player.name = "Music_battle"
		battle_player.volume_db = -60.0
		battle_player.bus = "Master"
		add_child(battle_player)
		_players["battle"] = battle_player
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.match_started.connect(_on_match_started, CONNECT_ONE_SHOT)


## 随机挑选一首战斗曲（不与上一次重复），设置循环后交给战斗播放器。
func _prepare_random_battle_stream() -> void:
	var path: String = BATTLE_TRACKS.pick_random()
	if path == _last_battle_path and BATTLE_TRACKS.size() > 1:
		path = BATTLE_TRACKS[(BATTLE_TRACKS.find(path) + 1) % BATTLE_TRACKS.size()]
	_last_battle_path = path
	var stream = load(path)
	_enable_loop(stream)
	_players["battle"].stream = stream


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
	if not _started or _players.is_empty():
		return
	_battle_hold = maxf(0.0, _battle_hold - delta)
	if _battle_hold <= 0.0 and _current != "peace":
		play_track("peace")


func _on_match_started():
	_started = true
	if _players.is_empty():
		return
	play_track("peace")


func _on_unit_damaged(_unit):
	if not _started or _players.is_empty():
		return
	_battle_hold = BATTLE_HOLD_SECONDS
	if _current != "battle":
		play_track("battle")


## 淡出当前曲目并淡入目标曲目（重复调用同一曲目为 no-op）。
## 战斗曲在切入前随机换一首（同场战斗连续触发不会中途换曲）。
func play_track(key: String):
	if _current == key or not _players.has(key):
		return
	if key == "battle":
		_prepare_random_battle_stream()
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
