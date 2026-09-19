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
const MachineGunTurretUnit := "res://source/match/units/MachineGunTurret.tscn"
const WorkerUnit := "res://source/match/units/Worker.tscn"
const TankUnit := "res://source/match/units/Tank.tscn"
const APCUnit := "res://source/match/units/APC.tscn"
const HeavyTankUnit := "res://source/match/units/HeavyTank.tscn"
const TransportTruckUnit := "res://source/match/units/TransportTruck.tscn"
const HelicopterUnit := "res://source/match/units/Helicopter.tscn"
const DroneUnit := "res://source/match/units/Drone.tscn"
const SoldierUnit := "res://source/match/units/Infantry.tscn"
const SniperUnit := "res://source/match/units/Sniper.tscn"
const RocketeerUnit := "res://source/match/units/Rocketeer.tscn"
const BarracksUnit := "res://source/match/units/Barracks.tscn"

## RA3 式生产分类。place=true 走蓝图放置（工人建造）；否则 producer 建筑排队生产。
##
## 【格子顺序 = 玩家找东西的顺序（2026-09-14 用户："建筑在上面，防御设施在下面"）】
## 上半区放**生产/经济建筑**（基地/车厂/机场/兵营），下半区放**防御设施**（对地炮/对空炮/机枪塔）。
## 改动这里只会挪格子位置，不影响任何玩法（点击行为由 `_on_cell_pressed` 按 scene 决定）。
const TABS = [
	{
		"id": "structures", "caption": "建筑", "place": true,
		"items": [
			{"scene": CommandCenterUnit, "caption": "基地", "icon": "command_center"},
			{"scene": VehicleFactoryUnit, "caption": "车厂", "icon": "vehicle_factory"},
			{"scene": AircraftFactoryUnit, "caption": "机场", "icon": "aircraft_factory"},
			{"scene": BarracksUnit, "caption": "兵营", "icon": "barracks"},
			{"scene": AntiGroundTurretUnit, "caption": "对地炮", "icon": "anti_ground_turret"},
			{"scene": AntiAirTurretUnit, "caption": "对空炮", "icon": "anti_air_turret"},
			{"scene": MachineGunTurretUnit, "caption": "机枪塔", "icon": "machine_gun_turret"},
		],
	},
	{
		"id": "infantry", "caption": "步兵", "producer": BarracksUnit,
		"producer_caption": "兵营",
		"items": [
			# 按价格升序：步兵 100 → 狙击兵 250 → 炮兵 300（2026-09-15 用户要求）。
			{"scene": SoldierUnit, "caption": "步兵", "icon": "soldier"},
			{"scene": SniperUnit, "caption": "狙击兵", "icon": "sniper"},
			{"scene": RocketeerUnit, "caption": "炮兵", "icon": "rocketeer"},
		],
	},
	{
		"id": "vehicles", "caption": "载具", "producer": VehicleFactoryUnit,
		"producer_caption": "车辆工厂",
		"items": [
			# 工人按钮放在载具页签首位：主基地开局即可生产，无需兵营/车厂
			{"scene": WorkerUnit, "caption": "工人", "icon": "worker",
				"producer": CommandCenterUnit, "producer_caption": "主基地"},
			# 【2026-09-15 用户要求】单位按价格从低到高排（改价时同步此处顺序）：
			# 工人 200 → 坦克 700 → 运输车 800 → 装甲车 1200 → 重型坦克 1800。
			{"scene": TankUnit, "caption": "坦克", "icon": "tank"},
			{"scene": TransportTruckUnit, "caption": "运输车", "icon": "transport_truck"},
			{"scene": APCUnit, "caption": "装甲车", "icon": "apc"},
			{"scene": HeavyTankUnit, "caption": "重型坦克", "icon": "heavy_tank"},
		],
	},
	{
		"id": "aircraft", "caption": "飞机", "producer": AircraftFactoryUnit,
		"producer_caption": "航空工厂",
		"items": [
			# 按价格升序：无人机 200 → 直升机 900（2026-09-15 用户要求）。
			{"scene": DroneUnit, "caption": "无人机", "icon": "drone"},
			{"scene": HelicopterUnit, "caption": "直升机", "icon": "helicopter"},
		],
	},
]

