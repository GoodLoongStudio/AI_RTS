extends PanelContainer
## 左侧选中单位头像栏（红警 3 式堆叠分组，2026-09-08）：
## 同类型单位堆叠为一个头像并显示 ×N 数量角标（如 10 士兵 + 5 坦克 → 2 格），
## 点击头像选中该类型的全部单位；栏体固定贴屏幕左侧垂直居中，
## 类型数超过可视高度时纵向滚动；无选中时整栏隐藏。
## 图标约定同 Ra3Sidebar：res://source/match/hud/ra3/icons/<icon>.png 存在则用图，否则退化为文字格子。

const ICON_BY_SCENE := {
	"res://source/match/units/Worker.tscn": "worker",
	"res://source/match/units/Tank.tscn": "tank",
	"res://source/match/units/Helicopter.tscn": "helicopter",
	"res://source/match/units/Drone.tscn": "drone",
	"res://source/match/units/Infantry.tscn": "soldier",
	"res://source/match/units/CommandCenter.tscn": "command_center",
	"res://source/match/units/VehicleFactory.tscn": "vehicle_factory",
	"res://source/match/units/AircraftFactory.tscn": "aircraft_factory",
	"res://source/match/units/AntiGroundTurret.tscn": "anti_ground_turret",
	"res://source/match/units/AntiAirTurret.tscn": "anti_air_turret",
	"res://source/match/units/Barracks.tscn": "barracks",
}

const CELL_SIZE := 48.0
const CELL_SEPARATION := 4.0
const FRAME_PADDING := 12.0
## 左侧栏最多纵向可见的堆叠格数，超出走滚动
const MAX_VISIBLE_CELLS := 8
const PANEL_WIDTH := CELL_SIZE + FRAME_PADDING * 2.0
const MAX_PANEL_HEIGHT := (
	MAX_VISIBLE_CELLS * CELL_SIZE + (MAX_VISIBLE_CELLS - 1) * CELL_SEPARATION + FRAME_PADDING
)
const REFRESH_INTERVAL := 0.3

const PANEL_BG = Color(0.09, 0.10, 0.12, 0.97)
const PANEL_EDGE = Color(0.45, 0.50, 0.55)
const CELL_BG = Color(0.05, 0.06, 0.08)
const CELL_EDGE = Color(0.30, 0.33, 0.36)
const CELL_HOVER_BG = Color(0.10, 0.13, 0.17)
const CAPTION_COLOR = Color(0.85, 0.87, 0.90)
const BADGE_BG = Color(0.02, 0.03, 0.05, 0.85)
const BADGE_COLOR = Color(0.98, 0.83, 0.42)

var _scroll: ScrollContainer = null
var _grid: VBoxContainer = null
var _refresh_accumulator := 0.0
var _last_signature := ""


func _ready():
	_apply_panel_style()
	_build_ui()
	MatchSignals.unit_selected.connect(func(_unit): _refresh_now())
	MatchSignals.unit_deselected.connect(func(_unit): _refresh_now())
	MatchSignals.deselect_all_units.connect(func(): _refresh_now())
	MatchSignals.unit_died.connect(func(_unit): _refresh_now())
	visible = false


func _process(delta):
	_refresh_accumulator += delta
	if _refresh_accumulator < REFRESH_INTERVAL:
		return
	_refresh_accumulator = 0.0
	_refresh_now()


func _build_ui():
	# 红警 3 式左侧栏：贴屏幕左缘、垂直居中，纵向排列堆叠头像格
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	offset_left = 8.0
	offset_right = 8.0 + PANEL_WIDTH
	offset_top = 0.0
	offset_bottom = 0.0
	grow_vertical = Control.GROW_DIRECTION_BOTH
	_scroll = ScrollContainer.new()
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	add_child(_scroll)
	_grid = VBoxContainer.new()
	_grid.add_theme_constant_override("separation", CELL_SEPARATION)
	_scroll.add_child(_grid)


## 按 scene_file_path 堆叠选中单位：同类型一格，保持首次出现顺序。
func _group_selected_by_type() -> Array:
	var selected := get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return is_instance_valid(unit) and unit.is_in_group("controlled_units")
	)
	var order: Array = []
	var by_type := {}
	for unit in selected:
		var key := str(unit.scene_file_path)
		if not by_type.has(key):
			by_type[key] = []
			order.append(key)
		by_type[key].append(unit)
	var groups: Array = []
	for key in order:
		groups.append({"scene": key, "units": by_type[key]})
	return groups


