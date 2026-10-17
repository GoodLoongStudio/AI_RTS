extends Node

## 建筑窄缝探针：沿主基地 +X/+Z 扫描炮塔候选。
## 重叠仍拒绝；表面间隙在 2.4～5.6 米内必须允许建造（不再发 BlocksPassage）；
## 拉开到 5.6 米以上也必须允许。再让 AI 自动选址连续落建筑。

const MatchScene = preload("res://tests/manual/TestOneUnit.tscn")
const TurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const AUTO_SCENES := [
	"res://source/match/units/Barracks.tscn",
	"res://source/match/units/VehicleFactory.tscn",
	"res://source/match/units/AircraftFactory.tscn",
	"res://source/match/units/OreRefinery.tscn",
]
const SEAL_GAP_M := 2.4
const PASS_GAP_M := 5.6
const SCAN_STEP_M := 0.1

var _failures := 0
var _report := {}


func _ready():
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	for _frame in range(4):
		await get_tree().process_frame
	var human = match_instance.get_node("Players/Human")
	var runtime = match_instance.get_node("StructurePlacementRuntime")
	human.add_resources({"resource_a": 20000, "resource_b": 20000}, "ScriptedAdjustment")
	var cc: Node3D = load("res://source/match/units/CommandCenter.tscn").instantiate()
	match_instance.call("_setup_and_spawn_unit", cc, Transform3D(Basis.IDENTITY, Vector3(40.0, 0.0, 28.0)), human, false)
	if cc.has_method("mark_as_constructed"):
		cc.mark_as_constructed()
	for _frame in range(60):
		await get_tree().physics_frame

	var cost = match_instance.get_node("BalanceConfigRuntime").GetConstructionCost(TurretScene)
	var turret_r := 1.0
	var probe = TurretScene.instantiate()
	turret_r = float(probe.get("radius"))
	probe.free()
	var cc_r := float(cc.get("radius"))
	for axis in [Vector3.RIGHT, Vector3.BACK]:
		var segments := []
		var last := ""
		var d := cc_r + turret_r - 0.5
		var axis_blocks := false
		var axis_occupied := false
		var axis_narrow := false
		var axis_wide := false
		while d < cc_r + turret_r + 9.0:
			var xf := Transform3D(Basis.IDENTITY, cc.global_position + axis * d)
			var issues: Array = runtime.Evaluate(human, TurretScene, xf, cost)["issues"]
			var gap := d - cc_r - turret_r
			var tag := "valid"
			if "Occupied" in issues:
				tag = "occupied"
				axis_occupied = true
			elif "BlocksPassage" in issues:
				tag = "blocks"
				axis_blocks = true
			elif not issues.is_empty():
				tag = str(issues[0])
			if "BlocksPassage" in issues:
				axis_blocks = true
			if issues.is_empty() and gap > SEAL_GAP_M and gap < PASS_GAP_M:
				axis_narrow = true
			if issues.is_empty() and gap >= PASS_GAP_M:
				axis_wide = true
			if tag != last:
				segments.append({"tag": tag, "from": snappedf(gap, 0.01)})
				last = tag
			d += SCAN_STEP_M
		print("[GAP] axis=%s segments=%s" % [str(axis), JSON.stringify(segments)])
		_report[str(axis)] = segments
		_check(not axis_blocks, "窄缝不得再报 BlocksPassage axis=%s" % str(axis))
		_check(axis_occupied, "重叠仍然拒绝 axis=%s" % str(axis))
		_check(axis_narrow, "2.4～5.6 米内应能建造 axis=%s segments=%s" % [str(axis), JSON.stringify(segments)])
		_check(axis_wide, "拉开到 5.6 米后仍应能建造 axis=%s" % str(axis))

	_check_aircraft_short_side(match_instance, runtime, human, cc)

	var auto := []
	for path in AUTO_SCENES:
		var scene: PackedScene = load(path)
		var spot: Dictionary = runtime.FindAutoSpot(human, scene, "base", Vector3.INF, 0.0)
		var found := bool(spot.get("found", false))
		var entry := {"scene": path.get_file(), "found": found, "reason": str(spot.get("reason", ""))}
		if found:
			var xf := Transform3D(Basis.IDENTITY, spot["pos"])
			var scene_cost = match_instance.get_node("BalanceConfigRuntime").GetConstructionCost(scene)
			var evaluation: Dictionary = runtime.Evaluate(human, scene, xf, scene_cost)
			entry["placed"] = bool(evaluation.get("accepted", false))
			entry["issues"] = evaluation.get("issues", [])
			entry["pos"] = str(spot["pos"])
			# 权威 Place 一次只允许一个工地；这里直接落成品，只验证选址链路。
			var built: Node3D = scene.instantiate()
			match_instance.call("_setup_and_spawn_unit", built, xf, human, false)
			if built.has_method("mark_as_constructed"):
				built.mark_as_constructed()
		auto.append(entry)
		print("[GAP] auto=%s" % JSON.stringify(entry))
		_check(found and entry.get("placed", false), "AI 自动选址应能放下 %s" % path.get_file())
		for _frame in range(30):
			await get_tree().physics_frame
	_report["auto"] = auto
	_report["failures"] = _failures

	var dir := "res://agent/runs/nav-clearance"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var file := FileAccess.open(dir + "/gap-rule.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "  "))
	print("Structure gap rule probe completed: %d failure(s)" % _failures)
	match_instance.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 飞机厂碰撞是 3.26×7.99 的盒子，逻辑半径等于长半轴。
## 短边朝向邻居时，半径方形会把可通行间隙算进 (2.4, 5.6) 从而误拒。
func _check_aircraft_short_side(match_instance: Node, runtime: Node, human: Node, cc: Node3D) -> void:
	var scene: PackedScene = load("res://source/match/units/AircraftFactory.tscn")
	var probe: Node3D = scene.instantiate()
	var box := probe.find_child("CollisionShape3D", false, false).shape as BoxShape3D
	var short_half := minf(box.size.x, box.size.z) * 0.5
	var short_is_x := box.size.x <= box.size.z
	var radius := float(probe.get("radius"))
	probe.free()
	var cc_shape := cc.find_child("CollisionShape3D", false, false).shape as CylinderShape3D
	var cc_half := float(cc_shape.radius)
	var cost = match_instance.get_node("BalanceConfigRuntime").GetConstructionCost(scene)
	for yaw_case in [
		{"axis": Vector3.RIGHT if short_is_x else Vector3.BACK, "yaw": 0.0, "name": "yaw0"},
		{"axis": Vector3.BACK if short_is_x else Vector3.RIGHT, "yaw": PI * 0.5, "name": "yaw90"},
	]:
		var axis: Vector3 = yaw_case["axis"]
		var yaw := float(yaw_case["yaw"])
		var d_pass := short_half + cc_half + PASS_GAP_M + 0.35
		var d_block := short_half + cc_half + (SEAL_GAP_M + PASS_GAP_M) * 0.5
		var pass_issues: Array = _gap_issues(runtime, human, scene, cost, cc, axis, d_pass, yaw)
		var block_issues: Array = _gap_issues(runtime, human, scene, cost, cc, axis, d_block, yaw)
		var old_gap := d_pass - radius - cc_half
		print("[GAP] aircraft %s d_pass=%.2f old_radius_gap=%.2f pass=%s block=%s" % [
			yaw_case["name"], d_pass, old_gap, pass_issues, block_issues])
		_check(old_gap > SEAL_GAP_M and old_gap < PASS_GAP_M,
			"飞机厂短边对照点用半径方形应落在禁区（%.2fm）" % old_gap)
		_check("BlocksPassage" not in pass_issues,
			"飞机厂短边可通行间隙不得误拒 %s issues=%s" % [yaw_case["name"], str(pass_issues)])
		_check("BlocksPassage" not in block_issues,
			"飞机厂短边窄缝现在允许建造 %s issues=%s" % [yaw_case["name"], str(block_issues)])


func _gap_issues(runtime: Node, human: Node, scene: PackedScene, cost, cc: Node3D,
		axis: Vector3, distance: float, yaw: float) -> Array:
	var xf := Transform3D(Basis(Vector3.UP, yaw), cc.global_position + axis * distance)
	return runtime.Evaluate(human, scene, xf, cost)["issues"]


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("[GAP] FAIL " + message)
