extends Node

## 形状链路夹具（提示词 §6 第 1 条）：圆柱/球/胶囊/长方体 必须被每个读取器正确读出；
## 凸体/凹网格等**未支持形状必须显式失败**（不能静默返回空 bounds 当作没有障碍）。

const ObstacleScript = preload("res://source/match/units/traits/MovementObstacle.gd")

var _failures := 0


func _ready():
	await get_tree().process_frame
	# 每个形状：构造 → 读取器 → 断言
	_expect_supported(CylinderShape3D.new(), "CylinderShape3D")
	_expect_supported(SphereShape3D.new(), "SphereShape3D")
	_expect_supported(CapsuleShape3D.new(), "CapsuleShape3D")
	_expect_supported(BoxShape3D.new(), "BoxShape3D")
	_expect_unsupported(ConvexPolygonShape3D.new(), "ConvexPolygonShape3D")
	_expect_unsupported(ConcavePolygonShape3D.new(), "ConcavePolygonShape3D")
	# 尺寸正确性：设定值 → 读出的 AABB 必须一致
	_check_bounds(CylinderShape3D.new(), "CylinderShape3D")
	_check_bounds(BoxShape3D.new(), "BoxShape3D")
	_check_bounds(CapsuleShape3D.new(), "CapsuleShape3D")
	_check_bounds(SphereShape3D.new(), "SphereShape3D")
	# 提示词 §6 夹具清单：偏心/嵌套变换、yaw 0/45/90/135、禁用形状、子 Area 检测圈
	_check_transforms()
	print("Shape pipeline fixture completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 世界几何应随 yaw 与偏心变换正确变化；禁用的形状与子 Area 检测圈不得污染主形状读取。
func _check_transforms() -> void:
	var host := Node3D.new()
	add_child(host)
	var body := StaticBody3D.new()
	host.add_child(body)
	# 折线 yaw：0 / 45 / 90 / 135 度，盒 (4,2,2) 的世界 XZ 包围应随之变化
	for deg in [0.0, 45.0, 90.0, 135.0]:
		for child in body.get_children():
			child.queue_free()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(4.0, 2.0, 2.0)
		cs.shape = box
		# 偏心：形状节点偏出本体 1.5m
		cs.position = Vector3(1.5, 0.0, 0.0)
		body.rotation_degrees = Vector3(0, deg, 0)
		body.add_child(cs)
		await get_tree().process_frame
		var world := _world_span(cs)
		var expect_x: float = 4.0 * absf(cos(deg_to_rad(deg))) + 2.0 * absf(sin(deg_to_rad(deg)))
		if world.x < expect_x - 0.05:
			_failures += 1
			push_error("yaw=%.0f° 盒世界跨度偏小：%.2f < %.2f（偏心/旋转未生效）" % [deg, world.x, expect_x])
	# 禁用形状：不应被当成有效主体
	for child in body.get_children():
		child.queue_free()
	var disabled := CollisionShape3D.new()
	disabled.shape = BoxShape3D.new()
	disabled.disabled = true
	body.add_child(disabled)
	await get_tree().process_frame
	var found := 0
	for child in body.find_children("*", "CollisionShape3D", true, false):
		if not (child as CollisionShape3D).disabled:
			found += 1
	if found != 0:
		_failures += 1
		push_error("禁用形状被当成有效主体（found=%d）" % found)
	# 子 Area 检测圈：不得污染主体形状（读取主体时只应拿到主体那一颗）
	for child in body.get_children():
		child.queue_free()
	var main := CollisionShape3D.new()
	main.shape = CylinderShape3D.new()
	(main.shape as CylinderShape3D).radius = 0.9
	body.add_child(main)
	var ring_area := Area3D.new()
	var ring := CollisionShape3D.new()
	ring.shape = CylinderShape3D.new()
	(ring.shape as CylinderShape3D).radius = 5.0
	ring_area.name = "TargetabilityRing"
	ring_area.add_child(ring)
	body.add_child(ring_area)
	await get_tree().process_frame
	var first := body.find_child("CollisionShape3D", true, false) as CollisionShape3D
	if first == null or first.shape == null or not is_equal_approx((first.shape as CylinderShape3D).radius, 0.9):
		_failures += 1
		push_error("主体形状读取被子 Area 检测圈污染（拿到 %s）" % (str(first.shape) if first != null else "null"))
	host.queue_free()


func _world_span(cs: CollisionShape3D) -> Vector3:
	var b := cs.shape as BoxShape3D
	var local := AABB(-b.size * 0.5, b.size)
	var xf: Transform3D = cs.global_transform
	var out := AABB()
	var first := true
	for i in range(8):
		var pt: Vector3 = xf * local.get_endpoint(i)
		if first:
			out = AABB(pt, Vector3.ZERO); first = false
		else:
			out = out.expand(pt)
	return out.size


func _mk(shape: Shape3D) -> Shape3D:
	if shape is CylinderShape3D:
		(shape as CylinderShape3D).radius = 1.25
		(shape as CylinderShape3D).height = 3.5
	elif shape is BoxShape3D:
		(shape as BoxShape3D).size = Vector3(4.0, 2.0, 6.0)
	elif shape is CapsuleShape3D:
		(shape as CapsuleShape3D).radius = 0.75
		(shape as CapsuleShape3D).height = 2.5
	elif shape is SphereShape3D:
		(shape as SphereShape3D).radius = 0.9
	return shape


func _probe() -> Object:
	return ObstacleScript.new()


func _expect_supported(shape: Shape3D, label: String) -> void:
	_mk(shape)
	var support: String = ObstacleScript.shape_support(shape)
	if support != "supported":
		_failures += 1
		push_error("%s 应被支持，实际 %s" % [label, support])
		return
	var probe := _probe()
	var box: AABB = probe.call("_shape_local_aabb", shape)
	probe.free()
	if box.size.length_squared() <= 0.0:
		_failures += 1
		push_error("%s 读取器返回空 AABB（静默漏读）" % label)


func _expect_unsupported(shape: Shape3D, label: String) -> void:
	var support: String = ObstacleScript.shape_support(shape)
	if support == "supported":
		_failures += 1
		push_error("%s 被误判为支持（应显式不支持）" % label)
		return
	var probe := _probe()
	var box: AABB = probe.call("_shape_local_aabb", shape)
	probe.free()
	if box.size.length_squared() > 0.0:
		_failures += 1
		push_error("%s 返回了非空 AABB，但支持矩阵里标为不支持 ⇒ 口径不一致" % label)


func _check_bounds(shape: Shape3D, label: String) -> void:
	_mk(shape)
	var probe := _probe()
	var box: AABB = probe.call("_shape_local_aabb", shape)
	probe.free()
	var ok := false
	if shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		ok = is_equal_approx(box.size.x, c.radius * 2.0) and is_equal_approx(box.size.y, c.height)
	elif shape is BoxShape3D:
		ok = box.size.is_equal_approx((shape as BoxShape3D).size)
	elif shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		ok = is_equal_approx(box.size.x, cap.radius * 2.0) and is_equal_approx(box.size.y, cap.height)
	elif shape is SphereShape3D:
		ok = is_equal_approx(box.size.x, (shape as SphereShape3D).radius * 2.0)
	if not ok:
		_failures += 1
		push_error("%s 读取尺寸不符：%s" % [label, str(box.size)])
