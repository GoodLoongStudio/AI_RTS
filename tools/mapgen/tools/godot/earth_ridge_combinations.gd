extends "res://tools/godot/earth_ridge_component.gd"

const DEST := "res://review/G4/kit_samples/earth_ridge_combinations"
const GRID_X := 256
const GRID_Z := 208
const GRID_STEP := .75
var variant: Dictionary

func elevation(x: float,z: float) -> float:
	if variant.shape=="arc":
		settings=variant.pieces[0]
		var radius:=float(variant.radius)
		var relative_z:=z+30.0
		var angle:=atan2(x,relative_z)
		if absf(angle)>1.7: return 0.0
		return super.elevation(angle*radius,Vector2(x,relative_z).length()-radius)
	var result:=0.0
	for part in variant.pieces:
		settings=part
		var local:=Vector2(x-float(part.x),z-float(part.z)).rotated(-float(part.angle))
		result=maxf(result,super.elevation(local.x,local.y))
	return result

func assembly_mesh(parent: Node3D,folder: String) -> void:
	var vertices:=PackedVector3Array()
	var normals:=PackedVector3Array()
	var indices:=PackedInt32Array()
	var footprint: Array=[]
	for iz in range(GRID_Z+1):
		var z: float=(iz-GRID_Z*.5)*GRID_STEP
		var start: Variant=null
		for ix in range(GRID_X+1):
			var x: float=(ix-GRID_X*.5)*GRID_STEP
			var h:=elevation(x,z)
			vertices.append(Vector3(x,h,z))
			normals.append(Vector3(elevation(x-.2,z)-elevation(x+.2,z),.4,elevation(x,z-.2)-elevation(x,z+.2)).normalized())
			if h>.5 and start==null: start=x
			if h<=.5 and start!=null:
				footprint.append([z,start,x-GRID_STEP])
				start=null
			if ix==0 or ix==GRID_X or iz==0 or iz==GRID_Z: assert(h==0.0,"Clipped mountain perimeter")
	for iz in range(GRID_Z):
		for ix in range(GRID_X):
			var a:=iz*(GRID_X+1)+ix
			var b:=a+1
			var c:=a+GRID_X+1
			var d:=c+1
			if maxf(maxf(vertices[a].y,vertices[b].y),maxf(vertices[c].y,vertices[d].y))<.001: continue
			indices.append_array([a,b,c,b,d,c])
	var data:=[]
	data.resize(Mesh.ARRAY_MAX)
	data[Mesh.ARRAY_VERTEX]=vertices
	data[Mesh.ARRAY_NORMAL]=normals
	data[Mesh.ARRAY_INDEX]=indices
	var mesh:=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,data)
	var inst:=MeshInstance3D.new()
	inst.name="EarthMass"
	inst.mesh=mesh
	inst.material_override=ridge_material()
	parent.add_child(inst)
	var body:=StaticBody3D.new()
	body.name="MountainCollision"
	inst.add_child(body)
	var shape:=CollisionShape3D.new()
	shape.shape=mesh.create_trimesh_shape()
	body.add_child(shape)
	parent.set_meta("kit_id",variant.id)
	parent.set_meta("intended_role","high_obstacle_nonbuildable")
	FileAccess.open(folder+"/footprint.json",FileAccess.WRITE).store_string(JSON.stringify({"grid_step_m":GRID_STEP,"candidate_z_xmin_xmax":footprint,"requires_g2_mapping":true},"  "))

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Real images require the Windows rendering display.")
		quit(2)
		return
	erosion.seed=91026
	erosion.frequency=.26
	erosion.fractal_octaves=3
	root.size=Vector2i(1800,1200)
	root.msaa_3d=Viewport.MSAA_4X
	var world:=Node3D.new()
	root.add_child(world)
	var env:=WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color("b9c9d0")
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("d6a06b")
	env.environment.ambient_light_energy=.34
	env.environment.tonemap_exposure=.78
	world.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.light_energy=.78
	sun.shadow_enabled=true
	world.add_child(sun)
	var ground:=MeshInstance3D.new()
	ground.mesh=PlaneMesh.new()
	ground.mesh.size=Vector2(2000,2000)
	ground.position.y=-.035
	ground.material_override=ridge_material()
	ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(ground)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.current=true
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	var config: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://tools/godot/earth_ridge_combinations.json"))
	for entry in config.variants:
		variant=entry
		var start_ms:=Time.get_ticks_msec()
		var folder:=DEST+"/"+str(variant.id)
		DirAccess.make_dir_recursive_absolute(folder)
		var kit:=Node3D.new()
		kit.name=str(variant.id)
		world.add_child(kit)
		assembly_mesh(kit,folder)
		records.clear()
		rng.seed=91026
		# Small talus blocks only on the mountain toe, not in the open corridors.
		for attempt in range(700):
			var x:=rng.randf_range(-72,72)
			var z:=rng.randf_range(-57,57)
			var h:=elevation(x,z)
			if h<.1 or h>2.2: continue
			var size:=rng.randf_range(.45,1.3)
			piece(kit,"SM_Env_RockFlat_03",Vector3(x,h+size*.22,z),Vector3(size*1.4,size*.65,size),rng.randf_range(0,TAU))
		var nodes: Array=[kit]
		while not nodes.is_empty():
			var node: Node=nodes.pop_back()
			for child in node.get_children():
				child.owner=kit
				nodes.append(child)
		var saved:=PackedScene.new()
		assert(saved.pack(kit)==OK)
		assert(ResourceSaver.save(saved,folder+"/component.tscn")==OK)
		var generated_ms:=Time.get_ticks_msec()-start_ms
		for view in [
			{"name":"overview","pos":Vector3(60,125,155),"target":Vector3(0,4,0),"size":132.0},
			{"name":"top","pos":Vector3(0,180,.01),"target":Vector3.ZERO,"size":136.0}
		]:
			camera.position=view.pos
			camera.size=view.size
			if variant.id=="arc_ridge" and view.name=="overview":
				camera.position=Vector3(85,165,45)
				camera.size=90.0
			camera.look_at(view.target)
			for frame in 12: await process_frame
			await RenderingServer.frame_post_draw
			var capture:=root.get_texture().get_image()
			assert(capture!=null and not capture.is_empty())
			assert(capture.save_png(folder+"/"+view.name+".png")==OK)
		FileAccess.open(folder+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({"kit_id":variant.id,"parameters":variant,"build_ms":generated_ms,"render_engine":Engine.get_version_info(),"display_driver":DisplayServer.get_name(),"geometry":"continuous_heightfield","material_source":"earth_ridge_component.gd:ridge_material","instances":records.duplicate(true),"collision":"trimesh","g2_g4_integrated":false,"navigation_validated":false,"status":"pending_user_visual_review"},"  "))
		print("COMBINATION_CAPTURED ",variant.id," build_ms=",generated_ms)
		kit.queue_free()
		await process_frame
	print("ALL_COMBINATIONS_COMPLETE")
	quit()
