extends Node

## 单位登记一致性冒烟测试（2026-09-12）。
##
## 为什么需要：一个单位"存在"这件事被手工登记在 6 处 ——
##   config/godot/*.assets.v1.json 的 unitAssets / weaponAssets、
##   CombatSfx.FIRE_SOUND_BY_SCENE（场景→开火音效）、
##   ProjectileVisuals.PROJECTILE_BY_UNIT_SCENE（场景→弹道表现）、
##   Ra3Sidebar 卡片、balance 的 unitTypes/constructions/productions、显示名表。
## 漏登记**不报错**，只在运行时静默失效 —— 2026-09-11/12 连续两次被咬：
## 装甲车与重型坦克漏了后两张镜像表 → "能打，但没声音、没弹道"。
## 本测试把"漏一处"变成"提交即失败"，并顺带禁止 get_meta(key, null) 这类静默地雷。

const ASSETS_CONFIG := "res://config/godot/demo.assets.v1.json"
const BALANCE_CONFIG := "res://config/balance/demo.balance.v1.json"
const COMBAT_SFX_SCRIPT := "res://source/match/units/traits/CombatSfx.gd"
const PROJECTILE_VISUALS_SCRIPT := "res://source/match/units/projectiles/ProjectileVisuals.gd"
const COMMAND_HUD_SCRIPT := "res://source/match/hud/TraditionalUnitCommandHUD.gd"

var _failures := 0
var _finished := false
var _warnings: Array = []


func _ready():
	await get_tree().process_frame
	_check_registrations()
	_check_aim_node_names()
	_check_meta_antipattern()
	_finish()


## 炮塔瞄准节点名必须与**代码查找名**一致：`AttackingWhileInRange._find_stationary_aim_node`
## 与 `Unit.presentation_aim_node` 找的都是 `RotateRandomlyWhenLookingForTargets`。
## 2026-09-12 实测：`AntiAirTurret.tscn` 里那个节点叫 `...Idle` → 对空炮塔的瞄准节点
## 永远解析不到（战斗瞄准退回转整座建筑、也没有待机扫描），而且**完全静默**。
func _check_aim_node_names():
	var offenders: Array = []
	_collect_aim_name_offenders("res://source/match/units", offenders)
	for path in offenders:
		_check(
			false,
			"炮塔瞄准节点名与代码查找名不一致（应命名 RotateRandomlyWhenLookingForTargets）: %s" % path
		)


