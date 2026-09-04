extends PanelContainer
## 红警3 风格右侧指挥侧栏。
## 布局（自上而下）：小地图 → 资金行 → 分类页签 + 3×3 生产网格 → 状态行 → 功能行。
## 生产为全局聚合：无需选中生产建筑，点击格子即向「队列最短」的同型建筑下达生产命令；
## 建筑页签点击后自动挑选空闲工人进入蓝图放置流程。
## 图标约定：res://source/match/hud/ra3/icons/<icon>.png 存在则用图，否则退化为文字格子。

const CommandCenterUnit := "res://source/match/units/CommandCenter.tscn"
const VehicleFactoryUnit := "res://source/match/units/VehicleFactory.tscn"
const AircraftFactoryUnit := "res://source/match/units/AircraftFactory.tscn"
const AntiGroundTurretUnit := "res://source/match/units/AntiGroundTurret.tscn"
const AntiAirTurretUnit := "res://source/match/units/AntiAirTurret.tscn"
const WorkerUnit := "res://source/match/units/Worker.tscn"
const TankUnit := "res://source/match/units/Tank.tscn"
const HelicopterUnit := "res://source/match/units/Helicopter.tscn"
const DroneUnit := "res://source/match/units/Drone.tscn"
const SoldierUnit := "res://source/match/units/Infantry.tscn"
const BarracksUnit := "res://source/match/units/Barracks.tscn"

## RA3 式生产分类。place=true 走蓝图放置（工人建造）；否则 producer 建筑排队生产。
const TABS = [
	{
		"id": "structures", "caption": "建筑", "place": true,
		"items": [
			{"scene": CommandCenterUnit, "caption": "基地", "icon": "command_center"},
			{"scene": VehicleFactoryUnit, "caption": "车厂", "icon": "vehicle_factory"},
			{"scene": AircraftFactoryUnit, "caption": "机场", "icon": "aircraft_factory"},
			{"scene": AntiGroundTurretUnit, "caption": "对地炮", "icon": "anti_ground_turret"},
			{"scene": AntiAirTurretUnit, "caption": "对空炮", "icon": "anti_air_turret"},
			{"scene": BarracksUnit, "caption": "兵营", "icon": "barracks"},
		],
	},
	{
		"id": "infantry", "caption": "步兵", "producer": BarracksUnit,
		"producer_caption": "兵营",
		"items": [
			{"scene": WorkerUnit, "caption": "工人", "icon": "worker"},
			{"scene": SoldierUnit, "caption": "步兵", "icon": "soldier"},
		],
	},
	{
		"id": "vehicles", "caption": "载具", "producer": VehicleFactoryUnit,
		"producer_caption": "车辆工厂",
		"items": [
			{"scene": TankUnit, "caption": "坦克", "icon": "tank"},
		],
	},
	{
		"id": "aircraft", "caption": "飞机", "producer": AircraftFactoryUnit,
		"producer_caption": "航空工厂",
		"items": [
			{"scene": HelicopterUnit, "caption": "直升机", "icon": "helicopter"},
			{"scene": DroneUnit, "caption": "无人机", "icon": "drone"},
		],
	},
]

const SIDEBAR_WIDTH := 288.0
const CELL_SIZE := 58.0
const GRID_COLUMNS := 3
const GRID_CAPACITY := 9
const REFRESH_INTERVAL := 0.4

const PANEL_BG = Color(0.09, 0.10, 0.12, 0.97)
const PANEL_EDGE = Color(0.45, 0.50, 0.55)
const GOLD = Color(0.95, 0.83, 0.42)
const GOLD_DIM = Color(0.62, 0.53, 0.28)
const CELL_BG = Color(0.05, 0.06, 0.08)
const CELL_EDGE = Color(0.30, 0.33, 0.36)
const CELL_HOVER_BG = Color(0.10, 0.13, 0.17)
const CELL_ACTIVE_BG = Color(0.13, 0.17, 0.22)
const CELL_DISABLED_BG = Color(0.05, 0.055, 0.065)
const CELL_DISABLED_EDGE = Color(0.18, 0.19, 0.21)
const HIGHLIGHT = Color(0.40, 0.62, 0.95)
const SHADE_COLOR = Color(0.18, 0.32, 0.55, 0.60)

