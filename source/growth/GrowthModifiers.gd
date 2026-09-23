class_name GrowthModifiers
extends RefCounted

## 成长加点（主菜单「永久加点」）→ 对局数值的**唯一**换算与施加处。
##
## 背景（2026-09-21 核查）：成长等级此前只被加点页 UI（`GrowthUpgrades.gd`）读取、
## 并被写进 Hermes 画像，对局里**没有任何一处**消费它 —— 玩家把 12 点花光也感觉
## 不到任何变化。本文件是这条链路的唯一实现：换算（levels → 倍率）与施加（倍率 →
## 单位/玩家数值）都只能在这里做。任何"别处自己再乘一遍"的写法都会让倍率被叠加两次。
##
## 数值来源：`config/growth_definitions.json` 每个节点的 `effect`（**每级**增量）。
## 换算口径：level 级 ⇒ 倍率 = 1.0 + value * level；`start_resources` 是绝对值累加。
##
## 生效范围（两处判据必须一致，否则同一份存档在不同环境战力不同）：
##   1) 只对**本地玩家**的单位生效 —— AI 与对手不受影响；
##   2) 只在**单机**生效。联机时权威端在服务器，而"本地玩家"是客户端概念，
##      若各客户端按自己的存档加成，就是各打各的 ⇒ 判为不生效（保持公平与可复现）。
##
## 与局内海克斯（augments）的关系：hp / attack_damage / sight_range **只由**
## `AugmentModifiers.apply_to_unit()` 写入一次，成长倍率通过 meta 交给它合并，
## 两者同一次计算相乘，不会互相覆盖。

const AugmentModifiers = preload("res://source/match/augments/AugmentModifiers.gd")

## 已施加标记：单位一生只施加一次（出生时属性刚注入完毕，是基线）。
const META_APPLIED := "growth_applied"
## 交给 AugmentModifiers 合并的倍率：{"hp":..,"damage":..,"sight":..}
const META_MULTS := "growth_mults"
## 定义文件路径（GrowthStore 也读它，两处同源）。
const DEFINITIONS_PATH := "res://config/growth_definitions.json"

const EFFECT_KEYS: Array[String] = [
	"damage_mult",
	"unit_hp_mult",
	"structure_hp_mult",
	"sight_mult",
	"structure_sight_mult",
	"speed_mult",
	"gather_mult",
	"build_work_mult",
	"carry_mult",
	"production_rate",
	"start_resources",
]

static var _cache: Dictionary = {}
static var _nodes_cache: Array = []


## 测试/换局用：清掉倍率缓存（levels 变化会自动换 key，通常不必手动调）。
static func reset_cache() -> void:
	_cache.clear()
	_nodes_cache.clear()


## 成长系统当前是否参与对局数值（见文件头"生效范围"）。
static func is_enabled() -> bool:
	# 联机不生效：权威端在服务器，本地存档不能左右权威数值。
	return not NetSession.is_networked()


## 本地玩家的成长等级表（存档快照）。拿不到就是没加点。
static func local_player_levels() -> Dictionary:
	var store := _store()
	if store == null:
		return {}
	var state = store.get("state")
	if not state is Dictionary:
		return {}
	var levels = (state as Dictionary).get("levels", null)
	return (levels as Dictionary).duplicate(true) if levels is Dictionary else {}


## 本地玩家的完整效果表（11 个 key 一定有值：倍率默认 1.0 / 资源默认 0）。
static func effects_for_local_player() -> Dictionary:
	return effects_for_levels(local_player_levels())


## 等级表 → 效果表的**唯一**换算。未知节点 id 直接忽略（旧存档里的已删除节点）。
static func effects_for_levels(levels: Dictionary) -> Dictionary:
	var key := JSON.stringify(levels)
	if _cache.has(key):
		return (_cache[key] as Dictionary).duplicate()
	var effects := {}
	for effect_key in EFFECT_KEYS:
		effects[effect_key] = 1.0
	effects["start_resources"] = 0
	for node in _nodes():
		var node_id := str((node as Dictionary).get("id", ""))
		var level := int(levels.get(node_id, 0))
		if level <= 0:
			continue
		var effect = (node as Dictionary).get("effect", null)
		if not effect is Dictionary:
			continue
		var type := str((effect as Dictionary).get("type", ""))
		if not EFFECT_KEYS.has(type):
			continue
		var value := float((effect as Dictionary).get("value", 0.0))
		if type == "start_resources":
			effects[type] = int(effects[type]) + int(round(value)) * level
		else:
			effects[type] = float(effects[type]) + value * float(level)
	_cache[key] = effects.duplicate()
	return effects


