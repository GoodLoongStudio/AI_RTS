extends SceneTree

## 校验 project.godot 修复：段头/键被吞掉时这两个设置会读不到。
func _init():
	print("[CFG] rendering_method        = ", ProjectSettings.get_setting("rendering/renderer/rendering_method", "<未设置>"))
	print("[CFG] rendering_method.mobile = ", ProjectSettings.get_setting("rendering/renderer/rendering_method.mobile", "<未设置>"))
	print("[CFG] main_scene              = ", ProjectSettings.get_setting("application/run/main_scene", "<未设置>"))
	print("[CFG] autoloads               = ", ProjectSettings.get_setting("autoload/McpInteractionServer", "<未设置>"))
	quit(0)
