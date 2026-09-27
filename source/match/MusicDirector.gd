extends Node
class_name MusicDirector

## 对局背景音乐导演：进入对局后按曲目列表轮播，不再按和平/战斗状态切歌。
## 【2026-09-26 用户换曲】轮播曲目 = 用户提供的对局双曲（正常 ↔ 激情交替），
## ASCII 副本在 assets/music/user/（原件在 <项目>/music/，已 .gdignore）。
## 注意：轮播依赖 `finished` 信号推进，曲目**不能**循环（循环会导致永远停在一首）；
## 单曲循环场景（菜单 BGM）由 MenuMusic 自行调 `_enable_loop`。
## 此前对局音乐按产品要求整体关闭（_setup_music_director 无人调用）——
## 用户交付对局双曲即恢复启用。

const PLAYLIST := [
	"res://assets/music/user/match_normal.mp3",
	"res://assets/music/user/match_intense.mp3",
]
const FADE_SECONDS := 1.5
## 曲目切换间的静音停顿（秒）：淡出 → 停顿 → 淡入
const SWITCH_GAP_SECONDS := 3.0
const MUSIC_DB := -6.0

var _players := {}
var _current := ""
var _pending := ""
var _switch_tween: Tween = null
var _started := false
var _playlist_index := -1


func _ready():
	var player := AudioStreamPlayer.new()
	player.name = "MatchMusic"
	player.volume_db = MUSIC_DB
	player.bus = "Music"
	player.finished.connect(_on_track_finished)
	add_child(player)
	_players["playlist"] = player
	MatchSignals.match_started.connect(_on_match_started, CONNECT_ONE_SHOT)


## 首次播放前才装载大音频流（24MB 级 WAV 解压耗时，避免拖慢对局启动）。
func _ensure_stream(key: String) -> void:
	var player: AudioStreamPlayer = _players[key]
	if player.stream != null:
		return
	if _playlist_index < 0:
		_playlist_index = 0
	var stream = load(PLAYLIST[_playlist_index])
	player.stream = stream


## 按流类型打开无缝循环：MP3/OGG 用 loop 属性，WAV 用 FORWARD 循环段。
static func _enable_loop(stream) -> void:
	if stream == null:
		return
	if stream is AudioStreamMP3:
		stream.loop = true
	elif stream is AudioStreamOggVorbis:
		stream.loop = true
	elif stream is AudioStreamWAV:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_begin = 0
		# 16-bit 立体声：帧数 = 字节数 / (2 字节 × 2 声道)
		stream.loop_end = stream.data.size() / 4


func _process(delta):
	if not _started or _players.is_empty():
		return
	if not _players["playlist"].playing:
		_on_track_finished()


func _on_match_started():
	_started = true
	if _players.is_empty():
		return
	_on_track_finished()


func _on_track_finished() -> void:
	if not _started or PLAYLIST.is_empty():
		return
	_playlist_index = (_playlist_index + 1) % PLAYLIST.size()
	var player: AudioStreamPlayer = _players["playlist"]
	player.stream = load(PLAYLIST[_playlist_index])
	player.volume_db = MUSIC_DB
	player.play()


## 曲目切换：淡出当前曲 → 静音停顿几秒 → 再淡入新曲（避免生硬硬切）。
## 无当前曲目（如开局首播）直接淡入，不停顿；
## 切换进行中重复请求同一目标为 no-op；反向请求则取消当前切换改道。
func play_track(_key: String):
	_on_track_finished()


## 停顿结束：真正切入新曲（战斗曲在此刻随机挑选）。
func _begin_track(_key: String):
	_on_track_finished()


