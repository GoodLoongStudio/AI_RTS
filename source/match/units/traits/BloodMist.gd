extends Node3D

## 步兵中弹的出血雾一次性表现（2026-09-29 用户要求：移除受轻击动画，改为血雾反馈）：
## 暗红血雾迸开 + 数滴血珠溅落，全部粒子一次性爆发，0.9 秒后自毁。
## 只做视觉：由 InfantryAnimationDriver 在 hp 下降（未致死）时于本端生成，
## 权威与联机镜像各自本地播放，无任何玩法副作用。

func _ready():
	add_to_group("blood_mist_effects")
	for child in get_children():
		if child is GPUParticles3D:
			child.emitting = true
	get_tree().create_timer(0.9).timeout.connect(queue_free)
