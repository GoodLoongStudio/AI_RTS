extends Node

## 系统 UI 统一风格验收探针（覆盖用户验收清单里可机器判定的部分）。
##
## 用法：
##   godot --headless --path . res://tools/probe_system_ui.tscn
##   godot --headless --path . res://tools/probe_system_ui.tscn -- --res=1280x720,1600x900
##
## 判据：逐条打印 `[PROBE] PASS/FAIL`，末行 `[PROBE] >>> PASS n / FAIL m`；
##      FAIL > 0 时以退出码 1 结束，供脚本直接断言。
##
## 为什么用真实场景启动而不是 `--script`：Autoload（GrowthStore / MenuMusic）只在
## 正常启动流程里注册，用 `--script` 跑会把"Autoload 未注册"误报成脚本错误。

## [显示名, 场景路径, 是否允许按需出现滚动条]
## 只有「设置」页允许：它含显示/鼠标/相机/音频四块，内容天然高于 720 视口，
## 用户的无滚动条清单里也不含它；但仍必须**默认隐藏**（不得 SHOW_ALWAYS 常驻）。
const PAGES := [
	["主菜单", "res://source/main-menu/Main.tscn", false],
	["单机Play", "res://source/main-menu/Play.tscn", false],
	["在线Online", "res://source/main-menu/Online.tscn", false],
	["成长入口", "res://source/main-menu/Growth.tscn", false],
	["成长升级", "res://source/main-menu/GrowthUpgrades.tscn", false],
	["玩家画像", "res://source/main-menu/PlayerProfile.tscn", false],
	["设置", "res://source/main-menu/Options.tscn", true],
	["地图生成", "res://source/main-menu/MapGeneration.tscn", true],
]

const DEFAULT_RESOLUTIONS := ["1280x720", "1600x900", "1920x1080"]

const IDENTITY_ROOT := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Body/Identity/IdentityBox"
const PROFILE_ROOT := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"

var _pass := 0
var _fail := 0
var _failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	for spec in _requested_resolutions():
		await _check_layout(spec)
	await _check_growth_entry()
	await _check_growth_tree()
	await _check_profile()
	await _check_growth_confirm()
	await _check_growth_reset()
	print("[PROBE] >>> PASS %d / FAIL %d" % [_pass, _fail])
	for line in _failures:
		print("[PROBE] FAILED: %s" % line)
	SmokeTestExit.request(get_tree(), 0 if _fail == 0 else 1)


# ---------------- 逐分辨率版面 ----------------

func _requested_resolutions() -> Array:
	var requested: Array = []
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--res="):
			for piece in arg.substr("--res=".length()).split(",", false):
				requested.append(piece)
	return DEFAULT_RESOLUTIONS.duplicate() if requested.is_empty() else requested


func _parse_size(spec: String) -> Vector2i:
	var parts := spec.split("x", false)
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


func _check_layout(spec: String) -> void:
	var target := _parse_size(spec)
	if target != Vector2i.ZERO:
		get_window().size = target
	await get_tree().process_frame
	await get_tree().process_frame
	var viewport_size := get_viewport().get_visible_rect().size
	_check(
		viewport_size.x >= 640.0 and viewport_size.y >= 360.0,
		"视口尺寸可判定 @%s" % spec,
		"实测 %s（目标 %s）" % [str(viewport_size), str(target)]
	)
	for entry in PAGES:
		await _check_page(entry[0], entry[1], spec, viewport_size, bool(entry[2]))


