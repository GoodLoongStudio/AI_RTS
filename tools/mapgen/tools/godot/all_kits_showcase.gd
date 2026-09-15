extends "res://tools/godot/earth_ridge_component.gd"

const SHOWCASE := "res://review/G4/kit_samples/all_kits_showcase"
const RIVER_Z := 10.0
const LAKE_POS := Vector3(-67,-.27,103)
var shared_soil: ShaderMaterial
var assembled: Array=[]

class WaterPalette:
	static func apply(mat: ShaderMaterial) -> ShaderMaterial:
		mat.shader=load("res://tools/godot/showcase_water.gdshader")
		return mat

class PlateauBuilder:
	extends "res://tools/godot/modular_plateau_component.gd"
	const Butte = preload("res://tools/godot/sandstone_butte.gd")
	# Account for the non-uniform world scale when setting each face angle.
	const TARGET_SLOPE_DEGREES := 20.0
	const SIDE_SLOPE_DEGREES := 30.0
	const MAIN_EASE := .75
	const MAIN_RUN := HEIGHT * .40 / (.84 * tan(deg_to_rad(TARGET_SLOPE_DEGREES))) + MAIN_EASE
	const SIDE_RUN := HEIGHT * .40 / (.84 * tan(deg_to_rad(SIDE_SLOPE_DEGREES))) + MAIN_EASE
	const MAIN_INSET := MAIN_RUN * .80
	const MAIN_HALF_WIDTH := 10.0 / .84
	const MAIN_SHOULDER := 2.8
	var corner_bevel_enabled:=true
	func _initialize(): pass
	func run(): pass
	func main_axis() -> Vector2:
		return Vector2(cos(deg_to_rad(50.0))*MESA_SX,sin(deg_to_rad(50.0))*MESA_SZ).normalized()
	func main_start() -> Vector2:
		var angle:=deg_to_rad(50.0)
		return MESA_CENTER+Vector2(cos(angle)*MESA_SX,sin(angle)*MESA_SZ)*mesa_radius(angle)-main_axis()*MAIN_INSET
	func main_height(distance: float) -> float:
		return ramp_profile_height(distance,MAIN_RUN,MAIN_EASE)
	func main_spec() -> Dictionary:
		return {"role":"main","start":main_start(),"axis":main_axis(),"run":MAIN_RUN,"width":MAIN_HALF_WIDTH*2.0,"shoulder":MAIN_SHOULDER,"height":HEIGHT,"inset":MAIN_INSET,"style":"deep_inset","target_slope_degrees":TARGET_SLOPE_DEGREES}
	func mesa_radius(theta: float) -> float:
		return super.mesa_radius(theta)+sin(theta*13.0+.8)*.65+sin(theta*23.0)*.3
	func mesa_height(x: float,z: float,specs: Array) -> float:
		# Build the unbroken rim first. Cut lanes and raised rock masses share its
		# vertices, so an inset removes terrain instead of overlaying a ramp.
		var h:=super.mesa_height(x,z,[])
		var band:=smoothstep(1.0,4.0,h)*(1.0-smoothstep(14.0,18.0,h))
		h+=(sin(x*1.15+z*.72)*.65+sin(x*.43-z*1.1)*.55)*band
		var relief:=0.0
		for rock in Butte.plateau_specs():
			relief=maxf(relief,Butte.elevation(Vector2(x,z)-rock.center,rock.half_size,rock.height,rock.phase))
		h+=relief*smoothstep(HEIGHT*.3,HEIGHT*.95,h)
		for spec in specs:
			h=carve_lane(h,Vector2(x,z),spec.start,spec.axis,spec.run,spec.width*.5,spec.shoulder)
		return carve_lane(h,Vector2(x,z),main_start(),main_axis(),MAIN_RUN,MAIN_HALF_WIDTH,MAIN_SHOULDER)
	func carve_lane(h: float,point: Vector2,start: Vector2,axis: Vector2,run_length: float,half_width: float,shoulder: float) -> float:
		var delta:=point-start
		var along:=delta.dot(axis)
		var side:=absf(delta.cross(axis))
		# Complete the top join before the original cliff rolls over, even for
		# entrances whose slope starts at the rim instead of inside the plateau.
		var blend:=(1.0-smoothstep(half_width,half_width+shoulder,side))*smoothstep(-9.0,-6.0,along)
		var result:=lerpf(h,ramp_profile_height(along,run_length,MAIN_EASE),blend)
		# Small bevel on the upper rock corner only. The drive surface and its
		# original constant-width shoulder profile remain untouched below it.
		if corner_bevel_enabled and is_equal_approx(run_length,MAIN_RUN) and side>half_width+.5:
			var lateral:=smoothstep(half_width+.5,half_width+1.8,side)*(1.0-smoothstep(half_width+3.5,half_width+5.0,side))
			var corner:=smoothstep(MAIN_INSET-8.0,MAIN_INSET-5.0,along)*(1.0-smoothstep(MAIN_INSET-1.0,MAIN_INSET+2.0,along))
			result-=1.8*lateral*corner*smoothstep(HEIGHT-5.0,HEIGHT-1.0,result)
		return result
	func mesa_ramp_specs() -> Array:
		var specs: Array=[]
		# Narrower, steeper side entrances have only a small overlap with the rim.
		for entry in [[130.0,4.0,SIDE_RUN,6.0,2.8],[215.0,3.5,SIDE_RUN,5.5,2.8],[-35.0,4.0,SIDE_RUN,6.0,2.8]]:
			var angle:=deg_to_rad(entry[0])
			var radial:=Vector2(cos(angle)*MESA_SX,sin(angle)*MESA_SZ)
			var axis:=radial.normalized()
			var start: Vector2=MESA_CENTER+radial*mesa_radius(angle)-axis*entry[1]
			specs.append({"role":"secondary","az":angle,"start":start,"axis":axis,"inset":entry[1],"run":entry[2],"width":entry[3],"shoulder":entry[4],"style":"shallow_inset","target_slope_degrees":SIDE_SLOPE_DEGREES})
		return specs
	func secondary_junction_specs() -> Array:
		var result: Array=[]
		for spec in mesa_ramp_specs():
			var lanes: Array=[]
			var lateral:=Vector2(-spec.axis.y,spec.axis.x)
			for side in [-.42,0.0,.42]:
				lanes.append({"start":spec.start+lateral*spec.width*side,"axis":spec.axis,"run":spec.run})
			result.append({"azimuth_degrees":rad_to_deg(spec.az),"lanes":lanes,"inset":spec.inset,"style":spec.style})
		return result
	func piece(parent: Node3D,id: String,pos: Vector3,size: Vector3,yaw: float):
		for spec in mesa_ramp_specs():
			var local: Vector2=Vector2(pos.x,pos.z)-spec.start
			if local.dot(spec.axis)>-5.0 and local.dot(spec.axis)<spec.run+3.0 and absf(local.cross(spec.axis))<spec.width*.5+size.length()*.5:
				return
		var delta:=Vector2(pos.x,pos.z)-main_start()
		var along:=delta.dot(main_axis())
		if along>-5.0 and along<MAIN_RUN+3.0 and absf(delta.cross(main_axis()))<MAIN_HALF_WIDTH+size.length()*.5:
			return
		super.piece(parent,id,pos,size,yaw)

