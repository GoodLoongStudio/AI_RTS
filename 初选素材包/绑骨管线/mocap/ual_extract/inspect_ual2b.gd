extends SceneTree

## UAL2 动画库清单
func _initialize():
	var path := "res://.godot_imported_UAL2_Source.gltf-320733edd54c171d8e44a152216067ac.res"
	var lib = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as AnimationLibrary
	if lib == null:
		print("LOAD_NULL")
		quit(1)
		return
	var names: PackedStringArray = lib.get_animation_list()
	print("UAL2_COUNT ", names.size())
	for n in names:
		print("UAL2_ANIM ", n)
	quit(0)
