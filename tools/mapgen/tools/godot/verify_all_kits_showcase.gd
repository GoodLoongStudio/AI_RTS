extends SceneTree

func _initialize() -> void: call_deferred("run")

func surface_height(grid: Dictionary,point: Vector2) -> float:
	var p:=point*2.0
	var cell:=Vector2i(floori(p.x),floori(p.y))
	var f:=p-Vector2(cell)
	for offset in [Vector2i.ZERO,Vector2i.RIGHT,Vector2i.DOWN,Vector2i.ONE]:
		assert(grid.has(cell+offset),"Main ramp extends outside the mesh")
	return lerpf(lerpf(grid[cell],grid[cell+Vector2i.RIGHT],f.x),lerpf(grid[cell+Vector2i.DOWN],grid[cell+Vector2i.ONE],f.x),f.y)

func check_main_ramp(plateau: Node3D,vertices: PackedVector3Array) -> Dictionary:
	assert(plateau.has_meta("main_ramp"),"Required main ramp is missing")
	var spec: Dictionary=plateau.get_meta("main_ramp")
	var start: Vector2=spec.start
	var axis: Vector2=spec.axis
	var lateral:=Vector2(-axis.y,axis.x)
	var width: float=spec.width*plateau.scale.x
	assert(absf(width-20.0)<.01,"Main ramp must provide 20 metres of clear width")
	var grid: Dictionary={}
	for v in vertices: grid[Vector2i(roundi(v.x*2.0),roundi(v.z*2.0))]=v.y
	var max_slope:=0.0
	var sample_count:=0
	for side in [-.46,0.0,.46]:
		var lane_start: Vector2=start+lateral*spec.width*side
		var previous:=surface_height(grid,lane_start)*plateau.scale.y
		assert(absf(previous-spec.height*plateau.scale.y)<.08,"Main ramp top is disconnected")
		for i in range(1,149):
			var t: float=spec.run*i/148.0
			var h:=surface_height(grid,lane_start+axis*t)*plateau.scale.y
			var drop:=previous-h
			assert(drop>=-.025,"Main ramp contains a reverse step")
			var grade:=rad_to_deg(atan(absf(drop)/(spec.run/148.0*plateau.scale.x)))
			max_slope=maxf(max_slope,grade)
			assert(grade<21.0,"Main ramp exceeds the requested 20-degree face")
			previous=h
			sample_count+=1
		assert(previous<.05,"Main ramp foot is not flush with ground")
	assert(absf(max_slope-20.0)<1.0,"Main ramp does not reach the requested 20-degree slope")
	return {"clear_width_m":width,"run_m":spec.run*plateau.scale.x,"rise_m":spec.height*plateau.scale.y,"max_sampled_slope_degrees":max_slope,"mesh_samples":sample_count,"continuous_descent":"passed"}

func check_secondary_junctions(plateau: Node3D,vertices: PackedVector3Array) -> Array:
	assert(plateau.has_meta("secondary_ramp_junctions"),"Secondary ramp checks are missing")
	var specs: Array=plateau.get_meta("secondary_ramp_junctions")
	assert(specs.size()==3)
	var grid: Dictionary={}
	for v in vertices: grid[Vector2i(roundi(v.x*2.0),roundi(v.z*2.0))]=v.y
	var results: Array=[]
	for spec in specs:
		var max_reverse_step:=0.0
		var max_grade:=0.0
		for lane in spec.lanes:
			var previous:=surface_height(grid,lane.start)*plateau.scale.y
			var main_spec: Dictionary=plateau.get_meta("main_ramp")
			assert(absf(previous-main_spec.height*plateau.scale.y)<.30,"Secondary ramp does not meet the plateau")
			for i in range(1,161):
				var p: Vector2=lane.start+lane.axis*lane.run*i/160.0
				var h:=surface_height(grid,p)*plateau.scale.y
				max_reverse_step=maxf(max_reverse_step,h-previous)
				max_grade=maxf(max_grade,rad_to_deg(atan(absf(h-previous)/(lane.run/160.0*plateau.scale.x))))
				previous=h
			assert(previous<.05,"Secondary ramp foot is not flush")
		assert(max_reverse_step<.04,"Secondary junction dips and rises again: "+str(spec.azimuth_degrees))
		assert(absf(max_grade-30.0)<1.0,"Secondary slope does not match the requested 30 degrees")
		results.append({"azimuth_degrees":spec.azimuth_degrees,"mesh_samples":480,"max_reverse_step_m":max_reverse_step,"max_slope_degrees":max_grade,"junction":"passed"})
	return results

