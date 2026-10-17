extends Node

## 新单位模型阵容截图（2026-09-11）：
## 一排生成全部新单位 + 坦克参照，相机俯瞰截图到 res://new_units_lineup.png，
## 同时验证机场可生产运输机（修复页签错放导致无法训练的问题）。

const MatchScene = preload("res://tests/manual/TestAllUnits.tscn")
const HelicopterScene = preload("res://source/match/units/Helicopter.tscn")
const APCScene = preload("res://source/match/units/APC.tscn")
# 补齐 Ra3Sidebar.TABS 中缺失图标的单位/建筑（见下方 roster）。
const BarracksScene = preload("res://source/match/units/Barracks.tscn")
const AntiGroundTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const AntiAirTurretScene = preload("res://source/match/units/AntiAirTurret.tscn")
const MachineGunTurretScene = preload("res://source/match/units/MachineGunTurret.tscn")
const InfantryScene = preload("res://source/match/units/Infantry.tscn")
const SniperScene = preload("res://source/match/units/Sniper.tscn")
const RocketeerScene = preload("res://source/match/units/Rocketeer.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const TransportTruckScene = preload("res://source/match/units/TransportTruck.tscn")
# Keep the current refinery icon; Scout retired on 2026-10-10.
const OreRefineryScene = preload("res://source/match/units/OreRefinery.tscn")
# 2026-09-29 复核旧图标：09-04 那批（基地/车厂/机场/坦克/直升机/无人机）画的还是换模型前的
# 旧外观（"基地"是个黄色货箱、"坦克"是亮黄旧车），一并纳入清单刷新。
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const AircraftFactoryScene = preload("res://source/match/units/AircraftFactory.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HelicopterSceneUnit = preload("res://source/match/units/Helicopter.tscn")
const DroneScene = preload("res://source/match/units/Drone.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")

## ── 图标规范（2026-10-10）────────────────────────────────────────────────
## 用户口径：「这些UI的建筑的大小你也规范一下，基地这么小，兵营这么大，都不协调」。
## 规则：每张图标都按模型**实际包围盒**取景，再迭代把**可见内容**（非透明像素包围盒）
## 收敛到占画面 `ICON_TARGET_FILL`，并把内容居中。
## 因此观感大小只由这一条规则决定，不再有人工逐条微调（那正是大小不一致的根因）。
const ICON_DIR := "res://source/match/hud/ra3/icons"
const ICON_SIZE_PX := 128
const ICON_TARGET_FILL := 0.82
## 迭代次数：先按包围盒估一个初值，再用"渲染→量占比→改相机 size/中心"收敛。
const ICON_FIT_ITERATIONS := 16
## 取景方向（相机相对取景中心的偏移方向）。沿用旧管线的等距视角，保证光照/朝向观感不变。
const ICON_VIEW_DIR := Vector3(2.2, 3.0, 3.2)

var _failures := 0
var _produced_drop_ships: Array = []


func _ready():
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	var match_instance = MatchScene.instantiate()
	add_child(match_instance)
	await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout

	var human = match_instance.get_node("Players/Human")

	# 机场生产直升机（飞机页签生产链路验证）
	var aircraft_factory = human.get_node("AircraftFactory")
	var waited := 0.0
	while waited < 10.0 and human.get("_economy_runtime") == null:
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	human.add_resources({"resource_a": 5000}, "ScriptedAdjustment")
	var item = aircraft_factory.production_queue.produce(HelicopterScene)
	_check(item != null, "机场应可入队生产运输机")
	var produce_waited := 0.0
	while _produced_drop_ships.is_empty() and produce_waited < 40.0:
		await get_tree().create_timer(0.25).timeout
		produce_waited += 0.25
	_check(
		_produced_drop_ships.size() == 1,
		"直升机应在 40s 内从机场部署（实际 %d）" % _produced_drop_ships.size()
	)

	# ── 逐单位生成渲染图标 ────────────────────────────────────────────────────
	# entry[0] = 输出文件名，必须与 Ra3Sidebar.TABS 的 icon key 完全一致。
	#
	# 【2026-10-10 图标规范（用户："基地这么小，兵营这么大，都不协调"）】
	# 这里**不再**逐条手调正交相机 size / 取景高度（旧 roster 是 步兵 0.9 … 基地 16.0 的手调值，
	# 实测内容占满度从 0.352（对地炮）到 1.000（兵营/矿场）差 2.8 倍，正是"大小不协调"的根因）。
	# 现在统一走 `_render_normalized_icon()`：按模型实际包围盒取景 + 迭代把**可见内容**
	# （非透明像素包围盒）收敛到 `ICON_TARGET_FILL` 并居中，因此每个图标观感大小一致。
	var roster = [
		["apc", APCScene],
		["barracks", BarracksScene],
		["anti_ground_turret", AntiGroundTurretScene],
		["anti_air_turret", AntiAirTurretScene],
		["machine_gun_turret", MachineGunTurretScene],
		["soldier", InfantryScene],
		["sniper", SniperScene],
		["rocketeer", RocketeerScene],
		["heavy_tank", HeavyTankScene],
		["transport_truck", TransportTruckScene],
		["ore_refinery", OreRefineryScene],
		["command_center", CommandCenterScene],
		["vehicle_factory", VehicleFactoryScene],
		["aircraft_factory", AircraftFactoryScene],
		["tank", TankScene],
		["helicopter", HelicopterSceneUnit],
		["drone", DroneScene],
		# 【2026-10-10 补齐】矿车图标此前不在清单里（`worker.png` 是手工/旧管线产物），
		# 导致它不随规范刷新；矿车在 Ra3Sidebar.TABS 的载具页里，必须一并纳入。
		["worker", WorkerScene],
	]
	# 用独立 SubViewport 渲染图标：共享 3D 世界但不带 HUD/侧栏
	var sub = SubViewport.new()
	sub.size = Vector2i(ICON_SIZE_PX, ICON_SIZE_PX)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = true
	sub.own_world_3d = true
	match_instance.add_child(sub)
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.4
	sub.add_child(light)
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 3.2
	sub.add_child(camera)
	for entry in roster:
		var unit = entry[1].instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis.IDENTITY, Vector3(12, 0, 12)), human, false
		)
		await get_tree().process_frame
		await get_tree().create_timer(0.4).timeout
		if not is_instance_valid(unit):
			continue
		var geometry = unit.find_child("Geometry", true, false)
		if geometry == null:
			unit.queue_free()
			continue
		# 只把网格拷进隔离世界渲染，规避地图建筑/导航漂移干扰
		var copy = geometry.duplicate()
		sub.add_child(copy)
		# Geometry 根节点自带模型缩放（载具 0.6 / 步兵 0.45…），必须保留；
		# 但炮塔的 Geometry 挂在 DetachTransform 下、被 PositionSynchronizer(RemoteTransform3D)
		# 接管，运行时 global 已被拉到单位世界坐标 (12,0,12)，直接拷会飞出取景框（图标全透明）。
		# 换算成「相对单位原点」的变换，两种结构都能还原作者意图的局部变换。
		copy.transform = unit.global_transform.affine_inverse() * geometry.global_transform
		var report: Dictionary = await _render_normalized_icon(sub, camera, copy, str(entry[0]))
		print("[ICON] %s fill=%.3f center_off=(%d,%d) size=%.2f iter=%d" % [
			entry[0], float(report["fill"]), int(report["dx"]), int(report["dy"]),
			float(report["camera_size"]), int(report["iterations"])])
		if float(report["fill"]) <= 0.0:
			_failures += 1
			print("FAIL: 图标 %s 渲染为空（取景失败）" % entry[0])
		copy.queue_free()
		unit.queue_free()
		await get_tree().process_frame
		await get_tree().create_timer(0.2).timeout
	print("[ICON] all icons rendered")

	print("New units lineup test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _on_unit_production_finished(unit, producer):
	if producer.name == "AircraftFactory" and unit.scene_file_path == HelicopterScene.resource_path:
		_produced_drop_ships.append(unit)


## 规范化渲染一个图标：自动取景（包围盒 → 迭代收敛到目标占满度 → 居中）并写盘。
## 返回 { fill, dx, dy, camera_size, iterations }（fill=可见内容占画面比例，dx/dy=居中残差像素）。
##
## 为什么要"渲染→量→改"迭代而不是纯算 AABB：世界轴对齐包围盒投影是**偏大**的包络，
## 斜置模型的真实剪影明显小于它 ⇒ 只用 AABB 会导致各图标占满度参差（还是不一致）。
## 迭代直接以**像素级可见内容**为判据，才能让"观感大小"真正一致。
##
## ⚠ 三个实测坑（2026-10-10 首次跑就踩到，别再踩）：
##   ① **回读滞后**：改完相机后要等"绘制完成的那一帧"再读纹理，读早了拿到的是上一帧
##      （表现为第一个条目量到空图、后面条目量到前一个模型的占比）⇒ 每次改完相机都 `_settle()`。
##   ② **空图必须退避放大**：模型很小时按 AABB 估的取景窗也可能一帧都拍不到东西
##      （首轮 APC 就是 fill=0.000）⇒ 连续空图就 `size *= 2` 重试，而不是直接放弃。
##   ③ **饱和要逃逸**：占比贴到 1.000 说明已经溢出画面（步兵那类小模型被压到 size≈0.09），
##      必须一次性放大很多才能跳出饱和区。
func _render_normalized_icon(sub: SubViewport, camera: Camera3D, model: Node3D, icon_name: String) -> Dictionary:
	var box := _aabb_of(model)
	var center := box.get_center()
	var dir := ICON_VIEW_DIR.normalized()
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	# 相机距离按模型大小定（正交投影下不影响大小，只影响近裁面/LOD）：
	# 旧管线相机离模型约 4.9m，这里给 6m 起、大建筑按最大边 1.6 倍拉开，避免相机陷进模型内部。
	var distance := maxf(6.0, minf(longest, 30.0) * 1.6)
	# 初值：用包围盒最大边估一个不会裁切的取景窗。
	# ⚠ 骨骼网格（步兵）的 `mesh.get_aabb()` 在绑定姿态下可能严重失真 ⇒ 初值上下限夹紧，
	#   真正的取景交给下面的迭代收敛。
	var initial_size := clampf(longest / ICON_TARGET_FILL * 1.25, 0.05, 60.0)
	if longest < 0.2:
		# 骨骼网格（步兵）的常见病：`mesh.get_aabb()` 在绑定姿态下退化成 ~0，
		# 依它算会给出 0.05 这种荒谬取景窗、要爬十几轮才到位。直接换中性初值。
		initial_size = 3.0
	camera.size = initial_size
	camera.look_at_from_position(center + dir * distance, center, Vector3.UP)
	print("  [icon-fit] %s aabb=%.2fx%.2fx%.2f initial_size=%.3f" % [
		icon_name, box.size.x, box.size.y, box.size.z, initial_size])

	var rect := Rect2i()
	var iterations := 0
	var best_fill := -1.0
	var best_size := camera.size
	for _i in range(ICON_FIT_ITERATIONS):
		rect = await _measure_ink(sub)
		var fill := 0.0
		if rect.size.x > 0 and rect.size.y > 0:
			fill = float(maxi(rect.size.x, rect.size.y)) / float(ICON_SIZE_PX)
			iterations += 1
			# 记录"最接近目标"的一次取景：收尾若仍未达标就退回它
			if best_fill < 0.0 or absf(fill - ICON_TARGET_FILL) < absf(best_fill - ICON_TARGET_FILL):
				best_fill = fill
				best_size = camera.size
			if absf(fill - ICON_TARGET_FILL) <= 0.02:
				break
		var world_per_px := camera.size / float(ICON_SIZE_PX)
		# ── 收敛策略（正交投影下 size ∝ 1/fill，线性步进即可）──────────────
		# 单步夹在 [0.4, 2.5]：既能让很差初值（步兵骨骼 AABB 退化 ⇒ 从 3.0 爬到 ~1.0）快速收敛，
		# 又不会过冲；溢出（fill≈1）按 2 倍缩回，空图按 0.5 放大（绝不让 size 塌到 0）。
		var gain := 1.0
		if fill <= 0.001:
			gain = 0.5
		elif fill >= 0.995:
			gain = 2.0
		else:
			gain = clampf(fill / ICON_TARGET_FILL, 0.4, 2.5)
		camera.size = clampf(camera.size * gain, 0.02, 500.0)
		# 居中：只在"内容完整在画面内"时可信（溢出时包围盒中心没有意义）
		if fill > 0.001 and fill < 0.98:
			center += _center_correction(camera, rect)
		camera.look_at_from_position(center + dir * distance, center, Vector3.UP)

	# 收尾①：最后一轮若仍在容差带外，退回"最接近目标"的那次取景
	if best_fill > 0.0 and absf(best_fill - ICON_TARGET_FILL) > 0.02:
		camera.size = best_size
		camera.look_at_from_position(center + dir * distance, center, Vector3.UP)

	# 收尾②：补居中（居中量总是"比缩放晚一步"，早退时最容易留下偏差）
	# 迭代最多 3 次：单次线性修正对某些模型（如对空炮的长炮管）不一定一步到位。
	for _i in range(3):
		rect = await _measure_ink(sub)
		if rect.size.x <= 0 or rect.size.y <= 0:
			break
		var residual := Vector2(rect.position) + Vector2(rect.size) * 0.5 \
			- Vector2(float(ICON_SIZE_PX), float(ICON_SIZE_PX)) * 0.5
		if residual.length() <= 2.0:
			break
		center += _center_correction(camera, rect)
		camera.look_at_from_position(center + dir * distance, center, Vector3.UP)

	# 收尾③：用最终取景再写盘一次，并回报最终指标（读两帧取后者，避开回读滞后）
	rect = await _measure_ink(sub)
	var final_image := sub.get_texture().get_image()
	var out := {"fill": 0.0, "dx": 0, "dy": 0, "camera_size": camera.size, "iterations": iterations}
	if final_image != null:
		if rect.size.x > 0 and rect.size.y > 0:
			var cx := float(rect.position.x) + float(rect.size.x) * 0.5
			var cy := float(rect.position.y) + float(rect.size.y) * 0.5
			out["fill"] = float(maxi(rect.size.x, rect.size.y)) / float(ICON_SIZE_PX)
			out["dx"] = int(round(cx - float(ICON_SIZE_PX) * 0.5))
			out["dy"] = int(round(cy - float(ICON_SIZE_PX) * 0.5))
		var save_err := final_image.save_png(
			ProjectSettings.globalize_path("%s/%s.png" % [ICON_DIR, icon_name]))
		out["save_err"] = save_err
	return out


## 像素级测量：先等"绘制完成的那一帧"，再**读两次**（中间再等一帧）取后者，
## 规避"改完相机读到的还是上一帧"的回读滞后（首版就是被它坑到出现 0.000/1.000 假值）。
func _measure_ink(sub: SubViewport) -> Rect2i:
	await _settle()
	var image := sub.get_texture().get_image()
	await _settle()
	var image2 := sub.get_texture().get_image()
	var use := image2 if image2 != null else image
	if use == null:
		return Rect2i()
	return use.get_used_rect()


## 把"内容中心相对画面中心的像素偏移"换算成取景中心的世界位移（沿相机 right/up 轴）。
func _center_correction(camera: Camera3D, rect: Rect2i) -> Vector3:
	var offset := Vector2(rect.position) + Vector2(rect.size) * 0.5 \
		- Vector2(float(ICON_SIZE_PX), float(ICON_SIZE_PX)) * 0.5
	var world_per_px := camera.size / float(ICON_SIZE_PX)
	var basis := camera.global_transform.basis
	return basis.x * (offset.x * world_per_px) - basis.y * (offset.y * world_per_px)


## 等"绘制完成的那一帧"再读纹理：先过 process_frame（让相机/变换生效），再等 frame_post_draw。
func _settle() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame


## 节点子树里所有可见 MeshInstance3D 的世界空间包围盒（无网格时返回空 AABB）。
func _aabb_of(node: Node3D) -> AABB:
	var merged := AABB()
	var has_any := false
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box := mesh_instance.global_transform * mesh_instance.mesh.get_aabb()
		merged = box if not has_any else merged.merge(box)
		has_any = true
	if not has_any:
		return AABB(Vector3.ZERO, Vector3.ONE * 0.5)
	return merged


## 在地图上找一个离所有单位/建筑至少 4 米的空位，保证图标里没有杂物。
func _find_free_spot() -> Vector3:
	var all_units = get_tree().get_nodes_in_group("units")
	for z in [12.0, 14.0, 10.0, 8.0]:
		for x in [4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0]:
			var candidate = Vector3(x, 0, z)
			var free := true
			for u in all_units:
				if is_instance_valid(u) and u.global_position.distance_to(candidate) < 4.0:
					free = false
					break
			if free:
				return candidate
	return Vector3(12, 0, 12)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	print("FAIL: %s" % message)
	push_error("New units lineup assertion failed: %s" % message)
