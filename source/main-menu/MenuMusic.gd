extends Node

## 主菜单背景音乐常驻播放器（2026-09-08）：
## 自动加载，跨场景切换持续播放——主菜单/单机模式/在线匹配/设置/成长系统/地图生成
## 等所有非对局界面都不间断；进入对局（Match.tscn 实例化）时淡出停止，
## 回到任一菜单界面自动续播。音量走 Music 总线（设置里可调）。

## 外星入侵废土风格菜单主题：不再直接播放原 menu_theme.ogg。
const MENU_MUSIC := "res://assets/music/reimagined/menu_signal.wav"
const MENU_MUSIC_DB := -4.0
const FADE_OUT_SECONDS := 1.0
const MENU_SCENES := [
	"res://source/main-menu/Main.tscn",
	"res://source/main-menu/Play.tscn",
	"res://source/main-menu/Online.tscn",
	"res://source/main-menu/Options.tscn",
	"res://source/main-menu/Growth.tscn",
	"res://source/main-menu/MapGeneration.tscn",
	"res://source/main-menu/Loading.tscn",
]

var _player: AudioStreamPlayer
var _fade_tween: Tween = null


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	_player.bus = "Music"
	add_child(_player)
	get_tree().node_added.connect(_on_node_added)
	# 进入对局以 match_started 为准（测试夹具嵌套实例的 scene_file_path 不可靠）
	MatchSignals.match_started.connect(_fade_out_and_stop)
	# headless（回归 / 专用服 / CI）不加载也不播放主菜单 BGM（2026-09-14）：
	# 无头下走的是 Dummy 音频驱动，Ogg 播放流在引擎退出时有 **~1/3 概率**不被释放，
	# 退出时报 `ObjectDB instances were leaked at exit` + `resources still in use at exit`
	# （泄漏对象 `AudioStreamPlaybackOggVorbis` / `OggPacketSequencePlayback` /
	# `OggPacketSequence` / `AudioStreamOggVorbis` + `res://assets/music/menu_theme.ogg`）。
	# 这两条都在回归 runner 的 `forbidden_output_patterns` 里 ⇒ **大批测试无端偶发变红**
	# （实测旧收尾 3/8 命中，而且在收尾里 stop()+stream=null 也压不住）。
	# 无头环境本来就没有听感需求，直接不播是最可靠的消除方式；玩家端（有窗口）行为不变。
	if DisplayServer.get_name() == "headless":
		return
	_player.volume_db = MENU_MUSIC_DB
	if ResourceLoader.exists(MENU_MUSIC):
		var stream = load(MENU_MUSIC)
		MusicDirector._enable_loop(stream)
		_player.stream = stream
	_player.play()


## 回到菜单场景 → 续播。
func _on_node_added(node: Node):
	var scene_path := str(node.scene_file_path)
	if scene_path.is_empty():
		return
	if scene_path in MENU_SCENES and not _player.playing:
		_fade_in_and_play()


func _fade_out_and_stop():
	if not _player.playing:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_player, "volume_db", -60.0, FADE_OUT_SECONDS)
	_fade_tween.tween_callback(_player.stop)


func _fade_in_and_play():
	# headless 下 `_ready` 明确不装载 stream（见那里的说明），这里直接跳过，
	# 免得对空 stream 调 play()。
	if _player.stream == null:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_player.volume_db = -60.0
	_player.play()
	_fade_tween.tween_property(_player, "volume_db", MENU_MUSIC_DB, FADE_OUT_SECONDS)