const SIDEBAR_WIDTH := 288.0
## 侧栏内边距 10+10 后的正方形边长，让小地图铺满、不再缩在扁框里。
const MINIMAP_EDGE := SIDEBAR_WIDTH - 20.0
const CELL_SIZE := 64.0
const CELL_WIDTH := 123.0
const GRID_COLUMNS := 2
const GRID_CAPACITY := 12
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
var _repair_button: Button = null
var _sell_button: Button = null
var _unload_button: Button = null
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
	# 维修/出售指定模式：按钮按下态与提示文案随真实模式同步（红警式，2026-09-14）。
	MatchSignals.command_targeting_changed.connect(_on_command_targeting_changed)
	_refresh_funds()
	_select_tab("structures")


## MatchSignals 是 autoload，生命周期长于本节点，退出时显式断开。
func _exit_tree():
	if MatchSignals.command_targeting_changed.is_connected(_on_command_targeting_changed):
		MatchSignals.command_targeting_changed.disconnect(_on_command_targeting_changed)


## 指定模式变化：按钮按下态与状态提示以真实模式为准。
func _on_command_targeting_changed(command_name: String):
	if _repair_button != null:
		_repair_button.button_pressed = command_name == "Repair"
	if _sell_button != null:
		_sell_button.button_pressed = command_name == "Sell"
	if command_name.is_empty():
		_set_status("已退出指定模式")


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
	minimap_node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	minimap_node.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	_minimap_slot.custom_minimum_size = Vector2(MINIMAP_EDGE, MINIMAP_EDGE)
	_minimap_slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_minimap_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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

	# 维修 / 出售（红警3 式，作用于当前选中的己方建筑）。
	var mode_row = HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	vbox.add_child(mode_row)
	_repair_button = Button.new()
	_repair_button.text = "维修"
	_repair_button.custom_minimum_size = Vector2(0, 26)
	_repair_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_repair_button.add_theme_font_size_override("font_size", 13)
	_make_mode_button_styles(_repair_button)
	# toggle 样式：按下态由 _on_command_targeting_changed 以真实模式为准同步，
	# 让玩家一眼看出当前处于维修/出售模式（红警式，2026-09-14）。
	_repair_button.toggle_mode = true
	_repair_button.tooltip_text = "维修模式：点建筑开始/停止维修（右键或 ESC 退出）"
	_repair_button.pressed.connect(_on_repair_pressed)
	mode_row.add_child(_repair_button)
	_sell_button = Button.new()
	_sell_button.text = "出售"
	_sell_button.custom_minimum_size = Vector2(0, 26)
	_sell_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sell_button.add_theme_font_size_override("font_size", 13)
	_make_mode_button_styles(_sell_button)
	_sell_button.toggle_mode = true
	_sell_button.tooltip_text = "出售模式：点建筑出售（右键或 ESC 退出）"
	_sell_button.pressed.connect(_on_sell_pressed)
	mode_row.add_child(_sell_button)
	_unload_button = Button.new()
	_unload_button.text = "卸货"
	_unload_button.custom_minimum_size = Vector2(0, 26)
	_unload_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unload_button.add_theme_font_size_override("font_size", 13)
	_style_button(_unload_button)
	_unload_button.pressed.connect(_on_unload_pressed)
	mode_row.add_child(_unload_button)

	vbox.add_child(HSeparator.new())

	# 红警式排版：分类页签横排在生产区上方，卡片竖排单列（可滚动）。
	var tab_row = HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 6)
	vbox.add_child(tab_row)
	var tab_group = ButtonGroup.new()
	for tab in TABS:
		var tab_button = Button.new()
		tab_button.text = tab.caption
		tab_button.toggle_mode = true
		tab_button.button_group = tab_group
		tab_button.custom_minimum_size = Vector2(56, 30)
		tab_button.add_theme_font_size_override("font_size", 13)
		tab_button.set_meta("tab_id", tab.id)
		tab_button.pressed.connect(_select_tab.bind(tab.id))
		_style_button(tab_button)
		tab_row.add_child(tab_button)
		_tab_buttons[tab.id] = tab_button

	var grid_scroll = ScrollContainer.new()
	grid_scroll.custom_minimum_size = Vector2(0, CELL_SIZE * 3 + 16)
	grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(grid_scroll)
	var grid_shell = PanelContainer.new()
	grid_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid_shell.add_theme_stylebox_override("panel", _make_cell_style(CELL_BG, CELL_EDGE, 4))
	grid_scroll.add_child(grid_shell)
	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	# 布局：网格滚动区 EXPAND_FILL 吃满全部剩余空间（用户要求卡片区域向下扩大），
	# 命令面板/功能行固定高度贴底。
	_command_slot = VBoxContainer.new()
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