func run() -> void:
	var folder:="res://review/G4/kit_samples/all_kits_showcase"
	var saved:=load(folder+"/all_kits.tscn") as PackedScene
	assert(saved!=null)
	var scene:=saved.instantiate()
	root.add_child(scene)
	var names:=["PlateauAndRamps","RiverAndBridge","Lake","LongRidge","ArcRidge","OffsetRidges","MountainCluster","SquareTopMountain","TerracedMassif","MixedMountainRange"]
	for label in names: assert(scene.has_node(label),"Missing kit "+label)
	var plateau_mesh: MeshInstance3D=scene.get_node("PlateauAndRamps").get_child(0)
	var land: ShaderMaterial=plateau_mesh.material_override
	for id in ["SquareTopMountain","TerracedMassif","MixedMountainRange"]:
		var group: Node3D=scene.get_node(id)
		var mountain_mesh: MeshInstance3D=group.get_node("ContinuousMountain")
		assert(mountain_mesh.material_override==land,"New mountain has mismatched material")
		var geometry: PackedVector3Array=mountain_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var highest:=0.0
		for vertex in geometry:
			highest=maxf(highest,vertex.y)
			assert(is_finite(vertex.y) and vertex.y>=0.0,"Invalid mountain height")
			if absf(vertex.x)>=43.5 or absf(vertex.z)>=24.5:
				assert(vertex.y<.001,"Mountain footprint is clipped by its mesh boundary")
		assert(highest>12.0,"New mountain geometry is missing")
	assert(scene.get_node("MixedMountainRange").get_meta("masses").size()==4)
	var land_nodes: Array=[scene.get_node("LongRidge/ContinuousEarthRidge"),scene.get_node("ArcRidge/EarthMass"),scene.get_node("OffsetRidges/EarthMass"),scene.get_node("MountainCluster/EarthMass"),scene.get_node("RiverAndBridge").get_child(0),scene.get_node("Lake").get_child(1)]
	for node in land_nodes:
		assert(node.material_override==land,"Land kits do not share one material")
	var river: ShaderMaterial=scene.get_node("RiverAndBridge").get_child(1).material_override
	var lake: ShaderMaterial=scene.get_node("Lake").get_child(0).material_override
	assert(river.shader.code==lake.shader.code,"Water palette mismatch")
	assert(lake.get_shader_parameter("lake_mode")==true)
	assert(river.shader.code.contains("showcase_shapes.gdshaderinc"),"Water does not use the shared shoreline definition")
	assert(land.shader.code.contains("showcase_shapes.gdshaderinc"),"Ground and water shoreline definitions differ")
	assert(scene.get_node("ContinuousBasin").material_override.get_shader_parameter("cut_water")==true)
	for parameter in ["main_lane","main_run","main_width"]:
		assert(scene.get_node("ContinuousBasin").material_override.get_shader_parameter(parameter)==land.get_shader_parameter(parameter),"Ground and ramp material masks differ")
	# Check actual assembled vertices against the river, including ramp toes.
	var clearance:=1000.0
	var vertices: PackedVector3Array=plateau_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var ramp_check:=check_main_ramp(scene.get_node("PlateauAndRamps"),vertices)
	var secondary_check:=check_secondary_junctions(scene.get_node("PlateauAndRamps"),vertices)
	var landform_check:=check_incised_landforms(scene.get_node("PlateauAndRamps"),vertices)
	if ramp_check.is_empty() or secondary_check.is_empty() or landform_check.is_empty():
		quit(1)
		return
	for vertex in vertices:
		if vertex.y<.035: continue
		var p: Vector3=plateau_mesh.global_transform*vertex
		var center:=sin(p.x*.022)*12.0+sin(p.x*.057+1.15)*5.0+10.0
		var half:=14.0*(1.0+.10*sin(p.x*.031+.6)+.035*sin(p.x*.081))
		clearance=minf(clearance,absf(p.z-center)-half)
	assert(clearance>4.5,"Plateau overlaps the river or its bank")
	var top:=Image.load_from_file(folder+"/top.png")
	assert(top!=null and top.get_size()==Vector2i(2200,1500))
	var water_samples:=0
	for x in range(-220,221,4):
		if x>=10 and x<=26: continue
		var z:=sin(x*.022)*12.0+sin(x*.057+1.15)*5.0+10.0
		var pixel:=Vector2i(roundi(1100+x*1500.0/370.0),roundi(750+z*1500.0/370.0))
		var color:=top.get_pixelv(pixel)
		assert(color.g>color.r*1.08 and color.g>color.b*1.025,"River is visually obstructed at x="+str(x))
		water_samples+=1
	for label in ["overview","plateau_bridge","lake_mountains","top","bank_detail","main_ramp","left_ramp_junction","plateau_buttes","mountain_varieties","combat_plateau","combat_units","combat_ridge","combat_bridge"]:
		var img:=Image.load_from_file(folder+"/"+label+".png")
		assert(img!=null and img.get_size()==Vector2i(2200,1500),"Missing render "+label)
	assert(scene.has_node("ScaleUnits"),"Missing scale reference units")
	assert(scene.has_node("ScaleBase") and scene.get_node("ScaleBase").get_child_count()==8,"Missing base development reference")
	var footprints: Array[Rect2]=[]
	for record in scene.get_meta("scale_base"):
		var size: Vector3=record.visual_size
		var pos: Vector3=record.position
		var footprint:=Rect2(Vector2(pos.x-size.x*.5,pos.z-size.z*.5),Vector2(size.x,size.z))
		for other in footprints:
			assert(not footprint.grow(1.0).intersects(other),"Base buildings lack separation")
		footprints.append(footprint)
		assert(absf(pos.y-7.2)<.2,"Base building not on plateau top")
		var plateau: Node3D=scene.get_node("PlateauAndRamps")
		var grid: Dictionary={}
		for vertex in vertices: grid[Vector2i(roundi(vertex.x*2),roundi(vertex.z*2))]=vertex.y
		for corner in [footprint.position,footprint.end,Vector2(footprint.end.x,footprint.position.y),Vector2(footprint.position.x,footprint.end.y)]:
			var local_point:=plateau.to_local(Vector3(corner.x,0,corner.y))
			assert(absf(surface_height(grid,Vector2(local_point.x,local_point.z))*plateau.scale.y-pos.y)<.3,"New landform intersects building: "+str(record.id))
	assert(scene.get_node("ScaleUnits").get_child_count()==72,"Missing reference formation")
	for unit in scene.get_node("ScaleUnits").get_children():
		var tank: bool=unit.get_meta("reference_kind")=="tank"
		assert(is_equal_approx(unit.get_meta("model_scale"),.21 if tank else .45))
		assert(is_equal_approx(unit.get_meta("avoidance_radius"),.9 if tank else .21))
	var bridge_meshes:=0
	for holder in scene.get_node("RiverAndBridge").get_children():
		if not holder is MeshInstance3D: bridge_meshes+=1
	assert(bridge_meshes>4,"Missing bridge kit parts")
	var metal:=load(folder+"/weathered_metal.tres") as ShaderMaterial
	assert(metal!=null and metal.get_shader_parameter("base_tex")!=null)
	FileAccess.open(folder+"/verification.json",FileAccess.WRITE).store_string(JSON.stringify({"scene_reload":"passed","required_kits":names,"shared_land_material_identity":"passed","river_lake_shared_shader":"passed","plateau_water_clearance_m":clearance,"river_continuity_pixel_samples":water_samples,"render_count":13,"reference_units":72,"unit_scale_matches_game":true,"main_ramp":ramp_check,"secondary_ramp_junctions":secondary_check,"incised_landforms":landform_check,"bridge_holders":bridge_meshes,"navigation_validated":false},"  "))
	print("ALL_KITS_SCENE_AND_SHARED_MATERIALS_PASS")
	scene.queue_free()
	await process_frame
	await process_frame
	call_deferred("quit")

