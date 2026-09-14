extends "res://source/ui/MenuPage.gd"

const BRANCH_NAMES := {"combat":"战斗", "economy":"经济", "construction":"建设"}
var pending: Dictionary = {}
var points_label: Label
var status_label: Label
var columns: HBoxContainer

func _ready() -> void:
	pending = GrowthStore.state.get("levels", {}).duplicate(true)
	_build_ui()

func _build_ui() -> void:
	var root: VBoxContainer = $CenterContainer/PanelContainer/MarginContainer/VBoxContainer
	points_label = root.get_node("Points")
	status_label = root.get_node("Status")
	columns = root.get_node("Columns")
	for branch in ["combat", "economy", "construction"]:
		var panel := VBoxContainer.new()
		panel.custom_minimum_size = Vector2(220, 0)
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var title := Label.new()
		title.text = BRANCH_NAMES[branch]
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 24)
		panel.add_child(title)
		for definition in GrowthStore.DEFINITIONS[branch]:
			var card := VBoxContainer.new()
			card.add_theme_constant_override("separation", 3)
			var label := Label.new()
			label.text = "%s  Lv.%d/%d" % [definition.get("name"), GrowthStore.get_level(definition.get("id"), pending), int(definition.get("max_level", 0))]
			card.add_child(label)
			var desc := Label.new()
			desc.text = str(definition.get("description", ""))
			desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			card.add_child(desc)
			var button := Button.new()
			button.text = "升级（%d 点）" % int(definition.get("costs")[min(GrowthStore.get_level(definition.get("id"), pending), int(definition.get("max_level", 1)) - 1)])
			button.disabled = not bool(GrowthStore.can_upgrade(definition.get("id"), pending).get("ok", false))
			button.pressed.connect(_on_upgrade.bind(definition.get("id")))
			card.add_child(button)
			panel.add_child(card)
		columns.add_child(panel)
	_update_labels()

func _on_upgrade(node_id: String) -> void:
	var current := GrowthStore.get_level(node_id, pending)
	pending[node_id] = current + 1
	_update_labels()

func _update_labels() -> void:
	points_label.text = "可用成长点：%d    本次未保存变化：%d" % [int(GrowthStore.state.get("available_points", 0)), _pending_cost()]
	for child in columns.get_children():
		for card in child.get_children():
			if card is VBoxContainer and card.get_child_count() >= 3:
				var label := card.get_child(0) as Label
				var button := card.get_child(2) as Button
				var name := label.text.split("  Lv.")[0]
				for branch in GrowthStore.DEFINITIONS.values():
					for definition in branch:
						if definition.get("name") == name:
							var level := GrowthStore.get_level(definition.get("id"), pending)
							label.text = "%s  Lv.%d/%d" % [definition.get("name"), level, int(definition.get("max_level", 0))]
							button.disabled = not bool(GrowthStore.can_upgrade(definition.get("id"), pending).get("ok", false))
							break

func _pending_cost() -> int:
	var total := 0
	for id in pending:
		var base := int(GrowthStore.state.get("levels", {}).get(id, 0))
		var target := int(pending[id])
		var definition := GrowthStore.get_definition(id)
		for i in range(base, target):
			total += int(definition.get("costs", [])[i])
	return total

func _on_confirm() -> void:
	var result := GrowthStore.confirm_pending(pending)
	status_label.text = "已保存成长选择" if bool(result.get("ok", false)) else str(result.get("reason", "保存失败"))
	if bool(result.get("ok", false)):
		pending = GrowthStore.state.get("levels", {}).duplicate(true)
	_update_labels()

func _on_reset() -> void:
	pending = GrowthStore.reset_pending().get("levels", {}).duplicate(true)
	status_label.text = "已重置本次未保存选择"
	_update_labels()

func _on_back() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Growth.tscn")

func _on_escape() -> bool:
	_on_back()
	return true