var _match = null
var _local_player = null
var _balance = null
var _active_tab_id := "structures"
var _tab_buttons = {}
var _cells = []
var _refresh_accumulator := 0.0

var _minimap_slot: PanelContainer = null
var _grid: GridContainer = null
var _function_row: HBoxContainer = null
var _command_slot: VBoxContainer = null
var _funds_label_a: Label = null
var _status_label: Label = null


func _ready():
	_match = find_parent("Match")
	add_to_group("ra3_sidebar")
	custom_minimum_size = Vector2(SIDEBAR_WIDTH, 0.0)
	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_left = -SIDEBAR_WIDTH
	_apply_panel_style()
	_build_ui()
	if not _match.is_node_ready():
		await _match.ready
	_local_player = _match.get_local_player()
	_balance = _match.get_node_or_null("BalanceConfigRuntime")
	if _local_player != null and "changed" in _local_player:
		_local_player.changed.connect(_refresh_funds)
	MatchSignals.not_enough_resources_for_production.connect(_on_not_enough_resources)
	_refresh_funds()
	_select_tab("structures")


func _process(delta):
	if _local_player == null:
		return
	_refresh_accumulator += delta
	if _refresh_accumulator < REFRESH_INTERVAL:
		return
	_refresh_accumulator = 0.0
	_refresh_tabs()
	_refresh_cells()
	_refresh_funds()


## 把现有 Minimap 节点收编进侧栏顶部（调用方先从原父节点 remove_child）。
func absorb_minimap(minimap_node: Control):
	_minimap_slot.add_child(minimap_node)


## 把 TraditionalUnitCommandHUD 收编进侧栏下部的命令区（脱离自由锚点，随侧栏布局）。
func absorb_command_panel(panel: Control):
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_command_slot.add_child(panel)


## 侧栏底部功能行按钮（如 AI 副官开关）。
func add_function_button(button: Button):
	button.custom_minimum_size = Vector2(128, 30)
	button.add_theme_font_size_override("font_size", 12)
	_style_button(button)
	_function_row.add_child(button)


# ---------------------------------------------------------------- UI 构建

func _apply_panel_style():
	var style = StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_EDGE
	style.set_border_width_all(1)
	style.border_width_right = 0
	style.corner_radius_top_left = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_right = 0
	add_theme_stylebox_override("panel", style)


func _build_ui():
	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# 顶部的阵营色装饰条（本地玩家色，RA3 阵营换肤的等价物）。
	var stripe = ColorRect.new()
	stripe.custom_minimum_size = Vector2(0, 3)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(stripe)
	stripe.set_meta("role", "faction_stripe")

	# 小地图槽。
	_minimap_slot = PanelContainer.new()
	_minimap_slot.custom_minimum_size = Vector2(0, 180)
	_minimap_slot.add_theme_stylebox_override(
		"panel", _make_cell_style(CELL_BG, CELL_EDGE, 4)
	)
	vbox.add_child(_minimap_slot)

	# 资金行。
	var funds_row = HBoxContainer.new()
	funds_row.add_theme_constant_override("separation", 6)
	vbox.add_child(funds_row)
	var funds_caption = Label.new()
	funds_caption.text = "资金"
	funds_caption.add_theme_font_size_override("font_size", 13)
	funds_caption.add_theme_color_override("font_color", GOLD_DIM)
	funds_row.add_child(funds_caption)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	funds_row.add_child(spacer)
	funds_row.add_child(_make_funds_chip("钱", Color(0.55, 0.75, 1.0)))
	_funds_label_a = _make_funds_value(funds_row)

	vbox.add_child(HSeparator.new())

	# 页签 + 3×3 生产网格。
	var production_row = HBoxContainer.new()
	production_row.add_theme_constant_override("separation", 6)
	vbox.add_child(production_row)

	var tab_column = VBoxContainer.new()
	tab_column.add_theme_constant_override("separation", 4)
	production_row.add_child(tab_column)
	var tab_group = ButtonGroup.new()
	for tab in TABS:
		var tab_button = Button.new()
		tab_button.text = tab.caption
		tab_button.toggle_mode = true
		tab_button.button_group = tab_group
		tab_button.custom_minimum_size = Vector2(46, 46)
		tab_button.add_theme_font_size_override("font_size", 13)
		tab_button.set_meta("tab_id", tab.id)
		tab_button.pressed.connect(_select_tab.bind(tab.id))
		_style_button(tab_button)
		tab_column.add_child(tab_button)
		_tab_buttons[tab.id] = tab_button

	var grid_shell = PanelContainer.new()
	grid_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_shell.add_theme_stylebox_override("panel", _make_cell_style(CELL_BG, CELL_EDGE, 4))
	production_row.add_child(grid_shell)
	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", 4)
	_grid.add_theme_constant_override("v_separation", 4)
	grid_shell.add_child(_grid)

	# 状态行（RA3 中央警告的简化版）。
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.add_theme_color_override("font_color", GOLD_DIM)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.clip_text = true
	vbox.add_child(_status_label)

	# 命令面板槽：收编 TraditionalUnitCommandHUD（右下情境面板进侧栏）。
	_command_slot = VBoxContainer.new()
	_command_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_command_slot)

	# 功能行。
	_function_row = HBoxContainer.new()
	_function_row.add_theme_constant_override("separation", 6)
	vbox.add_child(_function_row)

	# 阵营色条按本地玩家上色。
	if _local_player != null and "color" in _local_player:
		stripe.color = _local_player.color