class BridgeBuilder:
	extends "res://tools/godot/river_bridge_component.gd"
	var shared_soil: ShaderMaterial
	var worn_metal: ShaderMaterial
	func _initialize(): pass
	func run(): pass
	func river_center(x: float) -> float:
		return sin(x*.022)*12.0+sin(x*.057+1.15)*5.0
	func river_half(x: float) -> float:
		return 14.0*(1.0+.10*sin(x*.031+.6)+.035*sin(x*.081))
	func terrain_material(_base: Color) -> ShaderMaterial: return shared_soil
	func water_material() -> ShaderMaterial:
		var mat:=super.water_material()
		return WaterPalette.apply(mat)
	func bridge_part(parent: Node3D,suffix: String,pos: Vector3,size: Vector3,yaw: float=0.0) -> void:
		super.bridge_part(parent,suffix,pos,size,yaw)
		if worn_metal==null:
			worn_metal=ShaderMaterial.new()
			worn_metal.shader=load("res://tools/godot/showcase_metal.gdshader")
			worn_metal.set_shader_parameter("base_tex",load(BRIDGE_BASE+"PolygonScifiWorlds_Texture_01_A.png"))
			worn_metal.set_shader_parameter("rock_tex",load("res://assets/terrain_pbr/rock_diff.jpg"))
			worn_metal.set_shader_parameter("rock_normal",load("res://assets/terrain_pbr/rock_normal.jpg"))
		var todo: Array=[parent.get_child(-1)]
		while not todo.is_empty():
			var node: Node=todo.pop_back()
			todo.append_array(node.get_children())
			if node is MeshInstance3D: node.material_override=worn_metal

