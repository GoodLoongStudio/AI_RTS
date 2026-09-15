extends SceneTree

const OUT := "res://review/G4/g2_large_lake_kits"
const Kit = preload("res://tools/godot/all_kits_showcase.gd")
const Variety = preload("res://tools/godot/mountain_variety.gd")
const PBR := "res://assets/terrain_pbr/"
var world: Node3D
var soil: ShaderMaterial
var fields: PackedFloat32Array
var masks: PackedFloat32Array
var cell: float
var n: int
var source_n: int
var preview_mode := false
var logical_cell: float
var out_dir := OUT
var debug_masks := 0.0
var terrain_heights := PackedFloat32Array()
var rock_noise: FastNoiseLite
var crag_noise: FastNoiseLite
var range_noise: FastNoiseLite
var grit_noise: FastNoiseLite
var decorations := 0

func sample_height(point: Vector2) -> float:
	var x := clampf(point.x/cell,0,n-1.001)
	var z := clampf(point.y/cell,0,n-1.001)
	var ix := int(x)
	var iz := int(z)
	return lerpf(lerpf(terrain_heights[iz*n+ix],terrain_heights[iz*n+ix+1],x-ix),lerpf(terrain_heights[(iz+1)*n+ix],terrain_heights[(iz+1)*n+ix+1],x-ix),z-iz)

func approach(start: Vector2, direction: Vector2, width: float, material: Material) -> void:
	var v := PackedVector3Array()
	var idx := PackedInt32Array()
	var lateral := Vector2(-direction.y,direction.x)
	for row in range(17):
		for side in [-1,1]:
			var point: Vector2 = start+direction*row*1.5+lateral*side*(width*.5+row*.20)
			v.append(Vector3(point.x,sample_height(point)+.035,point.y))
		if row>0:
			var a := (row-1)*2
			idx.append_array([a,a+1,a+2,a+1,a+3,a+2])
	mesh_node(v,idx,material,"BridgeApproach")

func _initialize() -> void:
	call_deferred("run")

