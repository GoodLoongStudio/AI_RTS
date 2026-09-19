extends CanvasLayer

signal pick_requested(augment_id)

const ThemeTokens = preload("res://source/match/hud/production/ProductionTheme.gd")
const EscapeRouter = preload("res://source/ui/EscapeRouter.gd")

var _root: Control = null
var _title: Label = null
var _hint: Label = null
var _timer: Label = null
var _cards: HBoxContainer = null
var _deadline_msec := 0
var _offer: Array = []


func _ready() -> void:
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build()


func show_draft(snapshot: Dictionary, networked: bool) -> void:
	_offer = snapshot.get("offer", []) if snapshot.get("offer", []) is Array else []
	_deadline_msec = int(snapshot.get("deadline_msec", 0))
	if _offer.is_empty():
		hide_draft()
		return
	visible = true
	_title.text = "战区补给 · 三选一"
	if networked:
		_hint.text = "联机战局仍在推进。点一张，或等倒计时用推荐项。"
	else:
		_hint.text = "模拟已暂停。点一张，或按 1 / 2 / 3。超时采用推荐项。"
	_rebuild_cards(snapshot.get("rank", {}) if snapshot.get("rank", {}) is Dictionary else {})
	tick()


func hide_draft() -> void:
	visible = false
	_offer = []
	_deadline_msec = 0


func tick() -> void:
	if not visible:
		return
	var remain := maxi(0, _deadline_msec - Time.get_ticks_msec())
	_timer.text = "剩余 %d 秒" % int(ceil(remain / 1000.0))


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			EscapeRouter.claim()
			get_viewport().set_input_as_handled()
			return
		var index := -1
		if event.keycode == KEY_1 or event.keycode == KEY_KP_1:
			index = 0
		elif event.keycode == KEY_2 or event.keycode == KEY_KP_2:
			index = 1
		elif event.keycode == KEY_3 or event.keycode == KEY_KP_3:
			index = 2
		if index >= 0 and index < _offer.size():
			_emit_pick(str(_offer[index].get("id", "")))
			get_viewport().set_input_as_handled()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.03, 0.07, 0.09, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_CENTER)
	column.grow_horizontal = Control.GROW_DIRECTION_BOTH
	column.grow_vertical = Control.GROW_DIRECTION_BOTH
	column.offset_left = -480
	column.offset_right = 480
	column.offset_top = -220
	column.offset_bottom = 220
	column.add_theme_constant_override("separation", 12)
	_root.add_child(column)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	_title.add_theme_color_override("font_color", ThemeTokens.TEXT)
	column.add_child(_title)
	_timer = Label.new()
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_timer.add_theme_font_size_override("font_size", 16)
	_timer.add_theme_color_override("font_color", ThemeTokens.AMBER)
	column.add_child(_timer)
	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", ThemeTokens.MUTED)
	column.add_child(_hint)
	_cards = HBoxContainer.new()
	_cards.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards.add_theme_constant_override("separation", 16)
	column.add_child(_cards)


func _rebuild_cards(rank: Dictionary) -> void:
	for child in _cards.get_children():
		child.queue_free()
	var starred := str(rank.get("starred_id", ""))
	var source := str(rank.get("source", "rules"))
	var reasons: Array = rank.get("reasons", []) if rank.get("reasons", []) is Array else []
	for index in _offer.size():
		var item: Dictionary = _offer[index]
		var card_id := str(item.get("id", ""))
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(280, 220)
		var rarity := str(item.get("rarity", "silver"))
		var edge := ThemeTokens.AMBER if rarity == "gold" else ThemeTokens.CYAN
		if card_id == starred:
			edge = ThemeTokens.GREEN
		panel.add_theme_stylebox_override("panel", ThemeTokens.card_style("ready", false, card_id == starred))
		var inner := VBoxContainer.new()
		inner.add_theme_constant_override("separation", 8)
		panel.add_child(inner)
		var index_label := Label.new()
		index_label.text = str(index + 1)
		index_label.add_theme_color_override("font_color", edge)
		inner.add_child(index_label)
		var name_label := Label.new()
		name_label.text = str(item.get("name", card_id))
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		name_label.add_theme_font_size_override("font_size", 18)
		name_label.add_theme_color_override("font_color", ThemeTokens.TEXT)
		inner.add_child(name_label)
		var summary := Label.new()
		summary.text = str(item.get("summary", ""))
		summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		summary.add_theme_color_override("font_color", ThemeTokens.MUTED)
		inner.add_child(summary)
		var rec := Label.new()
		rec.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if card_id == starred:
			var reason_text := _reason_text(reasons, card_id)
			if source == "live":
				rec.text = "Hermes 推荐  %s" % reason_text
			elif source == "cache":
				rec.text = "成长画像推荐  %s" % reason_text
			else:
				rec.text = "规则推荐  %s" % reason_text
			rec.add_theme_color_override("font_color", ThemeTokens.GREEN)
		else:
			rec.text = ""
		inner.add_child(rec)
		var button := Button.new()
		button.text = "选择"
		button.pressed.connect(_emit_pick.bind(card_id))
		inner.add_child(button)
		_cards.add_child(panel)


func _reason_text(reasons: Array, card_id: String) -> String:
	for row in reasons:
		if row is Dictionary and str(row.get("id", "")) == card_id:
			return str(row.get("text", ""))
	return ""


func _emit_pick(augment_id: String) -> void:
	if augment_id.is_empty() or not visible:
		return
	pick_requested.emit(augment_id)
