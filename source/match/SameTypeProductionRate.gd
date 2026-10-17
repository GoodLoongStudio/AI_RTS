class_name SameTypeProductionRate
extends RefCounted

## 「同类建筑加速出兵」（2026-09-29 用户规则）：每多一座**已完工**的同类生产建筑，
## 该类建筑的出兵速度 +50%（2 座 = ×1.5，3 座 = ×2.0，无上限）。
##
## 口径与分工：
## - 只统计**已完工**建筑（is_constructed）；在建工地不提供加成（用户确认的口径）。
## - 主基地（command_center）**不**参与出兵加速 —— 它的同类加成作用在建筑施工速度上，
##   在 C# 侧实现（ConstructionService + GodotConstructionRatePort），两者互不掺和。
## - 矿场（ore_refinery）没有生产队列，天然不参与；给它写倍率是无效数据但无害。
## - 比例来源：balance 根字段 `sameTypeBonusPerExtraBuilding`（0 = 规则关闭）。
##
## 实现层：C# `ProductionService` 每 tick 经 `GodotProductionProducerRegistry.WorkPerTickOf`
## 实时读建筑的 `production_work_per_tick` 属性（支持小数）。这里维护的是**合成链**的
## 同类因子一段（growth × same_type → 最终值，见 `Unit.refresh_production_work_rate`），
## 事件驱动重算：完工 / 死亡改变数量，出生时给新建筑补当前倍率。
## 该规则对所有玩家生效（不限于本地玩家）；联机时权威端计算，客户端若也触发
## 重算只是幂等地同步镜像值，不影响权威性。

const COMMAND_CENTER_TYPE_ID := "command_center"

static var _installed := false
## balance 的同类加速比例；install 时读取一次（对局内不变）。
static var _bonus := 0.0


## Match._ready 调用。重复调用只刷新比例、不会重复连接信号（autoload 跨对局常驻）。
static func install(match: Node) -> void:
	var balance := match.get_node_or_null("BalanceConfigRuntime")
	if balance != null and balance.has_method("GetSameTypeBonusPerExtraBuilding"):
		_bonus = float(balance.call("GetSameTypeBonusPerExtraBuilding"))
	if _installed:
		return
	_installed = true
	MatchSignals.unit_construction_finished.connect(_on_structure_set_changed)
	MatchSignals.unit_died.connect(_on_structure_set_changed)
	MatchSignals.unit_spawned.connect(_on_structure_spawned)


## 完工 / 死亡都会改变"已完工同类建筑数"，重算该玩家该类型的倍率。
static func _on_structure_set_changed(unit) -> void:
	if not is_instance_valid(unit) or not unit.has_method("is_constructed"):
		return
	refresh_player_type(unit.player, str(unit.unit_type_id))


## 新建筑落地（尚在建）：按当前已完工数量初始化它的倍率，完工事件随后会再算一次。
static func _on_structure_spawned(unit) -> void:
	if not is_instance_valid(unit) or not unit.has_method("is_constructed"):
		return
	refresh_player_type(unit.player, str(unit.unit_type_id))


## 重算某玩家某类型的同类加速倍率，并写回该类型全部建筑（含在建，保证值随时正确）。
static func refresh_player_type(player: Node, type_id: String) -> void:
	if player == null or not is_instance_valid(player) or _bonus <= 0.0:
		return
	if type_id == COMMAND_CENTER_TYPE_ID:
		return
	var same_type: Array = player.get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				is_instance_valid(unit)
				and unit.player == player
				and unit.has_method("is_constructed")
				and str(unit.unit_type_id) == type_id
			)
	)
	var completed := same_type.filter(func(unit): return unit.is_constructed()).size()
	var rate := 1.0 if completed <= 1 else 1.0 + _bonus * (completed - 1)
	for unit in same_type:
		if not ("same_type_production_rate" in unit):
			continue
		unit.same_type_production_rate = rate
		unit.refresh_production_work_rate()
