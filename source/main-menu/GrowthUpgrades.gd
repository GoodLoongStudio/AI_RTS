extends "res://source/ui/MenuPage.gd"

## 永久加点页：三栏成长树 + 右侧节点详情 + 底部成长点操作。
##
## 数据纪律：等级 / 消耗 / 前置 / 上限**全部**来自 GrowthStore（数据源
## config/growth_definitions.json），UI 只负责呈现与暂存 pending，不硬编码任何数值。
## 节点数量变化后本页无需改动即可正确显示（图标除外——新节点要在 NODE_ICON 里登记）。
##
## 版面纪律（1280x720 不得出滚动条）：节点卡刻意做成**单行**（图标 + 名称 + 等级 + 状态），
## 高度约 38px，因此每分支 5–7 个节点都能塞进 720 视口。改回两行卡会把面板顶出视口。
## 另加 `_check_height_budget()` 做显式预算告警：将来 JSON 再加节点顶破视口时会在状态行
## 明说，而不是静默裁切。

const BRANCH_ORDER := ["combat", "economy", "construction"]
const BRANCH_NAMES := {"combat": "战斗", "economy": "经济", "construction": "建设"}
const BRANCH_DESC := {
	"combat": "提升部队火力、韧性与技能协同",
	"economy": "提升资源采集、储备与生产调度",
	"construction": "提升施工速度、工事强度与扩张能力",
}
const ICON_DIR := "res://assets/ui/icons/growth/"
## 节点 → 图标名。图标集见 assets/ui/icons/growth/（17 枚可复用；
## 未登记的节点会降级为"无图标卡片"，probe_system_ui 会把缺图直接判红）。
const NODE_ICON := {
	# 战斗
	"combat_power": "attack",
	"combat_guard": "armor",
	"combat_skill": "power",
	"combat_mobility": "infantry",
	"combat_command": "network",
	# 经济
	"economy_gather": "resource",
	"economy_stock": "credits",
	"economy_production": "production",
	"economy_logistics": "repair",
	"economy_trade": "trade",
	# 建设
	"construction_speed": "build",
	"construction_armor": "defense",
	"construction_network": "power",
	"construction_fortify": "armor",
	"construction_frontier": "frontier",
}
const CARD_HEIGHT := 38.0
const ICON_BOX := 26.0
const LINK_HEIGHT := 10.0

var pending: Dictionary = {}
var points_label: Label
var status_label: Label
var columns: HBoxContainer

var _selected_id := ""
var _cards := {}                 # node_id -> {panel, level, state, branch}
var _detail_title: Label
var _detail_level: Label
var _detail_desc: Label
var _detail_cost: Label
var _detail_req: Label
var _detail_state: Label
var _detail_button: Button


func _ready() -> void:
	pending = GrowthStore.state.get("levels", {}).duplicate(true)
	_build_ui()
	_apply_tones()
	# 版面稳定后再做高度预算（容器在下一帧才完成布局）。
	call_deferred("_check_height_budget")


# ---------------- 构建 ----------------

func _build_ui() -> void:
	var root: VBoxContainer = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer
	points_label = root.get_node("Points")
	status_label = root.get_node("Status")
	columns = root.get_node("Body/Columns")
	_build_detail(root.get_node("Body/Detail/DetailBox"))
	for branch in BRANCH_ORDER:
		columns.add_child(_build_branch(branch))
	# 自建子树打豁免标记：MenuPage 基类在 _ready 之后才会跑延迟的 apply(self)，
	# 不加这一步，三条分支的强调色描边与彩色标题会被通用样式整片刷掉。
	SystemUIStyle.skip_subtree(columns)
	SystemUIStyle.skip_subtree(root.get_node("Body/Detail/DetailBox"))
	_select_node(_first_node_id())
	_refresh()


