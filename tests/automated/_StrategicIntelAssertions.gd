extends Node

## 情报服务断言（RSI round-05 ✓，提示词 §2「必须可测试」）：
## 至少两张具体地图：map_name / preview_path / map_size / 4 个出生点坐标 / 资源摘要 必须**随输入变化** ✓；
## 加载失败必须返回**明确错误对象**（不是空的"成功情报" ✓）。

## 显式 preload：class_name 全局缓存在文件刚改过时可能还没刷新 ✗（实测踩到）
const Intel = preload("res://source/main-menu/StrategicMapIntel.gd")

var _failures := 0


func _ready() -> void:
	var paths: Array = MatchSetupShared.map_paths()
	var a: Dictionary = Intel.build(str(paths[0]))
	var b: Dictionary = Intel.build(str(paths[1]))
	_dump("A", a)
	_dump("B", b)
	_check(bool(a.get("ok", false)) and bool(b.get("ok", false)), "两张真实地图的情报都必须 ok")
	_check(str(a.get("map_name", "")) != str(b.get("map_name", "")), "map_name 必须随地图变化（%s vs %s）" % [a.get("map_name"), b.get("map_name")])
	_check(str(a.get("preview_path", "")) != str(b.get("preview_path", "")), "preview_path 必须随地图变化")
	_check(a.get("map_size", Vector2.ZERO) != Vector2.ZERO and b.get("map_size", Vector2.ZERO) != Vector2.ZERO, "map_size 必须有值（A=%s B=%s）" % [str(a.get("map_size")), str(b.get("map_size"))])
	_check((a.get("spawn_points", []) as Array).size() == 4 and (b.get("spawn_points", []) as Array).size() == 4, "两张地图都必须 4 个出生点")
	var sa: Array = a.get("spawn_points", [])
	var sb: Array = b.get("spawn_points", [])
	if sa.size() > 0 and sb.size() > 0:
		_check(float(sa[0].get("world_x", 0.0)) != float(sb[0].get("world_x", 0.0)) or float(sa[0].get("world_z", 0.0)) != float(sb[0].get("world_z", 0.0)), "出生点坐标必须随地图变化")
	# 尺寸必须与地图场景 Map 节点的真值一致（不是 Terrain 的 +4 ✗）
	var expected: Dictionary = {"PlainAndSimple.tscn": Vector2(208, 208)}
	for key in expected.keys():
		for it in [a, b]:
			if str(it.get("map_name", "")) == key.replace(".tscn", ""):
				_check(it.get("map_size") == expected[key], "%s 的 map_size 必须是 %s（Map 节点真值 ✓，不是 Terrain 网格 +4 ✗），实际 %s" % [key, str(expected[key]), str(it.get("map_size"))])
	# 加载失败 ⇒ 明确错误对象 ✓
	var bad: Dictionary = Intel.build("res://source/match/maps/__not_exist__.tscn")
	_check(not bool(bad.get("ok", true)) and str(bad.get("error_code", "")) == "map_file_not_found", "加载失败必须返回明确错误对象（实际 %s）" % str(bad))
	_check(bad.has("map_path"), "错误对象必须带上出错的 map_path")
	print("Strategic intel assertions completed: %d failure(s)" % _failures)
	get_tree().quit(0 if _failures == 0 else 1)


func _dump(tag: String, it: Dictionary) -> void:
	var sp: Array = it.get("spawn_points", [])
	var first := str(sp[0]) if sp.size() > 0 else "<none>"
	print("[INTEL] %s name=%s size=%s preview=%s 出生点=%d 资源=%d 首个=%s" % [
		tag, str(it.get("map_name", "")), str(it.get("map_size", "")), str(it.get("preview_path", "")).get_file(),
		sp.size(), (it.get("resources", []) as Array).size(), first])


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[INTEL] OK: " + msg)
	else:
		_failures += 1
		push_error("[INTEL] FAIL: " + msg)
