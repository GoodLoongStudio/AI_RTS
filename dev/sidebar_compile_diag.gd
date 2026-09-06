extends SceneTree

## Ra3Sidebar 编译隔离诊断：定位 Actions.Constructing 解析失败的真实原因。

func _initialize():
	print("[1] load Constructing.gd:")
	var constructing = load("res://source/match/units/actions/Constructing.gd")
	print("    -> ", constructing, "  can_instantiate=", constructing != null and constructing.can_instantiate())
	print("[2] load Ra3Sidebar.gd:")
	var sidebar = load("res://source/match/hud/ra3/Ra3Sidebar.gd")
	print("    -> ", sidebar)
	if sidebar != null:
		print("[3] Actions inner class:")
		var actions = sidebar.get("Actions")
		print("    -> ", actions)
	quit()
