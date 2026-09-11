extends "res://source/match/units/Unit.gd"

## 救护车（2026-09-11）：移动维修站——自动治疗 3 米内受伤的己方单位，
## 每回 1 点血消耗 0.1 资金（资金不足时暂停治疗）。

const HEAL_RADIUS := 3.0
const HEAL_RATE_HP_PER_SEC := 2.0
const HEAL_COST_PER_HP := 0.1

var _heal_debt := 0.0


func _process(delta):
	if hp == null or hp <= 0:
		return
	var player = get_parent()
	if player == null or player.get("_economy_runtime") == null:
		return
	var target = _find_wounded_ally()
	if target == null:
		return
	var heal = min(HEAL_RATE_HP_PER_SEC * delta, float(target.hp_max) - float(target.hp))
	if heal <= 0.0:
		return
	_heal_debt += heal * HEAL_COST_PER_HP
	var owed := int(floor(_heal_debt))
	if owed < 1:
		return
	if not player.has_resources({"resource_a": owed}):
		return
	if player.subtract_resources({"resource_a": owed}, "ScriptedAdjustment", self):
		_heal_debt -= owed
		target.set_hp_without_damage(min(target.hp + heal, target.hp_max))


## 找最近的受伤己方单位（不含正在建造中的建筑）。
func _find_wounded_ally():
	var best = null
	var best_distance := HEAL_RADIUS
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if not is_instance_valid(unit) or unit == self:
			continue
		if unit.hp == null or unit.hp_max == null or unit.hp >= unit.hp_max:
			continue
		if unit.has_method("is_under_construction") and unit.is_under_construction():
			continue
		var distance = global_position.distance_to(unit.global_position)
		if distance <= best_distance:
			best = unit
			best_distance = distance
	return best
