extends SceneTree

## 弹体朝向守门探针（2026-09-15 用户报"子弹射出会旋转"固化）。
##
## 不变式：**弹体在飞行途中只平移、不旋转**。朝向只在发射瞬间确定。
##
## 背景：`CannonShell._process` 原来每帧 `look_at(当前瞄准点)`，而权威端
## `ProjectileRuntime.GetAimPoint` 对**活着的目标**会持续返回目标当前位置（追瞄是玩法设计，
## 落点/伤害口径不动）⇒ 瞄准点一移动弹体每帧被重新定向 = 边飞边转。
##
## 跑法：`godot --headless --path . --script res://tools/probe_projectile_orientation.gd`
## 退出码 0=PASS（飞行中朝向变化 ≤0.01°），1=FAIL。

const ShellScene = preload("res://source/match/units/projectiles/CannonShell.tscn")
const ROTATION_TOLERANCE_DEG := 0.01


class MockRuntime:
	extends RefCounted
	var aim := Vector3.ZERO

	func GetAimPoint(_attack_id: String) -> Vector3:
		return aim

	func ResolveImpact(_attack_id: String, _point: Vector3) -> void:
		pass


func _initialize() -> void:
	_run()


func _run() -> void:
	var stage := Node3D.new()
	root.add_child(stage)
	var projectiles := Node3D.new()
	projectiles.name = "Projectiles"
	stage.add_child(projectiles)

	var runtime := MockRuntime.new()
	var muzzle := Transform3D(Basis(), Vector3(0, 1, 0))
	runtime.aim = Vector3(0, 0, -10)

	var shell = ShellScene.instantiate()
	shell.set("attack_id", "probe-orientation")
	shell.set("projectile_runtime", runtime)
	shell.set("launch_transform", muzzle)
	shell.set("visible_snapshot", true)
	projectiles.add_child(shell)

	await process_frame
	var rotation: Vector3 = shell.rotation_degrees
	var max_delta := 0.0
	var frames := 0
	for frame in range(1, 30):
		# 目标横移（模拟追瞄）：瞄准点每帧 +0.35m。
		runtime.aim = Vector3(float(frame) * 0.35, 0, -10)
		await process_frame
		if not is_instance_valid(shell):
			break
		frames += 1
		var now: Vector3 = shell.rotation_degrees
		max_delta = maxf(max_delta, (now - rotation).length())
		rotation = now

	print("[PROJ-ORIENT] 飞行 %d 帧，朝向最大变化 %.3f°（锁定值 %s）" % [frames, max_delta, rotation])
	if frames < 5:
		print("FAIL: 弹体过早销毁，探针没测到飞行段")
		quit(1)
	elif max_delta > ROTATION_TOLERANCE_DEG:
		print("FAIL: 弹体飞行途中发生了旋转（>%s°）—— 朝向必须在发射瞬间锁定" % ROTATION_TOLERANCE_DEG)
		quit(1)
	else:
		print("PASS: 弹体飞行途中不旋转")
		quit(0)
