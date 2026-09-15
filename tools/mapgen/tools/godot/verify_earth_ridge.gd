extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var packed := load("res://review/G4/kit_samples/earth_ridge_prototype/earth_ridge.tscn") as PackedScene
	assert(packed!=null,"Saved ridge cannot load")
	var kit := packed.instantiate()
	root.add_child(kit)
	assert(kit.get_meta("kit_id")=="earth_ridge_v1")
	await physics_frame
	await physics_frame
	var results: Array=[]
	for x in [-25.0,0.0,25.0]:
		var query := PhysicsRayQueryParameters3D.create(Vector3(x,50,0),Vector3(x,-5,0))
		var hit: Dictionary=kit.get_world_3d().direct_space_state.intersect_ray(query)
		assert(not hit.is_empty(),"Missing mountain collision")
		assert(hit.position.y>10.0 and hit.normal.y>0.0,"Invalid mountain collision height/normal")
		results.append({"x":x,"hit_y":hit.position.y,"normal_y":hit.normal.y})
	FileAccess.open("res://review/G4/kit_samples/earth_ridge_prototype/verification.json",FileAccess.WRITE).store_string(JSON.stringify({"scene_load":"passed","sampled_collision_rays":results,"navigation_tested":false},"  "))
	print("RIDGE_SAVED_SCENE_AND_COLLISION_PASS ",results)
	quit()
