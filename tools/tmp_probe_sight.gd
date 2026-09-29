extends SceneTree

## 临时诊断：哪些单位的 sight_range 为 null（FogOfWar.gd:201 报错根因定位）。
## 用法：AIRTS_TEST_BASE=24609 godot --headless --path . --quit-after 20000 \
##        --script res://tools/tmp_probe_sight.gd

const FIXTURES := [
	"res://tests/manual/TestPlayerVsAI.tscn",
]


func _initialize() -> void:
	for fixture_path in FIXTURES:
		var fixture: Node = load(fixture_path).instantiate()
		root.add_child(fixture)
		for i in range(240):
			await process_frame
		print("[PROBE] ===== fixture = ", fixture_path)
		var seen := {}
		for group in ["units", "revealed_units", "resource_units"]:
			for unit in get_nodes_in_group(group):
				var sight = unit.get("sight_range")
				var type_id = unit.get("unit_type_id")
				var script: Script = unit.get_script()
				var key := "%s | type_id=%s | sight=%s | in_units=%s" % [
					script.resource_path.get_file() if script != null else "<no script>",
					str(type_id), str(sight),
					unit.is_in_group("units"),
				]
				if seen.has(key):
					seen[key]["count"] += 1
					continue
				seen[key] = {"count": 1, "sample": String(unit.name), "null_sight": sight == null}
		for key in seen:
			var entry: Dictionary = seen[key]
			print("[PROBE] %s count=%d sample=%s%s" % [
				key, entry["count"], entry["sample"],
				"   <== sight_range 为空" if entry["null_sight"] else ""
			])
		fixture.queue_free()
	quit(0)
