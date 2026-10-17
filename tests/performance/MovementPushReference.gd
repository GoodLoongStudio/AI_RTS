extends "res://source/match/units/traits/Movement.gd"

# Frozen pre-optimization oracle; do not update it with the production implementation.
func _ready() -> void:
	set_physics_process(false)


func reference_ground_hull(node: Node3D, dir: Vector2, ground_band: float = 0.6) -> float:
	var origin: Vector3 = node.global_position
	var out := 0.0
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		# 注意：MeshInstance3D.skeleton 是 **NodePath**（不是 Skeleton3D 引用），必须解析成节点。
		var skel_path: NodePath = (gi as MeshInstance3D).skeleton if gi is MeshInstance3D else NodePath()
		var skel: Skeleton3D = null
		if skel_path != NodePath():
			skel = gi.get_node_or_null(skel_path) as Skeleton3D
		if skel != null:
			var xf_skel: Transform3D = (gi as Node3D).global_transform
			for b in range(skel.get_bone_count()):
				var bp: Vector3 = xf_skel * skel.get_bone_global_pose(b).origin
				if bp.y - origin.y > ground_band:
					continue
				out = maxf(out, Vector2(bp.x - origin.x, bp.z - origin.z).dot(dir))
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > ground_band:
				continue
			out = maxf(out, Vector2(pt.x - origin.x, pt.z - origin.z).dot(dir))
	return maxf(out, 0.0)


