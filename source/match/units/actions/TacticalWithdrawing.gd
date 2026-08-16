extends "res://source/match/units/actions/Action.gd"

const OpportunisticMovingFire = preload(
	"res://source/match/units/actions/OpportunisticMovingFire.gd"
)

var _target_position: Vector3
var _moving_fire = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")


func _init(target_position: Vector3):
	_target_position = target_position


func _ready():
	_movement_trait.tactical_withdraw(_target_position)
	_movement_trait.movement_finished.connect(_on_movement_finished)
	_moving_fire = OpportunisticMovingFire.new()
	add_child(_moving_fire)


func _exit_tree():
	if is_inside_tree():
		_movement_trait.stop()


## 在撤退期间重新读取停火策略；停火会立即终止当前移动射击子行为。
func refresh_combat_policy():
	if _moving_fire != null:
		_moving_fire.refresh_weapon_target()


func _on_movement_finished():
	queue_free()