## 维修/出售这类「模式按钮」的专属样式：toggle 激活时用琥珀底 + 加粗金边 + 金字，
## 让玩家一眼看出「当前正处于该模式」（2026-09-14 用户反馈：点了没有任何反馈）。
func _make_mode_button_styles(button: Button):
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
	pressed.bg_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.22)
	pressed.border_color = GOLD
	pressed.set_border_width_all(2)
	pressed.set_corner_radius_all(3)
	var disabled = StyleBoxFlat.new()
	disabled.bg_color = CELL_DISABLED_BG
	disabled.border_color = CELL_DISABLED_EDGE
	disabled.set_border_width_all(1)
	disabled.set_corner_radius_all(3)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("hover_pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_pressed_color", GOLD)
	button.add_theme_color_override("font_hover_pressed_color", GOLD)



# ---------------------------------------------------------------- 页签与格子

func _select_tab(tab_id: String):
	if _active_tab_id != tab_id:
		UISfx.play("ui_drawer")  # 页签切换：抽屉滑出音
	_active_tab_id = tab_id
	for id in _tab_buttons:
		var tab_button: Button = _tab_buttons[id]
		tab_button.set_pressed_no_signal(id == tab_id)
	for child in _grid.get_children():
		child.queue_free()
	_cells.clear()
	var tab = _tab_by_id(tab_id)
	# 【2026-09-15 用户要求】生产页签按价格从低到高排列（建筑页保持既有"建筑在上、防御在下"）。
	var ordered_items: Array = _sorted_items_for(tab)
	var filled := 0
	for tab_item in ordered_items:
		# 页签级字段（place/producer/producer_caption）下放合并进每个格子条目，
		# 供 _cost_caption/_queue_stats 等统一按 item 取用。
		# 物品自带 producer（如工人走主基地）时不得被页签默认值覆盖。
		var item = tab_item.duplicate()
		item["place"] = tab.get("place", false)
		if not tab.get("place", false):
			if not item.has("producer"):
				item["producer"] = tab.get("producer")
			if not item.has("producer_caption"):
				item["producer_caption"] = tab.get("producer_caption", "")
		var cell = _make_cell(item)
		_grid.add_child(cell.button)
		_cells.append(cell)
		filled += 1
	# 【2026-09-15 用户报障修复·勿回退】空槽位必须与真格子**同宽**（CELL_WIDTH，不是 CELL_SIZE）：
	# GridContainer 按“每列最大最小宽度”定列宽，64 宽的空槽位会让第二列比第一列窄一半，
	# 面板右侧剩一条空白、格子看着像被裁掉（用户红框标的就是第二列那排窄格子）。
	# 并且只把当前页签补成“整行”（不再无条件堆到 GRID_CAPACITY=12 个）：12 个空槽位会撑出 6 行，
	# 右侧因此常驻垂直滚动条，滚下去看到的却全是空格子。
	while filled % GRID_COLUMNS != 0:
		var empty = PanelContainer.new()
		empty.custom_minimum_size = Vector2(CELL_WIDTH, CELL_SIZE)
		empty.add_theme_stylebox_override(
			"panel", _make_cell_style(Color(0.035, 0.04, 0.05), Color(0.14, 0.15, 0.17), 3)
		)
		_grid.add_child(empty)
		filled += 1
	_refresh_tabs()
	_refresh_cells()


## 页签格子顺序：生产页按单位造价升序（取不到价格排最后，保证顺序稳定）；建筑页不排序。
func _sorted_items_for(tab: Dictionary) -> Array:
	var items: Array = tab.get("items", [])
	if tab.get("place", false) or items.is_empty():
		return items
	var sorted_items: Array = items.duplicate()
	sorted_items.sort_custom(func(a, b):
		return _production_cost_of(a) < _production_cost_of(b))
	return sorted_items


