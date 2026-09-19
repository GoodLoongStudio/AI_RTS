extends Control

const ThemeTokens = preload("res://source/match/hud/production/ProductionTheme.gd")

var _row: HBoxContainer = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	offset_left = 24
	offset_right = -24
	offset_top = 12
	offset_bottom = 48
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_row)
	visible = false


func set_owned(owned: Array) -> void:
	for child in _row.get_children():
		child.queue_free()
	if owned.is_empty():
		visible = false
		return
	visible = true
	for card in owned:
		if not card is Dictionary:
			continue
		var chip := Label.new()
		chip.text = str(card.get("name", card.get("id", "")))
		chip.add_theme_color_override("font_color", ThemeTokens.TEXT)
		var wrap := PanelContainer.new()
		var rarity := str(card.get("rarity", "silver"))
		wrap.add_theme_stylebox_override("panel", ThemeTokens.card_style("ready", false, rarity == "gold"))
		wrap.add_child(chip)
		_row.add_child(wrap)
