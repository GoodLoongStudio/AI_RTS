extends "res://source/match/units/Unit.gd"

signal constructed

const UNDER_CONSTRUCTION_MATERIAL = preload(
	"res://source/match/resources/materials/structure_under_construction.material.tres"
)

var _construction_progress = 1.0
var _construction_refund_requested := false
var _construction_completion_announced := true
## 权威整数施工工作量的最近一次快照（供 NetSync 下发给客户端；只读留痕）。
var _construction_completed_work := 0
var _construction_required_work := 0

## 维修/出售（2026-09-11，仿红警3）：维修按秒耗资金回血，出售返还半价即毁。
const REPAIR_RATE_HP_PER_SEC := 6.0
const REPAIR_COST_PER_HP := 0.25
const SELL_REFUND_RATIO := 0.5

var _repairing := false
var _repair_debt := 0.0

@onready var production_queue = find_child("ProductionQueue"):
	set(_value):
		pass


## 维修开关：开启后按秒回血并从玩家账户扣费，满血或资金不足自动停止。
func set_repairing(repairing: bool):
	_repairing = repairing
	_repair_debt = 0.0


func is_repairing() -> bool:
	return _repairing


func _process(delta):
	if not _repairing:
		return
	if hp == null or hp_max == null or hp >= hp_max:
		_repairing = false
		return
	var player = get_parent()
	if player == null or player.get("_economy_runtime") == null:
		return
	var heal = min(REPAIR_RATE_HP_PER_SEC * delta, float(hp_max) - float(hp))
	if heal <= 0.0:
		return
	_repair_debt += heal * REPAIR_COST_PER_HP
	var owed := int(floor(_repair_debt))
	if owed < 1:
		return
	if not player.has_resources({"resource_a": owed}):
		_repairing = false
		return
	if player.subtract_resources({"resource_a": owed}, "ScriptedAdjustment", self):
		_repair_debt -= owed
		set_hp_without_damage(min(hp + heal, hp_max))


## 出售：返还造价一半，走既有死亡路径移除建筑。
func sell():
	var refund := 0
	var match_node = find_parent("Match")
	if match_node != null:
		var balance = match_node.get_node_or_null("BalanceConfigRuntime")
		if balance != null and balance.has_method("GetConstructionCost"):
			var cost = balance.GetConstructionCost(load(str(scene_file_path)))
			if cost != null:
				refund = int(int(cost.get("resource_a", 0)) * SELL_REFUND_RATIO)
	set_repairing(false)
	var player = get_parent()
	# 退款条件（查得到造价 + 有权威经济账户）与"是否拆毁"必须分开：
	# 此前 hp = 0 嵌在退款分支内，于是**查不到造价或没有权威账户时建筑根本删不掉**
	# （用户报"不能删除建筑"；联机客户端更是必中）。现在退款失败也照样拆。
	if refund > 0 and player != null and player.get("_economy_runtime") != null:
		player.add_resources({"resource_a": refund}, "ConstructionRefund", self)
	MatchSignals.deselect_all_units.emit()
	hp = 0


func is_revealing():
	return super() and is_constructed()


func mark_as_under_construction():
	assert(not is_under_construction(), "structure already under construction")
	_construction_progress = 0.0
	_construction_completion_announced = false
	_construction_completed_work = 0
	_change_geometry_material(UNDER_CONSTRUCTION_MATERIAL)
	if hp == null:
		await ready
	set_hp_without_damage(1)
	UISfx.play("place")


## 镜像 C# 权威整数施工进度；新增 HP 属于施工来源，不触发受击事件。
func apply_authoritative_construction_work(completed_work: int, required_work: int) -> bool:
	if required_work <= 0 or completed_work < 0 or completed_work > required_work:
		return false
	if not is_under_construction() and completed_work < required_work:
		return false
	_construction_completed_work = completed_work
	_construction_required_work = required_work
	var previous_entitled_hp = 1 + int(_construction_progress * float(hp_max - 1))
	_construction_progress = float(completed_work) / float(required_work)
	var current_entitled_hp = 1 + int(_construction_progress * float(hp_max - 1))
	if current_entitled_hp > previous_entitled_hp:
		set_hp_without_damage(min(hp_max, hp + current_entitled_hp - previous_entitled_hp))
	return true


## 只读：施工进度上报 `[completed, required]`。
## `required <= 0` 表示"本节点不是施工中的建筑"（NetSync 据此决定要不要下发）。
func construction_progress_report() -> Array:
	return [_construction_completed_work, _construction_required_work]


## 客户端表现入口：按权威进度显示"施工中 → 进行中 → 完工"。
##
## 为什么客户端需要它：客户端建筑由 `NetSync._spawn_unit` 生成，**从不调用**
## `mark_as_under_construction`（那是权威端 `Match._setup_and_spawn_unit` 的路径），
## 于是客户端建筑一出现就是"完工外观"，玩家看不到任何建造过程。
## 这里只改**外观与进度镜像**，绝不改写 hp（客户端 hp 由快照结算）。
func present_construction(completed_work: int, required_work: int) -> void:
	if required_work <= 0 or completed_work < 0 or completed_work > required_work:
		return
	_construction_completed_work = completed_work
	_construction_required_work = required_work
	var progress := float(completed_work) / float(required_work)
	if progress >= 1.0:
		if is_under_construction():
			_construction_progress = 1.0
			_finish_construction()
		return
	if is_constructed():
		# 首次得知"其实还在建造中"（例如开工事件早于单位生成而丢失）：补上施工外观。
		_construction_progress = progress
		_construction_completion_announced = false
		_change_geometry_material(UNDER_CONSTRUCTION_MATERIAL)
		return
	_construction_progress = progress


## 完成施工表现并只发布一次 Legacy 完成事件；保留施工期间受到的伤害。
func complete_authoritative_construction() -> bool:
	if _construction_completion_announced or _construction_progress < 1.0:
		return false
	_construction_completion_announced = true
	_finish_construction()
	return true


## 取消当前施工并保证全额退款最多提交一次。
func cancel_authoritative_construction() -> bool:
	if _construction_refund_requested or not is_under_construction():
		return false
	_construction_refund_requested = true
	queue_free()
	return true


func is_constructed():
	return _construction_progress >= 1.0


func is_under_construction():
	return not is_constructed()


func _finish_construction():
	_change_geometry_material(null)
	_reapply_synty_material_binders()
	if is_inside_tree():
		constructed.emit()
		MatchSignals.unit_construction_finished.emit(self)


func _change_geometry_material(material):
	for child in find_child("Geometry").find_children("*"):
		if "material_override" in child:
			child.material_override = material


## 完工清空施工半透明材质后，恢复 Geometry 下 SyntyMaterialBinder 的图集外观。
func _reapply_synty_material_binders():
	var geometry = find_child("Geometry")
	if geometry == null:
		return
	for node in geometry.find_children("*"):
		var script = node.get_script()
		if script != null and script.resource_path.ends_with("SyntyMaterialBinder.gd"):
			node.apply()
