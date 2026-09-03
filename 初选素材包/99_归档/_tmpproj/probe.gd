extends SceneTree
func _initialize() -> void:
	var f := FileAccess.open("res://methods.txt", FileAccess.WRITE)
	for m in ClassDB.class_get_method_list("ENetConnection"):
		f.store_line("ENetConnection." + str(m.name))
	for m in ClassDB.class_get_method_list("ENetMultiplayerPeer"):
		f.store_line("ENetMultiplayerPeer." + str(m.name))
	f.close()
	quit(0)
