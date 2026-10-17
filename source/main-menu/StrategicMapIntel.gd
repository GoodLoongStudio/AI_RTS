extends RefCounted
class_name StrategicMapIntel

## 只读地图情报服务（2026-10-05 阶段 2）：从地图 .tscn 的**文本**提取 SpawnPoints、
## Resources 节点和地图元数据。不实例化场景、不创建 Match、不触发地形/碰撞/导航。
## 加载失败返回 {ok:false, error_code:...}；不返回空的"成功情报"。

const SPAWN_COUNT := 4


static func build(map_path: String) -> Dictionary:
	var handle := FileAccess.open(map_path, FileAccess.READ)
	if handle == null:
		return {"ok": false, "error_code": "map_file_not_found", "map_path": map_path}
	var text := handle.get_as_text()
	handle.close()
	var spawn_points := _parse_spawn_points(text)
	var resources := _parse_resources(text)
	var map_name := map_path.get_file().get_basename()
	var preview := _preview_path(map_path)
	# 【2026-10-06 阶段 2A 补齐】提示词要求情报对象带 map_size ✓。
	# 权威来源优先**地图场景自身**的 Map.size（世界米 ✓），读不到再回退常量表；
	# 两者都没有 ⇒ Vector2.ZERO + 在 unknown_facts 里明说「未知」✓（不估算 ✗）。
	var map_size := _parse_map_size(text)
	if map_size == Vector2.ZERO:
		var info: Dictionary = Constants.Match.ALL_MAPS.get(map_path, {})
		var s: Variant = info.get("size", null)
		if s is Vector2i:
			map_size = Vector2(s as Vector2i)
	var known := []
	known.append("地图文件 %s" % map_path.get_file())
	known.append("出生点 %d 个（地图场景 SpawnPoints 子节点权威坐标）" % spawn_points.size())
	if map_size != Vector2.ZERO:
		known.append("地图尺寸 %d × %d（世界米，来自所选地图）" % [int(map_size.x), int(map_size.y)])
	if resources.size() > 0:
		known.append("资源节点 %d 个（位置/类型从地图场景只读提取）" % resources.size())
	var unknown := [
		"敌方单位与意图", "实时资源变化", "地形通行性", "隐藏路径与视野盲区",
	]
	if map_size == Vector2.ZERO:
		unknown.append("地图尺寸（地图场景与常量表均未提供 ⇒ 未知）")
	return {
		"ok": true,
		"map_path": map_path,
		"map_id": map_name,
		"map_name": map_name,
		"map_size": map_size,
		"preview_path": preview,
		"spawn_points": spawn_points,
		"resources": resources,
		"known_facts": known,
		"unknown_facts": unknown,
	}


## 从 .tscn 文本提取地图世界尺寸（Map 节点的 size = Vector2(w, h) ✓）；读不到返回 ZERO ✓。
static func _parse_map_size(text: String) -> Vector2:
	# 【陷阱】地图场景里有**两个** size ✗：Terrain 网格是 (地图+2×EXTRA_MARGIN)，Map 节点才是真值。
	# 例：PlainAndSimple 的 Terrain = 212×212，Map = 208×208。
	# ⇒ 只在 **[node name="Map"** 之后的那一段里取 size ✓，绝不取第一个匹配 ✗。
	var lines := text.split("\n")
	var in_map := false
	for line in lines:
		var l := str(line).strip_edges()
		if l.begins_with("[node name="):
			in_map = l.begins_with("[node name=\"Map\"")
			continue
		if not in_map or not l.begins_with("size = Vector2("):
			continue
		var inner := l.substr("size = Vector2(".length())
		inner = inner.substr(0, inner.find(")"))
		var parts := inner.split(",")
		if parts.size() >= 2:
			return Vector2(float(parts[0]), float(parts[1]))
	return Vector2.ZERO


## 从 .tscn 文本提取 SpawnPoints 下 Marker3D 的世界坐标（只读文本解析，不实例化场景）。
static func _parse_spawn_points(text: String) -> Array:
	var points: Array = []
	var lines := text.split("\n")
	var in_spawn := false
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("[node ") and stripped.contains("SpawnPoints"):
			in_spawn = true
			continue
		if in_spawn and stripped.begins_with("[node "):
			# 离开 SpawnPoints 子节点区域（遇到下一个非 SpawnPoints 子节点）
			if not stripped.contains("parent=\"SpawnPoints"):
				in_spawn = false
				continue
		if not in_spawn:
			continue
		if stripped.begins_with("transform = Transform3D("):
			var coords := _parse_transform_origin(stripped)
			if coords != Vector3.INF:
				points.append({
					"index": points.size(),
					"world_x": coords.x,
					"world_z": coords.z,
					"facing": "未知",
					"label": "出生点 %d" % (points.size() + 1),
				})
	return points


## 从 .tscn 文本提取 Resources 下的资源节点（类型/位置）。
static func _parse_resources(text: String) -> Array:
	var out: Array = []
	var lines := text.split("\n")
	var in_res := false
	for line in lines:
		var stripped := line.strip_edges()
		if stripped.begins_with("[node ") and stripped.contains("Resources"):
			in_res = true
			continue
		if in_res and stripped.begins_with("[node ") and not stripped.contains("parent=\"Resources"):
			in_res = false
			continue
		if not in_res:
			continue
		if stripped.begins_with("[node ") and stripped.contains("instance="):
			var node_name := _extract_node_name(stripped)
			var type := "unknown"
			if node_name.contains("ResourceA") or node_name.contains("resource_a"):
				type = "A"
			elif node_name.contains("ResourceB") or node_name.contains("resource_b"):
				type = "B"
			for line2 in lines:
				if line2.contains(node_name) and line2.contains("transform"):
					var coords := _parse_transform_origin(line2.strip_edges())
					if coords != Vector3.INF:
						out.append({"type": type, "world_x": coords.x, "world_z": coords.z,
							"amount": "未知"})
					break
	return out


static func _parse_transform_origin(line: String) -> Vector3:
	var start := line.find("Transform3D(")
	if start == -1:
		return Vector3.INF
	var inner := line.substr(start + 12, line.length() - start - 13)
	var nums := inner.split(",")
	if nums.size() < 12:
		return Vector3.INF
	return Vector3(
		nums[9].strip_edges().to_float(),
		nums[10].strip_edges().to_float(),
		nums[11].strip_edges().to_float())


static func _extract_node_name(line: String) -> String:
	var start := line.find("name=\"")
	if start == -1:
		return ""
	var rest := line.substr(start + 6)
	var end := rest.find("\"")
	return rest.substr(0, end) if end != -1 else ""


static func _preview_path(map_path: String) -> String:
	var slug := map_path.get_file().get_basename()
	return "res://assets/map_previews/%s.png" % slug


## 摘要文本（嵌入聊天上下文用的紧凑一行）。
static func compact_summary(intel: Dictionary) -> String:
	if not intel.get("ok", false):
		return "地图情报不可用"
	var spawns := []
	for sp in intel.get("spawn_points", []):
		spawns.append("#%d(%.0f,%.0f)" % [sp["index"] + 1, sp["world_x"], sp["world_z"]])
	var res := []
	for r in intel.get("resources", []):
		res.append("%s(%.0f,%.0f)" % [r["type"], r["world_x"], r["world_z"]])
	return "地图=%s 尺寸=%s 出生点=%s 资源节点=%d个" % [
		intel.get("map_name", "?"), "见地图预览", "、".join(spawns) if spawns.size() > 0 else "未知",
		res.size()]
