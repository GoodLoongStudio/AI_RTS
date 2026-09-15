extends PanelContainer

@onready var _match = find_parent("Match")


func _on_toggle_button_pressed():
	var fog = _match.fog_of_war
	var next_enabled := true
	if fog.has_method("is_runtime_enabled"):
		next_enabled = not fog.is_runtime_enabled()
		fog.set_runtime_enabled(next_enabled)
		if next_enabled and _match.map != null:
			fog.resize(_match.map.size)
	else:
		fog.visible = not fog.visible
		next_enabled = fog.visible
	var visibility_handler = _match.find_child("UnitVisibilityHandler", true, false)
	if visibility_handler != null:
		visibility_handler.visible = next_enabled
	var minimap = _match.find_child("Minimap", true, false)
	if minimap != null and minimap.has_method("_sync_minimap_fog_mask"):
		minimap._sync_minimap_fog_mask()
