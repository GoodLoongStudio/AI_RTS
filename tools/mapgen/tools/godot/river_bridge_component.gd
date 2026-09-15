extends "res://tools/godot/river_plane_component.gd"

const BRIDGE_OUTPUT := "G:/AIRTS/RTS_Map_Tool/review/G4/kit_samples/river_bridge_prototype"
const BRIDGE_BASE := "res://assets/4006_科幻世界/PolygonSciFiWorlds/Models/"
const BRIDGE_WIDTH := 12.0
var bridge_instances: Array = []

func bridge_part(parent: Node3D, suffix: String, pos: Vector3, size: Vector3, yaw: float=0.0) -> void:
	var path := BRIDGE_BASE+"SM_Bld_Bridge"+suffix+"_01.fbx"
	var scene=load(path)
	assert(scene != null,path)
	var inst=scene.instantiate()
	var boxes: Array=[]
	bounds(inst,inst.transform,boxes)
	var box: AABB=boxes[0]
	for b in boxes:
		box=box.merge(b)
	var holder:=Node3D.new()
	parent.add_child(holder)
	holder.add_child(inst)
	inst.position-=box.get_center()
	holder.scale=size/box.size
	holder.rotation.y=yaw
	holder.position=pos
	var texture=load(BRIDGE_BASE+"PolygonScifiWorlds_Texture_01_A.png")
	var nodes: Array=[inst]
	while not nodes.is_empty():
		var node=nodes.pop_back()
		nodes.append_array(node.get_children())
		if node is MeshInstance3D:
			for surface in node.mesh.get_surface_count():
				var original=node.get_active_material(surface)
				var material=original.duplicate() if original is StandardMaterial3D else StandardMaterial3D.new()
				material.albedo_texture=texture
				material.roughness=.85
				node.set_surface_override_material(surface,material)
	bridge_instances.append({"kit_id":"bridge"+suffix,"resource":path,"position":[pos.x,pos.y,pos.z],"scale":[holder.scale.x,holder.scale.y,holder.scale.z],"yaw":yaw,"sha256":FileAccess.get_sha256(path)})

func add_bridge(parent: Node3D) -> void:
	# Sample the entire widened deck so both ends clear the curved banks.
	var x := 18.0
	var low := 1000.0
	var high := -1000.0
	for i in range(49):
		var sample_x := x-BRIDGE_WIDTH*.5+float(i)*.25
		low=minf(low,river_center(sample_x)-river_half(sample_x))
		high=maxf(high,river_center(sample_x)+river_half(sample_x))
	var start := low-3.0
	var finish := high+3.0
	var count := int(ceil((finish-start)/8.0))
	var span := (finish-start)/count
	for i in range(count):
		var z := start+(i+.5)*span
		bridge_part(parent,"",Vector3(x,.60,z),Vector3(BRIDGE_WIDTH,.7,span))
		for side in [-1,1]:
			bridge_part(parent,"_Rail",Vector3(x+side*(BRIDGE_WIDTH*.5-.2),1.35,z),Vector3(.65,1.35,span),PI if side==-1 else 0.0)
	for end in [start,finish]:
		var direction := -1.0 if end==start else 1.0
		bridge_part(parent,"_End",Vector3(x,.60,end+direction*1.1),Vector3(BRIDGE_WIDTH,.7,2.2),PI if direction<0 else 0.0)
		for side in [-1,1]:
			bridge_part(parent,"_Rail_Pillar",Vector3(x+side*(BRIDGE_WIDTH*.5-.2),1.4,end),Vector3(.7,1.1,.7))
		var vertices: Array=[]
		var indices: Array=[]
		for row in range(25):
			var t:=float(row)/24.0
			for column in range(33):
				var offset:=lerpf(-9.0,9.0,float(column)/32.0)
				var shoulder:=1.0-smoothstep(6.0,9.0,absf(offset))
				var height:=lerpf(-.301,.95,(1.0-smoothstep(0.0,1.0,t))*shoulder)
				vertices.append(Vector3(x+offset,height,end+direction*(2.15+t*6.0)))
		for row in range(24):
			for column in range(32):
				var a:=row*33+column
				indices.append_array([a,a+1,a+33,a+1,a+34,a+33])
		var approach_material:=terrain_material(Color.WHITE)
		approach_material.set_shader_parameter("dry_surface",true)
		mesh_from_arrays(parent,vertices,indices,approach_material)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(BRIDGE_OUTPUT)
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
	plane.size=Vector2(WIDTH,DEPTH)
	ground.mesh=plane
	ground.position.y=-.30
	ground.material_override=terrain_material(Color.WHITE)
	world.add_child(ground)
	add_channel(world)
	add_bridge(world)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	for view in [
		{"name":"overview","pos":Vector3(72,105,115),"target":Vector3(8,0,0),"size":110.0},
		{"name":"bridge_detail","pos":Vector3(56,46,70),"target":Vector3(18,0,12),"size":57.0},
		{"name":"top","pos":Vector3(0,118,0),"target":Vector3.ZERO,"size":106.0}
	]:
		camera.position=view.pos
		camera.size=view.size
		if view.name=="top":
			camera.rotation_degrees=Vector3(-90,0,0)
		else:
			camera.look_at(view.target)
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(BRIDGE_OUTPUT+"/"+view.name+".png")
	FileAccess.open(BRIDGE_OUTPUT+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({
		"kit_id":"river_bridge","status":"visual_prototype_pending_user_review",
		"water_source":"res://tools/godot/river_plane_component.gd",
		"continuous_water_under_bridge":true,"deck_top":.95,"deck_width":BRIDGE_WIDTH,
		"navigation_validated":false,"instances":bridge_instances
	},"  "))
	quit()
