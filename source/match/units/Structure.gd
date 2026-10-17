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
const REPAIR_ICON_TEXTURE = preload("res://assets/ui/cursors/cursor_repair.png")

var _repairing := false
var _repair_debt := 0.0
var _repair_icon: Sprite3D = null

@onready var production_queue = find_child("ProductionQueue"):
	set(_value):
		pass


## 维修开关：开启后按秒回血并从玩家账户扣费，满血或资金不足自动停止。
func set_repairing(repairing: bool):
	_repairing = repairing
	_repair_debt = 0.0
	present_repairing(repairing)


func is_repairing() -> bool:
	return _repairing


## Snapshot consumption changes only presentation, never client HP or economy.
func present_repairing(repairing: bool) -> void:
	if not is_inside_tree() or NetSession.is_dedicated_server():
		return
	if _repair_icon == null:
		if not repairing:
			return
		_repair_icon = Sprite3D.new()
		_repair_icon.name = "RepairStatusIcon"
		_repair_icon.texture = REPAIR_ICON_TEXTURE
		_repair_icon.pixel_size = 0.035
		_repair_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_repair_icon.no_depth_test = true
		_repair_icon.shaded = false
		_repair_icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		_repair_icon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_repair_icon.render_priority = 2
		_repair_icon.set_meta("exclude_from_geometry_measurements", true)
		_repair_icon.position.y = _repair_icon_anchor_height()
		add_child(_repair_icon)
	_repair_icon.visible = repairing


func _repair_icon_anchor_height() -> float:
	var top := 0.0
	var health_bar := get_node_or_null("HealthBar") as Node3D
	if health_bar != null:
		top = health_bar.position.y
	# Measure only the model once, excluding selection rings, particles and this icon.
	var geometry := find_child("Geometry", true, false)
	if geometry != null:
		for mesh in geometry.find_children("*", "MeshInstance3D", true, false):
			var bounds: AABB = mesh.get_aabb()
			var to_unit: Transform3D = global_transform.affine_inverse() * mesh.global_transform
			for index in 8:
				top = maxf(top, (to_unit * bounds.get_endpoint(index)).y)
	return top + 1.7


func _process(delta):
	if not _repairing:
		return
	# 客户端傀儡**只表现、绝不改 hp/资金**（权威在服务器，快照每 10Hz 盖回）。
	# 放在 `_repairing` 短路之后：不维修时零额外开销。
	# 真实客户端路径走 `present_repairing`（由 NetSync 下发），但这一行把"只表现"
	# 从**调用方约定**升级成**局部不变量**。2026-10-10 独立复核实测：
	# 傀儡态下直接调 `set_repairing(true)` 会本地 hp +16 / 资金 −4
	# （`tests/automated/_IndepVerifyRepairSpeed.gd --phase=edges` 当时唯一一条 FAIL）。
	if NetSession.is_client_puppet():
		return
	if hp == null or hp_max == null or hp >= hp_max:
		set_repairing(false)
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
		set_repairing(false)
		return
	if player.subtract_resources({"resource_a": owed}, "ScriptedAdjustment", self):
		_repair_debt -= owed
		# 只回**已付钱的那部分**血：owed 金按 REPAIR_COST_PER_HP 换回 owed/COST 点 HP。
		#
		# 2026-10-10 用户报"建筑维修速度太慢"。根因：攒账 `_repair_debt` 只累加资金，
		# 回血却只加**当帧**的 `heal` —— 前面几十帧攒进去的血全被丢弃，
		# 等于每花 1 金才回 `RATE × delta` 点血（而不是 1/COST = 4 点）。
		# 实测（tests/automated/StructureRepairRateTest.gd）：0.088 HP/s（口径 6，慢 68×）、
		# 15.075 金/HP（口径 0.25，贵 60×），且速率 ≈ RATE²×COST×delta **随帧率变化**。
		# 旧断言只要求 `hp > damaged_hp`，2 秒回 0.3HP 也算过，所以一直没被抓到。
		set_hp_without_damage(min(hp + owed / REPAIR_COST_PER_HP, hp_max))


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
