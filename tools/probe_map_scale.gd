extends SceneTree

## 地图尺度探针：只加载 map tscn（不进 Match），打印地面真值。
## 目的：确定「高度场顶点坐标 / 语义格坐标 / 世界米」三者的实际比例，
## 以及水面片、出生点、装饰物件是否落在同一个坐标系里。
## 运行：
##   Godot_v4.7.1-stable_mono_win64_console.exe --headless --path G:/AIRTS/AI_RTS \
##     --script res://tools/probe_map_scale.gd

const MAP_PATH := "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var packed: PackedScene = load(MAP_PATH)
	print("LOAD_MS ", Time.get_ticks_msec() - t0)
	if packed == null:
		push_error("probe: map load failed")
		quit(1)
		return
	var map: Node = packed.instantiate()
	root.add_child(map)
	await process_frame
	print("MAP size=", map.get("size"), " scale=", (map as Node3D).scale)

	var terrain: Node = map.get_node_or_null("Geometry/Terrain")
	if terrain is MeshInstance3D:
		var mi := terrain as MeshInstance3D
		var mesh := mi.mesh
		print("TERRAIN node_scale=", mi.scale, " node_pos=", mi.position)
		if mesh != null:
			print("TERRAIN mesh_local_aabb=", mesh.get_aabb())
			print("TERRAIN global_aabb=", mi.global_transform * mesh.get_aabb())
			print("TERRAIN verts=", mesh.surface_get_array_len(0))
	else:
		print("TERRAIN node missing or not MeshInstance3D")

	var hf_min := 0.0
	var hf_max := 0.0
	var hf_n := 0
	if terrain is MeshInstance3D and (terrain as MeshInstance3D).mesh != null:
		var arr: Array = (terrain as MeshInstance3D).mesh.surface_get_arrays(0)
		var vs: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		hf_n = vs.size()
		if hf_n > 0:
			hf_min = vs[0].y
			hf_max = vs[0].y
			for v in vs:
				hf_min = minf(hf_min, v.y)
				hf_max = maxf(hf_max, v.y)
			print("TERRAIN height_min=", hf_min, " height_max=", hf_max,
				" first_vert=", vs[0], " last_vert=", vs[hf_n - 1])

	var sp: Node = map.get_node_or_null("SpawnPoints")
	if sp != null:
		for c in sp.get_children():
			print("SPAWN ", c.name, " local=", (c as Node3D).position,
				" global=", (c as Node3D).global_position)

	var wb: Node = map.get_node_or_null("WaterBody")
	if wb != null:
		print("WATER children=", wb.get_child_count())
		var idx := 0
		var gmin := Vector3(1e9, 1e9, 1e9)
		var gmax := Vector3(-1e9, -1e9, -1e9)
		for c in wb.get_children():
			if c is MeshInstance3D:
				var p := (c as MeshInstance3D).global_position
				gmin = Vector3(minf(gmin.x, p.x), minf(gmin.y, p.y), minf(gmin.z, p.z))
				gmax = Vector3(maxf(gmax.x, p.x), maxf(gmax.y, p.y), maxf(gmax.z, p.z))
				if idx < 3:
					print("  WATER[", idx, "] local=", (c as Node3D).position,
						" global=", p, " mesh_aabb=", (c as MeshInstance3D).mesh.get_aabb())
				idx += 1
		print("WATER n=", idx, " global_min=", gmin, " global_max=", gmax)
	else:
		print("WATER body missing")

	var dec: Node = map.get_node_or_null("Decorations")
	if dec != null:
		var n := dec.get_child_count()
		var mn := 1e9
		var mx := -1e9
		var ymax := -1e9
		for i in range(n):
			var p: Vector3 = (dec.get_child(i) as Node3D).global_position
			mn = minf(mn, minf(p.x, p.z))
			mx = maxf(mx, maxf(p.x, p.z))
			ymax = maxf(ymax, p.y)
		print("DECO n=", n, " xz_min=", mn, " xz_max=", mx, " y_max=", ymax)
		if n > 0:
			print("  DECO[0] global=", (dec.get_child(0) as Node3D).global_position)

	var col: Node = map.get_node_or_null("Collision")
	if col != null:
		print("COLLISION children=", col.get_child_count())
		if col.get_child_count() > 0:
			var c0: Node3D = col.get_child(0)
			print("  COLLISION[0] global=", c0.global_position, " local=", c0.position)

	print("PROBE_DONE")
	quit(0)
