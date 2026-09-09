extends Node3D

## 炮弹落点一次性爆炸表现（仿 Defilade 命中效果）：
## 橙红火光迸发 + 黑烟升腾，全部粒子一次性爆发，1.8 秒后自毁。

func _ready():
	for child in get_children():
		if child is GPUParticles3D:
			child.emitting = true
	get_tree().create_timer(1.8).timeout.connect(queue_free)
