extends Node

## 成长系统（永久加点）「真在对局里生效」守门测试。
##
## 为什么必须有它：2026-09-21 核查发现成长等级**只被加点页 UI 读取**、从没进入对局
## 数值 —— 玩家花光 12 点，战斗/采集/建造/生产一点变化都没有。这类缺陷不会报错、
## 不会崩溃，只能靠"断言数值真的变了"来兜住。
##
## 跑法：godot --headless --path AI_RTS res://tests/automated/GrowthModifiersSmokeTest.tscn

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Mods = preload("res://source/match/augments/AugmentModifiers.gd")

## 满配加点：覆盖全部 11 个效果维度（数值与 config/growth_definitions.json 对齐）。
const FULL_LEVELS := {
	"combat_power": 5,
	"combat_guard": 5,
	"combat_mobility": 4,
	"combat_command": 4,
	"economy_gather": 5,
	"economy_stock": 5,
	"economy_production": 3,
	"economy_logistics": 4,
	"construction_speed": 5,
	"construction_armor": 5,
	"construction_network": 3,
}

var _failures := 0
var _match: Node = null
var _human: Node = null
var _ai: Node = null
var _state_backup: Dictionary = {}


func _ready() -> void:
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().create_timer(1.2, true, false, true).timeout
	_human = _match.get_node_or_null("Players/Human")
	_ai = _match.get_node_or_null("Players/SimpleClairvoyantAI")
	if _human == null:
		_fail("测试场景应包含 Human 玩家")
		_finish()
		return
	# Match 的 `_setup_players()` 要等地形/导航烘焙完成后才跑，玩家此时还没进
	# "players" 组 ⇒ `get_local_player()` 为 null，成长判据会误判成"不适用"。
	# 必须等它就绪，否则本测试只是在测"开局 1.2 秒"这个时机，而不是成长本身。
	await _await_match_ready()
	_state_backup = GrowthStore.state.duplicate(true)
	_test_definitions_have_effects()
	_test_conversion()
	_test_meta_name_parity()
	await _test_unit_application()
	await _test_worker_application()
	_test_player_scope()
	_test_match_award()
	# 还原：探针不得把满级加点留在玩家存档里。
	GrowthStore.state = _state_backup
	GrowthStore.save_state()
	GrowthModifiers.reset_cache()
	_finish()


## 每个成长节点都必须带 `effect`，且类型在 `GrowthModifiers.EFFECT_KEYS` 白名单内。
## 这是"加了点却没效果"的根因护栏：新增节点忘了写 effect 会立即被抓。
func _test_definitions_have_effects() -> void:
	var total := 0
	for branch in GrowthStore.DEFINITIONS.values():
		for node in branch:
			total += 1
			var node_id := str((node as Dictionary).get("id", ""))
			var effect = (node as Dictionary).get("effect", null)
			_check(effect is Dictionary, "%s 必须带 effect（否则加点不生效）" % node_id)
			if not effect is Dictionary:
				continue
			var type := str((effect as Dictionary).get("type", ""))
			_check(GrowthModifiers.EFFECT_KEYS.has(type),
				"%s 的 effect.type=%s 必须在可施加白名单内" % [node_id, type])
			_check(float((effect as Dictionary).get("value", 0.0)) != 0.0,
				"%s 的 effect.value 不得为 0" % node_id)
	_check(total >= 15, "成长树应有完整节点（实际 %d）" % total)


## 换算口径：倍率 = 1 + value * level（start_resources 为绝对值累加）。
func _test_conversion() -> void:
	var none := GrowthModifiers.effects_for_levels({})
	_check(is_equal_approx(float(none.get("damage_mult", 0.0)), 1.0), "0 级时倍率应为 1.0")
	_check(int(none.get("start_resources", -1)) == 0, "0 级时开局资源应为 0")

	var combat := GrowthModifiers.effects_for_levels({"combat_power": 5})
	_check(is_equal_approx(float(combat.get("damage_mult", 0.0)), 1.20),
		"战术火力 5 级应 +20% 伤害（实际 %s）" % str(combat.get("damage_mult")))

	var guard := GrowthModifiers.effects_for_levels({"combat_guard": 5})
	_check(is_equal_approx(float(guard.get("unit_hp_mult", 0.0)), 1.20),
		"战场韧性 5 级应 +20% 作战单位生命")

	var stacked := GrowthModifiers.effects_for_levels({
		"economy_gather": 5, "economy_trade": 3,
	})
	_check(is_equal_approx(float(stacked.get("gather_mult", 0.0)), 1.37),
		"同类型多节点应叠加 25% + 12% = 37%（实际 %s）" % str(stacked.get("gather_mult")))

	var stock := GrowthModifiers.effects_for_levels({"economy_stock": 5})
	_check(int(stock.get("start_resources", -1)) == 2000, "资源储备 5 级应 +2000 开局资源")

	var unknown := GrowthModifiers.effects_for_levels({"no_such_node": 3})
	_check(is_equal_approx(float(unknown.get("damage_mult", 0.0)), 1.0),
		"未知节点必须忽略，不得改变任何倍率")


