extends SceneTree
func _init():
	for path in ["res://source/match/handlers/MatchEndHandler.gd",
			"res://source/history/MatchReportStore.gd",
			"res://source/growth/GrowthStore.gd",
			"res://source/FeatureFlags.gd"]:
		var s = load(path)
		print("LOADCHK", path, "->", s != null)
	quit()
