class_name SmokeTestExit
extends RefCounted


## 在测试协程返回并释放局部 Godot/C# 包装引用后，留出短暂清理窗口再退出 SceneTree。
static func request(tree: SceneTree, exit_code: int) -> void:
	_silence_menu_music(tree)
	tree.create_timer(0.1).timeout.connect(_quit.bind(tree, exit_code), CONNECT_ONE_SHOT)


## 主菜单 BGM（autoload `MenuMusic`）是常驻播放器，只在 `MatchSignals.match_started`
## 时才淡出。headless 冒烟测试大多不是对局场景 ⇒ 没人停它，而 **Ogg 播放流在播放中途退出会泄漏**
## （实测泄漏对象是 `AudioStreamPlaybackOggVorbis` / `OggPacketSequencePlayback` /
## `OggPacketSequence` / `AudioStreamOggVorbis`，并触发 `Resource still in use:
## res://assets/music/menu_theme.ogg`）。概率约 1/6，而回归 runner 的
## `forbidden_output_patterns` 含 `ObjectDB instances were leaked at exit` ⇒ 表现为**偶发假红**。
## 这里在收尾窗口前停播并断开 stream 引用，让资源能正常释放（找不到 MenuMusic 时是空操作，
## 专用服/纯逻辑测试不受影响）。
static func _silence_menu_music(tree: SceneTree) -> void:
	var menu_music := tree.root.get_node_or_null("MenuMusic")
	if menu_music == null:
		return
	for child in menu_music.get_children():
		if child is AudioStreamPlayer:
			child.stop()
			child.stream = null


static func _quit(tree: SceneTree, exit_code: int) -> void:
	tree.quit(exit_code)
