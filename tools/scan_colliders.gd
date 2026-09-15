extends SceneTree

## 碰撞体静态扫描：遍历 G4 导出地图的全部 CollisionShape3D，
## 找 NaN / 退化（零面积、点数不足）/ 超大网格 —— TerrainNavigation
## parse/bake 线程 0xC0000005 的嫌疑数据源。纯读数据，不触发烘焙。

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var map_path := "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
	var map = load(map_path).instantiate()
	root.add_child(map)

	var total := 0
	var bad := []
	var by_owner := {}
	var todo: Array[Node] = [map]
	while not todo.is_empty():
		var n: Node = todo.pop_back()
		todo.append_array(n.get_children())
		if n is CollisionShape3D and n.shape != null:
			total += 1
			var sh: Shape3D = n.shape
			var issues := []
			var owner_node := _owner_of(n, map)
			if sh is ConcavePolygonShape3D:
				var faces: PackedVector3Array = sh.get_faces()
				var tris: int = faces.size() / 3
				if tris > 60000:
					issues.append("huge_tris=%d" % tris)
				if faces.size() == 0:
					issues.append("empty_faces")
				var step: int = maxi(1, faces.size() / 200)
				var nan_cnt := 0
				var degenerate := 0
				var checked := 0
				var i := 0
				while i + 2 < faces.size():
					var a := faces[i]
					var b := faces[i + 1]
					var c := faces[i + 2]
					if a.x != a.x or a.y != a.y or a.z != a.z:
						nan_cnt += 1
					var e1 := b - a
					var e2 := c - a
					var cr := e1.cross(e2)
					if cr.length() < 1e-9:
						degenerate += 1
					checked += 1
					i += step * 3
				if nan_cnt > 0:
					issues.append("NaN_sampled=%d" % nan_cnt)
				if checked > 0 and degenerate == checked:
					issues.append("all_degenerate")
			elif sh is ConvexPolygonShape3D:
				var pts: PackedVector3Array = sh.points
				if pts.size() < 4:
					issues.append("degenerate_convex_pts=%d" % pts.size())
			elif sh is BoxShape3D:
				var bs: Vector3 = sh.size
				if bs.x <= 0.0 or bs.y <= 0.0 or bs.z <= 0.0:
					issues.append("zero_box")
			if issues.size() > 0:
				bad.append("%s | %s | %s" % [str(owner_node), String(sh.get_class()).substr(0, 12), ", ".join(issues)])
				var ok := by_owner.get(owner_node, 0) as int
				by_owner[owner_node] = ok + 1

	print("SCAN total collision shapes: ", total)
	print("SCAN suspicious: ", bad.size())
	for b in bad:
		print("BAD  ", b)
	var summary := []
	for k in by_owner:
		summary.append("%s x%d" % [k, by_owner[k]])
	print("BY_OWNER ", " | ".join(summary))
	quit(0)

func _owner_of(n: Node, root_node: Node) -> String:
	var parts := []
	var cur: Node = n
	while cur != null and cur != root_node:
		parts.push_front(String(cur.name).substr(0, 14))
		cur = cur.get_parent()
	return "/".join(parts)
