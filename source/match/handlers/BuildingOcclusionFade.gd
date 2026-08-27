extends Node

const Structure = preload("res://source/match/units/Structure.gd")
const MIN_OCCLUDER_HEIGHT := 1.5
const FADE_ALBEDO_ALPHA := 0.38

var _occluders: Array[GeometryInstance3D] = []
var _faded: Dictionary = {}


func _ready():
	var match_root = find_parent("Match")
	if match_root != null and not match_root.is_node_ready():
		await match_root.ready
	_refresh_occluders()
	MatchSignals.unit_spawned.connect(func(_unit): _refresh_occluders())
	MatchSignals.unit_died.connect(func(_unit): call_deferred("_refresh_occluders"))


func _process(_delta):
	_apply_fade(_find_blocking_occluders())


func _refresh_occluders():
	_restore_all()
	_occluders.clear()
	var match_root = find_parent("Match")
	if match_root == null:
		return
	var decorations = match_root.get_node_or_null("Map/Decorations")
	if decorations != null:
		for mesh in decorations.find_children("*", "MeshInstance3D", true, false):
			if _is_tall_occluder(mesh):
				_occluders.append(mesh)
	for unit in get_tree().get_nodes_in_group("units"):
		if not (unit is Structure):
			continue
		var geometry = unit.find_child("Geometry")
		if geometry == null:
			continue
		for mesh in geometry.find_children("*", "MeshInstance3D", true, false):
			if _is_tall_occluder(mesh):
				_occluders.append(mesh)


func _find_blocking_occluders() -> Dictionary:
	var blocking := {}
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return blocking
	var camera_origin: Vector3 = camera.global_position
	for unit in get_tree().get_nodes_in_group("units"):
		if not _unit_should_stay_visible(unit):
			continue
		var target: Vector3 = unit.global_position + Vector3(0, 0.7, 0)
		for occluder in _occluders:
			if not is_instance_valid(occluder) or unit.is_ancestor_of(occluder):
				continue
			if _segment_hits_occluder(camera_origin, target, occluder):
				blocking[occluder] = true
	return blocking


func _apply_fade(blocking: Dictionary):
	for occluder in _occluders:
		if not is_instance_valid(occluder):
			continue
		_ensure_fade_materials(occluder)
		var should_fade: bool = blocking.has(occluder)
		if should_fade:
			occluder.material_override = occluder.get_meta("occlusion_fade_material")
			_faded[occluder] = true
		else:
			occluder.material_override = occluder.get_meta("occlusion_base_override")
			_faded.erase(occluder)


func _ensure_fade_materials(mesh: GeometryInstance3D):
	if mesh.has_meta("occlusion_fade_ready"):
		return
	mesh.set_meta("occlusion_base_override", mesh.material_override)
	var source: Material = mesh.material_override
	if source == null and mesh is MeshInstance3D:
		source = mesh.get_active_material(0)
	var fade_mat: Material = source.duplicate() if source != null else StandardMaterial3D.new()
	if fade_mat is StandardMaterial3D:
		fade_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var albedo: Color = fade_mat.albedo_color
		albedo.a = FADE_ALBEDO_ALPHA
		fade_mat.albedo_color = albedo
	mesh.set_meta("occlusion_fade_material", fade_mat)
	mesh.set_meta("occlusion_fade_ready", true)


func _restore_all():
	for occluder in _faded.keys():
		if not is_instance_valid(occluder):
			continue
		if occluder.has_meta("occlusion_base_override"):
			occluder.material_override = occluder.get_meta("occlusion_base_override")
	_faded.clear()


func _unit_should_stay_visible(unit: Node) -> bool:
	if unit == null or not is_instance_valid(unit) or not unit.visible:
		return false
	var geometry = unit.find_child("Geometry")
	if geometry != null and not geometry.visible:
		return false
	return true


func _is_tall_occluder(mesh: MeshInstance3D) -> bool:
	if mesh.mesh == null:
		return false
	var scale_y: float = abs(mesh.global_transform.basis.get_scale().y)
	return mesh.get_aabb().size.y * scale_y >= MIN_OCCLUDER_HEIGHT


func _segment_hits_occluder(from: Vector3, to: Vector3, mesh: MeshInstance3D) -> bool:
	return _aabb_intersects_segment(mesh.global_transform * mesh.get_aabb(), from, to)


## Godot 4.7 的 AABB.intersects_segment 返回 Vector3，不能和 null/false 比较。
func _aabb_intersects_segment(aabb: AABB, from: Vector3, to: Vector3) -> bool:
	var direction := to - from
	var t_min := 0.0
	var t_max := 1.0
	for axis in 3:
		var origin: float = from[axis]
		var delta: float = direction[axis]
		var min_bound: float = aabb.position[axis]
		var max_bound: float = aabb.position[axis] + aabb.size[axis]
		if abs(delta) < 0.000001:
			if origin < min_bound or origin > max_bound:
				return false
			continue
		var inv := 1.0 / delta
		var t1 := (min_bound - origin) * inv
		var t2 := (max_bound - origin) * inv
		if t1 > t2:
			var swap := t1
			t1 = t2
			t2 = swap
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	return true


func _exit_tree():
	_restore_all()