## 单位造价（单一 A 资源，与 _cost_caption 同口径）；取不到时给一个很大的值。
func _production_cost_of(item: Dictionary) -> int:
	if _balance == null or not _balance.has_method("GetProductionCost"):
		return 1 << 30
	var cost = _balance.GetProductionCost(_packed_scene(item.get("scene")))
	if cost == null:
		return 1 << 30
	return int(cost.get("resource_a", 0))


func _tab_by_id(tab_id: String):
	for tab in TABS:
		if tab.id == tab_id:
			return tab
	return TABS[0]


func _make_cell(item: Dictionary) -> Dictionary:
	## 生产卡片。布局按用户口径：
	## 左上图标（尽量放大）/ 右上状态角标 / 中部名称 / 底部造价·时间 / 右下队列数量。
	## 卡片高度刻意压在 CELL_SIZE，保证 1280x720 下同屏能看到主要单位。
	var button = Button.new()
	button.custom_minimum_size = Vector2(CELL_WIDTH, CELL_SIZE)
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
		icon.offset_left = 3
		icon.offset_top = 3
		icon.offset_right = -3
		icon.offset_bottom = -26
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(icon)
	else:
		var caption = Label.new()
		caption.text = item.caption
		caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		caption.add_theme_font_size_override("font_size", 15)
		caption.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
		caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		caption.offset_bottom = -24
		caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(caption)

	# 单位名称：放在图标正下方，比造价更重要。
	var name_label = Label.new()
	name_label.text = str(item.caption)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", ProductionTheme.TEXT)
	name_label.clip_text = true
	name_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_label.offset_top = -25
	name_label.offset_bottom = -14
	name_label.offset_left = 2
	name_label.offset_right = -2
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name_label)

	# 造价 · 生产时间。
	var cost = Label.new()
	cost.text = _cost_caption(item)
	cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	cost.add_theme_font_size_override("font_size", 10)
	cost.add_theme_color_override("font_color", ProductionTheme.AMBER)
	cost.clip_text = true
	cost.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	cost.offset_top = -14
	cost.offset_bottom = -1
	cost.offset_left = 4
	cost.offset_right = -30
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

	# 队列数量角标（右下）。
	var badge = Label.new()
	badge.text = ""
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_color_override("font_color", ProductionTheme.CYAN)
	badge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	badge.offset_left = -30
	badge.offset_right = -3
	badge.offset_top = -14
	badge.offset_bottom = -1
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(badge)

	# 状态角标（右上）：字形 + 短标签，颜色随状态。字形一律 ASCII，
	# 不依赖主题字体是否含 ✔ ✕ ⚠ 之类符号。
	var state_badge = Label.new()
	state_badge.text = ""
	state_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	state_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	state_badge.add_theme_font_size_override("font_size", 10)
	state_badge.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	state_badge.offset_left = -CELL_WIDTH + 2
	state_badge.offset_right = -3
	state_badge.offset_top = 2
	state_badge.offset_bottom = 16
	state_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(state_badge)

	button.tooltip_text = _item_tooltip(item)
	# 【2026-09-15 用户要求："图2这个详情UI是可以不要的"】**不再弹自绘详情卡**
	# （「真实单位数据 / 当前状态 / AI 建议」那一大块）。原生 `tooltip_text` 保留：
	# 悬停仍能看到"由谁生产 / 价格"一行；需要完整数据时看单位/建筑详情。
	# 悬停连接已移除。`ProductionTooltip.gd` **不能删** —— `UnitDetailPanel` 等
	# 仍在 preload 它复用 public static 格式化函数与中文词表。

	return {
		"item": item,
		"button": button,
		"shade": shade,
		"badge": badge,
		"name_label": name_label,
		"cost_label": cost,
		"state_badge": state_badge,
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

## 维修按钮：进入维修指定模式，随后左键点击己方建筑切换其维修状态（右键取消）。
func _on_repair_pressed():
	var controller = _local_actions_controller()
	if controller == null:
		# 没进模式就要把按钮回弹，否则 toggle 会停在按下的假状态。
		if _repair_button != null:
			_repair_button.button_pressed = false
		_set_status("维修：指令控制器未就绪")
		return
	controller.begin_repair_targeting()
	_set_status("维修模式：点建筑开始/停止维修，可连续操作（右键或 ESC 退出）")


## 卸货按钮：选中载有士兵的运输车后点击，乘客散开下车。
func _on_unload_pressed():
	var unloaded := 0
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if not is_instance_valid(unit) or not unit.is_in_group("selected_units"):
			continue
		var cargo = unit.find_child("CargoHold", true, false)
		if cargo != null and cargo.get_passenger_count() > 0:
			cargo.unload_all()
			unloaded += 1
	_set_status("已卸货 %s 台运输车" % unloaded if unloaded > 0 else "卸货：请先选中载有士兵的运输车")


## 出售按钮：进入出售指定模式，随后左键点击己方建筑精准出售（右键取消）。
func _on_sell_pressed():
	var controller = _local_actions_controller()
	if controller == null:
		if _sell_button != null:
			_sell_button.button_pressed = false
		_set_status("出售：指令控制器未就绪")
		return
	controller.begin_sell_targeting()
	_set_status("出售模式：点建筑即可出售，可连续操作（右键或 ESC 退出）")


## 本地玩家的指令控制器。
func _local_actions_controller():
	if _local_player == null:
		return null
	return _local_player.find_child("UnitActionsController", true, false)


## 当前选中的己方建筑列表（有 sell 能力的 Structure）。
func _selected_own_structures() -> Array:
	var result: Array = []
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if is_instance_valid(unit) and unit.has_method("sell"):
			result.append(unit)
	return result


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
		# 同类优先；找不到同类就退化为取消"队首"（不限类型）。
		# 原因：_queue_stats 只匹配同类型的排队项，一旦队列里全是别的单位
		# （例如副官排了一堆 worker），玩家点"步兵"右键就完全无反应——
		# 而 UI 却提示"右键可取消排队"，等于给了个用不了的自救手段（2026-09-11 实测）。
		if stats.last_match != null:
			stats.last_match.queue.cancel(stats.last_match.element)
		else:
			_cancel_head_of_any_queue(item)


## 兜底自救：取消该生产建筑队列里的**队首**（不限类型）。
## 仅当"按同类型找不到"时才会走到这里，正常取消失效路径不受影响。
func _cancel_head_of_any_queue(item: Dictionary) -> void:
	for unit in _own_units_by_scene(item.get("producer")):
		if not ("production_queue" in unit):
			continue
		var elements = unit.production_queue.get_elements()
		if elements.is_empty():
			continue
		unit.production_queue.cancel(elements[0])
		return


func _begin_structure_placement(structure_scene):
	if not _select_builder_if_needed():
		return
	# 与 WorkerMenu 相同入口：进入蓝图放置流程（联机时由放置处理器转发服务器）。
	MatchSignals.place_structure.emit(structure_scene)


func _select_builder_if_needed() -> bool:
	# 注意：request_legacy_construct 定义在 Unit 基类，所有单位都有该方法，
	# 不能用它判定工人——必须按 Worker 场景路径精确匹配。
	# 施工中的工人不被新建造任务抢占：选人各优先级全部排除正在建造的工人。
	var selected_workers = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return is_instance_valid(unit) and _is_worker(unit) and not _is_constructing_builder(unit)
	)
	if not selected_workers.is_empty():
		return true
	var idle_pick = null
	var any_pick = null
	for unit in _own_workers():
		if _is_constructing_builder(unit):
			continue
		if any_pick == null:
			any_pick = unit
		if idle_pick == null and unit.get("action") == null:
			idle_pick = unit
	var pick = idle_pick
	if pick == null:
		pick = any_pick
	if pick == null:
		_set_status("所有工人都在建造中：请等待任一建造完成，或生产新工人")
		return false
	MatchSignals.deselect_all_units.emit()
	for child in pick.get_children():
		if child.has_method("select"):
			child.select()
			break
	return true


