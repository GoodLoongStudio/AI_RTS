extends SceneTree

## Traversal probe for the saved visual kit scene.
## The showcase is intentionally navigation-neutral, so this harness supplies
## temporary trimesh colliders and a Recast navigation region. It then probes
## both directions over the main and side slopes, including their real height.

const FOLDER := "res://review/G4/kit_samples/all_kits_showcase"
const REPORT := FOLDER + "/traversal_verification.json"

var scene: Node3D
var region: NavigationRegion3D
var navigation_mesh: NavigationMesh
var terrain_map: RID

func _initialize() -> void:
	call_deferred("run")

func add_mesh_collider(mesh: Mesh, label: String, transform: Transform3D = Transform3D.IDENTITY) -> void:
	var body := StaticBody3D.new()
	body.name = label + "_TraversalCollider"
	body.transform = transform
	body.add_to_group("terrain_navigation_input")
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	root.add_child(body)

func add_ground_collider() -> void:
	var body := StaticBody3D.new()
	body.name = "TraversalGroundCollider"
	body.position = Vector3(0.0, -.25, 0.0)
	body.add_to_group("terrain_navigation_input")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(460.0, .5, 350.0)
	shape.shape = box
	body.add_child(shape)
	root.add_child(body)

func build_navigation() -> bool:
	navigation_mesh = NavigationMesh.new()
	navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navigation_mesh.geometry_source_group_name = "terrain_navigation_input"
	navigation_mesh.cell_size = .30
	navigation_mesh.cell_height = .30
	navigation_mesh.agent_height = 1.8
	navigation_mesh.agent_radius = .9
	navigation_mesh.agent_max_climb = .5
	navigation_mesh.filter_baking_aabb = AABB(Vector3(-230.0, -1.0, -175.0), Vector3(460.0, 45.0, 350.0))
	region = NavigationRegion3D.new()
	region.name = "TraversalProbeNavigation"
	region.navigation_mesh = navigation_mesh
	root.add_child(region)
	await process_frame
	region.bake_navigation_mesh(false)
	# Recast bakes on a worker thread; in a headless SceneTree the main loop spins
	# frames far faster than the bake finishes, so a frame-counted wait (the old
	# 600-frame loop) expired in well under a second, always saw polygons=0, then
	# tripped the assert below and left the main loop running forever (observed:
	# 50 min with no output and no report). Wait on wall-clock time instead.
	var t0 := Time.get_ticks_msec()
	var last_report := -1
	while Time.get_ticks_msec() - t0 < 90000:
		await process_frame
		var secs := int((Time.get_ticks_msec() - t0) / 1000)
		if secs % 5 == 0 and secs != last_report:
			last_report = secs
			print("TRAVERSAL_BAKE_WAIT ",secs,"s polygons=",navigation_mesh.get_polygon_count()," sources=",get_nodes_in_group("terrain_navigation_input").size())
		if navigation_mesh.get_polygon_count() > 0:
			await process_frame
			terrain_map = region.get_navigation_map()
			return terrain_map.is_valid()
	return false

func path_length(path: PackedVector3Array) -> float:
	var result := 0.0
	for i in range(1, path.size()):
		result += path[i - 1].distance_to(path[i])
	return result

func probe_pair(name: String, from_point: Vector3, to_point: Vector3) -> Dictionary:
	var from_nav := NavigationServer3D.map_get_closest_point(terrain_map, from_point)
	var to_nav := NavigationServer3D.map_get_closest_point(terrain_map, to_point)
	var path := NavigationServer3D.map_get_path(terrain_map, from_nav, to_nav, true)
	var endpoint := path[path.size() - 1] if not path.is_empty() else Vector3.INF
	var climb := 0.0
	for point in path:
		climb=maxf(climb,point.y-from_nav.y)
	return {
		"name": name,
		"from": [from_point.x,from_point.y,from_point.z],
		"to": [to_point.x,to_point.y,to_point.z],
		"from_nav": [from_nav.x,from_nav.y,from_nav.z],
		"to_nav": [to_nav.x,to_nav.y,to_nav.z],
		"path_points": path.size(),
		"path_length_m": path_length(path),
		"climb_m": climb,
		"endpoint_error_m": endpoint.distance_to(to_nav) if not path.is_empty() else INF,
		"pass": not path.is_empty() and endpoint.distance_to(to_nav)<2.0 and absf(endpoint.y-to_nav.y)<.75
	}

func run() -> void:
	scene=load(FOLDER+"/all_kits.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	# Plateau and every added mountain use the same mesh/collision source as
	# the rendered kit. Mountains are included to verify their skirts do not
	# create a hidden seam across the surrounding ground.
	for node in [scene.get_node("PlateauAndRamps"),scene.get_node("SquareTopMountain"),scene.get_node("TerracedMassif"),scene.get_node("MixedMountainRange")]:
		var mesh_node: MeshInstance3D=node.get_node("ContinuousMountain") if node.has_node("ContinuousMountain") else node.get_child(0)
		add_mesh_collider(mesh_node.mesh,String(node.name),mesh_node.global_transform)
	add_ground_collider()
	var bake_ok:=await build_navigation()
	if not bake_ok:
		# Write a failure report and exit instead of tripping an assert, which left
		# the SceneTree main loop running forever with no artifact on disk.
		var failed: Dictionary={
			"scene":"all_kits.tscn","navigation_bake":"failed",
			"polygons_after_bake":navigation_mesh.get_polygon_count(),
			"collider_sources":get_nodes_in_group("terrain_navigation_input").size(),
			"bake_wait_s":90,
			"reason":"Recast returned 0 polygons within 90s; ramp paths were NOT probed",
			"ramp_paths":[],"all_ramp_paths_pass":false}
		FileAccess.open(REPORT,FileAccess.WRITE).store_string(JSON.stringify(failed,"  "))
		print("KIT_TRAVERSAL ",JSON.stringify(failed))
		quit(1)
		return
	var builder=load("res://tools/godot/all_kits_showcase.gd").PlateauBuilder.new()
	var plateau:=scene.get_node("PlateauAndRamps")
	var results: Array=[]
	var specs: Array=[builder.main_spec()]
	specs.append_array(builder.mesa_ramp_specs())
	for spec in specs:
		var top_local: Vector2=spec.start+spec.axis*.6
		var bottom_local: Vector2=spec.start+spec.axis*(spec.run-.6)
		var top_h: float=builder.mesa_height(top_local.x,top_local.y, builder.mesa_ramp_specs())
		var bottom_h: float=builder.mesa_height(bottom_local.x,bottom_local.y, builder.mesa_ramp_specs())
		var top: Vector3=plateau.global_transform*Vector3(top_local.x,top_h,top_local.y)
		var bottom: Vector3=plateau.global_transform*Vector3(bottom_local.x,bottom_h,bottom_local.y)
		results.append(probe_pair(String(spec.role)+"_up",bottom,top))
		results.append(probe_pair(String(spec.role)+"_down",top,bottom))
	var passed:=true
	for result in results: passed=passed and bool(result.pass)
	var output={"scene":"all_kits.tscn","navigation_bake":"passed","agent_height_m":1.8,"agent_radius_m":.9,"agent_max_climb_m":.5,"ramp_paths":results,"all_ramp_paths_pass":passed,"mountain_collision_included":true,"visual_kit_navigation_note":"temporary harness; showcase scene itself remains navigation-neutral"}
	FileAccess.open(REPORT,FileAccess.WRITE).store_string(JSON.stringify(output,"  "))
	print("KIT_TRAVERSAL ",JSON.stringify(output))
	quit(0 if passed else 1)