class LakeBuilder:
	extends "res://tools/godot/lake_plane_component.gd"
	var shared_soil: ShaderMaterial
	func _initialize(): pass
	func run(): pass
	func terrain_material(_base: Color) -> ShaderMaterial: return shared_soil
	func water_material() -> ShaderMaterial:
		var mat:=super.water_material()
		return WaterPalette.apply(mat)
	func add_lake(parent: Node3D) -> void:
		super.add_lake(parent)
		var bank: MeshInstance3D=parent.get_child(1)
		var arrays:=bank.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		for i in vertices.size():
			var v:=vertices[i]
			var q:=Vector2(v.x/1.25,v.z/.90)
			var radius:=lake_radius(q.angle())
			var t:=clampf((q.length()-radius)/2.4,0.0,1.0)
			var direction:=q.normalized()
			vertices[i]=Vector3(direction.x*1.25*(radius+t*4.5),lerpf(0.0,.85,smoothstep(0.0,1.0,t)),direction.y*.90*(radius+t*4.5))
		arrays[Mesh.ARRAY_VERTEX]=vertices
		var mesh:=ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var st:=SurfaceTool.new()
		st.create_from(mesh,0)
		st.index()
		st.generate_normals()
		bank.mesh=st.commit()

func release_builder(builder: SceneTree) -> void:
	# These legacy builders are SceneTrees with private roots. Godot owns their
	# native Window handles; freeing them during the render pass can corrupt the
	# heap on Windows, so let the process reclaim them after the capture.
	return

func strip_flat_ground(inst: MeshInstance3D) -> void:
	var a:=inst.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array=a[Mesh.ARRAY_VERTEX]
	var old: PackedInt32Array=a[Mesh.ARRAY_INDEX]
	var kept:=PackedInt32Array()
	for i in range(0,old.size(),3):
		if maxf(vertices[old[i]].y,maxf(vertices[old[i+1]].y,vertices[old[i+2]].y))>.035:
			kept.append_array([old[i],old[i+1],old[i+2]])
	a[Mesh.ARRAY_INDEX]=kept
	var mesh:=ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,a)
	inst.mesh=mesh

func is_plant(node: Node) -> bool:
	while node!=null:
		if "Cactus" in str(node.name): return true
		node=node.get_parent()
	return false

func weather_plant(node: MeshInstance3D) -> void:
	for surface in node.mesh.get_surface_count():
		var original:=node.get_active_material(surface)
		if original is StandardMaterial3D:
			var mat:=original.duplicate() as StandardMaterial3D
			mat.albedo_color=Color(.78,.84,.56)
			mat.roughness=1.0
			node.set_surface_override_material(surface,mat)

func mountain(parent: Node3D,id: String,path: String,pos: Vector3,scale_value: Vector3,yaw: float=0.0) -> void:
	var kit: Node3D=load(path).instantiate()
	kit.name=id
	kit.position=pos
	kit.scale=scale_value
	kit.rotation.y=yaw
	parent.add_child(kit)
	var todo: Array=[kit]
	while not todo.is_empty():
		var node: Node=todo.pop_back()
		todo.append_array(node.get_children())
		if node is MeshInstance3D and not is_plant(node):
			node.material_override=shared_soil
			if node.name=="ContinuousEarthRidge": strip_flat_ground(node)
		elif node is MeshInstance3D:
			weather_plant(node)
	assembled.append({"id":id,"source":path,"position":pos,"scale":scale_value,"yaw":yaw})

