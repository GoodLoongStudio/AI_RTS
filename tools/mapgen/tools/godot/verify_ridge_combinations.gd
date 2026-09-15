extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var config: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://tools/godot/earth_ridge_combinations.json"))
	for variant in config.variants:
		var folder: String="res://review/G4/kit_samples/earth_ridge_combinations/"+str(variant.id)
		var packed:=load(folder+"/component.tscn") as PackedScene
		assert(packed!=null)
		var kit:=packed.instantiate()
		root.add_child(kit)
		assert(kit.get_meta("kit_id")==variant.id)
		await physics_frame
		await physics_frame
		var hits: Array=[]
		for probe in variant.probes:
			var query:=PhysicsRayQueryParameters3D.create(Vector3(probe[0],60,probe[1]),Vector3(probe[0],-5,probe[1]))
			var hit: Dictionary=kit.get_world_3d().direct_space_state.intersect_ray(query)
			assert(not hit.is_empty(),"Missing mountain collision")
			assert(hit.position.y>10 and hit.normal.y>0,"Invalid height/normal")
			hits.append({"xz":probe,"height":hit.position.y,"normal_y":hit.normal.y})
		var gap_z: float=-28.0 if variant.id=="arc_ridge" else 0.0
		var gap_query:=PhysicsRayQueryParameters3D.create(Vector3(0,60,gap_z),Vector3(0,-5,gap_z))
		assert(kit.get_world_3d().direct_space_state.intersect_ray(gap_query).is_empty(),"Mountain collider obstructs intended gap")
		FileAccess.open(folder+"/verification.json",FileAccess.WRITE).store_string(JSON.stringify({"scene_load":"passed","sampled_collision_rays":hits,"open_gap_sample":[0,gap_z],"open_gap_has_no_mountain_collision":true,"navigation_tested":false},"  "))
		print("VERIFIED ",variant.id)
		kit.queue_free()
		await process_frame
	quit()