func reference_push(point: Vector3, allow_escape: bool = false) -> Vector3:
	var group_name: String = (
		Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(domain, "")
	)
	if group_name == "" or not is_inside_tree():
		return point
	var obstacles := get_tree().get_nodes_in_group(group_name)
	if obstacles.is_empty():
		return point
	var own_radius: float = maxf(float(radius), 0.0)
	var unit_planar := Vector2(_unit.global_position.x, _unit.global_position.z)
	var planar := Vector2(point.x, point.z)
	for obstacle in obstacles:
		if obstacle == _unit or not is_instance_valid(obstacle):
			continue
		var obstacle_radius = obstacle.get("radius")
		if obstacle_radius == null:
			continue
		# 只有比单位本身更大的障碍才需要推出去：建筑（半径 1.5~2.0）会把落点吞进避让圈，
		# 而矿点/小炮塔（半径 0.6）本来就该被贴近——推出去反而会超出采集/交互的贴合距离，
		# 让工人卡在"到达→贴不上→重走"的循环里（实测过）。
		if float(obstacle_radius) <= own_radius:
			continue
		# 【2026-10-01 逐单位碰撞包围任务】障碍占地从"一律当圆"改为**贴形最近点**：
		#   长方体 ⇒ 真实 OBB 最近点（yaw 生效；窄轴不再白留 (maxHalf−minHalf) 的余量）；
		#   圆柱/胶囊/球 ⇒ 圆；不支持的形状 ⇒ 显式告警 + AABB 保守圆（不静默漏读）。
		# 【2026-10-01 回退说明】贴盒最近点（_obstacle_footprint_closest）已实现并保留，
		# 但当前配置下"贴盒 carve + 每步硬占位"会在盒的**宽轴**方向产生 −0.9m 穿模
		# （四方向实测），根因尚未定位 ⇒ 先回到**实测全安全**的"包含圆"口径：
		# stand_off = 障碍包含半径 + 个人空间 + margin（所有方向间隙 ≥ 0，代价是窄轴多留余量）。
		# 下一轮：定位"每步硬占位未生效"后再启用贴盒路径。
		# 贴形最近点（OBB/圆）；不支持形状显式告警 + AABB 兜底
		# 【2026-10-01 第 8 轮结论】贴形推出已验证可把工兵间隙从 1.66m 降到 1.02m（无穿模），
		# 但启用后 navigation-stability 三条断言转红（到达后仍被推动 ⇒ 订单不结束），
		# 且 carve 圆（包含半径+agent）成为新限制层 ⇒ 单靠贴形推出到不了目标带。
		# 下一轮需"贴形 carve + 贴形推出 + 到达优先"三者一起上并重新标定 navigation-stability。
		# 【2026-10-01 状态：未启用，勿按"已实现"计数】贴形最近点已实现（函数 _obstacle_footprint_closest），
		# 但**当前没有任何调用点**；历史上三次启用实验（含 carve 最小中心距约束）都让
		# navigation-stability 或 movement-recovery 转红 ⇒ 全部回退。启用前的硬前置（独立复核 D2）：
		#   工兵碰撞圆柱 r=0.92 **覆盖不了模型长轴 1.262**（车头各露出 0.342m）
		#   ⇒ 贴形推出必须取 max(碰撞形状, 近地视觉 hull 沿朝向) 作为占位半宽，否则车头会插进建筑。
		# 【2026-10-01 第 20 轮实测定量】贴形 + carve 约束 + D2（max(碰撞,视觉)）组合下：
		#   单位**能到达但慢约 3 倍**（building-mid-move 38.6s vs 基线 11.5s；stall 44 / escape 44），
		#   ⇒ 贴形推出在障碍附近产生微振荡，让 movement-recovery / navigation-stability 的**时序**断言失败。
		#   要落地必须同步重标定移动层脱困/到达阈值（超出碰撞层范围）⇒ 暂缓启用。
		var obstacle_origin: Vector3 = obstacle.global_position
		var closest := Vector2(obstacle_origin.x, obstacle_origin.z)
		# 【第 46 轮·推出发追踪实测（AIRTS_PUSH_TRACE=1）】兵营：r=3.11 own=1.36 ⇒ stand_off=4.47
		# ⇒ **恰好等于物理下限**（3.105+1.36=4.465，与 committed 实测逐位吻合 ✓）⇒ 说明
		# margin(0.1) − 补偿(0.25) = −0.15 < 0 ⇒ maxf 永远返回物理下限 ⇒ **安全余量与到达补偿完全抵消** ✓。
		# 含义：① 推出层目前**没有**额外白留 ✓（痛点不在这里）；② 想调余量必须让 margin > 补偿 ✓。
		# 【第 47 轮】贴形实验（带数值追踪）：
		var physical_min: float = float(obstacle_radius) + own_radius
		var obstacle_c := Vector2(obstacle.global_position.x, obstacle.global_position.z)
		var dir_c := planar - obstacle_c
		var dir_n := dir_c.normalized() if dir_c.length() > 0.0001 else Vector2.RIGHT
		var fp47 := _obstacle_footprint_closest(obstacle, planar)
		var shaped_inside := bool(fp47.get("inside", false))
		var current_shape_inside := false
		if allow_escape and bool(fp47.get("ok", false)):
			# 目的点可能已经离开形状，但当前单位仍在形状内部；
			# 这种情况只能先退到最近边界，不能用“目标在外面”穿过整栋建筑。
			var current_fp := _obstacle_footprint_closest(obstacle, unit_planar)
			current_shape_inside = bool(current_fp.get("inside", false))
		# 【第 48 轮·第二处修复】建筑类障碍的"近地视觉 hull"返回 0（主体顶点高于 0.6m 带 ✗）⇒
		# 回退到**碰撞形状沿该方向的半宽**（复核方 D2 要求的 max(碰撞, 视觉) 中，碰撞一侧 ✓）。
		var vis47: float = reference_ground_hull(_unit, dir_n)
		# 窄通道阶段的“允许短暂小穿模”只放宽移动个人空间到真实物理形状，
		# 不把动画/炮管 hull 再叠加一次；正常阶段仍保留视觉 hull 防穿模。
		if _narrow_pass_saved_radius >= 0.0:
			var narrow_collision_half := _unit_ground_half_extent(dir_n, false)
			if narrow_collision_half > 0.01:
				vis47 = narrow_collision_half
		if vis47 <= 0.01:
			var cs48: CollisionShape3D = null
			for ch in obstacle.get_parent().find_children("*", "CollisionShape3D", true, false):
				var c48 := ch as CollisionShape3D
				if c48 != null and c48.shape != null and not c48.disabled:
					cs48 = c48
					break
			if cs48 != null:
				if cs48.shape is BoxShape3D:
					var b48 := cs48.shape as BoxShape3D
					var xf48: Transform3D = cs48.global_transform
					var local_dir := xf48.basis.inverse() * Vector3(dir_n.x, 0.0, dir_n.y)
					vis47 = maxf(absf(local_dir.x) * b48.size.x * 0.5, absf(local_dir.z) * b48.size.z * 0.5)
				elif cs48.shape is CylinderShape3D:
					vis47 = (cs48.shape as CylinderShape3D).radius
		var shaped_closest: Vector2 = fp47.get("closest", obstacle_c)
		# 【第 51 轮·实验结论】把"单位侧也方向感知"（用单位 hull 替代个人空间）虽然让工兵间隙
		# 0.147 → **0.084m** ✓，但会让 navigation-stability 转红 ✗（到达后仍被推动 ⇒ 订单不结束）。
		# ⇒ 已回退：保留"障碍贴形 + 单位用个人空间"的组合（工兵 0.147 ✓ 在带内、全绿 ✓）。
		# 【第 52 轮·实验结论】"方向感知（单位 hull）+ 到达让位"组合**仍**会让 navigation-stability 转红 ✗
		# （12.6s，到达后仍被推动 ⇒ 订单不结束）⇒ 已回退 ✓。
		# 说明：瓶颈是**推出层与到达判定在同一帧的互相拉扯** ✓，不是让位阈值能解决的 ✓
		# ⇒ 下一步须改"到达判定的口径"（例如到达时冻结推出），而不是继续收 stand_off ✓。
		# 【第 53 轮·实验结论】"到达后冻结推出（让位 2.0m）+ 方向感知"**仍**让 navigation-stability 转红 ✗
		# ⇒ 该耦合**不是距离参数能解决的** ✓（0.6m 与 2.0m 都试过 ✗）⇒ 需改**到达判定本身**（与推出解耦）✓。
		var shaped_stand_off: float = maxf(own_radius, vis47) + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M
		var shaped_ok: bool = bool(fp47.get("ok", false))
		if _push_trace_on:
			print("[PUSH-SHAPE] obstacle=%s r=%.2f own=%.2f vis=%.2f 圆形so=%.2f 贴形so=%.2f 贴形closest=(%.2f,%.2f) ok=%s" % [
				str(obstacle.name), float(obstacle_radius), own_radius, vis47, physical_min, shaped_stand_off,
				shaped_closest.x, shaped_closest.y, str(fp47.get("kind", "?"))])
		# 【第 48 轮·正式启用贴形】stand_off 从**障碍表面**起算 = max(单位个人空间, 单位视觉 hull) + 余量 − 补偿
		# （D2 要求取 max(碰撞形状, 近地视觉 hull) —— 对象是**单位**自己 ✗ 不是障碍 ✓）。
		var stand_off: float = maxf(
			physical_min + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M,
			physical_min
		)
		if shaped_ok:
			closest = shaped_closest
			stand_off = maxf(shaped_stand_off, own_radius * 0.0)
		var step_distance: float = planar.distance_to(closest)
		if _push_trace_on:
			print("[PUSH] unit=%s obstacle=%s r=%.2f own=%.2f stand_off=%.2f step_d=%.2f escape=%s" % [
				_unit.name, str(obstacle.name), float(obstacle_radius), own_radius, stand_off, step_distance, str(allow_escape)])
		if step_distance >= stand_off:
			continue
		if allow_escape:
			# 脱困时允许沿障碍外侧离开，但不能把目标在障碍外误当成穿墙许可。
			# 如果当前位置或候选落点已进入真实形状，先推出到最近边界；只有
			# 两者都在形状外时才要求这一步不能继续向障碍中心靠近。
			if not shaped_inside and not current_shape_inside:
				var current_distance: float = unit_planar.distance_to(closest)
				if step_distance >= current_distance:
					continue
		var outward := unit_planar - closest
		if shaped_inside or current_shape_inside:
			# closest→unit 在 inside 情况下指向盒内，取反才是安全推出方向。
			outward = closest - unit_planar
		if outward.length() < 0.001:
			outward = planar - closest
		if outward.length() < 0.001:
			outward = Vector2.RIGHT
		planar = closest + outward.normalized() * stand_off
	return Vector3(planar.x, point.y, planar.y)


