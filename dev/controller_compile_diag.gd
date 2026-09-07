extends SceneTree

## UnitActionsController / Selection.gd 编译检查（含属性 setter 语法）。

func _initialize():
	print("[1] load UnitActionsController.gd:")
	var c = load("res://source/match/players/human/UnitActionsController.gd")
	print("    -> ", c)
	print("[2] load Selection.gd:")
	var s = load("res://source/match/units/traits/Selection.gd")
	print("    -> ", s)
	print("[3] load TraditionalUnitCommandHUD.gd:")
	var h = load("res://source/match/hud/TraditionalUnitCommandHUD.gd")
	print("    -> ", h)
	quit()