func tex(name: String) -> Texture2D:
	# Headless renders must work before the editor importer has produced .import files.
	var image := Image.load_from_file(ProjectSettings.globalize_path(PBR + name))
	if image == null or image.is_empty():
		push_error("texture unavailable: " + name)
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func mesh_node(vertices: PackedVector3Array, indices: PackedInt32Array, material: Material,
		label: String, uvs := PackedVector2Array(), uv2s := PackedVector2Array()) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if uv2s.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var surface := SurfaceTool.new()
	surface.create_from(mesh,0)
	surface.generate_normals()
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = surface.commit()
	node.material_override = material
	world.add_child(node)
	return node

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--debug-masks":
			debug_masks = 1.0
		elif arg == "--debug-rings":
			debug_masks = 2.0
		elif arg.begins_with("--out="):
			out_dir = arg.substr(6)
	DirAccess.make_dir_recursive_absolute(out_dir)
	rock_noise = FastNoiseLite.new()
	rock_noise.seed = 20260912
	rock_noise.frequency = .012
	rock_noise.fractal_octaves = 3
	crag_noise = FastNoiseLite.new()
	crag_noise.seed = 20260913
	crag_noise.frequency = 0.13
	crag_noise.fractal_octaves = 4
	crag_noise.fractal_lacunarity = 2.1
	# Range-axis field: an ultra-low-frequency direction field whose wavelength
	# (~300 m) spans many 48 m tiles. Every tile reads its ridge heading from this
	# one field, so neighbouring masses line up nose-to-tail into continuous
	# ranges instead of each tile planting an independently oriented hill.
	range_noise = FastNoiseLite.new()
	range_noise.seed = 20260914
	range_noise.frequency = 0.0032
	range_noise.fractal_octaves = 2
	# Face-breaking noise (~55 m facets): modulates the relief term so close views
	# show large fractured rock faces. High frequencies here grow spike forests
	# instead of rock faces - the big facets carry the shape, crag adds the grain.
	grit_noise = FastNoiseLite.new()
	grit_noise.seed = 20260915
	grit_noise.frequency = 0.11
	grit_noise.fractal_octaves = 2
	var input: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OUT+"/input.json"))
	source_n = int(input.vertex_size)
	n = source_n
	cell = float(input.cell_m)
	preview_mode = "--preview" in OS.get_cmdline_user_args()
	if preview_mode:
		# Keep the full authoritative 1025x1025 raster in previews. The previous
		# 2x decimation visibly narrowed and stair-stepped the river banks.
		n = source_n
		cell = float(input.cell_m)
	logical_cell = float(input.logical_cell_m)
	fields = FileAccess.get_file_as_bytes(OUT+"/fields.bin").to_float32_array()
	masks = FileAccess.get_file_as_bytes(OUT+"/masks.bin").to_float32_array()
	root.size = Vector2i(1400,1000) if preview_mode else Vector2i(2200,1800)
	world = Node3D.new()
	world.name = "G2LargeLakeKitMap"
	root.add_child(world)
	soil = load("res://review/G4/kit_samples/all_kits_showcase/unified_sandstone.tres").duplicate()
	# 1. main desert floor + its gravel detail
	soil.set_shader_parameter("sand_tex",tex("sand_uniform_diff.jpg"))  # 无缝各向同性沙地（替换带风纹照片的 dense_sand）
	soil.set_shader_parameter("sand_normal",tex("dense_sand_normal.jpg"))
	soil.set_shader_parameter("detail_tex",tex("sand_01_diff.jpg"))
	# 2. plateau tops
	soil.set_shader_parameter("top_tex",tex("moon_dusted_03_diff.jpg"))
	# 3. plateau cliff walls
	soil.set_shader_parameter("cliff_tex",tex("cliff_side_diff.jpg"))
	soil.set_shader_parameter("cliff_normal",tex("cliff_side_normal.jpg"))
	# 4. blocking mountains
	soil.set_shader_parameter("rock_tex",tex("dark_rock_02_diff.jpg"))
	soil.set_shader_parameter("rock_normal",tex("dark_rock_02_normal.jpg"))
	soil.set_shader_parameter("detail2_tex",tex("gray_rocks_diff.jpg"))
	# 5./6. river banks and lake shore
	soil.set_shader_parameter("bank_tex",tex("brown_mud_02_diff.jpg"))
	soil.set_shader_parameter("shore_tex",tex("damp_beach_sand_02_diff.jpg"))
	# 7. ramps
	soil.set_shader_parameter("ramp_tex",tex("dirt_aerial_02_diff.jpg"))
	# Four single-pass macro albedo fields; semantic masks decide where each appears.
	soil.set_shader_parameter("macro_sand_tex",tex("image25_macro_sand.png"))
	soil.set_shader_parameter("macro_gravel_tex",tex("image25_macro_gravel.png"))
	soil.set_shader_parameter("macro_rock_tex",tex("image25_macro_rock.png"))
	soil.set_shader_parameter("macro_wet_shore_tex",tex("image25_macro_wet_shore.png"))
	soil.set_shader_parameter("macro_albedo",tex("image25_macro_sand.png"))
	soil.set_shader_parameter("use_macro_albedo",true)
	# Macro fields drive the far view; retain a restrained legacy detail pass
	# so close inspection does not become a blurred colour card.
	soil.set_shader_parameter("macro_strength",0.72)
	soil.set_shader_parameter("use_masks",1.0)
	soil.set_shader_parameter("debug_masks",debug_masks)
	soil.set_shader_parameter("cut_water",false)
	soil.set_shader_parameter("main_run",0.0)
	soil.set_shader_parameter("main_width",0.0)
	soil.set_shader_parameter("ground_height",0.6*logical_cell)
	soil.set_shader_parameter("top_height",0.6*logical_cell+float(input.plateau_height_m))
	# The authoritative geometry supplies banks; disable showcase-only shore masks.
	soil.set_shader_parameter("river_z",-10000.0)
	soil.set_shader_parameter("lake_position",Vector2(-10000,-10000))
	soil.set_shader_parameter("showcase_world_scale",1.0)
	soil.set_shader_parameter("normal_strength",.022)
	soil.set_shader_parameter("bank_width",18.0)
	soil.set_shader_parameter("shore_width",42.0)
	var vertices := PackedVector3Array()
	var water_vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var water_indices := PackedInt32Array()
	var water_uv := PackedVector2Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var catalog := Variety.catalog()
	var plateau_builder := Kit.PlateauBuilder.new()
	var lanes: Array = []
	# Preserve the kit's horizontal/vertical ratio, hence its 20/30 degree slopes.
	var sx := 1.4
	var sy := 2.0/3.0
	for pl in input.plateaus:
		for ri in pl.ramp_centers.size():
			var rc: Array = pl.ramp_centers[ri]
			var rd: Array = pl.ramp_dirs[ri]
			var axis := -Vector2(rd[0],rd[1]).normalized()
			var run_length := Kit.PlateauBuilder.MAIN_RUN if ri==0 else Kit.PlateauBuilder.SIDE_RUN
			var inset := Kit.PlateauBuilder.MAIN_INSET if ri==0 else 3.5
			lanes.append({"start":Vector2(rc[0],rc[1])*logical_cell/sx-axis*inset,"axis":axis,"run":run_length,"half":Kit.PlateauBuilder.MAIN_HALF_WIDTH if ri==0 else 3.0})
	for z in range(n):
		for x in range(n):
			var index := z*n+x
			var sx_i := mini(x, source_n - 1)
			var sz_i := mini(z, source_n - 1)
			var source_index := sz_i * source_n + sx_i
			# plane 1 is the EDT depth inside a rock mass (0 outside), in 1025-grid
			# units, so it doubles as the on-rock test and as the flank rise ramp.
			var rock_depth := fields[source_n*source_n+source_index]
			var rock_outer := fields[3*source_n*source_n+source_index]
			var h := fields[source_index]*logical_cell
			var point := Vector2(x,z)*cell/sx
			var ramp_mask := 0.0
			for lane in lanes:
				var delta: Vector2 = point-lane.start
				var along := delta.dot(lane.axis)
				var side := absf(delta.cross(lane.axis))
				if along > -9 and along < lane.run+3 and absf(delta.cross(lane.axis)) < lane.half+7:
					h = .6*logical_cell+sy*plateau_builder.carve_lane((h-.6*logical_cell)/sy,point,lane.start,lane.axis,lane.run,lane.half,5.0)
				ramp_mask = maxf(ramp_mask,(1.0-smoothstep(lane.half,lane.half+5.0,side))
					*smoothstep(-4.0,1.0,along)*(1.0-smoothstep(lane.run-2.0,lane.run+3.0,along)))
			var rock_mask := 0.0
			# 权威高度（fields[0]）已由 Python 单一事实源（g4_terrain_mountains）
			# 烘入完整山体：岩体/侵蚀/扇顶基座/沙丘全部就位。渲染器只保留着色
			# 掩码（rise/fan）供 shader 的 rock/talus 分层，不再自行计算 relief。
			var rise := smoothstep(0.0, 10.0, rock_depth)
			if rock_depth > 0:
				rock_mask = rise
			elif rock_outer > 0.0:
				rock_mask = smoothstep(14.0, 0.0, rock_outer) * 0.30
			else:
				# Dune swells on the open floor: ALBEDO noise cannot shade a flat
				# plane - without geometric undulation the desert reads as one flat
				# beige card in every RTS frame. ~50 m wavelength, half-metre lift:
				# soft shading, no navigable slope impact (render-only height).
				var dune := rock_noise.get_noise_2d(float(x)*1.7+97.0,float(z)*1.7-13.0)
				h += dune*0.55
			var plateau_d := masks[2*source_n*source_n+source_index]
			# The authoritative heightfield steps from desert (0.6) onto the plateau
			# top across ONE cell, which rasterizes into a sawtooth cliff line at
			# every mesa rim. Soften exactly that rim band into a ~5 m steep slope:
			# still a cliff, no longer a staircase. Ramp lanes are carved above and
			# must keep their exact 20/30 degree geometry, so they gate the blend.
			var band_w := 1.0-smoothstep(5.0,12.0,absf(plateau_d))
			if band_w > 0.0 and ramp_mask < 0.05:
				var target := lerpf(.6*logical_cell,h,1.0-smoothstep(-7.0,1.0,plateau_d))
				h = lerpf(h,target,band_w)
			vertices.append(Vector3(x*cell,h,z*cell))
			terrain_heights.append(h)
			water_vertices.append(Vector3(x*cell,0,z*cell))
			water_uv.append(Vector2(fields[2*source_n*source_n+source_index]*logical_cell,maxf(0.0,-h)))
			uvs.append(Vector2(masks[2*source_n*source_n+source_index],masks[source_index]))
			uv2s.append(Vector2(masks[source_n*source_n+source_index],rock_mask if rock_mask>0.0 else -ramp_mask))
	for z in range(n-1):
		for x in range(n-1):
			var a := z*n+x
			indices.append_array([a,a+1,a+n,a+1,a+n+1,a+n])
			# Extend the water plane past the rasterised footprint, up the bank
			# slopes, so the visible shoreline is the smooth terrain/water
			# intersection instead of the staircase of the footprint mask.
			var ax := mini(x, source_n - 1)
			var az := mini(z, source_n - 1)
			var aa := az * source_n + ax
			var ab := az * source_n + mini(ax + 1, source_n - 1)
			var ac := mini(az + 1, source_n - 1) * source_n + ax
			var ad := mini(az + 1, source_n - 1) * source_n + mini(ax + 1, source_n - 1)
			# Visual water surface uses a slightly expanded contour so the channel
			# remains continuous through bridge approaches; authoritative masks stay
			# untouched and still drive gameplay/navigation.
			if minf(minf(fields[aa],fields[ab]),minf(fields[ac],fields[ad])) < 0.72:
				water_indices.append_array([a,a+1,a+n,a+1,a+n+1,a+n])
	var terrain := mesh_node(vertices,indices,soil,"G2TerrainAndKitRockMasses",uvs,uv2s)
	print("TERRAIN_FORMAT ",terrain.mesh.surface_get_format(0)," expect_uv=",Mesh.ARRAY_FORMAT_TEX_UV," uv2=",Mesh.ARRAY_FORMAT_TEX_UV2)
	terrain.create_trimesh_collision()
	var water := ShaderMaterial.new()
	water.shader = load("res://tools/godot/showcase_water.gdshader")
	water.set_shader_parameter("rock_tex",tex("dense_sand_diff.jpg"))
	water.set_shader_parameter("sand_normal",tex("dense_sand_normal.jpg"))
	var shader := Shader.new()
	shader.code = water.shader.code.replace("float edge=max(0.0,-(lake_mode ? lake_distance(p.xz) : river_distance(p.xz)));","float edge=max(0.0,UV.x);")
	water.shader = shader
	water.set_shader_parameter("showcase_world_scale",1.0)
	water.set_shader_parameter("terrain_depth",true)
	var water_node := mesh_node(water_vertices,water_indices,water,"G2WaterWithKitMaterial",water_uv)
	var wa := []
	wa.resize(Mesh.ARRAY_MAX)
	wa[Mesh.ARRAY_VERTEX] = water_vertices
	wa[Mesh.ARRAY_INDEX] = water_indices
	var water_normals := PackedVector3Array()
	water_normals.resize(water_vertices.size())
	water_normals.fill(Vector3.UP)
	wa[Mesh.ARRAY_NORMAL] = water_normals
	wa[Mesh.ARRAY_TEX_UV] = water_uv
	var wm := ArrayMesh.new()
	wm.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,wa)
	water_node.mesh = wm
	var builder := Kit.BridgeBuilder.new()
	builder.shared_soil = soil
	# Preserve the accepted bridge appearance from BridgeBuilder. Its original
	# PolygonSciFiWorlds texture and weathered-metal shader must remain isolated
	# from terrain macro albedo textures.
	builder.worn_metal = null
	var approach_material := soil.duplicate() as ShaderMaterial
	approach_material.set_shader_parameter("use_masks",0.0)
	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color("6f5a43")
	trim.roughness = .9
	for b in input.bridges:
		var start := Vector2(b.a[0],b.a[1])*logical_cell
		var end := Vector2(b.b[0],b.b[1])*logical_cell
		var direction := (end-start).normalized()
		var yaw := atan2(direction.x,direction.y)
		var length := start.distance_to(end)
		var width := float(b.width)*logical_cell
		var count := ceili(length/8.0)
		var span := length/count
		var group := Node3D.new()
		group.name = "KitBridge"+str(world.get_child_count())
		world.add_child(group)
		approach(start,-direction,width,approach_material)
		approach(end,direction,width,approach_material)
		# Bridgeheads and short expansion joints use the game's muted industrial palette.
		for endpoint in [start,end]:
			for sign_side in [-1,1]:
				var position: Vector2 = endpoint+Vector2(direction.y,-direction.x)*sign_side*(width*.5+.65)
				var post := MeshInstance3D.new()
				var block := BoxMesh.new()
				block.size = Vector3(2.2,2.2,3.0)
				post.mesh = block
				post.material_override = trim
				post.position = Vector3(position.x,.6*logical_cell+.5,position.y)
				post.rotation.y = yaw
				group.add_child(post)
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(width,.7,length)
		collision.shape = box
		body.add_child(collision)
		body.position = Vector3((start.x+end.x)*.5,.6*logical_cell-.35,(start.y+end.y)*.5)
		body.rotation.y = yaw
		group.add_child(body)
		for i in range(count):
			var at := start+direction*(i+.5)*span
			builder.bridge_part(group,"",Vector3(at.x,.6*logical_cell-.35,at.y),Vector3(width,.7,span),yaw)
			for side in [-1,1]:
				var offset: Vector2 = Vector2(direction.y,-direction.x)*side*(width*.5-.3)
				builder.bridge_part(group,"_Rail",Vector3(at.x+offset.x,.6*logical_cell+.65,at.y+offset.y),Vector3(.65,1.3,span),yaw)
	# ---- 装饰层（G2 decoration_hints → G4 VisualPlan）：collision=false、不进导航 ----
	var decor_file := out_dir+"/decorations.json"
	if not FileAccess.file_exists(decor_file):
		decor_file = OUT+"/decorations.json"
	if FileAccess.file_exists(decor_file) and not ("--no-decor" in OS.get_cmdline_user_args()):
		var ddata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(decor_file))
		var dgroup := Node3D.new()
		dgroup.name = "Decorations"
		world.add_child(dgroup)
		var scenes := {}
		var dmats := {}
		for inst in ddata.instances:
			var res: String = str(inst.res)
			if not scenes.has(res):
				scenes[res] = load(res)
			var packed = scenes[res]
			if packed == null:
				continue
			var atlas: String = str(inst.atlas)
			if not dmats.has(atlas):
				var mm := StandardMaterial3D.new()
				mm.albedo_texture = load(atlas)
				mm.roughness = .92
				mm.specular = .12
				dmats[atlas] = mm
			var model: Node3D = packed.instantiate()
			dgroup.add_child(model)
			var s := float(inst.scale)
			model.scale = Vector3.ONE*s
			var at := Vector2(float(inst.x),float(inst.z))
			model.position = Vector3(at.x,sample_height(at)-float(inst.min_y)*s,at.y)
			model.rotation.y = deg_to_rad(float(inst.yaw))
			var todo: Array[Node] = [model]
			while not todo.is_empty():
				var node: Node = todo.pop_back()
				todo.append_array(node.get_children())
				if node is MeshInstance3D:
					node.material_override = dmats[atlas]
			decorations += 1
		print("DECORATIONS ",decorations," assets=",scenes.size()," stats=",ddata.stats)
	else:
		print("DECORATIONS skipped (no decorations.json)")
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	# Warm parchment backdrop: the old blue-grey made the whole frame read cold
	# and flat; the map lives in a warm palette and its surround should too.
	environment.environment.background_color = Color("b0a68f")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.709804,0.615686,0.454902)
	environment.environment.ambient_light_energy = .52
	# Final grade: contrast + saturation lift so the frame stops reading pastel.
	environment.environment.adjustment_enabled = true
	environment.environment.adjustment_contrast = 1.10
	environment.environment.adjustment_saturation = 1.14
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-46,-34,0)
	# Harder key light + softer fill: real terrain reads by shadow contrast, and
	# the equal-ish old setup flattened every landform into pastel.
	sun.light_energy = 1.22
	sun.light_color = Color(1,.839216,.647059)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 4000
	world.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18,146,0)
	fill.light_energy = .12
	fill.light_color = Color("ead9c6")
	world.add_child(fill)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.far = 10000
	camera.current = true
	world.add_child(camera)
	var views: Array = [
		{"name":"top","size":2500,"eye":Vector3(1000,3000,1000),"look":Vector3(1000,0,1000)},
		# 30 degree RTS camera: the elevation the in-game camera actually uses.
		{"name":"iso30","size":2500,"eye":Vector3(2469,1200,2469),"look":Vector3(1000,0,1000)},
		{"name":"iso45","size":2500,"eye":Vector3(2550,2700,2900),"look":Vector3(1000,0,1000)},
		{"name":"detail","size":900,"eye":Vector3(1700,1300,2000),"look":Vector3(1000,0,1000)},
	]
	# Close-up C: the best-centred large rock mass (broken ridge / saddle / erosion
	# notches). Camera3D.size is the *vertical* extent, and the ground footprint of
	# an orthographic frame is size/sin(declination), so a 20-30 degree view needs a
	# small size to stay a close-up. Every camera here also clears y=0: otherwise the
	# lower frame reaches under the terrain slab and shows the background colour.
	var mfocus := Vector2(float(input.mountain_focus[0]),float(input.mountain_focus[1]))
	views.append({"name":"mountain_detail","size":150,
		"eye":Vector3(mfocus.x-70.0,185.0,mfocus.y+130.0),
		"look":Vector3(mfocus.x,34.0,mfocus.y)})
	views.append({"name":"mountain_ridge","size":340,
		"eye":Vector3(mfocus.x-230.0,265.0,mfocus.y+300.0),
		"look":Vector3(mfocus.x,45.0,mfocus.y)})
	# AI_RTS actual RTS camera: the game uses an orthographic 30-degree camera
	# (game_style shots: eye = look + (0,70,121.24) -> exactly 30 deg). Any verdict
	# about texture scale / silhouette must come from THIS camera, not the 2 km
	# overview: the overview hides mid-frequency relief the player always sees.
	# 立面机位：从山脚外法线方向 300 m、高 120 m 正对山体中心 —— 拍到
	# 山脚扇 -> 崖壁 -> 主脊的完整立面（旧机位在山背面，只剩剪影）。
	var ffocus := Vector2(float(input.mountain_foot_focus[0]),float(input.mountain_foot_focus[1]))
	var fnorm := Vector2(float(input.mountain_foot_normal[0]),float(input.mountain_foot_normal[1]))
	var ftan := Vector2(-fnorm.y,fnorm.x)
	views.append({"name":"rts_mountain","size":190,
		"eye":Vector3(ffocus.x + fnorm.x * 300.0, 120.0,
			ffocus.y + fnorm.y * 300.0),
		"look":Vector3(mfocus.x, 40.0, mfocus.y)})
	# RTS camera on the range foot: where the mass dissolves into the desert
	# through the deposition fan. Placed on the plain side, looking uphill.
	views.append({"name":"rts_foot","size":110,
		"eye":Vector3(ffocus.x+fnorm.x*215.0,132.0,ffocus.y+fnorm.y*215.0),
		"look":Vector3(ffocus.x-fnorm.x*12.0,8.0,ffocus.y-fnorm.y*12.0)})
	# A straight-in view at 55 m framed the rock wall edge-on and read as a smeared
	# close-up with no fan in frame. Stand off obliquely (normal + tangent) and
	# aim just outside the foot so the talus/fan band and the plain both fit.
	views.append({"name":"mountain_foot","size":110,
		"eye":Vector3(ffocus.x+fnorm.x*95.0+ftan.x*85.0,88.0,
			ffocus.y+fnorm.y*95.0+ftan.y*85.0),
		"look":Vector3(ffocus.x+fnorm.x*8.0,6.0,ffocus.y+fnorm.y*8.0)})
	# Close-up D: the river bank at a straight section (channel width continuity).
	var rfocus := Vector2(float(input.riverbank_focus[0]),float(input.riverbank_focus[1]))
	views.append({"name":"riverbank_detail","size":140,
		"eye":Vector3(rfocus.x-90.0,92.0,rfocus.y+100.0),
		"look":Vector3(rfocus.x,4.0,rfocus.y)})
	# Close-up A: the main 20 degree ramp of the first plateau.
	var pl0: Dictionary = input.plateaus[0]
	var rc0: Array = pl0.ramp_centers[0]
	var rd0: Array = pl0.ramp_dirs[0]
	var axis0 := -Vector2(rd0[0],rd0[1]).normalized()
	var start0 := Vector2(rc0[0],rc0[1])*logical_cell/sx-axis0*Kit.PlateauBuilder.MAIN_INSET
	var mid0 := (start0+axis0*Kit.PlateauBuilder.MAIN_RUN*.5)*sx
	var eye0 := mid0-axis0*78.0
	views.append({"name":"ramp_detail","size":105,"eye":Vector3(eye0.x,58.0,eye0.y),"look":Vector3(mid0.x,7.0,mid0.y)})
	# Close-up B: the first river bridge seen from the bank.
	var b0: Dictionary = input.bridges[0]
	var ba := Vector2(b0.a[0],b0.a[1])*logical_cell
	var bb := Vector2(b0.b[0],b0.b[1])*logical_cell
	var mid_b := (ba+bb)*.5
	var dir_b := (bb-ba).normalized()
	var perp_b := Vector2(-dir_b.y,dir_b.x)
	var eye_b := mid_b+perp_b*72.0+dir_b*34.0
	views.append({"name":"bridge_detail","size":130,"eye":Vector3(eye_b.x,52.0,eye_b.y),"look":Vector3(mid_b.x,2.0,mid_b.y)})
	for view in views:
		camera.size = float(view.size)
		camera.position = view.eye
		camera.look_at(view.look)
		if view.name=="top": camera.rotation_degrees = Vector3(-90,0,0)
		for frame in (4 if preview_mode else 12): await process_frame
		# OCCLUSION SAFETY: when another app covers the render window, Windows stops
		# compositing it and RenderingServer.frame_post_draw never fires - the render
		# then hangs at 0 captures with the process alive (seen when rendering during
		# the day instead of at night). force_draw pushes the frame synchronously so
		# capture never depends on the window being visible.
		RenderingServer.force_draw(true)
		root.get_texture().get_image().save_png(out_dir+"/"+view.name+".png")
		print("CAPTURE ",view.name)
	# Static references use the actual game assets and native model scales.
	var reference := Node3D.new()
	reference.name = "GameStyleReferences"
	world.add_child(reference)
	var center := Vector2(pl0.center[0],pl0.center[1])*logical_cell
	# Prefer the densest real decoration cluster so this shot shows units, buildings,
	# bridge-scale props and decorations together at true game scale.
	if input.has("scale_focus"):
		center = Vector2(float(input.scale_focus[0]),float(input.scale_focus[1]))
	var units := preload("res://tools/godot/showcase_units.gd").new()
	for row in range(2):
		for col in range(4):
			var at := center+Vector2(-6+col*3.5,8+row*4)
			units.add_unit(reference,"tank",Vector3(at.x,sample_height(at),at.y))
	for col in range(8):
		var at := center+Vector2(8+col*1.2,10)
		units.add_unit(reference,"infantry",Vector3(at.x,sample_height(at),at.y))
	for spec in [["SM_Bld_Pod_Research_05",.12,Vector2(-5,-9)],["SM_Bld_Corp_Barracks_01",.35,Vector2(7,-2)]]:
		var model: Node3D = load("res://assets/unit_scale/"+str(spec[0])+".fbx").instantiate()
		reference.add_child(model)
		model.scale = Vector3.ONE*float(spec[1])
		var at: Vector2 = center+spec[2]
		model.position = Vector3(at.x,sample_height(at),at.y)
		var nodes: Array[Node] = [model]
		var floor_y := INF
		while not nodes.is_empty():
			var item: Node = nodes.pop_back()
			nodes.append_array(item.get_children())
			if item is MeshInstance3D:
				var mat := StandardMaterial3D.new()
				mat.albedo_texture = load("res://assets/unit_scale/PolygonScifiWorlds_Texture_01_A.png")
				mat.roughness = .85
				item.material_override = mat
				var bounds: AABB = item.global_transform*item.get_aabb()
				floor_y = minf(floor_y,bounds.position.y)
		model.position.y += sample_height(at)-floor_y
	var look := Vector3(center.x,sample_height(center),center.y)
	camera.size = 65
	camera.position = look+Vector3(0,70,121.24356)
	camera.look_at(look)
	for frame in (6 if preview_mode else 16): await process_frame
	RenderingServer.force_draw(true)
	root.get_texture().get_image().save_png(out_dir+"/game_style.png")
	reference.queue_free()
	await process_frame
	# Same-scale shot with the bridge in frame: tanks on the deck, a building on
	# each bank, and whatever shore_zone decoration the plan placed on the water
	# line nearby. This is the units/buildings/bridge/decoration scale reference.
	var bref := Node3D.new()
	bref.name = "GameStyleBridge"
	world.add_child(bref)
	var deck_y := .6*logical_cell
	for row in range(3):
		var pt0 := mid_b+dir_b*(-24.0+row*24.0)
		units.add_unit(bref,"tank",Vector3(pt0.x,deck_y,pt0.y))
	var half_len_b := ba.distance_to(bb)*.5
	for side in [-1,1]:
		# Beyond the bridge ends, so the buildings stand on the banks. Offsetting
		# across the deck (perp) put them in mid-channel, under the river surface.
		var pt1: Vector2 = mid_b+dir_b*side*(half_len_b+22.0)+perp_b*10.0
		var model2: Node3D = load("res://assets/unit_scale/SM_Bld_Corp_Barracks_01.fbx").instantiate()
		bref.add_child(model2)
		model2.scale = Vector3.ONE*.35
		model2.position = Vector3(pt1.x,sample_height(pt1),pt1.y)
		var nodes2: Array[Node] = [model2]
		var floor2 := INF
		while not nodes2.is_empty():
			var item2: Node = nodes2.pop_back()
			nodes2.append_array(item2.get_children())
			if item2 is MeshInstance3D:
				var mat2 := StandardMaterial3D.new()
				mat2.albedo_texture = load("res://assets/unit_scale/PolygonScifiWorlds_Texture_01_A.png")
				mat2.roughness = .85
				item2.material_override = mat2
				var b2: AABB = item2.global_transform*item2.get_aabb()
				floor2 = minf(floor2,b2.position.y)
		model2.position.y += sample_height(pt1)-floor2
	var blook := Vector3(mid_b.x,deck_y,mid_b.y)
	camera.size = 120
	camera.position = blook+Vector3(perp_b.x*95.0,86.0,perp_b.y*95.0)+Vector3(dir_b.x*40.0,0,dir_b.y*40.0)
	camera.look_at(blook)
	for frame in (6 if preview_mode else 16): await process_frame
	RenderingServer.force_draw(true)
	root.get_texture().get_image().save_png(out_dir+"/game_style_bridge.png")
	print("CAPTURE game_style_bridge")
	bref.queue_free()
	await process_frame
	var pending: Array[Node] = [world]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child in node.get_children():
			child.owner = world
			pending.append(child)
	var packed := PackedScene.new()
	packed.pack(world)
	ResourceSaver.save(packed,out_dir+"/map.tscn")
	print("G2_KIT_RENDER_COMPLETE")
	world.queue_free()
	# Legacy SceneTree builders own native Windows handles; follow release_builder.
	await process_frame
	await process_frame
	quit()