func river(parent: Node3D,b: BridgeBuilder) -> void:
	var wv: Array=[]
	var wi: Array=[]
	var banks: Array=[]
	var bi: Array=[]
	const SEG := 920
	for i in range(SEG+1):
		var x: float=-230+i*.5
		var c:=b.river_center(x)
		var half:=b.river_half(x)
		wv.append_array([Vector3(x,-.02,c-half),Vector3(x,-.02,c+half)])
		for side in [-1.0,1.0]:
			banks.append_array([Vector3(x,0,c+side*half),Vector3(x,.34,c+side*(half+1.8)),Vector3(x,.85,c+side*(half+4.5))])
	for i in range(SEG):
		var q:=i*2
		wi.append_array([q,q+2,q+3,q,q+3,q+1])
		for side in range(2):
			var s:=i*6+side*3
			bi.append_array([s,s+6,s+7,s,s+7,s+1,s+1,s+7,s+8,s+1,s+8,s+2])
	b.mesh_from_arrays(parent,banks,bi,shared_soil)
	var bank: MeshInstance3D=parent.get_child(0)
	bank.name="RiverBanks"
	var st:=SurfaceTool.new()
	st.create_from(bank.mesh,0)
	st.index()
	st.generate_normals()
	bank.mesh=st.commit()
	b.mesh_from_arrays(parent,wv,wi,b.water_material())
	parent.get_child(1).name="RiverSurface"
	# Bridge parts retain their original deck elevation as the water is lowered.
	var before_bridge:=parent.get_child_count()
	b.add_bridge(parent)
	for child in parent.get_children().slice(before_bridge):
		child.position.y+=.58
	assembled.append({"id":"river_and_bridge","source":"river_bridge_component.gd","position":parent.position,"length_m":460,"bridge_instances":b.bridge_instances})

func make_ground(parent: Node3D) -> void:
	var ground:=MeshInstance3D.new()
	ground.name="ContinuousBasin"
	ground.mesh=PlaneMesh.new()
	ground.mesh.size=Vector2(460,350)
	var material:=shared_soil.duplicate()
	material.set_shader_parameter("cut_water",true)
	ground.material_override=material
	ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ground)
	# Physical bed under both water bodies, kept separate from navigation semantics.
	var bed:=MeshInstance3D.new()
	bed.name="BasinBed"
	bed.mesh=ground.mesh
	bed.position.y=-2.0
	bed.material_override=shared_soil
	bed.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(bed)

