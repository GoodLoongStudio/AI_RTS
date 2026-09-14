class_name SmokeTestExit
extends RefCounted


## 测试收尾：可选地先回收整局 → 停掉所有音频播放器 → 留 0.1s 清理窗口 → 退出。
##
## `match_root` 传承载整局的节点（一般是 `Match` 实例）时会先 `queue_free()` 并等两帧，
## 这样 Match 下的 `MusicDirector`（`peace_theme.wav` / `battle_theme.wav`，单文件 24MB 级）
## 和资源单位 `add_child.call_deferred()` 生成的 `ResourceDecayAnimation`
## （Node3D + GPUParticles3D）才会被真正释放。
##
## ⚠️ 整局留在树上就退出会命中回归 runner 的三条禁则
## （`ObjectDB instances were leaked at exit` / `resources still in use at exit` /
## `RID allocations of type .* were leaked at exit`）——2026-09-14 在
## `StructureRepairSellSmokeTest` 实测到 **51 个实例 + 9 个资源**泄漏。
## 新测试创建了整局就一定要把根节点传进来（不传 = 老行为，只做静音）。
static func request(tree: SceneTree, exit_code: int, match_root: Node = null) -> void:
	if match_root != null and is_instance_valid(match_root):
		match_root.queue_free()
		await tree.process_frame
		await tree.process_frame
	_silence_all_music(tree)
	tree.create_timer(0.1).timeout.connect(_quit.bind(tree, exit_code), CONNECT_ONE_SHOT)


## 停掉树上**所有**音频播放器并断开 stream 引用，让音频资源在退出时能正常释放。
##
## 覆盖两类常驻播放器，任一中招都会命中 `forbidden_output_patterns` 里的
## `ObjectDB instances were leaked at exit` ⇒ 表现为**偶发假红**：
##
## · 主菜单 BGM（autoload `MenuMusic`）：只在 `MatchSignals.match_started` 时才淡出，
##   非对局 headless 测试没人停它。Ogg 播放流中途退出会泄漏
##   （`AudioStreamPlaybackOggVorbis` / `OggPacketSequencePlayback` / `OggPacketSequence`
##   / `AudioStreamOggVorbis`，外加 `Resource still in use: res://assets/music/menu_theme.ogg`），
##   概率约 1/6，曾在 `CommandCursorSmokeTest` 上反复出现。
## · 对局 `Match/MusicDirector`：持 peace/battle 两个 `AudioStreamPlayer`，
##   WAV 播放流同理（`AudioStreamWAV` / `AudioStreamPlaybackWAV`）。
##
## 找不到播放器时是空操作，专用服/纯逻辑测试不受影响。
static func _silence_all_music(tree: SceneTree) -> void:
	for player in _collect_audio_players(tree.root):
		player.call("stop")
		player.set("stream", null)


## 递归收集所有音频播放器（3D 播放器在 headless 下也可能存在）。
static func _collect_audio_players(node: Node) -> Array:
	var found: Array = []
	if node is AudioStreamPlayer or node is AudioStreamPlayer3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(_collect_audio_players(child))
	return found


static func _quit(tree: SceneTree, exit_code: int) -> void:
	tree.quit(exit_code)