func _collect_aim_name_offenders(dir_path: String, offenders: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			if not name.begins_with("."):
				_collect_aim_name_offenders(full, offenders)
		elif name.ends_with(".tscn") and not full.contains("/traits/"):
			# 只查单位场景：trait 自身场景的根节点就叫 ...Idle，那是它的默认名，不是问题；
			# 真正要一致的是**实例到单位场景时用的节点名**（代码按这个名字 find_child）。
			var file := FileAccess.open(full, FileAccess.READ)
			if file != null:
				var text := file.get_as_text()
				if text.contains('name="RotateRandomlyWhenLookingForTargetsIdle"'):
					offenders.append(full)
		name = dir.get_next()
	dir.list_dir_end()


# ---------------------------------------------------------------- 登记一致性

func _check_registrations():
	var assets := _load_json(ASSETS_CONFIG)
	var balance := _load_json(BALANCE_CONFIG)
	if assets.is_empty() or balance.is_empty():
		return

	var scene_by_type := {}
	var types_by_scene := {}
	for entry in assets.get("unitAssets", []):
		var type_id := str(entry.get("unitTypeId", ""))
		var scene := str(entry.get("scenePath", ""))
		if type_id.is_empty() or scene.is_empty():
			_check(false, "unitAssets 条目缺 unitTypeId/scenePath: %s" % str(entry))
			continue
		scene_by_type[type_id] = scene
		types_by_scene[scene] = type_id
		_check(ResourceLoader.exists(scene), "unitAssets[%s] 的场景不存在: %s" % [type_id, scene])

	var weapons_by_id := {}
	for entry in assets.get("weaponAssets", []):
		weapons_by_id[str(entry.get("weaponId", ""))] = str(entry.get("projectileScenePath", ""))

	var fire_sound := _script_const(COMBAT_SFX_SCRIPT, "FIRE_SOUND_BY_SCENE")
	var projectile_visual := _script_const(PROJECTILE_VISUALS_SCRIPT, "PROJECTILE_BY_UNIT_SCENE")
	var display_names := _script_const(COMMAND_HUD_SCRIPT, "_UNIT_DISPLAY_NAMES")

	# 1) 带武器的单位必须同时登记"开火音效 + 弹道表现"，且其武器要有投射物映射
	var type_ids := {}
	for unit_type in balance.get("unitTypes", []):
		var type_id := str(unit_type.get("id", ""))
		type_ids[type_id] = true
		var weapon_ids: Array = unit_type.get("weaponIds", [])
		if weapon_ids.is_empty():
			continue
		var scene := str(scene_by_type.get(type_id, ""))
		if scene.is_empty():
			_check(false, "unitTypes[%s] 带武器，却在 unitAssets 里没有场景登记" % type_id)
			continue
		_check(
			fire_sound.has(scene),
			"带武器单位 %s（%s）未登记开火音效 → 开火没声音" % [type_id, scene]
		)
		_check(
			projectile_visual.has(scene),
			"带武器单位 %s（%s）未登记弹道表现 → 客户端看不到弹道" % [type_id, scene]
		)
		for weapon_id in weapon_ids:
			_check(
				weapons_by_id.has(str(weapon_id)),
				"单位 %s 使用武器 %s，但 weaponAssets 没有它的投射物映射" % [type_id, str(weapon_id)]
			)

	# 2) 反向：镜像表里不许残留"已不存在的单位"（删单位时最容易漏）
	for scene in fire_sound:
		_check(types_by_scene.has(scene), "开火音效表残留未登记场景: %s" % str(scene))
	for scene in projectile_visual:
		_check(types_by_scene.has(scene), "弹道表现表残留未登记场景: %s" % str(scene))

	# 3) 生产/建造配置引用的单位类型必须存在
	for item in balance.get("productions", []):
		var product := str(item.get("productUnitTypeId", ""))
		_check(type_ids.has(product), "productions 引用了不存在的单位类型: %s" % product)
	for item in balance.get("constructions", []):
		var built := str(item.get("unitTypeId", ""))
		_check(type_ids.has(built), "constructions 引用了不存在的单位类型: %s" % built)

	# 4) 显示名覆盖（选中摘要栏）：缺了只是退化成原始 id，不算失败但列出来
	if not display_names.is_empty():
		var missing: Array = []
		for type_id in type_ids:
			if not display_names.has(type_id):
				missing.append(type_id)
		if not missing.is_empty():
			_warnings.append("显示名表缺 %s（选中摘要会显示英文 id）" % str(missing))


# ---------------------------------------------------------------- 静默地雷

## 禁止 `get_meta(key, null)`：Godot 4.7 把显式 null 默认值当成"未提供 default"，
## 于是**每次调用都报错 + 堆栈**；放进 _process 就是"单位数 × 帧率"条错误/秒
## （2026-09-12 实测把 client.out 撑到 10.8MB、帧率 120→11）。
func _check_meta_antipattern():
	var pattern := RegEx.new()
	pattern.compile("get_meta\\([^)]*,\\s*null\\s*\\)")
	var offenders: Array = []
	_scan_dir("res://source", pattern, offenders)
	for path in offenders:
		_check(false, "禁止 get_meta(key, null)（先 has_meta 再取）: %s" % path)


func _scan_dir(dir_path: String, pattern: RegEx, offenders: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			if name != "." and name != ".." and not name.begins_with("."):
				_scan_dir(full, pattern, offenders)
		elif name.ends_with(".gd"):
			var file := FileAccess.open(full, FileAccess.READ)
			if file != null and pattern.search(_code_only(file.get_as_text())) != null:
				offenders.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## 只保留代码行：注释里写 `get_meta(x, null)` 是文档说明，不该判为违规。
func _code_only(text: String) -> String:
	var lines: Array = []
	for line in text.split("\n"):
		var hash_index := line.find("#")
		lines.append(line if hash_index < 0 else line.substr(0, hash_index))
	return "\n".join(lines)


# ---------------------------------------------------------------- 工具

func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_check(false, "配置读取失败: %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed == null or not (parsed is Dictionary):
		_check(false, "配置不是合法 JSON 对象: %s" % path)
		return {}
	return parsed


func _script_const(path: String, const_name: String) -> Dictionary:
	var script: Script = load(path)
	if script == null:
		_check(false, "脚本加载失败: %s" % path)
		return {}
	var constants: Dictionary = script.get_script_constant_map()
	if not constants.has(const_name):
		_check(false, "在 %s 里找不到 const %s" % [path, const_name])
		return {}
	var value = constants[const_name]
	if not (value is Dictionary):
		_check(false, "%s.%s 不是字典" % [path, const_name])
		return {}
	return value


func _finish():
	if _finished:
		return
	_finished = true
	for warning in _warnings:
		print("WARN: %s" % warning)
	print("Unit registration consistency smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Unit registration consistency smoke test assertion failed: %s" % message)
