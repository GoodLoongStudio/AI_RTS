extends Area3D

const ResourceDecayAnimation = preload("res://source/match/utils/ResourceDecayAnimation.tscn")

var radius:
	get:
		return find_child("MovementObstacle").radius
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)


func _enter_tree():
	tree_exiting.connect(_animate_decay)


func _animate_decay():
	var current_parent = get_parent()
	# 整场 Match 卸载时父节点也将销毁，此时不得再延迟创建脱离场景树的消散特效。
	if current_parent == null or not current_parent.is_inside_tree():
		return
	var ancestor = current_parent
	while ancestor != null:
		if ancestor.is_queued_for_deletion():
			return
		ancestor = ancestor.get_parent()
	var decay_animation = ResourceDecayAnimation.instantiate()
	decay_animation.global_transform = global_transform
	current_parent.add_child.call_deferred(decay_animation)
