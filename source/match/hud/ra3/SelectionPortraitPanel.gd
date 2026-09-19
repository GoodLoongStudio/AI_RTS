extends PanelContainer
## 左侧选中单位头像栏（红警 3 式堆叠分组）：
## 同类型一格 + 数量角标；点击选中该类型全部单位。视觉跟右侧指挥栏同一套青蓝玻璃。

const ThemeTokens = preload("res://source/match/hud/production/ProductionTheme.gd")

const ICON_BY_SCENE := {
	"res://source/match/units/Worker.tscn": "worker",
	"res://source/match/units/Tank.tscn": "tank",
	"res://source/match/units/HeavyTank.tscn": "heavy_tank",
	"res://source/match/units/Helicopter.tscn": "helicopter",
	"res://source/match/units/Drone.tscn": "drone",
	"res://source/match/units/Infantry.tscn": "soldier",
	"res://source/match/units/Sniper.tscn": "sniper",
	"res://source/match/units/Rocketeer.tscn": "rocketeer",
	"res://source/match/units/APC.tscn": "apc",
	"res://source/match/units/TransportTruck.tscn": "transport_truck",
	"res://source/match/units/CommandCenter.tscn": "command_center",
	"res://source/match/units/VehicleFactory.tscn": "vehicle_factory",
	"res://source/match/units/AircraftFactory.tscn": "aircraft_factory",
	"res://source/match/units/AntiGroundTurret.tscn": "anti_ground_turret",
	"res://source/match/units/AntiAirTurret.tscn": "anti_air_turret",
	"res://source/match/units/MachineGunTurret.tscn": "machine_gun_turret",
	"res://source/match/units/Barracks.tscn": "barracks",
}

const CAPTION_BY_ICON := {
	"worker": "工人",
	"tank": "坦克",
	"heavy_tank": "重坦",
	"helicopter": "直升机",
	"drone": "无人机",
	"soldier": "步兵",
	"sniper": "狙击",
	"rocketeer": "炮兵",
	"apc": "装甲车",
	"transport_truck": "运输车",
	"command_center": "基地",
	"vehicle_factory": "车厂",
	"aircraft_factory": "机场",
	"anti_ground_turret": "对地炮",
	"anti_air_turret": "对空炮",
	"machine_gun_turret": "机枪塔",
	"barracks": "兵营",
}

const CELL_W := 80.0
const CELL_H := 92.0
const CELL_SEPARATION := 6.0
const FRAME_PADDING := 8.0
const MAX_VISIBLE_CELLS := 8
const PANEL_WIDTH := CELL_W + FRAME_PADDING * 2.0
const REFRESH_INTERVAL := 0.3


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
	custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	offset_left = 16.0
	offset_right = 16.0 + PANEL_WIDTH
	offset_top = 0.0
	offset_bottom = 0.0
	grow_vertical = Control.GROW_DIRECTION_BOTH
	mouse_filter = Control.MOUSE_FILTER_STOP
	_scroll = ScrollContainer.new()
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(CELL_W, 0)
	add_child(_scroll)
	_grid = VBoxContainer.new()
	_grid.add_theme_constant_override("separation", int(CELL_SEPARATION))
	_scroll.add_child(_grid)


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
		_sync_live_stats()
		return
	_last_signature = signature
	for child in _grid.get_children():
		child.queue_free()
	for group in groups:
		_grid.add_child(_make_portrait(group["units"]))
	var visible_cells := mini(groups.size(), MAX_VISIBLE_CELLS)
	var height := (
		visible_cells * CELL_H + (visible_cells - 1) * CELL_SEPARATION + FRAME_PADDING
	)
	_scroll.custom_minimum_size = Vector2(CELL_W, height)


func _sync_live_stats() -> void:
	for child in _grid.get_children():
		if not child.has_meta("units"):
			continue
		_apply_hp(child, child.get_meta("units"))


func _make_portrait(units: Array) -> Button:
	var unit = units[0]
	var button := Button.new()
	button.custom_minimum_size = Vector2(CELL_W, CELL_H)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.clip_contents = true
	button.add_theme_stylebox_override("normal", _cell_style(false))
	button.add_theme_stylebox_override("hover", _cell_style(true))
	button.add_theme_stylebox_override("pressed", _cell_style(true))
	button.add_theme_stylebox_override("focus", _cell_style(true))
	button.text = ""

	var accent := ColorRect.new()
	accent.color = ThemeTokens.CYAN
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	accent.offset_right = 3
	button.add_child(accent)

	var icon_key := _icon_key(unit)
	var texture := _load_icon(icon_key)
	if texture != null:
		var icon := TextureRect.new()
		icon.texture = texture
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 8
		icon.offset_top = 8
		icon.offset_right = -8
		icon.offset_bottom = -22
		button.add_child(icon)
	else:
		var fallback := Label.new()
		fallback.text = _unit_caption(unit)
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		fallback.add_theme_font_size_override("font_size", 16)
		fallback.add_theme_color_override("font_color", ThemeTokens.TEXT)
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.offset_bottom = -22
		button.add_child(fallback)

	var shade := ColorRect.new()
	shade.color = Color(0.03, 0.07, 0.09, 0.72)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	shade.offset_top = -22
	button.add_child(shade)

	var hp_track := ColorRect.new()
	hp_track.color = Color(0.04, 0.08, 0.10, 0.95)
	hp_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_track.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hp_track.offset_left = 6
	hp_track.offset_right = -6
	hp_track.offset_top = -20
	hp_track.offset_bottom = -16
	button.add_child(hp_track)
	var hp_fill := ColorRect.new()
	hp_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hp_track.add_child(hp_fill)
	button.set_meta("hp_fill", hp_fill)

	var name_label := Label.new()
	name_label.text = _unit_caption(unit)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", ThemeTokens.TEXT)
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_label.offset_top = -16
	name_label.offset_bottom = -1
	button.add_child(name_label)

	var count := units.size()
	_add_count_badge(button, count)
	button.tooltip_text = "%s ×%d" % [_unit_caption(unit), count]
	button.set_meta("unit", unit)
	button.set_meta("units", units)
	_apply_hp(button, units)
	button.pressed.connect(_on_portrait_pressed.bind(units))
	return button


