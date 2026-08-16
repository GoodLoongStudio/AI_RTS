class_name SmokeTestExit
extends RefCounted


## 在测试协程返回并释放局部 Godot/C# 包装引用后，留出短暂清理窗口再退出 SceneTree。
static func request(tree: SceneTree, exit_code: int) -> void:
	tree.create_timer(0.1).timeout.connect(_quit.bind(tree, exit_code), CONNECT_ONE_SHOT)


static func _quit(tree: SceneTree, exit_code: int) -> void:
	tree.quit(exit_code)
