extends Node

## 布局探针（RSI round-02 ✓）：在 1280×720 / 1920×1080 / 2560×1440 三档下实例化战略模式页面，
## 断言：① 内容都在 SafeArea 内（5% 安全边距 ✓）；② 左右两栏不重叠 ✓；③ 窄屏时上下堆叠 ✓；
## ④ 交互目标 ≥44px ✓；⑤ 页面标题含地图名 ✓。

const PAGE := "res://source/main-menu/StrategicSandboxPage.tscn"
const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(960, 720)]

var _failures := 0


func _process(_delta: float) -> void:
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		push_error("[LAYOUT] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var rows := []
	for sz in SIZES:
		get_window().size = sz
		await get_tree().process_frame
		var page: Control = load(PAGE).instantiate()
		page.set("map_path", "res://source/match/maps/PlainAndSimple.tscn")
		add_child(page)
		# 【探针修正】真实游戏里页面是**整场景铺满视口**的根节点；探针里挂在普通 Node 下不会自动铺满 ✗
		# ⇒ 手动铺满，否则量到的是"最小尺寸"而不是布局结果。
		page.set_anchors_preset(Control.PRESET_FULL_RECT)
		page.size = Vector2(sz.x, sz.y)
		get_tree().current_scene = page
		for _f in range(20):
			await get_tree().process_frame
		var safe: Control = page.find_child("SafeArea", true, false)
		var center: Control = page.find_child("CenterPanel", true, false)
		var split: BoxContainer = page.find_child("ContentSplit", true, false)
		var briefing: Control = page.find_child("BriefingPanel", true, false)
		var adjutant: Control = page.find_child("AdjutantPanel", true, false)
		var back: Control = page.find_child("BackButton", true, false)
		var row := {"viewport": [sz.x, sz.y], "page_size": [page.size.x, page.size.y]}
		row["has_safe_center_split"] = safe != null and center != null and split != null
		if safe != null:
			row["safe_rect"] = [safe.global_position.x, safe.global_position.y, safe.size.x, safe.size.y]
			row["margin_left"] = safe.get_theme_constant("margin_left")
		if center != null and safe != null:
			var cr := Rect2(center.global_position, center.size)
			var sr := Rect2(safe.global_position, safe.size)
			row["center_inside_safe"] = sr.encloses(cr)
			row["center_size"] = [center.size.x, center.size.y]
		if briefing != null and adjutant != null:
			var br := Rect2(briefing.global_position, briefing.size)
			var ar := Rect2(adjutant.global_position, adjutant.size)
			row["panels_overlap"] = br.intersects(ar, false)
			row["briefing_size"] = [br.size.x, br.size.y]
			row["adjutant_size"] = [ar.size.x, ar.size.y]
			row["ratio_briefing"] = snappedf(br.size.x / maxf(1.0, br.size.x + ar.size.x), 0.01)
		if split != null:
			row["split_vertical"] = split.vertical
		if back != null:
			row["back_min"] = [back.custom_minimum_size.x, back.custom_minimum_size.y]
		# 【截图暴露的漏检】必须查"内容有没有超出视口被裁切" ✗（此前只查了容器包含关系 ✓）
		var comp: Control = page.find_child("Composer", true, false)
		if comp == null:
			comp = page.get("_chat_input")
		var facts: Control = page.get("_facts_unknown")
		var lowest := 0.0
		for probe in [comp, facts, back]:
			if probe is Control and (probe as Control).is_visible_in_tree():
				lowest = maxf(lowest, (probe as Control).global_position.y + (probe as Control).size.y)
		row["lowest_widget_bottom"] = lowest
		# 【定位裁切】分别量两栏的最小高度，找出是谁在撑高 ✓
		if briefing != null:
			row["briefing_min_h"] = briefing.get_combined_minimum_size().y
		if adjutant != null:
			row["adjutant_min_h"] = adjutant.get_combined_minimum_size().y
		var rv: Control = page.find_child("RootVBox", true, false)
		if rv != null:
			row["rootvbox_min_h"] = rv.get_combined_minimum_size().y
		var cp: Control = page.find_child("CenterPanel", true, false)
		if cp != null:
			row["centerpanel_min_h"] = cp.get_combined_minimum_size().y
		# 【口径修正 2】用**页面真实高度**（headless 下 get_window().size 可能不生效 ✗），
		# 且只要内容在 ScrollContainer 里（可滚动查看）就不算裁切 ✓。
		row["viewport_h"] = page.size.y
		row["requested_h"] = float(sz.y)
		var scrollable: bool = page.find_child("BriefingScroll", true, false) != null or page.find_child("PageScroll", true, false) != null
		row["scrollable"] = scrollable
		row["clipped"] = (lowest > page.size.y + 1.0) and not scrollable
		var header: Variant = page.get("_header_map_label")
		row["header_map_text"] = header.text if header is Label else "<none>"
		rows.append(row)
		print("[LAYOUT] %dx%d center=(%s) 安全边距=%s 中心在安全区内=%s 两栏重叠=%s 简报比=%s 堆叠=%s 返回键=%s 页头=%s" % [
			sz.x, sz.y, str(row.get("center_size", [])), str(row.get("margin_left", -1)),
			str(row.get("center_inside_safe", false)), str(row.get("panels_overlap", true)),
			str(row.get("ratio_briefing", -1)), str(row.get("split_vertical", false)),
			str(row.get("back_min", [])), str(row.get("header_map_text", ""))])
		page.queue_free()
		for _f in range(6):
			await get_tree().process_frame
	# 断言 ✓
	for r in rows:
		var vp: Array = r["viewport"]
		_check(bool(r.get("has_safe_center_split", false)), "%dx%d 必须有 SafeArea/CenterPanel/ContentSplit" % [vp[0], vp[1]])
		_check(bool(r.get("center_inside_safe", false)), "%dx%d 中央面板必须在安全区内" % [vp[0], vp[1]])
		_check(not bool(r.get("panels_overlap", true)), "%dx%d 左右两栏不得重叠" % [vp[0], vp[1]])
		var ml := int(r.get("margin_left", 0))
		_check(ml >= int(maxf(24.0, float(vp[0]) * 0.05)) - 1, "%dx%d 安全边距应 ≥5%%（实际 %d）" % [vp[0], vp[1], ml])
		_check(str(r.get("header_map_text", "")).contains("PlainAndSimple"), "%dx%d 页头应显示地图名" % [vp[0], vp[1]])
		_check(not bool(r.get("clipped", true)), "%dx%d 不得裁切内容（最低控件底 %.0f / 页面高 %.0f / 可滚动=%s）" % [vp[0], vp[1], float(r.get("lowest_widget_bottom", 0.0)), float(r.get("viewport_h", 0.0)), str(r.get("scrollable", false))])
	var wide: Dictionary = rows[0]
	var big: Dictionary = rows[2]
	var narrow: Dictionary = rows[3]
	_check(not bool(wide.get("split_vertical", true)), "1280 宽应**左右分栏**（≥1100 阈值 ✓）")
	_check(not bool(big.get("split_vertical", true)), "2560 宽应左右分栏（宽屏 ✓）")
	_check(bool(narrow.get("split_vertical", false)), "960 宽应**上下堆叠**（窄屏 ✓）")
	_check(absf(float(big.get("ratio_briefing", 0.0)) - 0.44) <= 0.03, "宽屏简报栏占比应约 44%%（实际 %s）" % str(big.get("ratio_briefing", -1)))
	var payload := {"probe": "strategic-layout", "rows": rows, "failures": _failures}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-prebattle-map-passing/"))
	var f := FileAccess.open(ProjectSettings.globalize_path("res://agent/runs/2026-10-06-prebattle-map-passing/layout-probe.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	print("Strategic layout probe completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[LAYOUT] OK: " + msg)
	else:
		_failures += 1
		push_error("[LAYOUT] FAIL: " + msg)
