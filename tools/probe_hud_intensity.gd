extends Node

## 副官强度行已按用户要求删除。本探针确认底部不再出现「保守 / 标准 / 激进」。
##
##   godot --path . res://tools/probe_hud_intensity.tscn --position -4000,-4000

const HudScript = preload("res://source/match/hud/AICommandHUD.gd")

var _failures := 0


class MatchStub:
	extends Node3D


class InputStub:
	extends Node
	signal ActionPressed(action_id: String)

	func SetContextActive(_context: String, _active: bool) -> void:
		pass

	func EnterTextInputMode() -> void:
		pass

	func ExitTextInputMode() -> void:
		pass


func _ready() -> void:
	await _run()
	get_tree().quit(1 if _failures > 0 else 0)


func _check(cond: bool, message: String) -> void:
	if cond:
		print("  OK  ", message)
	else:
		_failures += 1
		print("  FAIL  ", message)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _run() -> void:
	get_window().size = Vector2i(1280, 720)
	await _wait_frames(2)

	var match_node := MatchStub.new()
	match_node.name = "Match"
	var input_stub := InputStub.new()
	input_stub.name = "InputBindingRuntime"
	match_node.add_child(input_stub)
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	match_node.add_child(hud)
	var panel := Control.new()
	panel.name = "AICommandHUD"
	panel.set_script(HudScript)
	hud.add_child(panel)

	_own_tree(match_node, match_node)
	get_tree().root.add_child(match_node)
	await _wait_frames(3)
	panel.call("set_interface_visible", true)
	await _wait_frames(6)

	var buttons: Array = _collect_by_prefix(panel, "Intensity_")
	_check(buttons.is_empty(), "底部不再有副官强度按钮（实际 %d）" % buttons.size())
	_check(not _has_label_text(panel, "副官强度"), "底部不再显示「副官强度」标题")

	if _failures > 0:
		print("FAIL: hud intensity removed, %d failure(s)" % _failures)
	else:
		print("PASS: hud intensity removed")


func _has_label_text(node: Node, text: String) -> bool:
	if node is Label and str((node as Label).text) == text:
		return true
	for child in node.get_children():
		if _has_label_text(child, text):
			return true
	return false


func _collect_by_prefix(node: Node, prefix: String) -> Array:
	var out: Array = []
	if str(node.name).begins_with(prefix) and node is Control:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_by_prefix(child, prefix))
	return out


func _own_tree(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_tree(child, owner_node)
