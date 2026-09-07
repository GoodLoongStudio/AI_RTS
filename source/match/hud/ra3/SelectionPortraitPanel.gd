extends PanelContainer
## 左侧选中单位头像栏（红警 3 式，2026-09-07）：
## 框选多个单位时在地图左侧逐格显示每个单位的头像，
## 点击头像可单独选中该单位；无选中时整栏隐藏。
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

const CELL_SIZE := 56.0
const PANEL_HEIGHT := 72.0
const REFRESH_INTERVAL := 0.3

const PANEL_BG = Color(0.09, 0.10, 0.12, 0.97)
const PANEL_EDGE = Color(0.45, 0.50, 0.55)
const CELL_BG = Color(0.05, 0.06, 0.08)
const CELL_EDGE = Color(0.30, 0.33, 0.36)
const CELL_HOVER_BG = Color(0.10, 0.13, 0.17)
const CAPTION_COLOR = Color(0.85, 0.87, 0.90)

var _scroll: ScrollContainer = null
var _grid: HBoxContainer = null
var _refresh_accumulator := 0.0


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
	# 魔兽争霸式底部头像条：框体随内容收缩、群居屏幕正下方中央（最多 900px，超出横向滚动）
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	offset_left = 0.0
	offset_right = 0.0
	offset_top = -PANEL_HEIGHT - 8.0
	offset_bottom = -8.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	custom_maximum_size = Vector2(900.0, PANEL_HEIGHT)
	_scroll = ScrollContainer.new()
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_grid = HBoxContainer.new()
	_grid.add_theme_constant_override("separation", 4)
	_scroll.add_child(_grid)


## 重建头像格子（选中集通常 ≤ 20 个，全量重建成本可忽略）。
func _refresh_now():
	var selected := get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return is_instance_valid(unit) and unit.is_in_group("controlled_units")
	)
	visible = not selected.is_empty()
	if not visible:
		return
	for child in _grid.get_children():
		child.queue_free()
	for unit in selected:
		_grid.add_child(_make_portrait(unit))


func _make_portrait(unit) -> Button:
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
	button.tooltip_text = "%s\nHP: %s/%s" % [caption, str(unit.hp), str(unit.hp_max)]
	button.set_meta("unit", unit)
	button.pressed.connect(_on_portrait_pressed.bind(unit))
	return button


## 点击头像：取消全选，只选中该单位。
func _on_portrait_pressed(unit):
	if not is_instance_valid(unit) or not unit.is_in_group("controlled_units"):
		return
	MatchSignals.deselect_all_units.emit()
	for child in unit.get_children():
		if child.has_method("select"):
			child.select()
			break


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
