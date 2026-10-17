extends Node

## R32：内省 Godot 4.7 的避障可调项（有无线程模型/参数 ✓ 不猜 ✓）
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# ① ProjectSettings 里 navigation/avoidance 相关键 ✓
	var keys: Array = []
	for p in ProjectSettings.get_property_list():
		var n := str(p.get("name", ""))
		if n.contains("navigation") or n.contains("avoidance"):
			keys.append(n + " = " + str(ProjectSettings.get_setting(n)))
	keys.sort()
	print("[NAVCFG] ProjectSettings 相关键（", keys.size(), "）:")
	for k in keys.slice(0, 30):
		print("[NAVCFG]   ", k)
	# ② NavigationServer3D 的方法里与 avoidance/agent 有关的 ✓
	var ms: Array = []
	for m in NavigationServer3D.get_method_list():
		var n := str(m.get("name", ""))
		if n.contains("avoidance") or n.contains("agent") or n.contains("thread") or n.contains("process"):
			ms.append(n)
	ms.sort()
	print("[NAVCFG] NavigationServer3D 相关方法（", ms.size(), "）:")
	print("[NAVCFG]   ", ", ".join(ms).substr(0, 900))
	# ③ 当前进程实际线程情况 ✓
	print("[NAVCFG] OS.get_processor_count() = ", OS.get_processor_count())
	get_tree().quit(0)
