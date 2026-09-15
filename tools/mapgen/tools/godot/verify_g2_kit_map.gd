extends SceneTree

const OUT := "res://review/G4/g2_large_lake_kits"
const Kit = preload("res://tools/godot/all_kits_showcase.gd")

func _initialize() -> void:
	call_deferred("run")

func height_at(space: PhysicsDirectSpaceState3D, p: Vector2) -> float:
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(p.x,200,p.y),Vector3(p.x,-100,p.y)))
	return float(hit.position.y) if not hit.is_empty() else NAN

func run() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OUT+"/input.json"))
	var world: Node3D = load(OUT+"/map.tscn").instantiate()
	root.add_child(world)
	await physics_frame
	await physics_frame
	var space := world.get_world_3d().direct_space_state
	var scale := float(data.logical_cell_m)
	var report := {"world_size_m":data.world_size_m,"bridges":[],"ramps":[],"navigation_validated":false}
	for bridge in data.bridges:
		var a := Vector2(bridge.a[0],bridge.a[1])*scale
		var b := Vector2(bridge.b[0],bridge.b[1])*scale
		var max_error := 0.0
		for i in range(21):
			var y := height_at(space,a.lerp(b,(i+.5)/21.0))
			max_error = maxf(max_error,absf(y-.6*scale)) if is_finite(y) else INF
		report.bridges.append({"width_m":bridge.width*scale,"length_m":a.distance_to(b),"deck_max_height_error_m":max_error,"pass":max_error<.05})
	for pi in data.plateaus.size():
		var pl: Dictionary = data.plateaus[pi]
		for ri in pl.ramp_centers.size():
			var rc: Array = pl.ramp_centers[ri]
			var rd: Array = pl.ramp_dirs[ri]
			var axis := -Vector2(rd[0],rd[1]).normalized()
			var run_length := (Kit.PlateauBuilder.MAIN_RUN if ri==0 else Kit.PlateauBuilder.SIDE_RUN)*1.4
			var inset := (Kit.PlateauBuilder.MAIN_INSET if ri==0 else 3.5)*1.4
			var start := Vector2(rc[0],rc[1])*scale-axis*inset
			var max_slope := 0.0
			var last := height_at(space,start)
			for i in range(1,41):
				var y := height_at(space,start+axis*run_length*i/40.0)
				max_slope=maxf(max_slope,rad_to_deg(atan(absf(y-last)/(run_length/40.0)))) if is_finite(y) and is_finite(last) else INF
				last=y
			report.ramps.append({"plateau":pi,"role":"main" if ri==0 else "side","centerline_max_slope_degrees":max_slope,"pass":max_slope<(23 if ri==0 else 34)})
	FileAccess.open(OUT+"/geometry_checks.json",FileAccess.WRITE).store_string(JSON.stringify(report,"  "))
	print(JSON.stringify(report))
	if "--capture" in OS.get_cmdline_user_args():
		root.mode=Window.MODE_WINDOWED
		root.show()
		root.size=Vector2i(1800,1200)
		var camera := Camera3D.new()
		camera.projection=Camera3D.PROJECTION_ORTHOGONAL
		camera.far=5000
		world.add_child(camera)
		camera.current=true
		var pl: Dictionary=data.plateaus[2]
		var rc: Array=pl.ramp_centers[0]
		var rd: Array=pl.ramp_dirs[0]
		var target := Vector3(rc[0]*scale,6,rc[1]*scale)
		camera.size=170
		camera.position=target+Vector3(-rd[0]*170,140,-rd[1]*170)
		camera.look_at(target)
		print("CAPTURE_RAMP_BEGIN")
		for i in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT+"/ramp_detail.png")
		print("CAPTURE_RAMP_DONE")
		var b: Dictionary=data.bridges[2]
		target=Vector3((b.a[0]+b.b[0])*.5*scale,0,(b.a[1]+b.b[1])*.5*scale)
		camera.size=240
		camera.position=target+Vector3(150,190,150)
		camera.look_at(target)
		for i in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUT+"/bridge_detail.png")
	world.queue_free()
	await process_frame
	await process_frame
	quit()
