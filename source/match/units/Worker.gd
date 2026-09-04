extends "res://source/match/units/Unit.gd"

var resource_a = 0


func is_full():
	assert(resource_a <= resources_max, "worker capacity was exceeded somehow")
	return resource_a == resources_max
