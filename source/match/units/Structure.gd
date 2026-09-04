extends "res://source/match/units/Unit.gd"

signal constructed

const UNDER_CONSTRUCTION_MATERIAL = preload(
	"res://source/match/resources/materials/structure_under_construction.material.tres"
)

var _construction_progress = 1.0
var _construction_refund_requested := false
var _construction_completion_announced := true

@onready var production_queue = find_child("ProductionQueue"):
	set(_value):
		pass


func is_revealing():
	return super() and is_constructed()


func mark_as_under_construction():
	assert(not is_under_construction(), "structure already under construction")
	_construction_progress = 0.0
	_construction_completion_announced = false
	_change_geometry_material(UNDER_CONSTRUCTION_MATERIAL)
	if hp == null:
		await ready
	set_hp_without_damage(1)


## 镜像 C# 权威整数施工进度；新增 HP 属于施工来源，不触发受击事件。
func apply_authoritative_construction_work(completed_work: int, required_work: int) -> bool:
	if required_work <= 0 or completed_work < 0 or completed_work > required_work:
		return false
	if not is_under_construction() and completed_work < required_work:
		return false
	var previous_entitled_hp = 1 + int(_construction_progress * float(hp_max - 1))
	_construction_progress = float(completed_work) / float(required_work)
	var current_entitled_hp = 1 + int(_construction_progress * float(hp_max - 1))
	if current_entitled_hp > previous_entitled_hp:
		set_hp_without_damage(min(hp_max, hp + current_entitled_hp - previous_entitled_hp))
	return true


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
