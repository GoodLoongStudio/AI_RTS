extends Node

## 查 Skeleton3D 实际可用 API（2026-10-07 R4）✓
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var skel := Skeleton3D.new()
	add_child(skel)
	var ms: Array = []
	for m in skel.get_method_list():
		var n := str(m.get("name", ""))
		if n.contains("pose") or n.contains("bone"):
			ms.append(n)
	ms.sort()
	print("[SKEL-API] 方法数=", ms.size())
	print("[SKEL-API] ", ", ".join(ms).substr(0, 900))
	# 属性 ✓
	var ps: Array = []
	for p in skel.get_property_list():
		var n := str(p.get("name", ""))
		if n.contains("pose") or n.contains("bone"):
			ps.append(n)
	print("[SKEL-API] 属性: ", ", ".join(ps).substr(0, 400))
	get_tree().quit(0)