func _check_page(page_name: String, path: String, spec: String, viewport_size: Vector2,
		allow_scroll: bool) -> void:
	var page := await _open(path)
	if page == null:
		_check(false, "%s 场景可加载 @%s" % [page_name, spec], path)
		return

	# 1) 滚动条：绝不允许 SHOW_ALWAYS 常驻；不允许滚动的页面还要求实际不可见。
	var scrollers := _find_by_class(page, "ScrollContainer")
	var forced := 0
	var shown := 0
	var detail := PackedStringArray()
	for scroller in scrollers:
		if scroller.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_SHOW_ALWAYS:
			forced += 1
		var bar: VScrollBar = scroller.get_v_scroll_bar()
		var bar_visible: bool = bar != null and bar.visible
		if bar_visible:
			shown += 1
		detail.append("%s[%s]" % [scroller.name, "强制常显" if scroller.vertical_scroll_mode == 2 else ("可见" if bar_visible else "隐藏")])
	var scroll_ok := forced == 0 and (allow_scroll or shown == 0)
	_check(
		scroll_ok,
		"%s %s @%s" % [page_name, "滚动条按需（允许滚动）" if allow_scroll else "无滚动条", spec],
		"ScrollContainer=%d 强制常显=%d 当前可见=%d %s" % [scrollers.size(), forced, shown, " ".join(detail)]
	)

	# 2) 顶层定位面板不得溢出视口（溢出即等于"内容被裁切"）。
	var panel := _top_panel(page)
	if panel != null:
		var overflow_x := panel.size.x - viewport_size.x
		var overflow_y := panel.size.y - viewport_size.y
		_check(
			overflow_x <= 0.0 and overflow_y <= 0.0,
			"%s 顶层面板不溢出视口 @%s" % [page_name, spec],
			"面板=%s 视口=%s 溢出=(%.0f, %.0f)" % [str(panel.size), str(viewport_size), overflow_x, overflow_y]
		)

	page.queue_free()
	await get_tree().process_frame


func _top_panel(page: Node) -> Control:
	for panel in _find_by_class(page, "PanelContainer"):
		if panel.get_parent() is CenterContainer:
			return panel
	return null


# ---------------- 成长入口页 ----------------

func _check_growth_entry() -> void:
	var page := await _open("res://source/main-menu/Growth.tscn")
	if page == null:
		return
	var cards := page.get_node_or_null(
		"CenterContainer/PanelContainer/MarginContainer/VBoxContainer/Cards") as VBoxContainer
	_check(cards != null, "成长入口 Cards 容器存在")
	if cards != null:
		# 不写死卡片张数：入口卡会随功能增加（成长页从 2 张长到 3 张过）。
		# 真正要守的不变式是「加了卡但没把面板加高」——那会把卡片压扁/裁掉。
		_check(cards.get_child_count() >= 2, "成长入口至少两张功能卡",
			"实际=%d" % cards.get_child_count())
		_check(cards.size.y + 0.5 >= cards.get_combined_minimum_size().y,
			"成长卡片没被面板压扁（加卡必须同时加高面板）",
			"可用=%.0f 需要=%.0f" % [cards.size.y, cards.get_combined_minimum_size().y])
		var missing := PackedStringArray()
		for card in cards.get_children():
			if not (card is Button):
				missing.append("%s(非Button)" % card.name)
				continue
			if (card as Button).text != "":
				missing.append("%s(不应有纯文本标题)" % card.name)
		_check(missing.is_empty(), "成长卡以 Button 为根（可键盘/手柄聚焦）", " ".join(missing))
	page.queue_free()
	await get_tree().process_frame


# ---------------- 成长树 ----------------

