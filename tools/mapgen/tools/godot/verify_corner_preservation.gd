extends SceneTree

func _initialize(): call_deferred("run")

func run():
	var builder=load("res://tools/godot/all_kits_showcase.gd").PlateauBuilder.new()
	var specs=builder.mesa_ramp_specs()
	var main=builder.main_spec()
	var changed:=0
	var unchanged:=0
	var maximum_cut:=0.0
	for z in range(-4,61):
		for x in range(-4,65):
			builder.corner_bevel_enabled=false
			var original: float=builder.mesa_height(x,z,specs)
			builder.corner_bevel_enabled=true
			var revised: float=builder.mesa_height(x,z,specs)
			var cut: float=(original-revised)*.4
			var delta:=Vector2(x,z)-Vector2(main.start)
			var along: float=delta.dot(main.axis)
			var side: float=absf(delta.cross(main.axis))
			assert(cut>=-.00001 and cut<=.721,"Corner bevel moves too much rock")
			if absf(cut)>.00001:
				assert(side>main.width*.5+.5,"Corner bevel changes the original driving surface")
				assert(side<main.width*.5+5.0 and along>main.inset-8.0 and along<main.inset+2.0,"Bevel escapes its local rock-corner region")
				changed+=1
				maximum_cut=maxf(maximum_cut,cut)
			else:
				unchanged+=1
	assert(changed>5,"No actual rock-corner bevel was generated")
	var result={"original_lane_preserved":true,"changed_corner_samples":changed,"unchanged_samples":unchanged,"maximum_cut_m":maximum_cut}
	FileAccess.open("res://review/G4/kit_samples/all_kits_showcase/corner_verification.json",FileAccess.WRITE).store_string(JSON.stringify(result,"  "))
	print("LOCAL_CORNER_PRESERVATION_PASS ",result)
	builder.free()
	quit()
