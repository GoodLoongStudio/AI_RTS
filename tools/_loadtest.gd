extends SceneTree

## 临时诊断（2026-09-21）：验证地图场景能否被 load —— 用来区分「地图本身坏」还是「导出漏了」。
## 用法：godot --headless --path <repo> --script res://tools/_loadtest.gd

func _init() -> void:
	var paths := [
		"res://source/match/maps/PlainAndSimple.tscn",
		"res://source/match/maps/BigArena.tscn",
		"res://source/match/maps/generated/16-0/map_16-0.tscn",
		"res://source/match/maps/generated/47-0/map_47-0.tscn",
	]
	for p in paths:
		var exists := ResourceLoader.exists(p)
		var res = null
		if exists:
			res = ResourceLoader.load(p)
		print("[LOADTEST] %-58s exists=%s loaded=%s type=%s" % [
			p, str(exists), str(res != null), (res.get_class() if res != null else "-")])
	quit()
