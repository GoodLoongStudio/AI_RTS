extends Node3D

var target_unit = null

@onready var _unit = get_parent()
@onready var _animation_player = find_child("AnimationPlayer")


func _ready():
	find_parent("Match").get_node("RallyPointRuntime").RegisterProducer(_unit, self)
	_animation_player.play("idle")
	visible = _unit.is_in_group("selected_units")
	_unit.selected.connect(_show)
	_unit.deselected.connect(hide)


func _physics_process(_delta):
	if target_unit != null:
		global_position = target_unit.global_position


func _show():
	if target_unit == null:
		show()
	else:
		var targetability = target_unit.find_child("Targetability")
		if targetability != null:
			targetability.animate()


## 显示权威位置目标；视图不得反向修改 Rally 状态。
func apply_authoritative_position(position: Vector3):
	target_unit = null
	global_position = position
	if _unit.is_in_group("selected_units"):
		show()


## 显示权威实体目标；沿用目标高亮并隐藏地面标记。
func apply_authoritative_target(target):
	target_unit = target
	hide()


## 清除自定义目标后把表现复位到建筑门口默认状态。
func apply_authoritative_default():
	target_unit = null
	global_position = _unit.global_position
	if _unit.is_in_group("selected_units"):
		show()
