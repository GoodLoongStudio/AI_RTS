extends "res://source/match/units/actions/Action.gd"

const OpportunisticMovingFire = preload(
	"res://source/match/units/actions/OpportunisticMovingFire.gd"
)

var _target_position = null
var _enable_opportunistic_fire := false
var _moving_fire = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")


static func is_applicable(unit):
	return unit.find_child("Movement") != null


func _init(target_position, enable_opportunistic_fire := false):
	_target_position = target_position
	_enable_opportunistic_fire = enable_opportunistic_fire


func _ready():
	_movement_trait.move(_target_position)
	_movement_trait.movement_finished.connect(_on_movement_finished)
	if _enable_opportunistic_fire:
		_moving_fire = OpportunisticMovingFire.new()
		add_child(_moving_fire)


func _exit_tree():
	if is_inside_tree():
		_movement_trait.stop()


func _on_movement_finished():
	queue_free()


## 在普通或强制移动期间立即应用新的停火策略，不改变导航目标。
func refresh_combat_policy():
	if _moving_fire != null:
		_moving_fire.refresh_weapon_target()