## 重建头像格子：每类型一格 + ×N 角标；栏高随类型数自适应（封顶滚动）。
## 重建头像格子：每类型一格 + ×N 角标；栏高随类型数自适应（封顶滚动）。
## 选中组合未变化时跳过重建（此前每 0.3s 全量重建格子造成持续开销）。
func _refresh_now():
	var groups := _group_selected_by_type()
	visible = not groups.is_empty()
	if not visible:
		_last_signature = ""
		return
	var signature := ""
	for group in groups:
		signature += "%s:%d," % [group["scene"], group["units"].size()]
	if signature == _last_signature:
		return
	_last_signature = signature
	for child in _grid.get_children():
		child.queue_free()
	for group in groups:
		_grid.add_child(_make_portrait(group["units"]))
	var visible_cells := mini(groups.size(), MAX_VISIBLE_CELLS)
	var height := (
		visible_cells * CELL_SIZE + (visible_cells - 1) * CELL_SEPARATION + FRAME_PADDING
	)
	_scroll.custom_minimum_size = Vector2(PANEL_WIDTH, height)


func _make_portrait(units: Array) -> Button:
	var unit = units[0]
	var button := Button.new()
	button.custom_minimum_size = Vector2(CELL_SIZE, CELL_SIZE)
	button.clip_text = true
	button.add_theme_stylebox_override("normal", _cell_style())
	button.add_theme_stylebox_override("hover", _cell_style(true))
	button.add_theme_stylebox_override("pressed", _cell_style(true))
	button.add_theme_color_override("font_color", CAPTION_COLOR)
	button.add_theme_font_size_override("font_size", 11)
	var caption := _unit_caption(unit)
	var texture := _load_icon(_icon_key(unit))
	if texture != null:
		button.icon = texture
		button.expand_icon = true
		button.text = ""
	else:
		button.text = caption
	var count := units.size()
	button.tooltip_text = "%s ×%d\n首个 HP: %s/%s" % [caption, count, str(unit.hp), str(unit.hp_max)]
	button.set_meta("unit", unit)
	button.set_meta("units", units)
	if count > 1:
		_add_count_badge(button, count)
	button.pressed.connect(_on_portrait_pressed.bind(units))
	return button


## ×N 数量角标：贴格子右下角，不拦截鼠标。
func _add_count_badge(button: Button, count: int) -> void:
	var badge := Label.new()
	badge.text = "×%d" % count
	badge.add_theme_font_size_override("font_size", 11)
	badge.add_theme_color_override("font_color", BADGE_COLOR)
	var badge_bg := StyleBoxFlat.new()
	badge_bg.bg_color = BADGE_BG
	badge_bg.set_corner_radius_all(3)
	badge_bg.content_margin_left = 3.0
	badge_bg.content_margin_right = 3.0
	badge.add_theme_stylebox_override("normal", badge_bg)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(badge)
	badge.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	badge.offset_right = -2.0
	badge.offset_bottom = -1.0
	badge.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	badge.grow_vertical = Control.GROW_DIRECTION_BEGIN


## 点击堆叠头像：取消全选，选中该类型的全部己方单位。
func _on_portrait_pressed(units: Array):
	MatchSignals.deselect_all_units.emit()
	for unit in units:
		if not is_instance_valid(unit) or not unit.is_in_group("controlled_units"):
			continue
		var selection = unit.find_child("Selection")
		if selection != null and selection.has_method("select"):
			selection.select()


func _icon_key(unit) -> String:
	return str(ICON_BY_SCENE.get(unit.scene_file_path, ""))


func _unit_caption(unit) -> String:
	var scene_path := str(unit.scene_file_path)
	var file_name := scene_path.get_file().get_basename()
	return file_name


func _load_icon(icon_key: String) -> Texture2D:
	if icon_key.is_empty():
		return null
	var path := "res://source/match/hud/ra3/icons/%s.png" % icon_key
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _apply_panel_style():
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	add_theme_stylebox_override("panel", style)


func _cell_style(hovered := false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = CELL_HOVER_BG if hovered else CELL_BG
	style.border_color = CELL_EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	return style
