extends SceneTree

## 临时诊断（2026-09-25）：逐个加载单位场景，打印根类型，隔离 perf 场景实例化问题。

func _init():
	for unit in ["Tank", "HeavyTank", "Infantry", "APC", "Scout", "Helicopter", "Worker", "CommandCenter"]:
		var ps: PackedScene = load("res://source/match/units/%s.tscn" % unit)
		if ps == null:
			print("LOADCHK %s LOAD_NULL" % unit)
			continue
		var inst = ps.instantiate()
		if inst == null:
			print("LOADCHK %s INSTANTIATE_NULL" % unit)
			continue
		print("LOADCHK %s -> %s script=%s children=%d" % [unit, inst.get_class(),
			inst.get_script().resource_path if inst.get_script() != null else "none",
			inst.get_child_count()])
		inst.free()
	quit()
