extends Node

## 临时探针：炮塔实例化后打印节点树，定位挂点丢失原因。

func _ready():
	var unit: Node3D = load(str(OS.get_environment("TURRET_SCENE")) if OS.get_environment("TURRET_SCENE") != "" else "res://source/match/units/AntiGroundTurret.tscn").instantiate()
	add_child(unit)
	await get_tree().process_frame
	print("[PRB] root=", unit.name, " scale=", unit.scale)
	print("[PRB] MuzzleL(owned=true)=", unit.find_child("MuzzleL", true, true))
	print("[PRB] MuzzleL(owned=false)=", unit.find_child("MuzzleL", true, false))
	print("[PRB] Geometry=", unit.find_child("Geometry", true, true))
	print("[PRB] DetachTransform=", unit.find_child("DetachTransform", true, true))
	var geo := unit.find_child("Geometry", true, true)
	if geo != null:
		print("[PRB] Geometry children=", geo.get_children())
		for c in geo.get_children():
			print("[PRB]   geo child: ", c.name, " (", c.get_class(), ") owner=", c.owner)
	var stack: Array = [[unit, 0]]
	while not stack.is_empty():
		var entry = stack.pop_back()
		var node = entry[0]
		var depth: int = entry[1]
		if depth < 4:
			print("[PRB] tree ", "  ".repeat(depth), node.name, " (", node.get_class(), ")")
		for child in node.get_children():
			stack.push_back([child, depth + 1])
	get_tree().quit(0)