func _make_funds_chip(caption: String, color: Color) -> HBoxContainer:
	var chip = HBoxContainer.new()
	chip.add_theme_constant_override("separation", 3)
	var dot = ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = color
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(dot)
	var label = Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", color)
	chip.add_child(label)
	return chip


func _make_funds_value(row: HBoxContainer) -> Label:
	var label = Label.new()
	label.text = "0"
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", GOLD)
	row.add_child(label)
	return label


func _make_cell_style(bg: Color, edge: Color, radius: int) -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 4
	style.content_margin_top = 4
	style.content_margin_right = 4
	style.content_margin_bottom = 4
	return style


func _make_button_styles(button: Button):
	var normal = StyleBoxFlat.new()
	normal.bg_color = CELL_BG
	normal.border_color = CELL_EDGE
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(3)
	var hover = StyleBoxFlat.new()
	hover.bg_color = CELL_HOVER_BG
	hover.border_color = HIGHLIGHT
	hover.set_border_width_all(1)
	hover.set_corner_radius_all(3)
	var pressed = StyleBoxFlat.new()
	pressed.bg_color = CELL_ACTIVE_BG
	pressed.border_color = GOLD
	pressed.set_border_width_all(1)
	pressed.set_corner_radius_all(3)
	var disabled = StyleBoxFlat.new()
	disabled.bg_color = CELL_DISABLED_BG
	disabled.border_color = CELL_DISABLED_EDGE
	disabled.set_border_width_all(1)
	disabled.set_corner_radius_all(3)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)


func _style_button(button: Button):
	_make_button_styles(button)


# ---------------------------------------------------------------- 页签与格子

func _select_tab(tab_id: String):
	_active_tab_id = tab_id
	for id in _tab_buttons:
		var tab_button: Button = _tab_buttons[id]
		tab_button.set_pressed_no_signal(id == tab_id)
	for child in _grid.get_children():
		child.queue_free()
	_cells.clear()
	var tab = _tab_by_id(tab_id)
	var filled := 0
	for tab_item in tab.items:
		# 页签级字段（place/producer/producer_caption）下放合并进每个格子条目，
		# 供 _cost_caption/_queue_stats 等统一按 item 取用。
		var item = tab_item.duplicate()
		item["place"] = tab.get("place", false)
		if not tab.get("place", false):
			item["producer"] = tab.get("producer")
			item["producer_caption"] = tab.get("producer_caption", "")
		var cell = _make_cell(item)
		_grid.add_child(cell.button)
		_cells.append(cell)
		filled += 1
	while filled < GRID_CAPACITY:
		var empty = PanelContainer.new()
		empty.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
		empty.add_theme_stylebox_override(
			"panel", _make_cell_style(Color(0.035, 0.04, 0.05), Color(0.14, 0.15, 0.17), 3)
		)
		_grid.add_child(empty)
		filled += 1
	_refresh_tabs()
	_refresh_cells()


