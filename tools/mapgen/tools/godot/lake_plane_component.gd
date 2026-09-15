extends "res://tools/godot/river_plane_component.gd"

const LAKE_OUTPUT := "G:/AIRTS/RTS_Map_Tool/review/G4/kit_samples/lake_plane_prototype"
const SEGMENTS := 384

func lake_radius(angle: float) -> float:
	return 29.0*(1.0+.13*sin(3.0*angle+.4)+.065*cos(5.0*angle-1.0))

func add_lake(parent: Node3D) -> void:
	var water_vertices: Array = [Vector3(0,-.02,0)]
	var water_indices: Array = []
	var bank_vertices: Array = []
	var bank_indices: Array = []
	for i in range(SEGMENTS):
		var angle := TAU*float(i)/SEGMENTS
		var direction := Vector3(cos(angle)*1.25,0,sin(angle)*.90)
		var radius := lake_radius(angle)
		water_vertices.append(direction*radius+Vector3(0,-.02,0))
		bank_vertices.append(direction*radius)
		bank_vertices.append(direction*(radius+.7)+Vector3(0,.07,0))
		bank_vertices.append(direction*(radius+2.4)+Vector3(0,.27,0))
	for i in range(SEGMENTS):
		var next := (i+1)%SEGMENTS
		water_indices.append_array([0,i+1,next+1])
		for strip in range(2):
			var a := i*3+strip
			var b := next*3+strip
			bank_indices.append_array([a,b,b+1,a,b+1,a+1])
	var water := water_material()
	water.set_shader_parameter("lake_mode",true)
	mesh_from_arrays(parent,water_vertices,water_indices,water)
	mesh_from_arrays(parent,bank_vertices,bank_indices,terrain_material(Color("a98f78")))

func run() -> void:
	DirAccess.make_dir_recursive_absolute(LAKE_OUTPUT)
	root.size=Vector2i(1800,1200)
	root.msaa_3d=Viewport.MSAA_4X
	var world:=Node3D.new()
	root.add_child(world)
	var env:=WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color("b9c4c4")
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("e4e2dd")
	env.environment.ambient_light_energy=.42
	env.environment.tonemap_exposure=.86
	world.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-52,-32,0)
	sun.light_color=Color("fff8ef")
	sun.light_energy=.65
	sun.shadow_enabled=true
	world.add_child(sun)
	var ground:=MeshInstance3D.new()
	var plane:=PlaneMesh.new()
	plane.size=Vector2(150,110)
	ground.mesh=plane
	ground.position.y=-.30
	ground.material_override=terrain_material(Color("b58d6d"))
	world.add_child(ground)
	add_lake(world)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	for view in [
		{"name":"overview","pos":Vector3(0,118,0),"target":Vector3.ZERO,"size":86.0},
		{"name":"iso45","pos":Vector3(60,85,75),"target":Vector3.ZERO,"size":83.0},
		{"name":"bank_detail","pos":Vector3(39,53,62),"target":Vector3(8,0,22),"size":43.0}
	]:
		camera.position=view.pos
		camera.size=view.size
		if view.name=="overview":
			camera.rotation_degrees=Vector3(-90,0,0)
		else:
			camera.look_at(view.target)
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(LAKE_OUTPUT+"/"+view.name+".png")
	var dependencies: Dictionary = {}
	for path in ["res://tools/godot/lake_plane_component.gd","res://tools/godot/river_plane_component.gd","res://assets/terrain_pbr/sand_diff.jpg","res://assets/terrain_pbr/sand_normal.jpg","res://assets/terrain_pbr/rock_diff.jpg"]:
		dependencies[path]=FileAccess.get_sha256(path)
	FileAccess.open(LAKE_OUTPUT+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({
		"kit_id":"lake_plane","status":"visual_prototype_pending_user_review",
		"geometry":"closed continuous lake and matched shore rings",
		"water_level":-.02,"segments":SEGMENTS,"in_water_decorations":false,
		"material_source":"res://tools/godot/river_plane_component.gd",
		"dependencies":dependencies,
		"instances":[
			{"kit_id":"lake_water","piece_role":"continuous_water_surface","anchor":[0,-.02,0],"scale":[1,1,1]},
			{"kit_id":"lake_bank","piece_role":"closed_wet_shore","anchor":[0,0,0],"scale":[1,1,1]}
		]
	},"  "))
	quit()