func dress_shores(parent: Node3D, builder: BridgeBuilder) -> void:
	var dressing:=Node3D.new()
	dressing.name="ShoreStones"
	parent.add_child(dressing)
	rng.seed=91041
	var clusters: Array=[]
	for x in [-192.0,-138.0,-91.0,-26.0,69.0,111.0,174.0,205.0]:
		var side: float=-1.0 if clusters.size()%2==0 else 1.0
		clusters.append(Vector3(x,0,RIVER_Z+builder.river_center(x)+side*(builder.river_half(x)+7.0)))
	for angle in [.2,1.7,2.7,4.0,5.1]:
		var radius:=29.0*(1.0+.13*sin(3.0*angle+.4)+.065*cos(5.0*angle-1.0))+7.0
		clusters.append(Vector3(LAKE_POS.x+cos(angle)*radius*1.25,0,LAKE_POS.z+sin(angle)*radius*.90))
	for center in clusters:
		for i in range(rng.randi_range(3,6)):
			var pos: Vector3=center+Vector3(rng.randf_range(-2.0,2.0),0,rng.randf_range(-1.5,1.5))
			var size:=rng.randf_range(.5,1.8)
			pos.y=size*.24
			piece(dressing,"SM_Env_RockFlat_03",pos,Vector3(size*1.5,size*.7,size),rng.randf_range(0,TAU))
	var todo: Array=[dressing]
	while not todo.is_empty():
		var node: Node=todo.pop_back()
		todo.append_array(node.get_children())
		if node is MeshInstance3D: node.material_override=shared_soil
	assembled.append({"id":"shore_stones","seed":91041,"clusters":clusters.size(),"instances":records.duplicate(true)})

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Showcase capture needs the Windows graphics display")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(SHOWCASE)
	var started:=Time.get_ticks_msec()
	root.size=Vector2i(2200,1500)
	root.msaa_3d=Viewport.MSAA_4X
	shared_soil=ridge_material()
	shared_soil.shader=load("res://tools/godot/showcase_land.gdshader")
	# All dirt surfaces, from wet bank lips to plateau and mountain tops,
	# use precisely this shared material and world-space texture density.
	assert(ResourceSaver.save(shared_soil,SHOWCASE+"/unified_sandstone.tres")==OK)
	var world:=Node3D.new()
	world.name="AllKitsShowcase"
	root.add_child(world)
	var env:=WorldEnvironment.new()
	env.name="SharedLighting"
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color("b9d5d9")
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("f0f2f5")
	env.environment.ambient_light_energy=.32
	env.environment.tonemap_exposure=1.0
	world.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.name="Sun"
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.light_color=Color("fffaf3")
	sun.light_energy=.80
	sun.shadow_enabled=true
	sun.shadow_opacity=.72
	sun.directional_shadow_max_distance=800.0
	sun.shadow_blur=2.0
	world.add_child(sun)
	var pb:=PlateauBuilder.new()
	pb.rng.seed=32871
	var plateau:=Node3D.new()
	plateau.name="PlateauAndRamps"
	plateau.position=Vector3(-61,0,-89)
	plateau.scale=Vector3(.84,.40,.84)
	var lane_start:=Vector2(plateau.position.x,plateau.position.z)+pb.main_start()*plateau.scale.x
	var lane_axis:=pb.main_axis()
	shared_soil.set_shader_parameter("main_lane",Vector4(lane_start.x,lane_start.y,lane_axis.x,lane_axis.y))
	shared_soil.set_shader_parameter("main_run",pb.MAIN_RUN*plateau.scale.x)
	shared_soil.set_shader_parameter("main_width",pb.MAIN_HALF_WIDTH*2.0*plateau.scale.x)
	assert(ResourceSaver.save(shared_soil,SHOWCASE+"/unified_sandstone.tres")==OK)
	make_ground(world)
	world.add_child(plateau)
	pb.add_sculpted_terrain(plateau)
	plateau.set_meta("main_ramp",pb.main_spec())
	plateau.set_meta("ramp_specs",pb.mesa_ramp_specs())
	plateau.set_meta("secondary_ramp_junctions",pb.secondary_junction_specs())
	plateau.set_meta("raised_buttes",pb.Butte.plateau_specs())
	for child in plateau.get_children():
		if child is MeshInstance3D:
			strip_flat_ground(child)
			child.material_override=shared_soil
		else:
			var parts: Array=[child]
			while not parts.is_empty():
				var part: Node=parts.pop_back()
				parts.append_array(part.get_children())
				if part is MeshInstance3D and not is_plant(part):
					part.material_override=shared_soil
				elif part is MeshInstance3D:
					weather_plant(part)
	assembled.append({"id":"plateau_and_ramps","source":"all_kits_showcase.gd:PlateauBuilder","geometry":"shared_heightfield_incised_ramps_and_raised_buttes","position":plateau.position,"scale":plateau.scale,"main_ramp":pb.main_spec(),"ramp_specs":pb.mesa_ramp_specs(),"raised_buttes":pb.Butte.plateau_specs(),"instances":pb.records.duplicate(true)})
	var wb:=BridgeBuilder.new()
	wb.shared_soil=shared_soil
	var water:=Node3D.new()
	water.name="RiverAndBridge"
	water.position=Vector3(0,-.85,RIVER_Z)
	world.add_child(water)
	river(water,wb)
	assert(ResourceSaver.save(wb.worn_metal,SHOWCASE+"/weathered_metal.tres")==OK)
	dress_shores(world,wb)
	release_builder(wb)
	var lb:=LakeBuilder.new()
	lb.shared_soil=shared_soil
	var lake:=Node3D.new()
	lake.name="Lake"
	lake.position=Vector3(LAKE_POS.x,-.85,LAKE_POS.z)
	world.add_child(lake)
	lb.add_lake(lake)
	assembled.append({"id":"lake","source":"lake_plane_component.gd","position":LAKE_POS})
	release_builder(lb)
	mountain(world,"LongRidge","res://review/G4/kit_samples/earth_ridge_prototype/earth_ridge.tscn",Vector3(77,0,-111),Vector3(.65,.70,.65))
	mountain(world,"ArcRidge","res://review/G4/kit_samples/earth_ridge_combinations/arc_ridge/component.tscn",Vector3(108,0,115),Vector3(.60,.68,.60),PI)
	mountain(world,"OffsetRidges","res://review/G4/kit_samples/earth_ridge_combinations/offset_ridges/component.tscn",Vector3(-164,0,-109),Vector3(.42,.58,.44),-.25)
	mountain(world,"MountainCluster","res://review/G4/kit_samples/earth_ridge_combinations/mountain_cluster/component.tscn",Vector3(-163,0,94),Vector3(.44,.62,.44),.25)
	var variety=load("res://tools/godot/mountain_variety.gd")
	for spec in variety.catalog():
		var group: Node3D=variety.build(spec,shared_soil)
		world.add_child(group)
		assembled.append({"id":spec.id,"source":"mountain_variety.gd","position":spec.position,"masses":spec.masses,"geometry":"continuous_heightfield"})
	var units = load("res://tools/godot/showcase_units.gd").new()
	units.populate(world,plateau,pb)
	assembled.append({"id":"scale_reference_units","source":"AI_RTS/source/match/units","instances":units.records})
	assembled.append({"id":"base_development_reference","instances":world.get_meta("scale_base")})
	release_builder(pb)
	var camera:=Camera3D.new()
	camera.name="InspectionCamera"
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.current=true
	world.add_child(camera)
	var views: Array=[
		{"name":"overview","pos":Vector3(155,340,395),"target":Vector3(0,0,0),"size":392.0},
		{"name":"plateau_bridge","pos":Vector3(30,165,155),"target":Vector3(-38,0,-48),"size":194.0},
		{"name":"lake_mountains","pos":Vector3(20,180,265),"target":Vector3(-35,2,103),"size":217.0},
		{"name":"top","pos":Vector3(0,450,.01),"target":Vector3.ZERO,"size":370.0},
		{"name":"bank_detail","pos":Vector3(51,42,83),"target":Vector3(18,0,20),"size":66.0},
		{"name":"main_ramp","pos":Vector3(-2,33,-15),"target":Vector3(-39,4,-67),"size":48.0},
		{"name":"left_ramp_junction","pos":Vector3(-101,33,-17),"target":Vector3(-82,5,-73),"size":40.0},
		{"name":"plateau_buttes","pos":Vector3(-5,55,-14),"target":Vector3(-54,12,-115),"size":72.0},
		{"name":"mountain_varieties","pos":Vector3(90,105,210),"target":Vector3(35,6,96),"size":145.0},
		{"name":"combat_plateau","pos":Vector3(-25,84,2),"target":Vector3(-60,3,-87),"size":112.0},
		{"name":"combat_units","pos":Vector3(-60,29,-35),"target":Vector3(-60,7.2,-76),"size":28.0},
		{"name":"combat_ridge","pos":Vector3(93,52,-41),"target":Vector3(77,5,-100),"size":78.0},
		{"name":"combat_bridge","pos":Vector3(29,20,44),"target":Vector3(18,.6,19),"size":20.0}
	]
	var build_time:=Time.get_ticks_msec()-started
	for view in views:
		camera.position=view.pos
		camera.size=view.size
		camera.look_at(view.target)
		for frame in 16: await process_frame
		await RenderingServer.frame_post_draw
		var screenshot:=root.get_texture().get_image()
		assert(screenshot!=null and not screenshot.is_empty())
		assert(screenshot.save_png(SHOWCASE+"/"+view.name+".png")==OK)
		print("SHOWCASE_CAPTURED ",view.name)
	camera.position=views[0].pos
	camera.size=views[0].size
	camera.look_at(views[0].target)
	var queue: Array=[world]
	while not queue.is_empty():
		var node: Node=queue.pop_back()
		for child in node.get_children():
			child.owner=world
			queue.append(child)
	var packed:=PackedScene.new()
	assert(packed.pack(world)==OK)
	assert(ResourceSaver.save(packed,SHOWCASE+"/all_kits.tscn")==OK)
	FileAccess.open(SHOWCASE+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({"id":"all_kits_material_showcase","version":12,"scale_basis":"AI_RTS game units","plateau_height":7.2,"main_ramp_width":20.0,"rock_corner_bevel_depth_m":0.72,"tank_avoidance_diameter":1.8,"style":"sunlit_sandstone_canyon","status":"pending_user_visual_review","plateau_version":"20_degree_deep_main_30_degree_shallow_sides","main_slope_degrees":20.0,"side_slope_degrees":30.0,"render_engine":Engine.get_version_info(),"display_driver":DisplayServer.get_name(),"build_ms":build_time,"shared_land_material":"unified_sandstone.tres","bridge_material":"weathered_metal.tres","water_material":"res://tools/godot/showcase_water.gdshader","water_shape_source":"res://tools/godot/showcase_shapes.gdshaderinc","water_level":-.87,"shore_width":4.5,"components":assembled,"views":views,"g2_g4_integrated":false,"navigation_validated":false},"  "))
	print("SHOWCASE_COMPLETE build_ms=",build_time)
	world.queue_free()
	await process_frame
	await process_frame
	call_deferred("quit")






