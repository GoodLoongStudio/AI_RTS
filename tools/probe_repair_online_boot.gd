extends Node

## 引导层：只负责把驱动挂到 `root`，然后自己退位。
##
## 为什么必须分两层：探针场景是 `current_scene`，而联机开局会换场景
## （`Loading` → `Match`），`current_scene` 连同它上面的脚本会被释放，
## 协程停在 `await` 上永远不再继续 —— 表现为"进程一直不退出、日志停在某一帧"。
## 挂到 `root` 的节点不属于任何场景，换场景不影响它。

const DRIVER_PATH := "res://tools/probe_repair_online.gd"


func _ready() -> void:
	var driver := Node.new()
	driver.name = "ProbeRepairOnlineDriver"
	driver.set_script(load(DRIVER_PATH))
	get_tree().root.add_child.call_deferred(driver)