## 施加链路靠 meta 名对齐：两边写死同一个字符串，改一侧忘另一侧会静默失效。
func _test_meta_name_parity() -> void:
	_check(GrowthModifiers.META_MULTS == Mods.GROWTH_MULTS_META,
		"成长 meta 名两侧必须一致（%s vs %s）" % [
			GrowthModifiers.META_MULTS, Mods.GROWTH_MULTS_META,
		])


## 真机：同一个场景里先后以「0 级」与「满配」生成同类单位，逐个数值比对。
func _test_unit_application() -> void:
	_set_levels({})
	var base := _spawn_tank("GrowthProbeBase")
	await get_tree().process_frame
	_set_levels(FULL_LEVELS)
	var grown := _spawn_tank("GrowthProbeGrown")
	await get_tree().process_frame
	if base == null or grown == null:
		_fail("应能生成两辆对照坦克")
		return
	var base_hp := float(base.get("hp_max"))
	var grown_hp := float(grown.get("hp_max"))
	_check(base_hp > 0.0 and grown_hp > 0.0, "对照坦克应拿到平衡表生命值")
	_check(is_equal_approx(grown_hp, base_hp * 1.20),
		"满配生命应为基础值 ×1.20（基础 %s → 实际 %s）" % [str(base_hp), str(grown_hp)])

	var base_sight := float(base.get("sight_range"))
	var grown_sight := float(grown.get("sight_range"))
	_check(is_equal_approx(grown_sight, base_sight * 1.20),
		"满配视野应 ×1.20（基础 %s → 实际 %s）" % [str(base_sight), str(grown_sight)])

	var base_speed := _speed_of(base)
	var grown_speed := _speed_of(grown)
	_check(base_speed > 0.0, "对照坦克应有移动速度")
	_check(is_equal_approx(grown_speed, base_speed * 1.12),
		"满配移速应 ×1.12（基础 %s → 实际 %s）" % [str(base_speed), str(grown_speed)])

	_check(is_equal_approx(float(base.get("damage_multiplier")), 1.0),
		"0 级时伤害倍率应为 1.0")
	_check(is_equal_approx(float(grown.get("damage_multiplier")), 1.20),
		"满配伤害倍率应为 1.20（C# 开火时读取，实际 %s）" % str(grown.get("damage_multiplier")))

	# 幂等：再施加一次不得把倍率叠加成 1.44。
	GrowthModifiers.apply_to_unit(grown)
	_check(is_equal_approx(float(grown.get("hp_max")), base_hp * 1.20),
		"重复施加不得叠加（实际 %s）" % str(grown.get("hp_max")))

	# 成长与局内海克斯必须**叠乘**而不是互相覆盖（两条路径共用一次计算）。
	Mods.apply_to_unit(grown, [{"effect": {"type": "damage_mult", "value": 1.5}}])
	_check(is_equal_approx(float(grown.get("damage_multiplier")), 1.80),
		"成长 ×1.20 与海克斯 ×1.5 应叠乘为 1.80（实际 %s）" % str(grown.get("damage_multiplier")))
	base.free()
	grown.free()

	# 建筑分支（坚固工事/区域防御 + 建筑视野）：真机 spawn 建筑要走放置流程，这里用
	# 场上现成的指挥中心 + 手工注入结构倍率，覆盖 `AugmentModifiers` 的 structure 分支。
	var structure := _find_structure(_human)
	if structure == null:
		_fail("场上应有可验证的建筑（指挥中心）")
		return
	var before_structure_hp := float(structure.get("hp_max"))
	structure.set_meta(GrowthModifiers.META_MULTS, {"hp": 1.25, "damage": 1.0, "sight": 1.0})
	structure.set_meta(GrowthModifiers.META_APPLIED, true)
	Mods.apply_to_unit(structure, [])
	_check(is_equal_approx(float(structure.get("hp_max")), before_structure_hp * 1.25),
		"建筑结构倍率应生效 ×1.25（基础 %s → 实际 %s）" % [
			str(before_structure_hp), str(structure.get("hp_max")),
		])


## 真机：工人载量与施工工效（C# 下单时实时读这两个 GDScript 属性）。
func _test_worker_application() -> void:
	_set_levels({})
	var base := _spawn_worker("GrowthProbeWorkerBase")
	await get_tree().process_frame
	_set_levels(FULL_LEVELS)
	var grown := _spawn_worker("GrowthProbeWorkerGrown")
	await get_tree().process_frame
	if base == null or grown == null:
		_fail("应能生成两个对照工人")
		return
	var base_carry := int(base.get("resources_max"))
	var grown_carry := int(grown.get("resources_max"))
	_check(base_carry > 0, "工人应有载量（实际 %d）" % base_carry)
	_check(grown_carry == int(round(float(base_carry) * 1.40)),
		"满配载量应 ×1.40（基础 %d → 实际 %d）" % [base_carry, grown_carry])

	# 施工 / 生产工效走**浮点倍率**：整数工作量（通常为 1）乘 1.3 取整后还是 1，
	# 直接断言整数值会得到假绿 —— 必须断言倍率本身，由 C# 按小数累加推进。
	_check(is_equal_approx(float(base.get("construction_work_rate")), 1.0),
		"0 级时施工工效应为 1.0")
	_check(is_equal_approx(float(grown.get("construction_work_rate")), 1.30),
		"满配施工工效应为 1.30（实际 %s）" % str(grown.get("construction_work_rate")))
	_check(is_equal_approx(float(grown.get("production_work_per_tick")), 1.24),
		"满配生产工效应为 1.24（实际 %s）" % str(grown.get("production_work_per_tick")))
	base.free()
	grown.free()


