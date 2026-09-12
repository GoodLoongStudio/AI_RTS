extends "res://source/match/units/actions/Action.gd"

var _target_unit = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(target_unit):
	_target_unit = target_unit


func _ready():
	_target_unit.tree_exited.connect(queue_free)
	_target_unit.constructed.connect(queue_free)
	_unit.get_node("Sparkling").enable()
	# 施工火花是本地 Action 驱动的表现：客户端傀儡不跑 Action，必须由权威端补发。
	_unit.broadcast_presentation("gather", {"active": true})


func _exit_tree():
	_unit.get_node("Sparkling").disable()
	_unit.broadcast_presentation("gather", {"active": false})


func _process(_delta):
	if (
		not Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit)
		or _target_unit.is_constructed()
	):
		queue_free()
		return
