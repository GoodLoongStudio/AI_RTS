extends Node
func _ready():
	var unit: Node3D = load("res://source/match/units/AntiGroundTurret.tscn").instantiate()
	add_child(unit)
	await get_tree().process_frame
	print("[PRB] owned=false MuzzleL=", unit.find_child("MuzzleL", true, false))
	print("[PRB] owned=true  MuzzleL=", unit.find_child("MuzzleL", true, true))
	print("[PRB] owned=false ProjectileOrigin=", unit.find_child("ProjectileOrigin", true, false))
	var nested := unit.find_child("Geometry", true, true)
	print("[PRB] Geometry(owned=true)=", nested, " children=", nested.get_child_count() if nested else -1)
	var detach := unit.find_child("DetachTransform", true, true)
	print("[PRB] DetachTransform(owned=true)=", detach, " owner=", detach.owner if detach else null)
	get_tree().quit(0)
