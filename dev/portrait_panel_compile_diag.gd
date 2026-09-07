extends SceneTree

## SelectionPortraitPanel / Match.gd 编译检查。

func _initialize():
	print("[1] load SelectionPortraitPanel.gd:")
	var panel = load("res://source/match/hud/ra3/SelectionPortraitPanel.gd")
	print("    -> ", panel)
	print("[2] load Match.gd:")
	var match_script = load("res://source/match/Match.gd")
	print("    -> ", match_script)
	quit()