## 采集交付倍率：由采集交付的唯一实现调用（`CollectingResourcesSequentially`）。
static func gather_multiplier(player: Node) -> float:
	if not _is_local_effect_player(player):
		return 1.0
	return float(effects_for_local_player().get("gather_mult", 1.0))


## 开局额外资源（int，"资源储备"节点）。
static func starting_resource_bonus(player: Node) -> int:
	if not _is_local_effect_player(player):
		return 0
	return int(effects_for_local_player().get("start_resources", 0))


## 在单位属性注入完成后施加一次成长加成（出生时调用，幂等）。
static func apply_to_unit(unit: Node) -> void:
	if unit == null or not is_instance_valid(unit) or not is_enabled():
		return
	if unit.has_meta(META_APPLIED):
		return
	var player = unit.get("player")
	if not _is_local_effect_player(player):
		return
	var effects := effects_for_local_player()
	var is_structure := unit.has_method("is_constructed")
	unit.set_meta(META_MULTS, {
		"hp": float(effects.get("structure_hp_mult" if is_structure else "unit_hp_mult", 1.0)),
		"damage": float(effects.get("damage_mult", 1.0)),
		"sight": float(effects.get("sight_mult", 1.0)) * (
			float(effects.get("structure_sight_mult", 1.0)) if is_structure else 1.0
		),
	})
	# hp / attack_damage / sight_range 的唯一写入者：把局内加成与成长一次算完。
	AugmentModifiers.apply_to_unit(unit, [])
	_apply_speed(unit, float(effects.get("speed_mult", 1.0)))
	_apply_carry(unit, float(effects.get("carry_mult", 1.0)))
	_apply_build_work(unit, float(effects.get("build_work_mult", 1.0)))
	_apply_production_rate(unit, float(effects.get("production_rate", 1.0)))
	unit.set_meta(META_APPLIED, true)


# ------------------------------------------------------------------ 施加细节


static func _apply_speed(unit: Node, mult: float) -> void:
	var movement := unit.find_child("Movement", true, false)
	if movement == null:
		return
	movement.set("speed", maxf(0.1, float(movement.get("speed")) * maxf(0.0, mult)))


static func _apply_carry(unit: Node, mult: float) -> void:
	var base := int(unit.get("resources_max"))
	if base <= 0:
		return
	unit.set("resources_max", maxi(1, int(round(float(base) * maxf(0.0, mult)))))


## 施工工效：写浮点倍率 `construction_work_rate`（C# 下单/推进时**实时**读取）。
## ⚠ 不要改成放大 `construction_work_per_tick`：它是整数且通常为 1，
## 1 × 1.3 取整后还是 1，加成会被静默吃掉（2026-09-21 实测过这个假绿）。
static func _apply_build_work(unit: Node, mult: float) -> void:
	if not "construction_work_rate" in unit:
		return
	unit.set("construction_work_rate", maxf(0.1, mult))


## 生产工效：C# `ProductionService` 每 tick 推进量（浮点，默认 1.0）。
static func _apply_production_rate(unit: Node, mult: float) -> void:
	if not "production_work_per_tick" in unit:
		return
	unit.set("production_work_per_tick", maxf(0.1, mult))


# ------------------------------------------------------------------ 内部工具


## 成长只对本地玩家生效；联机（`is_enabled()` 已 false）一律不适用。
static func _is_local_effect_player(player: Node) -> bool:
	if player == null or not is_instance_valid(player) or not is_enabled():
		return false
	return player == _local_player_of(player)


static func _local_player_of(node: Node) -> Node:
	var match_root := node.find_parent("Match")
	if match_root == null or not match_root.has_method("get_local_player"):
		return null
	return match_root.get_local_player()


static func _store() -> Node:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("GrowthStore")


## 扁平节点列表：优先用 GrowthStore 已加载的定义（与加点页 UI 同源），
## 拿不到（如独立脚本环境）再自己读 json。
static func _nodes() -> Array:
	if not _nodes_cache.is_empty():
		return _nodes_cache
	var definitions = null
	var store := _store()
	if store != null:
		definitions = store.get("DEFINITIONS")
	if not definitions is Dictionary:
		var file := FileAccess.open(DEFINITIONS_PATH, FileAccess.READ)
		if file == null:
			return []
		var parsed = JSON.parse_string(file.get_as_text())
		file.close()
		definitions = (parsed as Dictionary).get("branches", {}) if parsed is Dictionary else {}
	if definitions is Dictionary:
		for branch in (definitions as Dictionary).values():
			if branch is Array:
				for node in branch:
					if node is Dictionary:
						_nodes_cache.append(node)
	return _nodes_cache
