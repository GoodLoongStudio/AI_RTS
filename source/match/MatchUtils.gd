class Unit:
	const Movement = preload("res://source/match/utils/UnitMovementUtils.gd")
	const Placement = preload("res://source/match/utils/UnitPlacementUtils.gd")


const Resources = preload("res://source/match/utils/ResourceUtils.gd")


## 地图是否是"逻辑地形"（工作台生成图：Terrain 挂 GeneratedTerrain 脚本、带 height_data_path）。
##
## ⚠ 判据必须**先查属性存在性**再取值。普通地图的 Terrain 节点**没有**这个属性，
## `Object.get()` 会返回 null → `str(null)` = "<null>" ≠ "" → 把普通地图误判成逻辑地形
## → 跳过导航烘焙 → C# 建造校验的 `Navigable()` 恒 false → 任何落点都被拒
## `SurfaceNotBuildable`（2026-09-15 实测：PlainAndSimple / BigArena 双双中招，
## 联机里建造整体不可用）。全仓库"是不是逻辑地形"的判断只允许走这里，
## 不许再写第二份内联实现（同一判据曾复制到 5 处，一处写错全链路一起错）。
static func is_logic_terrain_map(map: Node) -> bool:
	if map == null:
		return false
	var terrain: Node = map.find_child("Terrain", true, false)
	if terrain == null:
		return false
	return "height_data_path" in terrain and str(terrain.get("height_data_path")) != ""


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
