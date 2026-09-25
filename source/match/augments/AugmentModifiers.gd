class_name AugmentModifiers
extends RefCounted

## 把已选加成落到单位/交货数字上。只改 Godot 权威数值，副官不得再乘一遍。

const Structure = preload("res://source/match/units/Structure.gd")
const META_HP := "aug_base_hp_max"
const META_DAMAGE := "aug_base_attack_damage"
const META_SIGHT := "aug_base_sight_range"
## 成长倍率的 meta 名：**必须**与 `GrowthModifiers.META_MULTS` 保持一致
## （守门测试 `tests/automated/GrowthModifiersSmokeTest.gd` 会断言两边相等）。
const GROWTH_MULTS_META := "growth_mults"


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
	# 成长（永久加点）倍率由 GrowthModifiers 写入 meta，这里**合并进同一次计算**：
	# 两条加成路径共用一条写入路径，后跑的一方才不会把先跑的成果抹掉。
	# ⚠ 这里用字面量而不是 `GrowthModifiers.META_MULTS`：那边 preload 本文件，
	# 反向再引用会形成脚本循环依赖。守门测试 `GrowthModifiersSmokeTest` 会断言两者一致。
	var growth: Dictionary = unit.get_meta(GROWTH_MULTS_META, {}) if unit.has_meta(
		GROWTH_MULTS_META
	) else {}
	var hp_mult := float(growth.get("hp", 1.0))
	var damage_mult := float(growth.get("damage", 1.0))
	var sight_mult := float(growth.get("sight", 1.0))
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
	# `attack_damage` 只是 HUD 镜像；**真实伤害在 C# 结算**（`ProjectileRuntime` 用武器
	# catalog 的 BaseDamage）。倍率必须一并写进 `damage_multiplier`，否则伤害类加成
	# 永远只改面板数字（2026-09-21 发现成长系统此前完全没接入时顺带核实）。
	# 成长与海克斯的倍率已在上面合并成同一个 mult ⇒ 这里是唯一的写入者。
	if "damage_multiplier" in unit:
		unit.set("damage_multiplier", maxf(0.0, mult))


static func _apply_sight(unit: Node, mult: float) -> void:
	if not unit.has_meta(META_SIGHT):
		return
	unit.set("sight_range", maxf(0.1, float(unit.get_meta(META_SIGHT)) * mult))
