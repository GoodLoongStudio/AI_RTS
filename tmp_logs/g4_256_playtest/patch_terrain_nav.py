from pathlib import Path

p = Path(r"G:\AIRTS\AI_RTS\source\match\TerrainNavigation.gd")
text = p.read_text(encoding="utf-8")
old = """func _ready():
	# Runtime baking should use physics geometry. Parsing MeshInstance3D geometry forces
	# a GPU -> CPU readback and Godot 4.7 reports it as a runtime performance warning.
	_navigation_region.navigation_mesh.geometry_parsed_geometry_type = (
		NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	)
	assert(_safety_checks())"""
new = """func _ready():
	var nav_parent = get_parent()
	var match_node = find_parent("Match")
	var map_node = match_node.get_node_or_null("Map") if match_node != null else null
	if nav_parent != null and nav_parent.has_method("should_skip_runtime_navigation") and nav_parent.should_skip_runtime_navigation(map_node):
		print("G4PERF skip terrain nav map_force_update")
		return
	# Runtime baking should use physics geometry. Parsing MeshInstance3D geometry forces
	# a GPU -> CPU readback and Godot 4.7 reports it as a runtime performance warning.
	_navigation_region.navigation_mesh.geometry_parsed_geometry_type = (
		NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	)
	assert(_safety_checks())"""
if old not in text:
    raise SystemExit("pattern not found")
p.write_text(text.replace(old, new, 1), encoding="utf-8")
print("patched", p)
