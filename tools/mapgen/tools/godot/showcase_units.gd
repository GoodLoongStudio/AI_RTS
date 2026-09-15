extends RefCounted

const BASE := "res://assets/unit_scale/"
var records: Array = []

func add_unit(parent: Node3D, kind: String, pos: Vector3, yaw: float = 0.0, pitch: float = 0.0) -> void:
	var tank := kind == "tank"
	var holder := Node3D.new()
	holder.name = kind + "_%03d" % records.size()
	holder.position = pos
	holder.rotation = Vector3(pitch, yaw, 0)
	var model: Node3D = load(BASE + ("SM_Veh_HoverTank_01.fbx" if tank else "Infantry_native_v3.glb")).instantiate()
	holder.add_child(model)
	model.scale = Vector3.ONE * (.21 if tank else .45)
	model.rotation.y = PI
	model.position.y = .15 if tank else 0.0
	var radius := .9 if tank else .21
	var pending: Array = [model]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		if node is AnimationPlayer and node.has_animation("Idle"):
			node.get_animation("Idle").loop_mode = Animation.LOOP_LINEAR
			node.autoplay = "Idle"
		if tank and node is MeshInstance3D:
			var material := StandardMaterial3D.new()
			material.albedo_texture = load(BASE + "PolygonScifiWorlds_Texture_01_A.png")
			material.roughness = .8
			node.material_override = material
	parent.add_child(holder)
	var ring := MeshInstance3D.new()
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius - .025
	mesh.outer_radius = radius + .025
	mesh.rings = 32
	mesh.ring_segments = 6
	ring.mesh = mesh
	ring.position.y = .045
	var ring_material := StandardMaterial3D.new()
	ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_material.albedo_color = Color("43c5ed")
	ring.material_override = ring_material
	holder.add_child(ring)
	holder.set_meta("reference_kind", kind)
	holder.set_meta("avoidance_radius", radius)
	holder.set_meta("model_scale", .21 if tank else .45)
	records.append({"kind":kind,"position":pos,"yaw":yaw,"pitch":pitch,"model_scale":.21 if tank else .45,"avoidance_radius":radius})

func populate(world: Node3D, plateau: Node3D, builder: SceneTree) -> void:
	var group := Node3D.new()
	group.name = "ScaleUnits"
	world.add_child(group)
	# Use the exact generated heightfield vertices for ground contact.
	var surface: MeshInstance3D = plateau.get_child(0)
	var grid: Dictionary = {}
	for v in surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		grid[Vector2i(roundi(v.x*2),roundi(v.z*2))] = v.y
	# Bilinear interpolation matches the existing ramp verification grid.
	for row in range(3):
		for column in range(3):
			var local := Vector2(-14+column*4, 2+row*3.5)
			place_on_plateau(group, plateau, grid, "tank", local)
	for row in range(4):
		for column in range(6):
			place_on_plateau(group, plateau, grid, "infantry", Vector2(2+column*1.3,10+row*1.5))
	var axis: Vector2 = builder.main_axis()
	var lateral := Vector2(-axis.y, axis.x)
	var yaw := atan2(-axis.x,-axis.y)
	for row in range(2):
		for column in range(3):
			var local: Vector2 = builder.main_start()+axis*(builder.MAIN_RUN*(.22+row*.56))+lateral*((column-1)*3.3)
			place_on_plateau(group,plateau,grid,"tank",local,yaw)
	for row in range(2):
		for column in range(6):
			add_unit(group,"infantry",Vector3(-50+column*1.1,.02,-54+row*1.3))
	for row in range(2):
		for column in range(3):
			add_unit(group,"tank",Vector3(14.8+column*3.2,.68,15+row*4.0))
	for column in range(4):
		add_unit(group,"tank",Vector3(64+column*3.2,.02,-80))
	for column in range(8):
		add_unit(group,"infantry",Vector3(67+column*1.1,.02,-76))
	for column in range(3):
		add_unit(group,"tank",Vector3(-177+column*3.0,.02,-86))
	world.set_meta("scale_units",records)
	add_base(world,plateau,grid)

func add_base(world: Node3D, plateau: Node3D, grid: Dictionary) -> void:
	var group := Node3D.new()
	group.name = "ScaleBase"
	world.add_child(group)
	var buildings := [
		["CommandCenter","SM_Bld_Pod_Research_05",.12,Vector2(0,-20)],
		["BarracksA","SM_Bld_Corp_Barracks_01",.35,Vector2(-22,-4)],
		["BarracksB","SM_Bld_Corp_Barracks_01",.35,Vector2(-22,-15)],
		["VehicleFactoryA","SM_Bld_Scav_Garage_01",.20,Vector2(20,-5)],
		["VehicleFactoryB","SM_Bld_Scav_Garage_01",.20,Vector2(14,-16)],
		["Airfield","SM_Bld_Corp_LandingPad_02",.16,Vector2(3,-4)],
		["ResearchA","SM_Bld_Pod_Research_05",.12,Vector2(-12,-29)],
		["ResearchB","SM_Bld_Pod_Research_05",.12,Vector2(10,-25)]
	]
	var building_records: Array = []
	for spec in buildings:
		var holder := Node3D.new()
		holder.name=spec[0]
		group.add_child(holder)
		var point: Vector2=spec[3]
		holder.position=plateau.to_global(Vector3(point.x,height_at(grid,point),point.y))
		var model: Node3D=load(BASE+spec[1]+".fbx").instantiate()
		holder.add_child(model)
		model.scale=Vector3.ONE*spec[2]
		var pending: Array=[model]
		var box := AABB()
		var first := true
		while not pending.is_empty():
			var node: Node=pending.pop_back()
			pending.append_array(node.get_children())
			if node is MeshInstance3D:
				var material:=StandardMaterial3D.new()
				material.albedo_texture=load(BASE+"PolygonScifiWorlds_Texture_01_A.png")
				material.roughness=.85
				node.material_override=material
				var bounds: AABB=holder.global_transform.affine_inverse()*node.global_transform*node.get_aabb()
				box=bounds if first else box.merge(bounds)
				first=false
		model.position.y-=box.position.y
		building_records.append({"id":spec[0],"model":spec[1],"scale":spec[2],"position":holder.position,"visual_size":box.size})
	world.set_meta("scale_base",building_records)

func height_at(grid: Dictionary, p: Vector2) -> float:
	var cell := Vector2i(floori(p.x*2),floori(p.y*2))
	var f := p*2-Vector2(cell)
	for offset in [Vector2i.ZERO,Vector2i.RIGHT,Vector2i.DOWN,Vector2i.ONE]:
		assert(grid.has(cell+offset), "Unit outside plateau grid")
	return lerpf(lerpf(grid[cell],grid[cell+Vector2i.RIGHT],f.x),lerpf(grid[cell+Vector2i.DOWN],grid[cell+Vector2i.ONE],f.x),f.y)

func place_on_plateau(group: Node3D, plateau: Node3D, grid: Dictionary, kind: String, p: Vector2, yaw: float = 0.0) -> void:
	var forward := Vector2(-sin(yaw),-cos(yaw))
	var slope := (height_at(grid,p+forward)-height_at(grid,p-forward))*plateau.scale.y/(2*plateau.scale.x)
	var position := plateau.to_global(Vector3(p.x,height_at(grid,p),p.y))
	add_unit(group,kind,position+Vector3.UP*.02,yaw,atan(slope))
