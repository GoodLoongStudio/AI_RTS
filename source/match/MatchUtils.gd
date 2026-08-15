class Unit:
	const Movement = preload("res://source/match/utils/UnitMovementUtils.gd")
	const Placement = preload("res://source/match/utils/UnitPlacementUtils.gd")


const Resources = preload("res://source/match/utils/ResourceUtils.gd")


static func traverse_node_tree_and_replace_materials_matching_albedo(
	starting_node, albedo_to_match, epsilon, material_to_set
):
	if starting_node == null:
		return
	for child in starting_node.find_children("*"):
		if not "mesh" in child:
			continue
		for surface_id in range(child.mesh.get_surface_count()):
			var surface_material = child.mesh.get("surface_{0}/material".format([surface_id]))
			if (
				surface_material != null
				and Utils.Colour.is_equal_approx_with_epsilon(
					surface_material.albedo_color, albedo_to_match, epsilon
				)
			):
				child.set("surface_material_override/{0}".format([surface_id]), material_to_set)


static func select_units(units_to_select):
	var shift_selecting := false
	if not units_to_select.empty():
		var first_unit = units_to_select.peek()
		var match_node = first_unit.find_parent("Match") if first_unit != null else null
		var input_runtime = match_node.get_node_or_null("InputBindingRuntime") if match_node != null else null
		shift_selecting = input_runtime != null and input_runtime.IsModifierPressed("Shift")
	if not units_to_select.empty() and not shift_selecting:
		MatchSignals.deselect_all_units.emit()
	for unit in units_to_select.iterate():
		var selection = unit.find_child("Selection")
		if selection != null:
			selection.select()
