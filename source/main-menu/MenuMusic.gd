extends Node

## 主菜单背景音乐常驻播放器（2026-09-08）：
## 自动加载，跨场景切换持续播放——主菜单/单人战役/自定义战斗/联机/设置/制作人员
## 等所有非对局界面都不间断；进入对局（Match.tscn 实例化）时淡出停止，
## 回到任一菜单界面自动续播。音量走 Music 总线（设置里可调）。

const MENU_MUSIC := "res://assets/music/menu_theme.ogg"
const MENU_MUSIC_DB := -4.0
const FADE_OUT_SECONDS := 1.0
const MENU_SCENES := [
	"res://source/main-menu/Main.tscn",
	"res://source/main-menu/Play.tscn",
	"res://source/main-menu/Online.tscn",
	"res://source/main-menu/Options.tscn",
	"res://source/main-menu/Credits.tscn",
	"res://source/main-menu/Loading.tscn",
	"res://source/campaign/CampaignMenu.tscn",
]

var _player: AudioStreamPlayer
var _fade_tween: Tween = null


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	if ResourceLoader.exists(MENU_MUSIC):
		var stream = load(MENU_MUSIC)
		MusicDirector._enable_loop(stream)
		_player.stream = stream
	_player.volume_db = MENU_MUSIC_DB
	_player.bus = "Music"
	add_child(_player)
	_player.play()
	get_tree().node_added.connect(_on_node_added)
	# 进入对局以 match_started 为准（测试夹具嵌套实例的 scene_file_path 不可靠）
	MatchSignals.match_started.connect(_fade_out_and_stop)


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
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	_player.volume_db = -60.0
	_player.play()
	_fade_tween.tween_property(_player, "volume_db", MENU_MUSIC_DB, FADE_OUT_SECONDS)