## 作用域：只对本地玩家生效，AI / 对手不得吃到加成。
func _test_player_scope() -> void:
	_set_levels(FULL_LEVELS)
	_check(is_equal_approx(GrowthModifiers.gather_multiplier(_human), 1.25),
		"本地玩家采集倍率应为 1.25（实际 %s）" % str(GrowthModifiers.gather_multiplier(_human)))
	_check(int(GrowthModifiers.starting_resource_bonus(_human)) == 2000,
		"本地玩家开局赠款应为 2000")
	if _ai != null:
		_check(is_equal_approx(GrowthModifiers.gather_multiplier(_ai), 1.0),
			"AI 玩家不得吃到成长采集加成")
		_check(int(GrowthModifiers.starting_resource_bonus(_ai)) == 0,
			"AI 玩家不得吃到成长开局赠款")


# ------------------------------------------------------------------ 工具


## 局后发点闭环：胜 3 / 负 1，且 `available + spent == earned` 恒成立、必须落盘。
func _test_match_award() -> void:
	GrowthStore.state = {
		"available_points": 0, "levels": {}, "earned_total": 12, "spent_total": 12,
	}
	GrowthStore.save_state()
	var win: Dictionary = GrowthStore.award_match_points("victory")
	_check(bool(win.get("ok", false)) and int(win.get("awarded", 0)) == 3,
		"胜利应发 3 点（实际 %s）" % str(win))
	var lose: Dictionary = GrowthStore.award_match_points("defeat")
	_check(bool(lose.get("ok", false)) and int(lose.get("awarded", 0)) == 1,
		"失败应发 1 点（实际 %s）" % str(lose))
	var after_award := int(GrowthStore.state.get("available_points", -1))
	var after_earned := int(GrowthStore.state.get("earned_total", -1))
	var after_spent := int(GrowthStore.state.get("spent_total", -1))
	_check(after_award == 4 and after_earned == 16,
		"两点奖励应累计为可用 4 / 累计获得 16（实际 %d / %d）" % [after_award, after_earned])
	_check(after_award + after_spent == after_earned,
		"发点后必须保持 available + spent == earned（%d + %d != %d）" % [
			after_award, after_spent, after_earned,
		])
	var unknown: Dictionary = GrowthStore.award_match_points("draw")
	_check(not bool(unknown.get("ok", false))
			and int(GrowthStore.state.get("available_points", -1)) == 4,
		"非胜非负不得发点、也不得改动存档")
	var persisted := -1
	if FileAccess.file_exists(GrowthStore.SAVE_PATH):
		var file := FileAccess.open(GrowthStore.SAVE_PATH, FileAccess.READ)
		if file != null:
			var parsed = JSON.parse_string(file.get_as_text())
			if parsed is Dictionary:
				persisted = int((parsed as Dictionary).get("available_points", -1))
	_check(persisted == 4, "发点必须落盘（重启可读回，实际 %d）" % persisted)


func _await_match_ready(timeout_s := 30.0) -> void:
	var waited := 0.0
	while waited < timeout_s:
		if _match.get_local_player() != null:
			return
		await get_tree().create_timer(0.2, true, false, true).timeout
		waited += 0.2
	_fail("Match 应在 %s 秒内就绪出本地玩家" % str(timeout_s))


func _set_levels(levels: Dictionary) -> void:
	GrowthStore.state["levels"] = levels.duplicate(true)
	GrowthModifiers.reset_cache()


func _spawn_tank(unit_name: String) -> Node:
	var tank := TankScene.instantiate()
	tank.name = unit_name
	tank.add_to_group("units")
	_human.add_child(tank)
	return tank


func _spawn_worker(unit_name: String) -> Node:
	var worker := WorkerScene.instantiate()
	worker.name = unit_name
	worker.add_to_group("units")
	_human.add_child(worker)
	return worker


func _find_structure(player: Node) -> Node:
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() == player and Mods.is_structure_unit(unit):
			return unit
	return null


func _speed_of(unit: Node) -> float:
	var movement := unit.find_child("Movement", true, false)
	return float(movement.get("speed")) if movement != null else 0.0


func _check(condition: bool, description: String) -> void:
	if condition:
		print("[OK] ", description)
		return
	print("[FAIL] ", description)
	_failures += 1


func _fail(description: String) -> void:
	print("[FAIL] ", description)
	_failures += 1


func _finish() -> void:
	print("[GROWTH-SMOKE] failures=", _failures)
	get_tree().quit(1 if _failures > 0 else 0)
