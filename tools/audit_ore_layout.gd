extends SceneTree

## 散矿地图布局审计（提示词 §5 阶段 4 / §2 第 4 项「散矿地图布局」）。
##
## 只做一件事：把**每张图每一家**的主矿 / 扩张矿 / 侧翼矿 / 中央矿数量、距离、
## 容量与"能不能被一座矿场服务"算出来并落盘。布局不合格就照实写不合格，
## **不用规则阈值掩盖**（提示词原话）。
##
## 运行（headless 即可，不看画面）：
##   Godot_v4.7.1-stable_mono_win64_console.exe --headless --path G:/AIRTS/AI_RTS \
##     --script res://tools/audit_ore_layout.gd
## 输出：`build/ore_layout/audit.json` + `audit.md`
##
## 可达性口径（写在报告里，不假装测过）：
##   本工具量的是**平面距离 + 成组性**（一座矿场能不能同时服务到两颗矿）。
##   导航可达性由真实对局取证：fs_ref7 那局己方单位从基地直线走 ~170 米到达远端矿点
##   并在当地建成矿场，说明该图上这条路径是通的；其余图的路径可达性未在此工具里证明。

const BANDS := {
	"主矿": 45.0,        # ≤45m：开局工人徒步就能采，不需要矿场
	"扩张矿": 95.0,      # ≤95m：值得专门建矿场的近扩张目标
	"侧翼/共享": 150.0,  # ≤150m：边路/两家够得着的共享资源
}
const SERVICE_RADIUS := 30.0   # OreRefinery 默认服务半径（balance 里的同一口径）
## 候选图：手摆图 + 生成图入口都要覆盖（提示词 8.1「覆盖实际使用的手摆地图和生成地图入口」）。
## 【2026-09-29】原表里的 16-0-2057e4a0b4 / 14-1795193960 是旧规则产物，已删除；
## 改指当前 5 张新规则合格图。
const MAPS := [
	"res://source/match/maps/PlainAndSimple.tscn",
	"res://source/match/maps/BigArena.tscn",
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn",
	"res://source/match/maps/generated/36-1846106761-767a002977/map_36-1846106761-767a002977.tscn",
	"res://source/match/maps/generated/8-561215132-767a002977/map_8-561215132-767a002977.tscn",
	"res://source/match/maps/generated/39-655312406-767a002977/map_39-655312406-767a002977.tscn",
	"res://source/match/maps/generated/8-608324557-767a002977/map_8-608324557-767a002977.tscn",
]
const OUT_DIR := "res://build/ore_layout"

var _rows: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	for map_path in MAPS:
		if not ResourceLoader.exists(map_path):
			_rows.append({"map": map_path, "error": "地图不存在或未生成"})
			continue
		var holder := Node3D.new()
		root.add_child(holder)
		var map: Node3D = load(map_path).instantiate()
		holder.add_child(map)
		# 资源点由地图自己的脚本在运行时铺设，必须等帧。
		for _i in range(60):
			await process_frame
		_rows.append(_audit_map(map_path, map))
		holder.queue_free()
		for _i in range(5):
			await process_frame
	_write_outputs()
	quit(0)


## null 安全取整数。**不能写 `int(x or 0)`**：GDScript 的 `or` 返回 bool，
## 引擎实测 `int(30000 or 0)` == 1，那样所有矿量与容量都会变成 1。
func _ore(source, key: String) -> int:
	var value = source.get(key)
	return int(value) if value != null else 0


func _audit_map(map_path: String, map: Node3D) -> Dictionary:
	var ores: Array = []
	for node in map.find_children("*", "Node3D", true, false):
		if node.get("resource_a") != null or node.get("resource_b") != null:
			ores.append(node)
	var spawns: Array = []
	# 【为什么按父节点名过滤而不是 find_children("SpawnPoints/*")】
	# `find_children(pattern, ...)` 的 pattern 匹配的是**节点名**，不是节点路径，
	# 所以 "SpawnPoints/*" 一个也匹配不到 ⇒ 上一版四张图的 spawn_points 全是 0，
	# 整份审计退化成"按地图原点算距离"，那种数字看着像结果，其实什么都没说。
	for marker in map.find_children("*", "Marker3D", true, false):
		var parent := marker.get_parent()
		if parent != null and str(parent.name).begins_with("SpawnPoints"):
			spawns.append(marker.global_position)
	var result := {
		"map": map_path, "ore_nodes": ores.size(), "spawn_points": spawns.size(),
		"per_home": [], "unowned_nodes": 0,
	}
	if ores.is_empty():
		result["error"] = "图上没有任何资源节点"
		return result
	if spawns.is_empty():
		# 生成图用出生点标记，手摆图同样在 SpawnPoints 下；找不到就整图按中心算一份。
		result["warning"] = "找不到出生点标记，只按整图统计"
		result["whole_map"] = _band_stats(ores, Vector3.ZERO, spawns.is_empty())
		return result
	for home_index in range(spawns.size()):
		var home: Vector3 = spawns[home_index]
		var entry := _band_stats(ores, home, false)
		entry["home"] = [round(home.x * 10) / 10, round(home.z * 10) / 10]
		entry["home_index"] = home_index
		# 归属：距本家最近的那颗矿才算本家资源（两家都够得着的是共享矿）。
		var owned: Array = []
		for node in ores:
			var nearest := _distance_to_any_home(node.global_position, spawns, home)
			if nearest == home and node.global_position.distance_to(home) <= BANDS["侧翼/共享"]:
				owned.append(node)
		entry["owned_nodes"] = owned.size()
		result["per_home"].append(entry)
	return result


