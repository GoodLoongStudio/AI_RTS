extends Node

## 最小开局迷雾探针 ✓：只打原始值，回答"开局为什么这里会有迷雾/已探索" ✓。

func _process(_delta: float) -> void:
	# 【关键】游戏在窗口失焦时暂停整棵树 ⇒ headless 探针会永远等不到 physics_frame ✗
	if get_tree().paused:
		get_tree().paused = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		push_error("[FOGMIN] 超时")
		get_tree().quit(2))
	await _run()


func _run() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	add_child(m)
	get_tree().current_scene = m
	var fog: Node = m.get_node_or_null("FogOfWar")
	print("[FOGMIN] FogOfWar 节点 = ", fog)
	for step in [2, 30, 120, 400]:
		for _i in range(step):
			await get_tree().physics_frame
		if fog == null:
			print("[FOGMIN] frame=%d 无 FogOfWar" % step)
			continue
		var grids = fog.get("_explored_grids")
		var gsize = fog.get("_explored_grid_size")
		var human: Node = m.get_node("Players").get_children()[0]
		var cc: Node3D = human.get_node_or_null("CommandCenter")
		var set_total := 0
		var players := 0
		var farthest := 0.0
		if grids is Dictionary:
			var d: Dictionary = grids
			players = d.size()
			for k in d.keys():
				var g: PackedByteArray = d[k]
				var n := 0
				for i in range(g.size()):
					if g[i] != 0:
						n += 1
				set_total += n
				if n > 0 and gsize is Vector2i and cc != null:
					var sx: int = (gsize as Vector2i).x
					for i in range(g.size()):
						if g[i] == 0:
							continue
						var cx := i % sx
						var cz := i / sx
						var wx := (float(cx) + 0.5) * 2.0
						var wz := (float(cz) + 0.5) * 2.0
						farthest = maxf(farthest, Vector2(wx - cc.global_position.x, wz - cc.global_position.z).length())
		print("[FOGMIN] frame=%d players=%d 已探明格=%d 网格=%s 探明最远=%.1fm CC=(%.1f,%.1f)" % [
			step, players, set_total, str(gsize), farthest,
			cc.global_position.x if cc != null else -999.0, cc.global_position.z if cc != null else -999.0])
		var units := get_tree().get_nodes_in_group("revealed_units")
		var own := 0
		var enemy := 0
		var details := []
		for u in units:
			if u is Node3D:
				var owner_ok := u.get_parent() == human
				if owner_ok:
					own += 1
				else:
					enemy += 1
				if details.size() < 6:
					details.append("%s(own=%s,sight=%s)" % [u.name, str(owner_ok), str(u.get("sight_range"))])
		print("[FOGMIN] frame=%d revealed_units=%d 己方=%d 其他=%d 例:%s" % [step, units.size(), own, enemy, str(details)])
	print("FogMin probe completed")
	get_tree().quit(0)