## 工人当前是否在建造（含寻路在途）：顶层动作为 Constructing。
##
## 必须走 `Unit.presentation_action_name()` 而不是直接读 `action`：
## 联机客户端是傀儡，`action` **恒为 null**（Unit._set_action 主动丢弃），
## 于是这条判据在客户端会恒 false → 把"服务器上其实正在建造的工人"当成空闲工人，
## 派给新的建造任务后**把原来那座建筑的施工顶掉**（2026-09-11 表现层修复）。
## 权威端在快照里下发了当前动作路径，客户端据此与房主行为保持一致。
func _is_constructing_builder(unit) -> bool:
	var resource_path := ""
	if unit.has_method("presentation_action_name"):
		resource_path = str(unit.presentation_action_name())
	if resource_path.is_empty():
		var action = unit.get("action")
		if action != null and action.get_script() != null:
			resource_path = str(action.get_script().resource_path)
	return resource_path == "res://source/match/units/actions/Constructing.gd"


func _is_worker(unit) -> bool:
	return unit.scene_file_path == WorkerUnit


func _produce_unit(item: Dictionary):
	var producer = _pick_producer(item.producer)
	if producer == null:
		_set_status("没有可用的%s" % str(item.get("producer_caption", "生产建筑")))
		return
	var queue_item = producer.production_queue.produce(_packed_scene(item.scene))
	# 联机模式下 produce() **必然返回 null**（命令已转发服务器、结果异步回来，
	# 见 ProductionQueue.produce 的 PendingAuthority 分支）。此前这里一律当成
	# "队列已满"，导致格子明明是空的却报满、玩家以为坏了（2026-09-11 实测）。
	# 改用 get_last_result() 区分"待确认 / 真失败"。
	var last_result: Dictionary = producer.production_queue.get_last_result()
	var status := str(last_result.get("status", ""))
	var caption := str(item.get("producer_caption", "生产建筑"))
	if queue_item != null:
		_set_status("%s 已加入%s生产队列" % [str(item.caption), caption])
	elif status == "PendingAuthority":
		_set_status("%s 已提交%s生产队列（等待服务器确认）" % [str(item.caption), caption])
	elif status == "InsufficientResources":
		_set_status("资源不足，无法生产%s" % str(item.caption))
	else:
		_set_status("%s 生产失败（%s）" % [str(item.caption), status if not status.is_empty() else "未知原因"])


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
	var empty := {
		"count": 0,
		"producers": 0,
		"progress": 0.0,
		"last_match": null,
	}
	# 建筑页是工人蓝图放置，条目没有 producer。用 item.producer 会每 0.4s 刷 SCRIPT ERROR，
	# 大湖活局里光打栈就会把主线程打穿。
	if item.get("place", false):
		return empty
	var producer = item.get("producer")
	if producer == null:
		return empty
	var queued_count := 0
	var producer_count := 0
	var best_progress := 0.0
	var last_match = null
	for unit in _own_units_by_scene(producer):
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
	# 【2026-09-14 用户报"我没有车间怎么能 UI 显示造这些坦克和载具"】：
	# 没有对应生产设施的页签**整个藏起来** —— 原来只是把按钮置灰，但格子里的图标与价格
	# 仍是亮的（Godot 的 disabled 样式只改按钮底，不改子控件），看起来就是"能造"。
	# 发现路径不变：在"建筑"页造出车厂/兵营/机场，对应页签就会出现。
	var available_tabs: Array = []
	for tab in TABS:
		var available := false
		if tab.get("place", false):
			available = not _own_workers().is_empty()
		else:
			available = not _own_units_by_scene(tab.producer).is_empty()
			if not available:
				# 页签内任一物品有其可用生产设施即解锁（如"载具"页签的工人走主基地生产）
				for item in tab.items:
					if not item.get("place", false) and not _own_units_by_scene(
						item.get("producer", tab.producer)
					).is_empty():
						available = true
						break
		if available:
			available_tabs.append(str(tab.id))
		var tab_button: Button = _tab_buttons[tab.id]
		tab_button.disabled = not available
		tab_button.visible = available
		if not available:
			tab_button.tooltip_text = str(tab.caption) + "（暂无可用的生产设施）"
		else:
			tab_button.tooltip_text = str(tab.caption)
	# 当前页签已不可用（设施还没造 / 被打掉）→ 自动切到第一个可用页签，
	# 否则会停在一个"整页空白"的网格上（比置灰更难懂）。
	if not available_tabs.is_empty() and not available_tabs.has(_active_tab_id):
		_select_tab(str(available_tabs[0]))