func _apply_tones() -> void:
	## Header / Points / Status 与最外层 PanelContainer 是 tscn 里声明的节点，
	## 会被 MenuPage 基类延迟的通用 apply 刷成同色 / 套上多余内边距。
	## 这里按语义覆盖并打豁免标记 —— 与执行时序无关。
	# 外面已经有 MarginContainer 提供 22/16 内边距，panel 自身不许再带 content margin，
	# 否则纵向白白多吃 36px（是 720 视口放不下的主因之一）。
	var panel := $CenterContainer/PanelContainer as PanelContainer
	panel.add_theme_stylebox_override("panel", SystemUIStyle.flat(
		SystemUIStyle.GLASS_DEEP, SystemUIStyle.RADIUS_PANEL, SystemUIStyle.LINE_STRONG, 1))
	var root := $CenterContainer/PanelContainer/MarginContainer/VBoxContainer
	var header := root.get_node("Header") as Label
	var points := root.get_node("Points") as Label
	var status := root.get_node("Status") as Label
	header.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	points.add_theme_color_override("font_color", SystemUIStyle.AMBER_HI)
	status.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	for node in [panel, header, points, status]:
		node.set_meta("ui_skip", true)


func _check_height_budget() -> void:
	var viewport_height := get_viewport().get_visible_rect().size.y
	var panel := $CenterContainer/PanelContainer as Control
	if panel == null or viewport_height <= 0.0:
		return
	var needed := panel.get_combined_minimum_size().y
	if needed > viewport_height - 20.0:
		status_label.text = "警告：成长树内容需要 %.0fpx 高于当前视口 %.0fpx，请减少分支节点" % [
			needed, viewport_height,
		]
		print("[GROWTH][WARN] 成长树高度 %.0f > 视口-20 %.0f" % [needed, viewport_height - 20.0])


func _build_branch(branch: String) -> Control:
	var accent := SystemUIStyle.branch_accent(branch)
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(232, 0)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.add_theme_stylebox_override("panel", SystemUIStyle.branch_style(branch))

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(box)

	var title := SystemUIStyle.make_label(str(BRANCH_NAMES.get(branch, branch)), 22, accent)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var desc := SystemUIStyle.make_label(str(BRANCH_DESC.get(branch, "")), 12, SystemUIStyle.MUTED)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(desc)

	var definitions: Array = GrowthStore.DEFINITIONS.get(branch, [])
	for index in range(definitions.size()):
		if index > 0:
			box.add_child(_make_link(accent))
		box.add_child(_make_node_card(branch, definitions[index]))
	return frame


func _make_link(accent: Color) -> Control:
	## 节点间的上下级连接线：一条竖向细色条，比纯文字列表更容易看出层级。
	var holder := CenterContainer.new()
	holder.custom_minimum_size = Vector2(0, LINK_HEIGHT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var line := ColorRect.new()
	line.color = Color(accent.r, accent.g, accent.b, 0.8)
	line.custom_minimum_size = Vector2(2, LINK_HEIGHT)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(line)
	return holder


func _make_node_card(branch: String, definition: Dictionary) -> Control:
	var node_id := str(definition.get("id", ""))
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, CARD_HEIGHT)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(_on_card_input.bind(node_id))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(row)

	row.add_child(_make_icon(node_id))

	var name_label := SystemUIStyle.make_label(str(definition.get("name", node_id)), 14)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	row.add_child(name_label)

	var level_label := SystemUIStyle.make_label("", 11, SystemUIStyle.MUTED)
	level_label.custom_minimum_size = Vector2(52, 0)
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(level_label)

	var state_label := SystemUIStyle.make_label("", 11, SystemUIStyle.MUTED)
	state_label.custom_minimum_size = Vector2(50, 0)
	state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(state_label)

	_cards[node_id] = {
		"panel": card,
		"level": level_label,
		"state": state_label,
		"branch": branch,
	}
	return card


func _make_icon(node_id: String) -> Control:
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(ICON_BOX, ICON_BOX)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon_name := str(NODE_ICON.get(node_id, ""))
	if not icon_name.is_empty():
		var path := ICON_DIR + icon_name + ".svg"
		if ResourceLoader.exists(path):
			icon.texture = load(path)
	return icon


func _build_detail(box: VBoxContainer) -> void:
	_detail_title = SystemUIStyle.make_label("", 18)
	box.add_child(_detail_title)

	_detail_level = SystemUIStyle.make_label("", 13, SystemUIStyle.MUTED)
	box.add_child(_detail_level)

	var rule := HSeparator.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(rule)

	_detail_desc = SystemUIStyle.make_label("", 13, SystemUIStyle.MUTED)
	_detail_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_detail_desc)

	_detail_cost = SystemUIStyle.make_label("", 13)
	box.add_child(_detail_cost)

	_detail_req = SystemUIStyle.make_label("", 13, SystemUIStyle.MUTED)
	_detail_req.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_detail_req)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(spacer)

	_detail_state = SystemUIStyle.make_label("", 13, SystemUIStyle.MUTED)
	_detail_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_detail_state)

	_detail_button = SystemUIStyle.make_button("升级", 46)
	_detail_button.pressed.connect(_on_upgrade_selected)
	box.add_child(_detail_button)


