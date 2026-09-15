extends Node

## ESC 回退冒烟测试（2026-09-14 用户要求更新：对局内 ESC 与 F10 都能唤出暂停菜单，
## 且 ESC 始终逐级返回；有系统认领本次 ESC（取消放置/目标选择等）时菜单不得抢）：
## 0) 类级守门：主菜单侧每个页面脚本都必须接入统一 ESC 回退（MenuPage 基类）；
## 1) 对局中菜单未打开 → 注入真实 ESC → 应唤出暂停菜单并暂停对局；
## 2) 打开设置面板 → 注入 ESC → 应关闭设置面板并回到暂停菜单；
## 3) 再注入 ESC → 应回到对局（菜单关闭、解除暂停）；
## 4) 先认领本次 ESC（EscapeRouter.claim()）→ 再发 global.cancel → 菜单不得打开。
## 说明：打开动作用直接调用（测的是"关闭"链路）；关闭与唤出必须走真实输入事件，
## 经 InputBindingRuntime(C#) 解析 global.cancel → Menu 全链路。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const EscapeRouter = preload("res://source/ui/EscapeRouter.gd")
const MENU_PAGE_SCRIPTS := [
	"res://source/main-menu/Play.gd",
	"res://source/main-menu/Online.gd",
	"res://source/main-menu/Options.gd",
	"res://source/main-menu/Credits.gd",
	"res://source/main-menu/Growth.gd",
	"res://source/main-menu/MapGeneration.gd",
	"res://source/main-menu/GrowthUpgrades.gd",
	"res://source/main-menu/PlayerProfile.gd",
	"res://source/main-menu/MatchHistory.gd",
	"res://source/main-menu/MatchDetail.gd",
]

var _failures := 0
var _finished := false
## 整局根节点：收尾时必须回收（见 SmokeTestExit.request 的说明；不回收会漏 51 实例 + 9 资源 + RID）。
var _match: Node = null


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	await _check_menu_page_escape_entries()

	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	_match = match_instance
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var menu = match_instance.get_node_or_null("Menu")
	_check(menu != null, "对局应包含 Menu 节点")
	var runtime = match_instance.get_node_or_null("InputBindingRuntime")
	_check(runtime != null, "对局应包含 InputBindingRuntime 节点")
	if menu == null or runtime == null:
		_finish()
		return

	_check(not menu.visible and not get_tree().paused, "开局应处于对局中（菜单关闭、未暂停）")

	# 1) 菜单未打开：ESC 应唤出暂停菜单（2026-09-14 用户口径：ESC 与 F10 等价唤出）。
	_press_escape()
	await _settle()
	_check(
		menu.visible and get_tree().paused,
		"对局中第一次 ESC 应唤出暂停菜单（实际 visible=%s paused=%s）"
			% [menu.visible, get_tree().paused]
	)

	# 2) 设置面板打开：ESC 只关面板，保持在暂停菜单。
	menu._on_settings_button_pressed()
	_check(menu._options_panel != null, "设置面板应已打开")
	_press_escape()
	await _settle()
	_check(
		menu._options_panel == null and menu.visible,
		"ESC 应关闭设置面板并回到暂停菜单（实际 panel=%s visible=%s）"
			% [menu._options_panel, menu.visible]
	)

	# 3) 暂停菜单：ESC 应回到对局。
	_press_escape()
	await _settle()
	_check(
		not menu.visible and not get_tree().paused,
		"ESC 应回到对局（实际 visible=%s paused=%s）" % [menu.visible, get_tree().paused]
	)

	# 4) 已有系统认领本次 ESC 时，菜单兜底不得抢（同步发信号以便与 claim 同帧）。
	EscapeRouter.claim()
	runtime.emit_signal("ActionPressed", "global.cancel")
	await get_tree().process_frame
	_check(
		not menu.visible and not get_tree().paused,
		"有系统认领 ESC 时菜单不得打开（实际 visible=%s paused=%s）"
			% [menu.visible, get_tree().paused]
	)

	_finish()


## 类级守门：主菜单侧每个页面都必须接入统一 ESC 回退（继承 MenuPage 并提供 _on_escape），
## 且关键分支必须"先关面板、不越级返回"（防将来被改坏成 return false 或直接返回主菜单）。
## 新增页面时必须加入本清单——漏掉就会在回归里红灯（2026-09-14 用户要求）。
func _check_menu_page_escape_entries():
	for script_path in MENU_PAGE_SCRIPTS:
		var script: Script = load(script_path)
		if script == null:
			_check(false, "%s 应可加载" % script_path)
			continue
		var page = script.new()
		var has_escape: bool = page != null \
			and page.has_method("_on_escape") \
			and page.has_method("_unhandled_input")
		_check(
			has_escape,
			"%s 应具备 ESC 回退入口（继承 res://source/ui/MenuPage.gd 并提供 _on_escape）" % script_path
		)
		if page != null:
			page.free()

	# Options 嵌入模式：ESC 必须只关面板（emit close_requested）并消费事件，绝不越级返回。
	var options = load("res://source/main-menu/Options.tscn").instantiate()
	options.embedded_mode = true
	add_child(options)
	await get_tree().process_frame
	var close_fired := [false]
	options.close_requested.connect(func(): close_fired[0] = true)
	_check(
		options._on_escape() and close_fired[0],
		"Options 嵌入模式 ESC 应关面板（close_requested）且消费事件"
	)
	options.queue_free()

	# Play 页：面板打开时 ESC 只关面板、不返回主菜单（"返回主菜单"分支会切场景，测试里不触发）。
	var play = load("res://source/main-menu/Play.tscn").instantiate()
	add_child(play)
	await get_tree().process_frame
	play._open_options_panel()
	_check(play._options_panel != null, "Play 页设置面板应可打开")
	var play_consumed: bool = play._on_escape()
	_check(
		play_consumed and play._options_panel == null,
		"Play 页面板打开时 ESC 应只关面板（不返回主菜单）"
	)
	play.queue_free()


func _press_escape():
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_ESCAPE
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	var release := InputEventKey.new()
	release.physical_keycode = KEY_ESCAPE
	release.keycode = KEY_ESCAPE
	release.pressed = false
	Input.parse_input_event(release)


func _settle():
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	if get_tree().paused:
		get_tree().paused = false
	print("ESC return smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)


func _check(condition: bool, message: String):
	if condition:
		print("  [PASS] %s" % message)
		return
	_failures += 1
	print("FAIL: %s" % message)
