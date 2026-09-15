extends SceneTree

## Audit the saved showcase kit for troop passability. This deliberately
## distinguishes geometric slope quality from gameplay collision/navigation:
## the showcase is a visual scene and must not be reported as game-ready just
## because the rendered ramp has a continuous height profile.

const FOLDER := "res://review/G4/kit_samples/all_kits_showcase"
const REPORT := FOLDER + "/passability_audit.json"

func _initialize() -> void:
	call_deferred("run")

func count_physics(node: Node) -> Dictionary:
	var result={"static_bodies":0,"collision_shapes":0,"navigation_regions":0}
	var pending: Array=[node]
	while not pending.is_empty():
		var current: Node=pending.pop_back()
		if current is StaticBody3D: result.static_bodies+=1
		if current is CollisionShape3D: result.collision_shapes+=1
		if current is NavigationRegion3D: result.navigation_regions+=1
		pending.append_array(current.get_children())
	return result

func geometric_ramps(builder, plateau: Node3D) -> Array:
	var specs: Array=[builder.main_spec()]
	specs.append_array(builder.mesa_ramp_specs())
	var results: Array=[]
	for spec in specs:
		var previous: float=INF
		var max_slope:=0.0
		var reverse_step:=0.0
		var samples:=0
		for i in range(1,161):
			var distance: float=spec.run*i/160.0
			var p: Vector2=spec.start+spec.axis*distance
			var height: float=builder.mesa_height(p.x,p.y,builder.mesa_ramp_specs())*plateau.scale.y
			if previous<INF:
				var drop:=previous-height
				reverse_step=maxf(reverse_step,-drop)
				max_slope=maxf(max_slope,rad_to_deg(atan(absf(drop)/(spec.run/160.0*plateau.scale.x))))
			previous=height
			samples+=1
		var target: float=20.0 if spec.role=="main" else 30.0
		results.append({"role":String(spec.role),"samples":samples,"target_slope_degrees":target,"max_sampled_slope_degrees":max_slope,"reverse_step_m":reverse_step,"geometry_pass":reverse_step<.05 and absf(max_slope-target)<1.0,"clear_width_m":spec.width*plateau.scale.x})
	return results

func run() -> void:
	var scene: Node3D=load(FOLDER+"/all_kits.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	var builder=load("res://tools/godot/all_kits_showcase.gd").PlateauBuilder.new()
	var plateau: Node3D=scene.get_node("PlateauAndRamps")
	var kit_names=["PlateauAndRamps","SquareTopMountain","TerracedMassif","MixedMountainRange","LongRidge","ArcRidge","OffsetRidges","MountainCluster","RiverAndBridge"]
	var kits=[]
	var gameplay_ready:=true
	for name in kit_names:
		var node: Node=scene.get_node(name)
		var physics: Dictionary=count_physics(node)
		var ready: bool=physics.static_bodies>0 and physics.collision_shapes>0
		if name in ["PlateauAndRamps","SquareTopMountain","TerracedMassif","MixedMountainRange","RiverAndBridge"] and not ready:
			gameplay_ready=false
		kits.append({"id":name,"physics":physics,"collision_ready":ready,"role":"walkable_or_boundary" if name in ["PlateauAndRamps","RiverAndBridge"] else "mountain_obstacle"})
	var ramps:=geometric_ramps(builder,plateau)
	var ramp_geometry_ready:=true
	for ramp in ramps: ramp_geometry_ready=ramp_geometry_ready and bool(ramp.geometry_pass)
	var output={
		"scene":"all_kits.tscn",
		"geometry_slope_test":"passed" if ramp_geometry_ready else "failed",
		"ramps":ramps,
		"kit_physics":kits,
		"navigation_regions_in_showcase":count_physics(scene).navigation_regions,
		"collision_navigation_gameplay_ready":gameplay_ready and count_physics(scene).navigation_regions>0,
		"answer":"not_ready_in_showcase_scene",
		"reason":"The saved showcase has visual meshes and reference units, but no gameplay collision for the plateau/new mountain kits and no NavigationRegion3D. Integrate the same geometry into the authoritative G2/G4 terrain before claiming troop traversal."
	}
	FileAccess.open(REPORT,FileAccess.WRITE).store_string(JSON.stringify(output,"  "))
	print("KIT_PASSABILITY_AUDIT ",JSON.stringify(output))
	quit(0 if ramp_geometry_ready else 1)
