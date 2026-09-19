class_name AugmentModifiers
extends RefCounted

## 把已选加成落到单位/交货数字上。只改 Godot 权威数值，副官不得再乘一遍。

const Structure = preload("res://source/match/units/Structure.gd")
const META_HP := "aug_base_hp_max"
const META_DAMAGE := "aug_base_attack_damage"
const META_SIGHT := "aug_base_sight_range"


static func scale_gather(base_amount: int, gather_mult: float) -> int:
	if base_amount <= 0:
		return base_amount
	return maxi(0, int(round(float(base_amount) * maxf(1.0, gather_mult))))


static func is_structure_unit(unit: Node) -> bool:
	return unit != null and is_instance_valid(unit) and unit is Structure


static func apply_to_unit(unit: Node, owned: Array) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	_ensure_baselines(unit)
	var hp_mult := 1.0
	var damage_mult := 1.0
	var sight_mult := 1.0
	for card in owned:
		if not card is Dictionary:
			continue
		var effect = card.get("effect", {})
		if not effect is Dictionary:
			continue
		var effect_type := str(effect.get("type", ""))
		var value := float(effect.get("value", 1.0))
		var scope := str(effect.get("scope", "all"))
		if not _scope_matches(unit, scope) and effect_type in ["hp_mult", "damage_mult"]:
			continue
		if effect_type == "hp_mult":
			hp_mult *= value
		elif effect_type == "damage_mult":
			damage_mult *= value
		elif effect_type == "sight_mult":
			sight_mult *= value
	_apply_hp(unit, hp_mult)
	_apply_damage(unit, damage_mult)
	_apply_sight(unit, sight_mult)


static func _scope_matches(unit: Node, scope: String) -> bool:
	if scope == "" or scope == "all":
		return true
	if scope == "structure":
		return is_structure_unit(unit)
	if scope == "unit":
		return not is_structure_unit(unit)
	return true


static func _ensure_baselines(unit: Node) -> void:
	if not unit.has_meta(META_HP) and unit.get("hp_max") != null:
		unit.set_meta(META_HP, float(unit.get("hp_max")))
	if not unit.has_meta(META_DAMAGE) and unit.get("attack_damage") != null:
		unit.set_meta(META_DAMAGE, float(unit.get("attack_damage")))
	if not unit.has_meta(META_SIGHT) and unit.get("sight_range") != null:
		unit.set_meta(META_SIGHT, float(unit.get("sight_range")))


static func _apply_hp(unit: Node, mult: float) -> void:
	if not unit.has_meta(META_HP):
		return
	var base_max := float(unit.get_meta(META_HP))
	var new_max := maxf(1.0, base_max * mult)
	var old_max = unit.get("hp_max")
	var old_hp = unit.get("hp")
	unit.set("hp_max", new_max)
	if old_max != null and old_hp != null and float(old_max) > 0.0:
		var ratio := float(old_hp) / float(old_max)
		unit.set("hp", maxf(1.0, new_max * ratio))


static func _apply_damage(unit: Node, mult: float) -> void:
	if not unit.has_meta(META_DAMAGE):
		return
	unit.set("attack_damage", maxf(0.0, float(unit.get_meta(META_DAMAGE)) * mult))


static func _apply_sight(unit: Node, mult: float) -> void:
	if not unit.has_meta(META_SIGHT):
		return
	unit.set("sight_range", maxf(0.1, float(unit.get_meta(META_SIGHT)) * mult))
