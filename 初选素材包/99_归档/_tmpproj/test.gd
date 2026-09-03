extends SceneTree
func _initialize() -> void:
	var f := FileAccess.open("res://script_ran.txt", FileAccess.WRITE)
	f.store_string("OK")
	f.close()
	quit(0)
