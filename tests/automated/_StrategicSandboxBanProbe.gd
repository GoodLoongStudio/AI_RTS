extends Node

## 封禁验证（2026-10-06 用户要求：战略模式测试先关掉 ✓）
## 断言：① 单机页的战略按钮**不可见且禁用** ✓；② 程序化触发入口也**被拒**（不创建页面）✓；
##       ③ 其它按钮（开始游戏/返回）不受影响 ✓；④ 开关本身为 false ✓。

const PLAY := "res://source/main-menu/Play.tscn"
const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"

var _failures := 0


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_error("[BAN] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	# ① 开关为 false ✓
	var flags := get_node_or_null("/root/FeatureFlags")
	_check(flags != null, "必须存在 FeatureFlags autoload")
	if flags != null:
		_check(not bool(flags.get("strategic_sandbox_enabled")), "strategic_sandbox_enabled 必须默认 false（实际 %s）" % str(flags.get("strategic_sandbox_enabled")))
	# ② 单机页按钮 ✓
	var page: Control = load(PLAY).instantiate()
	add_child(page)
	get_tree().current_scene = page
	for _f in range(20):
		await get_tree().process_frame
	var btn: Button = page.get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer/SandboxButton")
	_check(btn != null, "场景里仍应保留 SandboxButton 节点（只是隐藏 ✓ 代码保留 ✓）")
	if btn != null:
		print("[BAN] SandboxButton visible=%s disabled=%s" % [str(btn.visible), str(btn.disabled)])
		_check(not btn.visible, "战略模式按钮必须**隐藏**")
		_check(btn.disabled, "战略模式按钮必须**禁用**")
		_check(not btn.pressed.is_connected(page._on_sandbox_pressed), "场景里的 pressed 连接必须已断开")
	# ③ 程序化触发也被拒 ✓（不创建战略页面 ✓）
	var before_children := get_tree().root.get_child_count()
	page.call("_on_sandbox_pressed")
	for _f in range(10):
		await get_tree().process_frame
	var created := false
	for c in get_tree().root.get_children():
		if c.scene_file_path == PAGE:
			created = true
	_check(not created, "开关关闭时程序化触发不得创建战略页面")
	print("[BAN] 触发后 root 子节点数 %d → %d" % [before_children, get_tree().root.get_child_count()])
	# ④ 其它按钮仍在 ✓
	var start_btn: Button = page.get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer/StartButton")
	if start_btn == null:
		var found := page.find_children("*", "Button", true, false)
		_check(found.size() >= 2, "开始/返回等按钮必须仍然存在（实际 %d 个按钮）" % found.size())
	else:
		_check(start_btn.visible, "开始游戏按钮必须仍可见")
	print("Strategic sandbox ban probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[BAN] OK: " + msg)
	else:
		_failures += 1
		push_error("[BAN] FAIL: " + msg)
