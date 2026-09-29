extends Node3D

## 冒烟专用假单位：只用来占一个"在 revealed_units 组里但没拿到平衡目录定义"的坑位，
## 复现 FogOfWar 遇到 sight_range == null 的路径（第二轮任务 B 的回归哨兵）。
## 不进游戏、不进 units 组，因此不会被索敌网格/生产/HUD 看见。

var sight_range = null
var unit_type_id = "smoke_null_sight"


func is_revealing() -> bool:
	return true
