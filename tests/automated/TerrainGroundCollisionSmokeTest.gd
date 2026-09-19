extends Node

## 遗留地面碰撞清理守门测试（2026-09-14"单位浮空"根因修复的类级守门）。
##
## 背景：新地图的地面由 `GeneratedTerrain` 高度场网格承载，但地图文件里仍留着旧版生成器的
## 台阶盒板（`Collision/Solid*/Walk*`），两套都挂在 `terrain_navigation_input` 组里 → 导航烘焙
## 取较高面 → 单位站在盒板顶上、视觉悬空。修法：`GeneratedTerrain` 建树时把这些盒板摘出
## 导航输入并清空碰撞层（旧地图没有 GeneratedTerrain，天然不受影响）。
##
## 本测试守三件事：
## 1) 清理只认 `Solid<数字>` / `Walk<数字>`：桥等其它静态碰撞必须原样保留（不误伤）；
## 2) 清理逻辑必须留在 `GeneratedTerrain` 里（不被挪到全局路径，否则旧地图会连地面一起丢）；
## 3) `GeneratedTerrain._ready` 的调用入口存在（防被改名/删除导致修复静默失效）。

const GeneratedTerrainScript = preload("res://source/match/maps/generated/GeneratedTerrain.gd")
const NAV_GROUP := "terrain_navigation_input"

var _failures := 0
var _finished := false


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	_check_strip_only_touches_legacy_plates()
	_check_cleanup_lives_in_generated_terrain_only()
	_check_world_height_and_spawn_grounding()
	_report_real_map_structure()
	_finish()


## 1) 最小节点树：只摘 Solid*/Walk*（纯数字后缀），其它静态碰撞一律不动。
func _check_strip_only_touches_legacy_plates():
	var map := Node3D.new()
	map.name = "Map"
	add_child(map)
	var collision := Node3D.new()
	collision.name = "Collision"
	map.add_child(collision)

	var should_strip := ["Solid1", "Walk2", "Solid100", "Walk3535"]
	var should_keep := ["Bridge1", "SolidBridge", "WalkBridge7x", "WaterBody"]
	for node_name in should_strip + should_keep:
		var body := StaticBody3D.new()
		body.name = node_name
		body.collision_layer = 2
		body.add_to_group(NAV_GROUP)
		collision.add_child(body)
	# 非 StaticBody3D 的同名节点（结构不同）不该被当作盒板处理。
	var oddball := Node3D.new()
	oddball.name = "Solid5"
	collision.add_child(oddball)

	var stripped: int = GeneratedTerrainScript.strip_legacy_ground_collision(collision)
	_check(
		stripped == should_strip.size(),
		"清理数量应为 %d（实际 %d）" % [should_strip.size(), stripped]
	)

	for node_name in should_strip:
		var body := collision.get_node(node_name) as StaticBody3D
		var in_group: bool = body != null and body.is_in_group(NAV_GROUP)
		var layer: int = body.collision_layer if body != null else -1
		_check(
			body != null and not in_group and layer == 0,
			"%s 应被摘出导航输入并清空碰撞层（实际 in_group=%s layer=%s）" % [node_name, in_group, layer]
		)
	for node_name in should_keep:
		var body := collision.get_node(node_name) as StaticBody3D
		var in_group: bool = body != null and body.is_in_group(NAV_GROUP)
		var layer: int = body.collision_layer if body != null else -1
		_check(
			body != null and in_group and layer == 2,
			"%s 属桥/水面等非台阶盒板，必须原样保留（实际 in_group=%s layer=%s）" % [node_name, in_group, layer]
		)
	_check(
		oddball.is_inside_tree() and oddball.get_parent() == collision,
		"非 StaticBody3D 的同名节点不应被改动"
	)

	# 幂等：再跑一次不应出错，且已处理节点仍计入返回数量。
	var second: int = GeneratedTerrainScript.strip_legacy_ground_collision(collision)
	_check(second == should_strip.size(), "重复调用应保持幂等（实际 %d）" % second)

	map.queue_free()


## 2) 清理入口只存在于 GeneratedTerrain；全局路径（Match / TerrainNavigation）不得调用，
##    否则旧地图（地面=这些盒板）会连地面碰撞一起丢。
func _check_cleanup_lives_in_generated_terrain_only():
	_check(
		_script_has_method(GeneratedTerrainScript, "_strip_legacy_ground_plates"),
		"GeneratedTerrain 必须保留 _strip_legacy_ground_plates 入口（_ready 调用）"
	)
	_check(
		_script_has_method(GeneratedTerrainScript, "strip_legacy_ground_collision"),
		"GeneratedTerrain 必须保留可测的静态清理函数"
	)
	for path in ["res://source/match/Match.gd", "res://source/match/TerrainNavigation.gd"]:
		var text: String = _read_text(path)
		_check(
			text != "" and not ("strip_legacy_ground_collision" in text),
			"%s 不得调用遗留盒板清理（只允许 GeneratedTerrain 处理新地图）" % path
		)


## 3) 信息性检查：当前真实新地图里确实同时存在"高度场地形"与"遗留盒板"，
##    说明清理有实际作用对象（不计失败；地图更新后本条会自然变化）。
func _check_world_height_and_spawn_grounding():
	_check(
		_script_has_method(GeneratedTerrainScript, "sample_world_height"),
		"GeneratedTerrain 必须提供世界空间高度采样"
	)
	var match_text := _read_text("res://source/match/Match.gd")
	_check(
		match_text.contains("ground_height_at") and match_text.contains("HOVER_OFFSET"),
		"Match 出场必须走世界高度 + 飞机离地"
	)
	_check(
		not match_text.contains("<= 3.0"),
		"Match 不得再用 3m 护栏跳过投地"
	)
	var move_text := _read_text("res://source/match/units/traits/Movement.gd")
	_check(
		move_text.contains("_snap_air_height") and move_text.contains("_physics_process_air_move"),
		"空中单位必须按地表离地，而不是钉在 Air.Y"
	)


func _report_real_map_structure():
	var generated_root := "res://source/match/maps/generated"
	var dirs := DirAccess.get_directories_at(generated_root)
	for dir_name in dirs:
		var index_path := "%s/%s/map_index.json" % [generated_root, dir_name]
		if not FileAccess.file_exists(index_path):
			continue
		var json = JSON.parse_string(_read_text(index_path))
		if not (json is Dictionary) or not json.has("path"):
			continue
		var map_path: String = str(json["path"])
		if not FileAccess.file_exists(map_path):
			continue
		var text: String = _read_text(map_path)
		print("  [INFO] %s：GeneratedTerrain=%s Solid*=%d Walk*=%d"
			% [map_path, "GeneratedTerrain.gd" in text, text.count('name="Solid'), text.count('name="Walk')])
		return
	print("  [INFO] 未找到可读的生成地图 index（跳过真实地图结构检查）")


## 脚本对象没有实例 API has_method()；用方法表判断（顺带避免 new 出脚本触发 _ready）。
func _script_has_method(script: Script, method_name: String) -> bool:
	for method in script.get_script_method_list():
		if str(method.get("name", "")) == method_name:
			return true
	return false


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


func _on_failsafe():
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish():
	if _finished:
		return
	_finished = true
	print("Terrain ground collision smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		print("  [PASS] %s" % message)
		return
	_failures += 1
	print("FAIL: %s" % message)