# ---------------- 交互 ----------------

func _on_card_input(event: InputEvent, node_id: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_select_node(node_id)


func _select_node(node_id: String) -> void:
	if node_id.is_empty():
		return
	_selected_id = node_id
	_refresh()


func _on_upgrade_selected() -> void:
	_on_upgrade(_selected_id)


func _on_upgrade(node_id: String) -> void:
	if node_id.is_empty():
		return
	var status := GrowthStore.can_upgrade(node_id, pending)
	if not bool(status.get("ok", false)):
		status_label.text = "无法升级：%s" % str(status.get("reason", ""))
		_refresh()
		return
	pending[node_id] = GrowthStore.get_level(node_id, pending) + 1
	var definition := GrowthStore.get_definition(node_id)
	status_label.text = "已选择「%s」→ Lv.%d（尚未保存，需点击确认加点）" % [
		str(definition.get("name", node_id)), int(pending[node_id]),
	]
	_refresh()


# ---------------- 刷新 ----------------

func _refresh() -> void:
	points_label.text = "可用成长点：%d        本次未保存变化：%d 点" % [
		int(GrowthStore.state.get("available_points", 0)), _pending_cost(),
	]
	for node_id in _cards.keys():
		_refresh_card(str(node_id))
	_refresh_detail()


func _refresh_card(node_id: String) -> void:
	var entry: Dictionary = _cards.get(node_id, {})
	if entry.is_empty():
		return
	var definition := GrowthStore.get_definition(node_id)
	if definition.is_empty():
		return
	var level := GrowthStore.get_level(node_id, pending)
	var max_level := int(definition.get("max_level", 0))
	var branch := str(entry["branch"])
	var accent := SystemUIStyle.branch_accent(branch)
	var status := GrowthStore.can_upgrade(node_id, pending)

	(entry["level"] as Label).text = "%d/%d" % [level, max_level]

	var state_text := "可升级"
	var state_color := accent
	var border := accent
	var border_width := 2
	var locked := false
	if level >= max_level:
		state_text = "已满级"
		state_color = SystemUIStyle.GREEN
		border = SystemUIStyle.GREEN
	elif not bool(status.get("ok", false)):
		if str(status.get("reason", "")) == "前置未满足":
			state_text = "未解锁"
			state_color = SystemUIStyle.DIM
			border = SystemUIStyle.DISABLED_LINE
			border_width = 1
			locked = true
		else:
			state_text = "点数不足"
			state_color = SystemUIStyle.AMBER
			border = SystemUIStyle.LINE_SOFT
			border_width = 1

	var state_node := entry["state"] as Label
	state_node.text = state_text
	state_node.add_theme_color_override("font_color", state_color)

	var style := SystemUIStyle.rounded(SystemUIStyle.PANEL, border, border_width, 7)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	if node_id == _selected_id:
		style.shadow_color = Color(accent.r, accent.g, accent.b, 0.45)
		style.shadow_size = 5
	var panel := entry["panel"] as PanelContainer
	panel.add_theme_stylebox_override("panel", style)
	panel.modulate = Color(1, 1, 1, 0.55) if locked else Color.WHITE


func _refresh_detail() -> void:
	var definition := GrowthStore.get_definition(_selected_id)
	if definition.is_empty():
		_detail_title.text = "未选择节点"
		_detail_level.text = ""
		_detail_desc.text = ""
		_detail_cost.text = ""
		_detail_req.text = ""
		_detail_state.text = ""
		_detail_button.text = "升级"
		_detail_button.disabled = true
		return

	var level := GrowthStore.get_level(_selected_id, pending)
	var max_level := int(definition.get("max_level", 0))
	var branch := _branch_of(_selected_id)
	var accent := SystemUIStyle.branch_accent(branch)

	_detail_title.text = str(definition.get("name", _selected_id))
	_detail_title.add_theme_color_override("font_color", accent)
	_detail_level.text = "等级 %d / %d      分支 %s" % [
		level, max_level, str(BRANCH_NAMES.get(branch, branch)),
	]
	_detail_desc.text = str(definition.get("description", ""))

	var prerequisite := str(definition.get("prerequisite", ""))
	if prerequisite.is_empty():
		_detail_req.text = "前置条件：无（起始节点）"
		_detail_req.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	else:
		var pre_definition := GrowthStore.get_definition(prerequisite)
		var pre_level := GrowthStore.get_level(prerequisite, pending)
		var satisfied := pre_level > 0
		_detail_req.text = "前置条件：%s Lv.%d%s" % [
			str(pre_definition.get("name", prerequisite)), pre_level,
			"" if satisfied else "（未满足）",
		]
		_detail_req.add_theme_color_override("font_color",
			SystemUIStyle.MUTED if satisfied else SystemUIStyle.RED)

	var status := GrowthStore.can_upgrade(_selected_id, pending)
	if level >= max_level:
		_detail_cost.text = "升级消耗：—"
		_detail_state.text = "该节点已达上限"
		_detail_state.add_theme_color_override("font_color", SystemUIStyle.GREEN)
		_detail_button.text = "已满级"
		_detail_button.disabled = true
		return

	var cost := int(status.get("cost", 0))
	_detail_cost.text = "升级消耗：%d 点" % cost
	var ok := bool(status.get("ok", false))
	if ok:
		_detail_state.text = "可升级 → Lv.%d" % (level + 1)
		_detail_state.add_theme_color_override("font_color", accent)
	else:
		_detail_state.text = "无法升级：%s" % str(status.get("reason", ""))
		_detail_state.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	_detail_button.text = "升级（%d 点）" % cost
	_detail_button.disabled = not ok


# ---------------- 工具 ----------------

func _first_node_id() -> String:
	var definitions: Array = GrowthStore.DEFINITIONS.get(BRANCH_ORDER[0], [])
	if definitions.is_empty():
		return ""
	return str(definitions[0].get("id", ""))


func _branch_of(node_id: String) -> String:
	for branch in BRANCH_ORDER:
		for definition in GrowthStore.DEFINITIONS.get(branch, []):
			if str(definition.get("id", "")) == node_id:
				return branch
	return BRANCH_ORDER[0]


func _pending_cost() -> int:
	var total := 0
	for id in pending:
		var base := int(GrowthStore.state.get("levels", {}).get(id, 0))
		var target := int(pending[id])
		var definition := GrowthStore.get_definition(str(id))
		var costs: Array = definition.get("costs", [])
		for i in range(base, target):
			if i < costs.size():
				total += int(costs[i])
	return total


# ---------------- 底部动作 ----------------

func _on_confirm() -> void:
	var result := GrowthStore.confirm_pending(pending)
	if bool(result.get("ok", false)):
		status_label.text = "已保存成长选择"
		pending = GrowthStore.state.get("levels", {}).duplicate(true)
	else:
		status_label.text = "保存失败：%s" % str(result.get("reason", "未知原因"))
	_refresh()


func _on_reset() -> void:
	## 彻底重置（洗点）：连**已保存**的等级一起清空，投入的点全额退还；未保存的暂存选择一并丢弃。
	## 语义与旧版不同 —— 旧版只丢暂存（"撤销本次选择"），在没有未保存变化时点下去毫无反应。
	var dropped := _pending_cost()
	var result := GrowthStore.reset_all()
	pending = GrowthStore.state.get("levels", {}).duplicate(true)
	if not bool(result.get("ok", false)):
		status_label.text = "重置失败：%s" % str(result.get("reason", "未知原因"))
	else:
		var refunded := int(result.get("refunded", 0))
		if refunded <= 0 and dropped <= 0:
			status_label.text = "当前没有可重置的加点：尚未投入任何成长点"
		else:
			var detail := "已彻底重置加点：%d 个节点归零，退还 %d 点成长点" % [
				int(result.get("nodes", 0)), refunded,
			]
			if dropped > 0:
				detail += "，未保存的 %d 点选择一并丢弃" % dropped
			status_label.text = detail
	_refresh()


func _on_back() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Growth.tscn")


func _on_escape() -> bool:
	_on_back()
	return true
