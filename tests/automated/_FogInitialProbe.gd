extends Node

## 开局迷雾探针（用户问：开局没探索，为什么有历史战争迷雾？）
## 直接读 FogOfWar 的 _explored_grids（每玩家一份 PackedByteArray）⇒
## 量出"开局那一刻已探明的格子数、范围、离基地最远距离" ✓。

const OUT_DIR := "res://agent/runs/2026-10-02-fog-initial/"


func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		push_error("[FOG] 超时兜底")
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
	var samples := []
	# 在若干时间点采样 ✓
	for step in [1, 10, 60, 180, 420]:
		while _frames < step:
			await get_tree().physics_frame
			_frames += 1
		samples.append(_snapshot(fog, m, step))
	# 【修正】逐条明文打印（JSON.stringify 在这里输出成了空对象 ✗）
	for s in samples:
		print("[FOG] frame=%s cell=%sm grid=%s players=%s explored_cells=%s max_reach=%sm detail=%s" % [
			str(s.get("frame", -1)), str(s.get("cell_m", -1)), str(s.get("grid", [])), str(s.get("players", -1)),
			str(s.get("explored_cells", -1)), str(s.get("max_reach_m", -1)), str(s.get("player_detail", []))])
	var payload := {"probe": "fog-initial", "samples": samples}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "fog-initial.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "  "))
		f.close()
	print("[FOG] %s" % JSON.stringify(samples))
	print("Fog initial probe completed")
	get_tree().quit(0)


var _frames := 0


func _snapshot(fog: Node, m: Node, frame: int) -> Dictionary:
	if fog == null or not is_instance_valid(fog):
		return {"frame": frame, "error": "no FogOfWar"}
	var grids: Variant = fog.get("_explored_grids")
	var cell: float = float(fog.get("EXPLORED_CELL_M"))
	var size: Vector2i = fog.get("_explored_grid_size")
	var out := {"frame": frame, "cell_m": cell, "grid": [size.x, size.y], "players": 0, "explored_cells": 0,
		"max_reach_m": 0.0, "player_detail": []}
	if not (grids is Dictionary):
		out["error"] = "grids not dict"
		return out
	var dict: Dictionary = grids
	out["players"] = dict.size()
	var human: Node = m.get_node("Players").get_children()[0]
	var base_pos: Vector3 = human.get_node("CommandCenter").global_position
	for p in dict.keys():
		var grid: PackedByteArray = dict[p]
		var set_count := 0
		var max_reach := 0.0
		var min_cx := 1 << 30
		var max_cx := -1
		var min_cz := 1 << 30
		var max_cz := -1
		for cz in range(size.y):
			for cx in range(size.x):
				if grid[cz * size.x + cx] != 0:
					set_count += 1
					min_cx = mini(min_cx, cx); max_cx = maxi(max_cx, cx)
					min_cz = mini(min_cz, cz); max_cz = maxi(max_cz, cz)
					var wx := (float(cx) + 0.5) * cell
					var wz := (float(cz) + 0.5) * cell
					max_reach = maxf(max_reach, Vector2(wx - base_pos.x, wz - base_pos.z).length())
		out["explored_cells"] = maxi(int(out["explored_cells"]), set_count)
		out["max_reach_m"] = maxf(float(out["max_reach_m"]), max_reach)
		out["player_detail"].append({"name": str(p.name), "cells": set_count,
			"bbox": [min_cx, min_cz, max_cx, max_cz] if max_cx >= 0 else [],
			"max_reach_from_base_m": snappedf(max_reach, 0.01)})
	return out
