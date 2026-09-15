extends "res://plateau_base.gd"

# Standalone visual/collision kit. G2 placement and navigation remain authoritative.
const OUTPUT := "res://review/G4/kit_samples/earth_ridge_prototype"
const STEP := 0.5
const NX := 256
const NZ := 152
var erosion := FastNoiseLite.new()
var settings := {"length_m":112.0,"width_m":46.0,"height_m":25.0,"seed":91026,"bend_m":4.5}
var build_ms := 0

func centerline(x: float) -> float:
	return sin(x*.042)*float(settings.bend_m)+sin(x*.105+.6)*1.25

func elevation(x: float, z: float) -> float:
	var taper := 1.0-smoothstep(.60,1.0,absf(x)/(float(settings.length_m)*.5))
	if taper<=0.0: return 0.0
	var offset := z-centerline(x)
	var side := -1.0 if offset<0.0 else 1.0
	var distance := absf(offset)
	var width := float(settings.width_m)*.5*(.90+.11*sin(x*.11+.8)+.06*sin(x*.31))
	width *= .93 if side<0 else 1.07
	width *= sqrt(taper)
	var crest := float(settings.height_m)*(.83+.13*sin(x*.17+.8)+.08*sin(x*.37))
	# Branching ravines break up the flanks; their relief fades at the toe.
	var u := clampf(distance/width,0.0,1.0)
	var ribs := sin(x*.48+distance*.17*side+sin(x*.12)*1.2)
	var small_ribs := sin(x*.99+distance*.28+sin(distance*.19))
	var profile := pow(maxf(0.0,1.0-u),1.38)
	var relief := (ribs*1.65+small_ribs*.55)*sin(u*PI)*taper
	var crag := erosion.get_noise_2d(x,z)*1.35*smoothstep(0.0,.22,1.0-u)
	var h := crest*profile*taper+relief+crag*taper
	return maxf(0.0,h)*smoothstep(0.0,.14,1.0-u)