func _refresh_cells():
	for cell in _cells:
		var item: Dictionary = cell.item
		var stats = _queue_stats(item)
		# 拥有数量（同类型自建单位/建筑数）。放置类建筑同样有意义。
		var owned: int = _own_units_by_scene(item.scene).size()
		var state := _cell_state(item, stats)

		# 可产判定沿用原有逻辑，不改动任何玩法行为。
		if item.get("place", false):
			cell.button.disabled = _own_workers().is_empty()
		else:
			cell.button.disabled = stats.producers == 0
			# 【2026-09-15 用户要求】没有生产设施的项**不显示**：置灰只改底色，
			# 图标与价格照旧是亮的 —— 看起来就是"没有车厂也能造坦克"。
			# 发现路径不变：建筑页造出车厂/兵营/机场，对应格子就会出现。
			cell.button.visible = stats.producers > 0

		# 进度遮罩（原有 RA3 式自底向上填充，保留）。
		var queued: int = int(stats.get("count", 0))
		if queued == 0:
			cell.shade.offset_top = 0
		else:
			cell.shade.offset_top = -CELL_SIZE * float(stats.get("progress", 0.0))

		# 右下：拥有数量；右上：状态角标（字形 + 短标签，颜色随状态）。
		cell.badge.text = "×%d" % owned if owned > 0 else ""
		var glyph: String = ProductionTheme.state_glyph(state)
		if state == ProductionTheme.STATE_READY:
			# 一切正常时不堆文字，只留一个小字形，避免卡片噪声。
			cell.state_badge.text = glyph
		elif state == ProductionTheme.STATE_PRODUCING:
			cell.state_badge.text = "%s×%d" % [glyph, queued]
		else:
			cell.state_badge.text = "%s%s" % [glyph, ProductionTheme.state_label(state)]
		cell.state_badge.add_theme_color_override(
			"font_color", ProductionTheme.state_color(state)
		)
		# 卡片描边随状态变化（与角标、字形、Tooltip 文本共同表达同一状态）。
		cell.button.add_theme_stylebox_override(
			"normal", ProductionTheme.card_style(state)
		)
		cell.button.add_theme_stylebox_override(
			"hover", ProductionTheme.card_style(state, true)
		)
		cell.button.add_theme_stylebox_override(
			"pressed", ProductionTheme.card_style(state, false, true)
		)


