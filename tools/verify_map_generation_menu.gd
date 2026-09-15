extends SceneTree

## 主菜单「地图生成」全屏工作台冒烟。
## 用法：godot --headless --path . --script res://tools/verify_map_generation_menu.gd

var _failures := 0


func _initialize() -> void:
	await _run()
	if _failures > 0:
		push_error("FAIL: map generation menu smoke, %d failure(s)" % _failures)
		quit(1)
	else:
		print("PASS: map generation menu smoke")
		quit(0)


func _run() -> void:
	var main_packed: PackedScene = load("res://source/main-menu/Main.tscn")
	_check(main_packed != null, "Main.tscn 可加载")
	if main_packed == null:
		return
	var main := main_packed.instantiate()
	root.add_child(main)
	for i in range(4):
		await process_frame
	var vbox := main.get_node_or_null("CenterContainer/PanelContainer/MarginContainer/VBoxContainer")
	_check(vbox != null, "主菜单按钮容器存在")
	if vbox != null:
		var names: PackedStringArray = []
		for child in vbox.get_children():
			if child is Button:
				names.append(child.name)
		_check(names == PackedStringArray([
			"PlayButton", "OnlineButton", "GrowthButton", "MapGenButton", "OptionsButton", "QuitButton"
		]), "主菜单按钮顺序应为 单机/在线/成长/地图生成/设置/退出（实际 %s）" % ", ".join(names))
		var growth_i := _child_index(vbox, "GrowthButton")
		var map_i := _child_index(vbox, "MapGenButton")
		var options_i := _child_index(vbox, "OptionsButton")
		_check(growth_i >= 0 and map_i == growth_i + 1 and options_i == map_i + 1,
			"地图生成应夹在成长系统与设置之间")
	main.queue_free()
	await process_frame

	var page_packed: PackedScene = load("res://source/main-menu/MapGeneration.tscn")
	_check(page_packed != null, "MapGeneration.tscn 可加载")
	if page_packed == null:
		return
	var page := page_packed.instantiate() as Control
	root.add_child(page)
	for i in range(8):
		await process_frame
	_check(page.has_method("_on_escape") and page.has_method("_unhandled_input"),
		"工坊页具备 ESC 回退入口")
	_check(page.get_node_or_null("CenterContainer") == null, "工坊页不再使用居中小面板")
	_check(page.get_node_or_null("SafeMargin") != null, "工坊页使用铺满安全区的 SafeMargin")
	_check(page.get_node_or_null("SafeMargin/Root/Body/CenterCol/LegendBar") != null, "G2 预览下方有图例条")
	var preview_aspect := page.get_node_or_null("SafeMargin/Root/Body/CenterCol/PreviewAspect") as AspectRatioContainer
	_check(preview_aspect != null, "中栏预览使用正方形 AspectRatioContainer")
	if preview_aspect != null:
		_check(is_equal_approx(preview_aspect.ratio, 1.0), "中栏预览比例应为 1:1")
	var viewport_size := root.get_viewport().get_visible_rect().size
	if viewport_size != Vector2.ZERO:
		var covered := page.size.x >= viewport_size.x * 0.9 and page.size.y >= viewport_size.y * 0.9
		_check(covered, "工坊页应覆盖视口（页=%s 视口=%s）" % [str(page.size), str(viewport_size)])
	var generate_btn := page.find_child("GenerateButton", true, false) as Button
	_check(generate_btn != null, "有生成完整地图按钮（文案=%s）" % (generate_btn.text if generate_btn else "无"))
	_check(_find_button(page, "快速预览地形") != null, "有快速预览地形")
	_check(_find_button(page, "返回主菜单") != null, "有返回主菜单")
	for stage_name in ["出生布局", "地形生成", "资源与素材", "游戏场景导出", "引擎加载与导航验收"]:
		_check(_find_label(page, stage_name) != null, "阶段可见：%s" % stage_name)
	for layer_name in ["最终顶视", "45°轴测", "斜视参考", "资源", "地形逻辑", "路线"]:
		_check(_find_button(page, layer_name) != null, "图层页签可见：%s" % layer_name)
	page.queue_free()
	await process_frame

	var setup_script := load("res://source/main-menu/MatchSetupPage.gd")
	_check(setup_script != null, "MatchSetupPage.gd 可加载")
	if setup_script != null:
		var box: Vector2 = setup_script.PREVIEW_BOX_SIZE
		_check(is_equal_approx(box.x, box.y), "大厅地图预览框应为正方形（实际 %s）" % str(box))
	var sidebar_script := load("res://source/match/hud/ra3/Ra3Sidebar.gd")
	_check(sidebar_script != null, "Ra3Sidebar.gd 可加载")
	if sidebar_script != null:
		_check(
			is_equal_approx(sidebar_script.MINIMAP_EDGE, sidebar_script.SIDEBAR_WIDTH - 20.0),
			"侧栏小地图槽边长应等于侧栏内宽"
		)


func _child_index(parent: Node, child_name: String) -> int:
	for i in parent.get_child_count():
		if parent.get_child(i).name == child_name:
			return i
	return -1


func _find_button(root_node: Node, text: String) -> Button:
	for node in root_node.find_children("*", "Button", true, false):
		if node is Button and (node as Button).text == text:
			return node
	return null


func _find_label(root_node: Node, text: String) -> Label:
	for node in root_node.find_children("*", "Label", true, false):
		if node is Label and (node as Label).text == text:
			return node
	return null


func _check(ok: bool, message: String) -> void:
	if ok:
		print("  [PASS] %s" % message)
		return
	_failures += 1
	print("  [FAIL] %s" % message)