func ridge_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
uniform sampler2D sand_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D sand_normal : filter_linear_mipmap, repeat_enable;
uniform sampler2D rock_normal : filter_linear_mipmap, repeat_enable;
varying vec3 p;
varying vec3 wn;
void vertex(){p=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;wn=normalize(MODEL_NORMAL_MATRIX*NORMAL);}
void fragment(){
 vec3 weights=pow(abs(normalize(wn)),vec3(5.0));weights/=max(dot(weights,vec3(1.0)),.001);
 vec3 rock=texture(rock_tex,p.zy*.105).rgb*weights.x+texture(rock_tex,p.xz*.105).rgb*weights.y+texture(rock_tex,p.xy*.105).rgb*weights.z;
 vec3 sand=texture(sand_tex,p.xz*.05).rgb;
 float rock_luma=dot(rock,vec3(.299,.587,.114));
 float sand_luma=dot(sand,vec3(.299,.587,.114));
 float steep=1.0-smoothstep(.58,.88,wn.y);
 float exposed=steep*smoothstep(.6,5.0,p.y);
 float strata=sin(p.y*2.5+sin(p.x*.11)*1.1+sin(p.z*.21)*.65)*.025;
 vec3 soil=(sand_luma*1.08+.09)*vec3(.84,.61,.37);
 vec3 stone=(rock_luma*.80+.19+strata)*vec3(.72,.46,.27);
 ALBEDO=mix(soil,stone,exposed*.78);
 ROUGHNESS=.98;
 // Small texture-normal perturbation in view space; macro normals are geometry.
 vec3 detail=mix(texture(sand_normal,p.xz*.05).xyz,texture(rock_normal,p.xz*.105).xyz,exposed)*2.0-1.0;
 vec3 bumped=normalize(wn+vec3(detail.x,0.0,detail.y)*.13);
 NORMAL=normalize((VIEW_MATRIX*vec4(bumped,0.0)).xyz);
}
"""
	mat.shader=shader
	for id in ["sand_tex","rock_tex","sand_normal","rock_normal"]:
		var filename := str(id).replace("_tex","_diff")
		mat.set_shader_parameter(id,load("res://assets/terrain_pbr/"+filename+".jpg"))
	return mat

func make_ridge(parent: Node3D) -> MeshInstance3D:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var footprint: Array=[]
	var highest := 0.0
	for iz in range(NZ+1):
		var z := (iz-NZ*.5)*STEP
		for ix in range(NX+1):
			var x := (ix-NX*.5)*STEP
			var h := elevation(x,z)
			highest=maxf(highest,h)
			verts.append(Vector3(x,h,z))
			normals.append(Vector3(elevation(x-.15,z)-elevation(x+.15,z),.30,elevation(x,z-.15)-elevation(x,z+.15)).normalized())
	for iz in range(NZ):
		for ix in range(NX):
			var a := iz*(NX+1)+ix
			var b := a+1
			var c := a+NX+1
			var d := c+1
			# Godot front faces use clockwise winding when viewed from above.
			indices.append_array([a,b,c,b,d,c])
	for i in range(113):
		var x := -56.0+i
		var low := 0.0
		var high := 0.0
		for j in range(153):
			var z := -38.0+j*.5
			if elevation(x,z)>.5:
				if low==0.0: low=z
				high=z
		if high>low: footprint.append([x,low,high])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=verts
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_INDEX]=indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var inst := MeshInstance3D.new()
	inst.name="ContinuousEarthRidge"
	inst.mesh=mesh
	inst.material_override=ridge_material()
	parent.add_child(inst)
	inst.owner=parent
	var body := StaticBody3D.new()
	body.name="RidgeCollision"
	inst.add_child(body)
	body.owner=parent
	var collision := CollisionShape3D.new()
	collision.shape=mesh.create_trimesh_shape()
	body.add_child(collision)
	collision.owner=parent
	parent.set_meta("kit_id","earth_ridge_v1")
	parent.set_meta("intended_role","high_obstacle_nonbuildable")
	FileAccess.open(OUTPUT+"/footprint.json",FileAccess.WRITE).store_string(JSON.stringify({"sampling_m":.5,"blocking_candidate_x_zmin_zmax":footprint,"requires_g2_mapping":true},"  "))
	assert(highest>20.0 and highest<35.0)
	return inst

func run() -> void:
	if DisplayServer.get_name()=="headless":
		push_error("Image capture requires a rendering display; run --display-driver windows --rendering-method gl_compatibility, without --headless.")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var config_path := "res://tools/godot/earth_ridge_parameters.json"
	if FileAccess.file_exists(config_path): settings.merge(JSON.parse_string(FileAccess.get_file_as_string(config_path)),true)
	erosion.seed=int(settings.seed)
	erosion.frequency=.26
	erosion.fractal_octaves=3
	rng.seed=int(settings.seed)
	root.size=Vector2i(1800,1200)
	root.msaa_3d=Viewport.MSAA_4X
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color("b9c9d0")
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color("d6a06b")
	env.environment.ambient_light_energy=.34
	env.environment.tonemap_exposure=.78
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-48,-28,0)
	sun.light_energy=.78
	sun.shadow_enabled=true
	world.add_child(sun)
	var kit := Node3D.new()
	kit.name="EarthRidgeKit"
	world.add_child(kit)
	var ridge := make_ridge(kit)
	var ground := MeshInstance3D.new()
	ground.mesh=PlaneMesh.new()
	ground.mesh.size=Vector2(2000,2000)
	ground.position.y=-.035
	ground.material_override=ridge.material_override
	ground.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(ground)
	# Sparse fallen sandstone blocks, sourced from the same approved western kit.
	for i in range(58):
		var x := rng.randf_range(-48,48)
		var side := -1.0 if i%2==0 else 1.0
		var z := centerline(x)+side*rng.randf_range(12,22)
		var h := elevation(x,z)
		if h>7.0: continue
		var size := rng.randf_range(.45,1.6)
		piece(kit,"SM_Env_RockFlat_03",Vector3(x,h+size*.22,z),Vector3(size*1.4,size*.65,size),rng.randf_range(0,TAU))
	# Persist the actual renderable kit, with ownership for imported descendants.
	var queue: Array=[kit]
	while not queue.is_empty():
		var node: Node=queue.pop_back()
		for child in node.get_children():
			child.owner=kit
			queue.append(child)
	var packed := PackedScene.new()
	assert(packed.pack(kit)==OK)
	assert(ResourceSaver.save(packed,OUTPUT+"/earth_ridge.tscn")==OK)
	build_ms=Time.get_ticks_msec()-started
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.current=true
	var views := [
		{"name":"overview","pos":Vector3(80,80,115),"target":Vector3(0,5,0),"size":100.0},
		{"name":"flank_detail","pos":Vector3(14,35,73),"target":Vector3(3,10,0),"size":58.0},
		{"name":"reverse","pos":Vector3(-72,60,-115),"target":Vector3(0,7,0),"size":94.0}
	]
	for view in views:
		camera.position=view.pos
		camera.size=view.size
		camera.look_at(view.target)
		for frame in 12: await process_frame
		await RenderingServer.frame_post_draw
		var picture := root.get_texture().get_image()
		assert(picture!=null and not picture.is_empty())
		assert(picture.save_png(OUTPUT+"/"+view.name+".png")==OK)
		print("CAPTURED ",view.name)
	FileAccess.open(OUTPUT+"/component.json",FileAccess.WRITE).store_string(JSON.stringify({"kit_id":"earth_ridge_v1","status":"visual_prototype_pending_user_review","parameters":settings,"geometry":"continuous_eroded_heightfield","vertices":(NX+1)*(NZ+1),"triangles":NX*NZ*2,"build_ms":build_ms,"total_ms":Time.get_ticks_msec()-started,"render_engine":Engine.get_version_info(),"display_driver":DisplayServer.get_name(),"collision":"trimesh","navigation_validated":false,"g2_g4_integrated":false,"materials":["res://assets/terrain_pbr/sand_diff.jpg","res://assets/terrain_pbr/rock_diff.jpg","res://assets/terrain_pbr/sand_normal.jpg","res://assets/terrain_pbr/rock_normal.jpg"],"instances":records,"views":views},"  "))
	print("RIDGE_COMPLETE ",build_ms," ms build")
	quit()