func _tab_by_id(tab_id: String):
	for tab in TABS:
		if tab.id == tab_id:
			return tab
	return TABS[0]


func _make_cell(item: Dictionary) -> Dictionary:
	var button = Button.new()
	button.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
	_make_button_styles(button)
	button.set_meta("cell_caption", str(item.caption))
	button.pressed.connect(_on_cell_pressed.bind(item))
	button.gui_input.connect(_on_cell_gui_input.bind(item))

	var icon_texture = _load_icon(item.icon)
	if icon_texture != null:
		var icon = TextureRect.new()
		icon.texture = icon_texture
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 5
		icon.offset_top = 5
		icon.offset_right = -5
		icon.offset_bottom = -15
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(icon)
	else:
		var caption = Label.new()
		caption.text = item.caption
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.add_theme_font_size_override("font_size", 14)
		caption.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.offset_bottom = -12
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(caption)

	var cost = Label.new()
	cost.text = _cost_caption(item)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost.add_theme_font_size_override("font_size", 10)
	cost.add_theme_color_override("font_color", GOLD_DIM)
	cost.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	cost.offset_top = -14
	cost.offset_bottom = -2
	cost.offset_left = 2
	cost.offset_right = -2
	cost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(cost)

	# RA3 式生产进度遮罩（自底向上填充）。
	var shade = ColorRect.new()
	shade.color = SHADE_COLOR
	shade.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	shade.offset_top = 0
	shade.offset_bottom = 0
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(shade)

	# 队列数量角标。
	var badge = Label.new()
	badge.text = ""
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.add_theme_font_size_override("font_size", 12)
	badge.add_theme_color_override("font_color", GOLD)
	badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -34
	badge.offset_right = -4
	badge.offset_top = 2
	badge.offset_bottom = 18
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(badge)

	button.tooltip_text = _item_tooltip(item)
	return {
		"item": item, "button": button, "shade": shade, "badge": badge,
	}


func _scene_path(value) -> String:
	if value is PackedScene:
		return value.resource_path
	return str(value)


func _packed_scene(value) -> PackedScene:
	if value is PackedScene:
		return value
	return load(str(value)) as PackedScene


func _load_icon(icon_key: String) -> Texture2D:
	if icon_key == null or icon_key.is_empty():
		return null
	var path := "res://source/match/hud/ra3/icons/%s.png" % icon_key
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _cost_caption(item: Dictionary) -> String:
	if _balance == null:
		return ""
	if not _balance.has_method("GetProductionCost"):
		return ""
	var cost = null
	if item.get("place", false):
		if not _balance.has_method("GetConstructionCost"):
			return ""
		cost = _balance.GetConstructionCost(_packed_scene(item.scene))
	else:
		cost = _balance.GetProductionCost(_packed_scene(item.scene))
	if cost == null:
		return ""
	var a := int(cost.get("resource_a", 0))
	# 单资源（钱）后成本只展示 A；历史 B 成本已折算并入。
	return "%d" % a


func _item_tooltip(item: Dictionary) -> String:
	var lines := [str(item.caption)]
	if item.get("place", false):
		lines.append("点击后由工人前往建造")
	else:
		lines.append("由%s生产（右键取消排队）" % str(item.get("producer_caption", "")))
	var cost_text := _cost_caption(item)
	if not cost_text.is_empty():
		# _cost_caption 现在只返回折算后的单一 A 资源数字（如 "2400"），不再含 "/"。
		lines.append("资源: %s" % cost_text)
	return "\n".join(lines)


# ---------------------------------------------------------------- 命令

func _on_cell_pressed(item: Dictionary):
	if item.get("place", false):
		_begin_structure_placement(_packed_scene(item.scene))
	else:
		_produce_unit(item)


func _on_cell_gui_input(event: InputEvent, item: Dictionary):
	if event is InputEventMouseButton and event.pressed:
		if event.button_index != MOUSE_BUTTON_RIGHT or item.get("place", false):
			return
		var stats = _queue_stats(item)
		if stats.last_match != null:
			stats.last_match.queue.cancel(stats.last_match.element)


func _begin_structure_placement(structure_scene):
	if not _select_builder_if_needed():
		return
	# 与 WorkerMenu 相同入口：进入蓝图放置流程（联机时由放置处理器转发服务器）。
	MatchSignals.place_structure.emit(structure_scene)


