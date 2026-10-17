extends Node

## 非单位物件（金矿 / 装饰物）的碰撞与视觉对照：
## 视觉 = 所有网格世界 AABB 并集；碰撞 = CollisionShape3D 的形状；carve = MovementObstacle 半径。

const TARGETS := [
	"res://source/match/units/non-player/ResourceA.tscn",
	"res://source/match/units/non-player/ResourceB.tscn",
	"res://source/match/decorations/RockLargeA.tscn",
]


func _ready():
	await get_tree().process_frame
	print("[OBJ] 物件|视觉X|视觉Y|视觉Z|形状|形状半径/半宽|obstacle_r")
	for path in TARGETS:
		var inst: Node3D = (load(path) as PackedScene).instantiate()
		add_child(inst)
		await get_tree().process_frame
		await get_tree().physics_frame
		var box := AABB()
		var first := true
		for gi in inst.find_children("*", "GeometryInstance3D", true, false):
			var p := str(gi.get_path())
			if p.contains("Selection") or p.contains("Highlight") or p.contains("Targetability"):
				continue
			var w: AABB = (gi as GeometryInstance3D).get_aabb()
			if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and w.size.length() < 0.01:
				w = (gi as MeshInstance3D).mesh.get_aabb()
			if w.size.length() < 0.001:
				continue
			var xf: Transform3D = (gi as Node3D).global_transform
			for i in range(8):
				var pt: Vector3 = xf * w.get_endpoint(i)
				if first:
					box = AABB(pt, Vector3.ZERO); first = false
				else:
					box = box.expand(pt)
		var cs := inst.find_child("CollisionShape3D", true, false) as CollisionShape3D
		var kind := "无"
		var r := -1.0
		if cs != null and cs.shape != null:
			var s := cs.shape
			var sc: Vector3 = cs.global_transform.basis.get_scale()
			if s is CylinderShape3D:
				kind = "Cylinder"; r = (s as CylinderShape3D).radius * sc.x
			elif s is BoxShape3D:
				kind = "Box"; r = (s as BoxShape3D).size.x * 0.5 * sc.x
			elif s is CapsuleShape3D:
				kind = "Capsule"; r = (s as CapsuleShape3D).radius * sc.x
		var ob_r := -1.0
		var ob: Node = inst.find_child("MovementObstacle", true, false)
		if ob != null:
			ob_r = float(ob.get("radius"))
		print("[OBJ] %s|%.2f|%.2f|%.2f|%s|%.2f|%.2f" % [
			path.get_file().replace(".tscn", ""), box.size.x, box.size.y, box.size.z, kind, r, ob_r])
		var flag := "无"
		var clearance := 0.0
		if ob != null:
			flag = "true" if bool(ob.get("affect_navigation_mesh")) else "false"
			clearance = Utils.Match.Unit.Movement.carve_clearance_of(inst)
		print("[OBJ]   ↳ 参与导航烘焙=%s | carve 净空=%.2fm" % [flag, clearance])
		inst.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)