func _check_growth_tree() -> void:
	var page := await _open("res://source/main-menu/GrowthUpgrades.tscn")
	if page == null:
		return
	var root := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"
	var columns := page.get_node_or_null(root + "/Body/Columns") as HBoxContainer
	_check(columns != null, "成长树 Columns 存在")
	if columns == null:
		page.queue_free()
		return
	_check(columns.get_child_count() == 3, "成长树为三栏", "实际=%d" % columns.get_child_count())

	# 期望值直接由 GrowthStore.DEFINITIONS 推出来 —— JSON 增删节点后本探针不用改，
	# 只有"UI 没跟上数据"才会红。
	var expected_cards := 0
	var expected_links := 0
	for branch in ["combat", "economy", "construction"]:
		var count: int = GrowthStore.DEFINITIONS.get(branch, []).size()
		expected_cards += count
		expected_links += maxi(count - 1, 0)

	var cards := 0
	var links := 0
	var icons: Array = []
	var branch_names := PackedStringArray()
	for frame in columns.get_children():
		branch_names.append(str(frame.name))
		var box := frame.get_child(0)
		for child in box.get_children():
			if child is PanelContainer:
				cards += 1
				# 图标只认"卡片 → HBox → TextureRect"这一条路径：
				# 整页扫 TextureRect 会把 Background.tscn 的根节点也算进来。
				for inner in child.get_children():
					if inner is HBoxContainer:
						for leaf in inner.get_children():
							if leaf is TextureRect:
								icons.append(leaf)
			elif child is CenterContainer:
				links += 1
	_check(cards == expected_cards, "成长节点卡片数与数据源一致",
		"实际=%d 期望=%d" % [cards, expected_cards])
	_check(links == expected_links, "分支连接线数与数据源一致",
		"实际=%d 期望=%d" % [links, expected_links])

	# 图标必须真的加载：缺图会在 UI 上静默降级成"无图标卡片"，这里把它变成红灯。
	var missing_icons := PackedStringArray()
	for icon in icons:
		if (icon as TextureRect).texture == null:
			missing_icons.append(str(icon.get_path()))
	_check(
		icons.size() == expected_cards and missing_icons.is_empty(),
		"成长节点图标全部加载",
		"卡片图标=%d 期望=%d 缺图=%d %s" % [
			icons.size(), expected_cards, missing_icons.size(), " ".join(missing_icons),
		]
	)

	# 分支配色必须落在三条分支各自的强调色上（证明没有被通用样式刷平）。
	var accents := {}
	for frame in columns.get_children():
		var style := (frame as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		if style != null:
			accents[str(frame.name)] = style.border_color.to_html(false)
	var distinct := {}
	for key in accents:
		distinct[accents[key]] = true
	_check(distinct.size() == 3, "三条分支配色互不相同", str(accents))

	# 详情区按钮 + 状态文案
	var button := page.get_node_or_null(root + "/Body/Detail/DetailBox") 
	var detail_buttons := []
	if button != null:
		for child in button.get_children():
			if child is Button:
				detail_buttons.append(child)
	_check(detail_buttons.size() == 1, "详情区有唯一的升级按钮", "实际=%d" % detail_buttons.size())

	if _want_dump():
		print("[PROBE] ---- GrowthUpgrades 节点树（含尺寸） ----")
		_dump_tree(page, 0)

	page.queue_free()
	await get_tree().process_frame


func _want_dump() -> bool:
	return "--dump" in OS.get_cmdline_user_args()


func _dump_tree(node: Node, depth: int) -> void:
	var indent := "  ".repeat(depth)
	var extra := ""
	if node is Control:
		var control := node as Control
		extra = " size=%s min=%s" % [
			str(control.size), str(control.get_combined_minimum_size()),
		]
	print("[PROBE] %s%s (%s)%s" % [indent, node.name, node.get_class(), extra])
	for child in node.get_children():
		_dump_tree(child, depth + 1)


# ---------------- 玩家画像 ----------------

func _check_profile() -> void:
	var page := await _open("res://source/main-menu/PlayerProfile.tscn")
	if page == null:
		return
	var radar := page.get_node_or_null(PROFILE_ROOT + "/Body/Analysis/AnalysisBox/Radar")
	_check(radar != null and radar.has_method("set_values"), "画像雷达节点就绪")
	var axis_labels := 0
	if radar != null:
		for child in radar.get_children():
			if child is Label:
				axis_labels += 1
	_check(axis_labels == 5, "雷达为五维（战斗/经济/建设/进攻倾向/风险偏好）", "轴名数=%d" % axis_labels)

	var sample := page.get_node_or_null(IDENTITY_ROOT + "/Sample") as Label
	var recommendation := page.get_node_or_null(
		PROFILE_ROOT + "/HermesCard/HermesBox/Recommendation") as Label
	var evidence := page.get_node_or_null(PROFILE_ROOT + "/HermesCard/HermesBox/Evidence") as Label

	# 空快照：必须进空状态，且不得出现任何"编造的分析结论"。
	var backup := GrowthStore.profile.duplicate(true)
	GrowthStore.profile = {}
	page.call("_bind")
	await get_tree().process_frame
	_check(
		sample != null and sample.text.contains("暂无 Hermes 画像快照"),
		"无快照时显示空状态",
		sample.text.replace("\n", " / ") if sample != null else "Sample 节点缺失"
	)
	_check(
		recommendation != null and recommendation.text.contains("暂无"),
		"无快照时不编造推荐",
		recommendation.text if recommendation != null else "Recommendation 节点缺失"
	)
	_check(
		evidence != null and evidence.text.contains("暂无"),
		"无快照时标注依据缺失",
		evidence.text if evidence != null else "Evidence 节点缺失"
	)
	_check(
		radar != null and radar.get("has_data") == false,
		"无快照时雷达不画数据多边形",
		"has_data=%s" % str(radar.get("has_data") if radar != null else "?")
	)

	GrowthStore.profile = backup
	page.call("_bind")
	await get_tree().process_frame
	_check(
		sample != null and not sample.text.contains("暂无 Hermes 画像快照"),
		"有快照时展示真实字段",
		sample.text.replace("\n", " / ") if sample != null else "?"
	)

	page.queue_free()
	await get_tree().process_frame


# ---------------- 加点确认 / 落盘 / 还原 ----------------

func _check_growth_confirm() -> void:
	var node_id := ""
	for branch in ["combat", "economy", "construction"]:
		for definition in GrowthStore.DEFINITIONS.get(branch, []):
			var id := str(definition.get("id", ""))
			if bool(GrowthStore.can_upgrade(id, {}).get("ok", false)):
				node_id = id
				break
		if not node_id.is_empty():
			break
	_check(not node_id.is_empty(), "存在可升级的成长节点", "node_id=%s" % node_id)
	if node_id.is_empty():
		return

	var state_backup: Dictionary = GrowthStore.state.duplicate(true)
	var base_level := GrowthStore.get_level(node_id, {})
	var before_points := int(GrowthStore.state.get("available_points", 0))
	var status := GrowthStore.can_upgrade(node_id, {})
	var cost := int(status.get("cost", 0))

	var pending := {}
	pending[node_id] = base_level + 1
	var result := GrowthStore.confirm_pending(pending)
	_check(bool(result.get("ok", false)), "确认加点成功", str(result))
	_check(
		GrowthStore.get_level(node_id, {}) == base_level + 1,
		"加点后等级 +1",
		"%s: %d -> %d" % [node_id, base_level, GrowthStore.get_level(node_id, {})]
	)
	_check(
		int(GrowthStore.state.get("available_points", 0)) == before_points - cost,
		"成长点扣减正确",
		"%d - %d = %d（实际 %d）" % [
			before_points, cost, before_points - cost,
			int(GrowthStore.state.get("available_points", 0)),
		]
	)

	# 落盘证据：重启后能读回同一等级（验收第 10 条）。
	var persisted := -1
	if FileAccess.file_exists(GrowthStore.SAVE_PATH):
		var file := FileAccess.open(GrowthStore.SAVE_PATH, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				persisted = int((parsed as Dictionary).get("levels", {}).get(node_id, 0))
	_check(persisted == base_level + 1, "加点已落盘（重启可读回）",
		"user://growth_state.json 中 %s=%d" % [node_id, persisted])

	# 还原：探针不得留下副作用。
	GrowthStore.state = state_backup
	GrowthStore.save_state()
	_check(
		GrowthStore.get_level(node_id, {}) == base_level and
			int(GrowthStore.state.get("available_points", 0)) == before_points,
		"探针已还原成长状态",
		"等级 %d / 点数 %d" % [
			GrowthStore.get_level(node_id, {}), int(GrowthStore.state.get("available_points", 0)),
		]
	)


# ---------------- 彻底重置（洗点） ----------------

func _check_growth_reset() -> void:
	## 用户验收（2026-09-15）："重置"必须是**彻底重置加点** —— 已保存的等级一起归零，
	## 且投入的成长点必须**全额退还**。旧实现只丢弃未保存的暂存（undo 语义），
	## 玩家把点花完、又没有未保存变化时点下去毫无反应，等于按钮失效。
	var node_id := ""
	for branch in ["combat", "economy", "construction"]:
		var definitions: Array = GrowthStore.DEFINITIONS.get(branch, [])
		if not definitions.is_empty():
			node_id = str(definitions[0].get("id", ""))
			break
	if node_id.is_empty():
		_check(false, "存在可用于重置验证的成长节点", "DEFINITIONS 为空")
		return
	var definition := GrowthStore.get_definition(node_id)
	var costs: Array = definition.get("costs", [])
	if costs.is_empty():
		_check(false, "节点有成本定义（重置期望值从数据源推导）", node_id)
		return
	var max_level := int(definition.get("max_level", 0))
	# 期望退款 = 升满该节点的 costs 前缀和（**多级累加**，不是只退第一级）：
	# 用户现场就是 combat_power 5/5 + combat_mobility 2/4 一共投了 12 点，
	# 只退第一级 = 吞点，属于最隐蔽的一类错误。
	var expected_refund := 0
	for i in range(mini(max_level, costs.size())):
		expected_refund += int(costs[i])
	var budget := expected_refund + 8
	var state_backup: Dictionary = GrowthStore.state.duplicate(true)

	# --- 1) 先真花点：把首节点逐级升满，得到一个"已投入"的存档 ---
	GrowthStore.state = {
		"available_points": budget, "levels": {}, "earned_total": budget, "spent_total": 0,
	}
	GrowthStore.save_state()
	var spend_pending := {}
	spend_pending[node_id] = max_level
	var spent := GrowthStore.confirm_pending(spend_pending)
	_check(bool(spent.get("ok", false)), "重置前置：可逐级加点至满级", str(spent))
	var points_after_spend := int(GrowthStore.state.get("available_points", 0))
	_check(
		points_after_spend == budget - expected_refund,
		"重置前置：多级加点按成本前缀和扣减",
		"%d - %d = %d（实际 %d）" % [
			budget, expected_refund, budget - expected_refund, points_after_spend,
		]
	)

	# --- 2) reset_all 必须归零 + 全额退款 ---
	var result := GrowthStore.reset_all()
	_check(bool(result.get("ok", false)), "重置全部加点返回成功", str(result))
	_check(
		int(result.get("refunded", 0)) == expected_refund,
		"退还点数 == 多级已投入成本（不吞点）",
		"期望 %d / 实际 %d" % [expected_refund, int(result.get("refunded", 0))]
	)
	var levels_after: Dictionary = GrowthStore.state.get("levels", {})
	_check(levels_after.is_empty(), "重置后已保存等级清空", str(levels_after))
	_check(
		int(GrowthStore.state.get("available_points", 0)) == budget,
		"重置后点数回到投入前",
		"实际 %d（期望 %d）" % [int(GrowthStore.state.get("available_points", 0)), budget]
	)
	_check(
		int(GrowthStore.state.get("spent_total", 0)) == 0,
		"重置后累计消耗归零（可用 + 已花 == 累计获得）",
		"spent=%d" % int(GrowthStore.state.get("spent_total", 0))
	)

	# 落盘证据：重启后读回的等级表必须是空的
	var persisted := {}
	if FileAccess.file_exists(GrowthStore.SAVE_PATH):
		var file := FileAccess.open(GrowthStore.SAVE_PATH, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				persisted = (parsed as Dictionary).get("levels", {})
	_check(persisted.is_empty(), "重置已落盘（等级表为空）", str(persisted))

	# 幂等：空存档再点一次不得报错、不得吞点
	var again := GrowthStore.reset_all()
	_check(
		bool(again.get("ok", false)) and int(again.get("refunded", 0)) == 0
			and int(GrowthStore.state.get("available_points", 0)) == budget,
		"空存档重复重置幂等（不报错、不吞点）",
		str(again)
	)

	# --- 3) UI 层：点「重置全部加点」，等级退回 0 且状态行如实报出退还点数 ---
	GrowthStore.state = {
		"available_points": budget, "levels": {}, "earned_total": budget, "spent_total": 0,
	}
	var ui_pending := {}
	ui_pending[node_id] = max_level
	GrowthStore.confirm_pending(ui_pending)
	var page := await _open("res://source/main-menu/GrowthUpgrades.tscn")
	if page != null:
		var reset_button := page.find_child("Reset", true, false) as Button
		_check(reset_button != null, "成长页存在重置按钮", "Actions/Reset")
		if reset_button != null:
			_check(
				reset_button.text == "重置全部加点",
				"重置按钮文案表明是彻底重置",
				"实际 = %s" % reset_button.text
			)
			reset_button.pressed.emit()
			await get_tree().process_frame
			var status := page.find_child("Status", true, false) as Label
			_check(
				status != null and status.text.begins_with("已彻底重置加点"),
				"重置按钮给出可读反馈（不再是静默无变化）",
				status.text if status != null else "Status 节点缺失"
			)
			var points_label := page.find_child("Points", true, false) as Label
			_check(
				points_label != null
					and points_label.text.contains("可用成长点：%d " % budget),
				"重置按钮退还成长点",
				points_label.text if points_label != null else "Points 节点缺失"
			)
			_check(
				_node_level_text(page, node_id) == "0/%d" % max_level,
				"重置按钮把节点等级退回 0",
				"%s 卡片等级 = %s" % [node_id, _node_level_text(page, node_id)]
			)
		page.queue_free()
		await get_tree().process_frame

	# 还原：探针不得留下副作用
	GrowthStore.state = state_backup
	GrowthStore.save_state()
	var restored_levels: Dictionary = GrowthStore.state.get("levels", {})
	var backup_levels: Dictionary = state_backup.get("levels", {})
	_check(
		int(GrowthStore.state.get("available_points", 0))
			== int(state_backup.get("available_points", 0))
			and restored_levels == backup_levels,
		"重置探针已还原成长状态",
		"点数 %d / 等级 %s" % [
			int(GrowthStore.state.get("available_points", 0)), str(restored_levels),
		]
	)


func _node_level_text(page: Node, node_id: String) -> String:
	## 取页面卡片登记表里的等级 Label 文本（GrowthUpgrades 用 `_cards: node_id -> {level: Label}`）。
	var cards = page.get("_cards")
	if cards is Dictionary:
		var entry = (cards as Dictionary).get(node_id, {})
		if entry is Dictionary:
			var label = (entry as Dictionary).get("level")
			if label is Label:
				return (label as Label).text
	return ""


# ---------------- 工具 ----------------

func _open(path: String) -> Node:
	if not ResourceLoader.exists(path):
		_check(false, "场景可加载", path)
		return null
	var page := (load(path) as PackedScene).instantiate()
	add_child(page)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	return page


func _find_by_class(node: Node, type_name: String) -> Array:
	var found: Array = []
	if node.is_class(type_name):
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_by_class(child, type_name))
	return found


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("[PROBE] PASS  %s | %s" % [label, detail])
	else:
		_fail += 1
		_failures.append("%s | %s" % [label, detail])
		print("[PROBE] FAIL  %s | %s" % [label, detail])
