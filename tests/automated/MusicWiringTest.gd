extends Node

## 音乐接线端到端验证（2026-09-26 用户换曲）：
##   菜单 BGM =《游戏背景音乐》(assets/music/user/menu_bgm.mp3, 循环)
##   对局 BGM =《正常》《激情》(match_normal/intense.mp3) 轮播，进对局即播
## 必须窗口化跑：MusicDirector 与 MenuMusic 在 headless 下都不工作（有意设计）。
## 默认音量设置是静音（Master mute），播放无声但不影响状态断言。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const MENU_MP3 := "res://assets/music/user/menu_bgm.mp3"
const NORMAL_MP3 := "res://assets/music/user/match_normal.mp3"
const INTENSE_MP3 := "res://assets/music/user/match_intense.mp3"

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	# ---- ① 三首曲目都能加载且是 MP3 流 ----
	for path in [MENU_MP3, NORMAL_MP3, INTENSE_MP3]:
		var stream = load(path)
		_check(stream != null and stream is AudioStreamMP3,
			"应能加载 MP3 流：%s" % path)
	_check(FileAccess.file_exists("res://music/.gdignore"),
		"music/ 原件目录应已 .gdignore（不重复导入）")

	# ---- ② MenuMusic 自动加载：新曲目 + MP3 循环已开 ----
	var menu_music: Node = get_tree().root.get_node_or_null("MenuMusic")
	_check(menu_music != null, "应有 MenuMusic 自动加载")
	if menu_music != null:
		var player: AudioStreamPlayer = menu_music.get_node_or_null("Player") \
			as AudioStreamPlayer
		_check(player != null, "MenuMusic 应有播放器")
		if player != null:
			_check(str(player.stream.resource_path) == MENU_MP3,
				"菜单 BGM 应为《游戏背景音乐》（实际 %s）" % player.stream.resource_path)
			_check(player.bus == "Music", "菜单 BGM 应走 Music 总线")
			_check(player.stream is AudioStreamMP3 and player.stream.loop,
				"菜单 BGM 应无缝循环（AudioStreamMP3.loop=true）")

	# ---- ③ 起真对局 → MusicDirector 挂载并对局曲开播 ----
	var settings = MatchSettings.new()
	var human = load("res://source/data-model/PlayerSettings.gd").new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = load("res://source/data-model/PlayerSettings.gd").new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.PER_PLAYER

	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(a_match)

	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if a_match.get_node_or_null("MusicDirector") != null:
			break
	var director: Node = a_match.get_node_or_null("MusicDirector")
	_check(director != null, "对局应挂载 MusicDirector（对局音乐已启用）")
	if director != null:
		var playlist: Variant = director.get("PLAYLIST")
		var paths: Array = []
		for p in (playlist as Array):
			paths.append(str(p))
		_check(paths == [NORMAL_MP3, INTENSE_MP3],
			"对局轮播应为《正常》《激情》（实际 %s）" % str(paths))
		# 等 match_started → 首曲开播
		deadline = Time.get_ticks_msec() + 30000
		var playing := false
		while Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
			var mp: AudioStreamPlayer = director.get_node_or_null("MatchMusic") \
				as AudioStreamPlayer
			if mp != null and mp.playing:
				playing = true
				_check(mp.bus == "Music", "对局 BGM 应走 Music 总线")
				_check(str(mp.stream.resource_path) in [NORMAL_MP3, INTENSE_MP3],
					"对局首曲应为《正常》或《激情》（实际 %s）" % mp.stream.resource_path)
				_check(not (mp.stream as AudioStreamMP3).loop,
					"对局曲目不得循环（轮播靠 finished 推进）")
				break
		_check(playing, "进入对局后对局 BGM 应在播放")

	# ---- ④ 菜单曲在进对局时淡出停止（MusicDirector 接棒）----
	# 淡出动画 1.0s，先等它走完再断言。
	await get_tree().create_timer(2.0).timeout
	if menu_music != null:
		var player: AudioStreamPlayer = menu_music.get_node_or_null("Player") \
			as AudioStreamPlayer
		if player != null:
			_check(not player.playing, "进对局后菜单 BGM 应已淡出停止")

	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Music wiring: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Music wiring: %d failure(s)" % _failures)
		get_tree().quit(1)
