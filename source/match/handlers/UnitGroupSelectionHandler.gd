extends Node3D

var _unit_group_names = [null]
@onready var _input_runtime = find_parent("Match").get_node("InputBindingRuntime")


func _ready():
	for group_id in range(1, 10):
		_unit_group_names.append("unit_group_{0}".format([group_id]))
	_input_runtime.connect("ActionPressed", _on_input_action_pressed)


func _on_input_action_pressed(action_id: String):
	for group_id in range(1, 10):
		if action_id == "group.set_%d" % group_id:
			set_group(group_id)
			return
		if action_id == "group.access_%d" % group_id:
			access_group(group_id)
			return


func access_group(group_id: int):
	var units_in_group = Utils.Set.from_array(
		get_tree().get_nodes_in_group(_unit_group_names[group_id])
	)
	Utils.Match.select_units(units_in_group)


func set_group(group_id: int):
	for unit in get_tree().get_nodes_in_group(_unit_group_names[group_id]):
		unit.remove_from_group(_unit_group_names[group_id])
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if unit.is_in_group("controlled_units"):
			unit.add_to_group(_unit_group_names[group_id])
