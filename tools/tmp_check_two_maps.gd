extends SceneTree

# 临时：加载两张新替换地图的 G4 场景。
const MAPS := [
	"47-903520021-767a002977",
	"36-1846106761-767a002977",
]

func _init():
	for id in MAPS:
		var path := "res://source/match/maps/generated/%s/map_%s.tscn" % [id, id]
		var packed = load(path)
		if packed == null:
			print("MAP %s  LOAD_FAIL" % id)
			continue
		var node = packed.instantiate()
		if node == null:
			print("MAP %s  INSTANTIATE_FAIL" % id)
			continue
		print("MAP %s  OK children=%d" % [id, node.get_child_count()])
		node.free()
	quit()
