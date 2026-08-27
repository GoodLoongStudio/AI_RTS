extends Node

## 只在战局未暂停时推进的模拟毫秒，供攻击间隔、战役计时等执行逻辑使用。
## 本节点继承 Match 的 PAUSABLE；菜单 / 输入 / 语音才使用 PROCESS_MODE_ALWAYS。
var _msec := 0


func _physics_process(delta: float):
	_msec += int(round(delta * 1000.0))


func get_msec() -> int:
	return _msec


func is_frozen() -> bool:
	return get_tree() != null and get_tree().paused