## 生产卡片状态：能用 ProductionCatalog 就用它（单一事实来源）；查不到退回本页原有粗判。
func _cell_state(item: Dictionary, stats: Dictionary) -> String:
	if item.get("place", false):
		return ProductionTheme.STATE_LOCKED if _own_workers().is_empty() \
			else ProductionTheme.STATE_READY
	if int(stats.get("producers", 0)) == 0:
		return ProductionTheme.STATE_LOCKED
	if int(stats.get("count", 0)) > 0:
		return ProductionTheme.STATE_PRODUCING
	var item_id := str(item.get("icon", ""))
	if item_id != "" and not ProductionCatalog.entry(item_id).is_empty():
		var result = ProductionCatalog.state_of(item_id, {
			"player": _local_player,
			"producer": _first_producer(item),
			"queue_items": int(stats.count),
		})
		if result is Dictionary and result.has("state"):
			return str(result["state"])
	return ProductionTheme.STATE_READY


func _first_producer(item: Dictionary):
	var producers := _own_units_by_scene(item.get("producer"))
	return producers[0] if not producers.is_empty() else null


# ---------------- 悬停 Tooltip（2026-09-15 已按用户要求移除） ----------------
#
# 原来这里用自绘 `ProductionTooltip` 弹一整块「真实单位数据 / 当前状态 / AI 建议」。
# 用户要求去掉（"这个详情UI是可以不要的"）→ 悬停只留原生 `tooltip_text` 一行。
# **注意**：`ProductionTooltip.gd` 不能删 —— `UnitDetailPanel` / `ProductionQueuePanel`
# / `BaseStatusStrip` 还在 preload 它复用那批 public static 函数与中文词表。


func _refresh_funds():
	if _local_player == null:
		return
	_funds_label_a.text = str(int(_local_player.resource_a))


func _set_status(text: String):
	if _status_label == null:
		return
	_status_label.text = text


func _on_not_enough_resources(player):
	if player == _local_player:
		_set_status("资源不足，生产无法继续")
