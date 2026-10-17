extends Node

## 局内战略聊天封禁验证（2026-10-06 用户要求：现在不要战略讨论了 ✓）
## 真实 Match ✓：面板仍存在 ✓，但聊天区**不构建** ✓（无开关按钮/输入框/发送 ✓），HUD 也不提示 ✓。

var _failures := 0
var _m: Node


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		push_error("[CHATBAN] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	_m = load("res://source/match/Match.tscn").instantiate()
	_m.settings = settings
	_m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(_m)
	get_tree().current_scene = _m
	for _f in range(150):
		await get_tree().physics_frame
	# ① 开关为 false ✓
	var flags := get_node_or_null("/root/FeatureFlags")
	_check(flags != null and not bool(flags.get("strategic_chat_enabled")), "strategic_chat_enabled 必须默认 false")
	# ② 聊天控件**不应存在** ✓
	var adj_node: Node = _find_adjutant(_m)
	var toggle: Variant = adj_node.get("_chat_toggle_button") if adj_node != null else null
	var input: Variant = adj_node.get("_chat_input") if adj_node != null else null
	var send: Variant = adj_node.get("_chat_send_button") if adj_node != null else null
	print("[CHATBAN] toggle=%s input=%s send=%s" % [str(toggle), str(input), str(send)])
	_check(toggle == null, "不得构建战略聊天开关按钮")
	_check(input == null, "不得构建战略聊天输入框")
	_check(send == null, "不得构建战略聊天发送按钮")
	# ③ 副官面板本体仍在 ✓
	var panel_nodes := _m.find_children("*", "AdjutantButton", true, false)
	var adj := _m.find_child("AdjutantButton", true, false)
	_check(adj != null or panel_nodes.size() > 0, "副官面板本体必须仍然存在（只是没有聊天区）")
	# ④ HUD 不得出现"战略聊天"提示 ✓
	var hud_text := _collect_text(_m)
	var has_hint := hud_text.contains("战略讨论请用") or hud_text.contains("战略聊天")
	print("[CHATBAN] HUD/面板文本中是否含战略聊天字样: %s" % str(has_hint))
	_check(not has_hint, "不得再出现"请用战略聊天"之类提示")
	print("Strategic chat ban probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


## 找副官面板脚本实例（按脚本类名 ✓，避免遍历整棵树 ✗）
func _find_adjutant(root_node: Node) -> Node:
	for n in root_node.find_children("*", "", true, false):
		var s: Script = n.get_script()
		if s != null and str(s.resource_path).ends_with("AdjutantButton.gd"):
			return n
	return null


func _collect_text(root_node: Node) -> String:
	var s := ""
	for n in root_node.find_children("*", "", true, false):
		if n is Label:
			s += (n as Label).text + "\n"
		elif n is RichTextLabel:
			s += (n as RichTextLabel).text + "\n"
		elif n is Button:
			s += (n as Button).text + "\n"
	return s


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[CHATBAN] OK: " + msg)
	else:
		_failures += 1
		push_error("[CHATBAN] FAIL: " + msg)
