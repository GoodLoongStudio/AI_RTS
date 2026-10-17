extends Node

## 回归：从真实 Play -> host -> Loading 链路注入坏配置时，必须显示失败并关闭房间。

const PlayScene := preload("res://source/main-menu/Play.tscn")


func _ready() -> void:
	NetSession.disconnect_if_networked()
	await get_tree().process_frame
	var play: Node = PlayScene.instantiate()
	get_tree().root.add_child(play)
	await get_tree().process_frame
	play.call("_on_start_button_pressed")

	var saw_loading := false
	var load_failed := false
	for i in range(600):
		await get_tree().process_frame
		var current := get_tree().current_scene
		if current != null and current.name == "Loading":
			saw_loading = true
			load_failed = bool(current.get("_load_failed"))
			if load_failed:
				break

	var passed := saw_loading and load_failed and not NetSession.is_networked()
	if passed:
		print("[LOCAL-LOADING-FAILURE-GATE] PASS")
	else:
		push_error("[LOCAL-LOADING-FAILURE-GATE] FAIL loading=%s failed=%s networked=%s" % [
			saw_loading, load_failed, NetSession.is_networked()])
	NetSession.disconnect_if_networked()
	get_tree().quit(0 if passed else 1)
