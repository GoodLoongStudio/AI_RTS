extends Node

# Lightweight campaign identity component attached to a normal RTS Unit.
# The hero remains a regular Unit/Tank for movement, combat and selection, while
# campaign systems can identify it without depending on squad membership or scene type.

var hero_id: String = "vanguard"
var display_name: String = "先锋指挥单元"
var portrait_label: String = "先锋"
var role: String = "primary_combat_hero"
var is_primary: bool = true


func configure(data: Dictionary):
	hero_id = str(data.get("hero_id", hero_id))
	display_name = str(data.get("hero_name", display_name))
	portrait_label = str(data.get("hero_portrait_label", portrait_label))
	role = str(data.get("hero_role", role))
	is_primary = bool(data.get("hero_is_primary", is_primary))


func get_hero_unit() -> Node3D:
	return get_parent() as Node3D