func _add_count_badge(button: Button, count: int) -> void:
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := SystemUIStyle.rounded(
		Color(SystemUIStyle.CYAN_DEEP.r, SystemUIStyle.CYAN_DEEP.g, SystemUIStyle.CYAN_DEEP.b, 0.92),
		ThemeTokens.CYAN,
		1,
		4
	)
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	chip.add_theme_stylebox_override("panel", style)
	var badge := Label.new()
	badge.text = "×%d" % count
	badge.add_theme_font_size_override("font_size", 14)
	badge.add_theme_color_override("font_color", ThemeTokens.CYAN)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(badge)
	button.add_child(chip)
	chip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	chip.offset_top = 4
	chip.offset_right = -4
	chip.offset_bottom = 24
	chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	chip.grow_vertical = Control.GROW_DIRECTION_BEGIN


func _apply_hp(button: Control, units: Array) -> void:
	var fill = button.get_meta("hp_fill") if button.has_meta("hp_fill") else null
	if fill == null or not is_instance_valid(fill):
		return
	var hp_sum := 0.0
	var hp_max_sum := 0.0
	for unit in units:
		if not is_instance_valid(unit):
			continue
		if unit.get("hp") != null:
			hp_sum += float(unit.hp)
		if unit.get("hp_max") != null:
			hp_max_sum += float(unit.hp_max)
	var ratio := 1.0 if hp_max_sum <= 0.0 else clampf(hp_sum / hp_max_sum, 0.0, 1.0)
	fill.anchor_right = ratio
	fill.offset_right = 0
	if ratio > 0.55:
		fill.color = ThemeTokens.GREEN
	elif ratio > 0.28:
		fill.color = ThemeTokens.AMBER
	else:
		fill.color = ThemeTokens.RED
	var caption := _unit_caption(units[0]) if not units.is_empty() else ""
	button.tooltip_text = "%s ×%d  生命 %.0f%%" % [caption, units.size(), ratio * 100.0]


func _on_portrait_pressed(units: Array):
	MatchSignals.deselect_all_units.emit()
	var focus_unit = null
	for unit in units:
		if not is_instance_valid(unit) or not unit.is_in_group("controlled_units"):
			continue
		var selection = unit.find_child("Selection")
		if selection != null and selection.has_method("select"):
			selection.select()
		if focus_unit == null:
			focus_unit = unit
	if focus_unit != null and focus_unit.is_inside_tree():
		var camera = get_tree().root.find_child("IsometricCamera3D", true, false)
		if camera != null and camera.has_method("set_position_safely"):
			if camera.has_method("clear_follow_target"):
				camera.clear_follow_target()
			camera.set_position_safely(focus_unit.global_position)


func _icon_key(unit) -> String:
	return str(ICON_BY_SCENE.get(unit.scene_file_path, ""))


func _unit_caption(unit) -> String:
	var key := _icon_key(unit)
	if CAPTION_BY_ICON.has(key):
		return str(CAPTION_BY_ICON[key])
	var scene_path := str(unit.scene_file_path)
	return scene_path.get_file().get_basename()


func _load_icon(icon_key: String) -> Texture2D:
	if icon_key.is_empty():
		return null
	var path := "res://source/match/hud/ra3/icons/%s.png" % icon_key
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _apply_panel_style():
	var style := SystemUIStyle.glass(Vector2(FRAME_PADDING, FRAME_PADDING))
	style.bg_color = Color(SystemUIStyle.GLASS.r, SystemUIStyle.GLASS.g, SystemUIStyle.GLASS.b, 0.82)
	style.border_color = SystemUIStyle.LINE
	style.set_border_width_all(1)
	style.set_corner_radius_all(SystemUIStyle.RADIUS)
	style.shadow_color = Color(SystemUIStyle.CYAN.r, SystemUIStyle.CYAN.g, SystemUIStyle.CYAN.b, 0.16)
	style.shadow_size = 8
	add_theme_stylebox_override("panel", style)


func _cell_style(hovered := false) -> StyleBoxFlat:
	return ThemeTokens.card_style(ThemeTokens.STATE_READY, hovered, hovered)