func _select_builder_if_needed() -> bool:
	# 注意：request_legacy_construct 定义在 Unit 基类，所有单位都有该方法，
	# 不能用它判定工人——必须按 Worker 场景路径精确匹配。
	var selected_workers = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return is_instance_valid(unit) and _is_worker(unit)
	)
	if not selected_workers.is_empty():
		return true
	var idle_pick = null
	var any_pick = null
	for unit in _own_workers():
		if any_pick == null:
			any_pick = unit
		if idle_pick == null and unit.get("action") == null:
			idle_pick = unit
	var pick = idle_pick
	if pick == null:
		pick = any_pick
	if pick == null:
		_set_status("没有可用工人：请先在「步兵」页签生产工人")
		return false
	MatchSignals.deselect_all_units.emit()
	for child in pick.get_children():
		if child.has_method("select"):
			child.select()
			break
	return true


func _is_worker(unit) -> bool:
	return unit.scene_file_path == WorkerUnit


func _produce_unit(item: Dictionary):
	var producer = _pick_producer(item.producer)
	if producer == null:
		_set_status("没有可用的%s" % str(item.get("producer_caption", "生产建筑")))
		return
	producer.production_queue.produce(_packed_scene(item.scene))


func _pick_producer(producer_scene):
	var best = null
	var best_queue_size := 999999
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit):
			continue
		if not unit.is_in_group("controlled_units"):
			continue
		if unit.scene_file_path != _scene_path(producer_scene):
			continue
		if not ("production_queue" in unit):
			continue
		var queue_size = unit.production_queue.size()
		if queue_size < best_queue_size:
			best_queue_size = queue_size
			best = unit
	return best


# ---------------------------------------------------------------- 刷新

func _own_workers() -> Array:
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return is_instance_valid(unit) and _is_worker(unit) and unit.is_in_group("controlled_units")
	)


func _own_units_by_scene(producer_scene) -> Array:
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				is_instance_valid(unit)
				and unit.is_in_group("controlled_units")
				and unit.scene_file_path == _scene_path(producer_scene)
			)
	)


func _queue_stats(item: Dictionary) -> Dictionary:
	var queued_count := 0
	var producer_count := 0
	var best_progress := 0.0
	var last_match = null
	for unit in _own_units_by_scene(item.producer):
		producer_count += 1
		if not ("production_queue" in unit):
			continue
		for element in unit.production_queue.get_elements():
			if _prototype_path(element.unit_prototype) != _scene_path(item.scene):
				continue
			queued_count += 1
			best_progress = max(best_progress, element.progress())
			last_match = {"queue": unit.production_queue, "element": element}
	return {
		"count": queued_count,
		"producers": producer_count,
		"progress": best_progress,
		"last_match": last_match,
	}


func _prototype_path(prototype) -> String:
	if prototype is PackedScene:
		return prototype.resource_path
	return str(prototype)


func _refresh_tabs():
	for tab in TABS:
		var available := false
		if tab.get("place", false):
			available = not _own_workers().is_empty()
		else:
			available = not _own_units_by_scene(tab.producer).is_empty()
		var tab_button: Button = _tab_buttons[tab.id]
		tab_button.disabled = not available
		if not available:
			tab_button.tooltip_text = str(tab.caption) + "（暂无可用的生产设施）"
		else:
			tab_button.tooltip_text = str(tab.caption)


func _refresh_cells():
	for cell in _cells:
		var item: Dictionary = cell.item
		if item.get("place", false):
			var has_worker: bool = not _own_workers().is_empty()
			cell.button.disabled = not has_worker
			continue
		var stats = _queue_stats(item)
		cell.button.disabled = stats.producers == 0
		if stats.count == 0:
			cell.badge.text = ""
			cell.shade.offset_top = 0
		else:
			cell.badge.text = "×%d" % stats.count
			cell.shade.offset_top = -CELL_SIZE * stats.progress


func _refresh_funds():
	if _local_player == null:
		return
	_funds_label_a.text = str(int(_local_player.resource_a))


func _set_status(text: String):
	_status_label.text = text


func _on_not_enough_resources(player):
	if player == _local_player:
		_set_status("资源不足，生产无法继续")