func check_incised_landforms(plateau: Node3D, vertices: PackedVector3Array) -> Dictionary:
	var grid: Dictionary={}
	for v in vertices: grid[Vector2i(roundi(v.x*2),roundi(v.z*2))]=v.y
	var specs: Array=[plateau.get_meta("main_ramp")]
	specs.append_array(plateau.get_meta("ramp_specs"))
	var cuts: Array=[]
	for spec in specs:
		var is_main: bool=spec.role=="main"
		if is_main:
			assert(spec.inset/spec.run>.75,"Main ramp should be mostly embedded")
		else:
			assert(spec.inset>0 and spec.inset/spec.run<.30,"Side entrance should have a shallow inset")
			assert(spec.width*plateau.scale.x<5.5,"Side entrance is too wide")
		var rim: Vector2=spec.start+spec.axis*spec.inset
		var rim_height:=surface_height(grid,rim)*plateau.scale.y
		assert(rim_height<2.0 if is_main else rim_height>5.0,"Incorrect incision depth at the original rim")
		cuts.append({"role":spec.role,"inset_m":spec.inset*plateau.scale.x,"outside_run_m":(spec.run-spec.inset)*plateau.scale.x,"rim_height_m":rim_height})
	assert(cuts.size()==4,"All four entrances must be checked")
	var caps: Array=[]
	for spec in plateau.get_meta("raised_buttes"):
		var center: Vector2=spec.center
		var cap_height:=surface_height(grid,center)*plateau.scale.y
		assert(cap_height>plateau.scale.y*18.0+5.0,"Raised mountain missing from plateau")
		var variation:=0.0
		for offset in [Vector2(.25,0),Vector2(-.25,0),Vector2(0,.25),Vector2(0,-.25)]:
			variation=maxf(variation,absf(surface_height(grid,center+offset*spec.half_size)*plateau.scale.y-cap_height))
		assert(variation<.65,"Mountain cap is pointed or not supported by the plateau")
		caps.append({"id":spec.id,"height_world_m":cap_height,"cap_variation_m":variation})
	return {"incised_ramps":cuts,"raised_flat_caps":caps}