func _band_stats(ores: Array, home: Vector3, from_origin: bool) -> Dictionary:
	var stats := {"near": 0, "expand": 0, "flank": 0, "central": 0,
		"near_capacity": 0, "expand_capacity": 0, "flank_capacity": 0, "central_capacity": 0,
		"expand_min_dist": null, "remote_refinery_groups": 0, "remote_isolated_nodes": 0,
		"min_node_spacing": null}
	var remote: Array = []
	for node in ores:
		var distance: float = node.global_position.distance_to(home)
		var amount := _ore(node, "resource_a") + _ore(node, "resource_b")
		if distance <= BANDS["主矿"]:
			stats["near"] += 1
			stats["near_capacity"] += amount
		elif distance <= BANDS["扩张矿"]:
			stats["expand"] += 1
			stats["expand_capacity"] += amount
			stats["remote_refinery_groups"] += 0
			remote.append(node)
			if stats["expand_min_dist"] == null:
				stats["expand_min_dist"] = round(distance * 10) / 10
		elif distance <= BANDS["侧翼/共享"]:
			stats["flank"] += 1
			stats["flank_capacity"] += amount
			remote.append(node)
		else:
			stats["central"] += 1
			stats["central_capacity"] += amount
			remote.append(node)
	# "一座矿场能服务几颗"：远端矿点按 SERVICE_RADIUS 互相成组（矿场可以建在组内任意合法落点）。
	var seen := {}
	var groups := 0
	var isolated := 0
	for node in remote:
		if seen.has(node):
			continue
		groups += 1
		var stack: Array = [node]
		seen[node] = true
		var members := 0
		while not stack.is_empty():
			var current = stack.pop_back()
			members += 1
			for other in remote:
				if seen.has(other):
					continue
				if current.global_position.distance_to(other.global_position) <= SERVICE_RADIUS:
					seen[other] = true
					stack.append(other)
		if members == 1:
			isolated += 1
	stats["remote_refinery_groups"] = groups
	stats["remote_isolated_nodes"] = isolated
	var spacing = _min_spacing(ores)
	stats["min_node_spacing"] = spacing
	if from_origin:
		stats["note"] = "按地图原点统计（无出生点标记）"
	return stats


func _min_spacing(ores: Array):
	var best: float = INF
	for i in range(ores.size()):
		for j in range(i + 1, ores.size()):
			var d: float = ores[i].global_position.distance_to(ores[j].global_position)
			if d < best:
				best = d
	return null if best == INF else round(best * 100) / 100


func _distance_to_any_home(position: Vector3, spawns: Array, self_home: Vector3) -> Vector3:
	var best := self_home
	var best_distance := position.distance_to(self_home)
	for home in spawns:
		if home == self_home:
			continue
		if position.distance_to(home) < best_distance:
			best_distance = position.distance_to(home)
			best = home
	return best


func _write_outputs() -> void:
	var json_path := OUT_DIR + "/audit.json"
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(_rows, "  "))
	file.close()
	var lines: Array[String] = ["# 散矿地图布局审计（§5 阶段 4）", ""]
	lines.append("| 地图 | 矿点数 | 出生点 | 每家：主矿/扩张/侧翼/中央 | 远端可成组数 | 孤立远端矿 | 最近矿距(m) |")
	lines.append("|---|---|---|---|---|---|---|")
	for row in _rows:
		if row.has("error"):
			lines.append("| %s | — | — | — | — | — | 错误：%s |" % [row["map"], row["error"]])
			continue
		var homes: Array = []
		if row.get("per_home") is Array:
			homes = row["per_home"]
		if homes.is_empty():
				homes = [row["whole_map"]] if typeof(row.get("whole_map")) == TYPE_DICTIONARY else [{}]
		var summary := ""
		for entry in homes:
			summary += "%d/%d/%d/%d " % [
				int(entry.get("near", 0)), int(entry.get("expand", 0)),
				int(entry.get("flank", 0)), int(entry.get("central", 0))]
		var first: Dictionary = homes[0] if homes.size() > 0 else {}
		lines.append("| %s | %s | %s | %s | %s | %s | %s |" % [
			str(row["map"]).split("/")[-1], str(_ore(row, "ore_nodes")),
			str(_ore(row, "spawn_points")), ("—" if summary.strip_edges() == "" else summary.strip_edges()),
			str(first.get("remote_refinery_groups")),
			str(first.get("remote_isolated_nodes")), str(first.get("min_node_spacing"))])
	lines.append("")
	lines.append("## 判读口径")
	lines.append("- 主矿 ≤45m／扩张矿 ≤95m／侧翼共享 ≤150m／中央 >150m（超过侧翼带即高风险矿）。")
	lines.append("- 远端可成组数 = 45m 以外的矿点按 30 米（矿场服务半径）互相连通后的组数；")
	lines.append("  组数为 0 说明没有远端矿可建矿场，孤立远端矿多说明建一座矿场只能服务一颗、成本划不来。")
	lines.append("- 可达性本工具只量平面距离；导航可达由真实对局里单位实际走到远端矿点并在当地建成矿场取证。")
	var md := FileAccess.open(OUT_DIR + "/audit.md", FileAccess.WRITE)
	md.store_string("\n".join(lines) + "\n")
	md.close()
	print("[AUDIT] 写出 %s / %s" % [json_path, OUT_DIR + "/audit.md"])
