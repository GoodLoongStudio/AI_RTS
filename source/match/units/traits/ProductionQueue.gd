extends Node

signal element_enqueued(element)
signal element_removed(element)


## HUD 使用的只读生产项目视图；权威身份、状态和进度均来自 C#。
class ProductionQueueElement:
	extends Resource
	var item_id := ""
	var unit_prototype = null
	var required_work := 1
	var completed_work := 0
	var state := "Queued"
	## 该建筑当前的每 tick 工效（成长 × 同类建筑加成的合成值，见
	## Unit.refresh_production_work_rate）。60 = 物理帧率（tick/秒）。
	## 工效 >1 时实际耗时更短，ETA 必须按它折算，否则进度条会"越走越慢"。
	var work_per_tick := 1.0
	var time_total:
		get:
			return float(required_work) / (60.0 * work_per_tick)
	var time_left:
		get:
			return float(required_work - completed_work) / (60.0 * work_per_tick)

	## 返回仅用于 HUD 的归一化进度。
	func progress():
		return float(completed_work) / float(required_work)


var _queue := []
var _runtime = null
var _last_result: Dictionary = {}

const AiPerfStats = preload("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")

@onready var _unit = get_parent()


func _ready():
	var perf_on := AiPerfStats.enabled()
	var started := Time.get_ticks_usec() if perf_on else 0
	_runtime = find_parent("Match").get_node("ProductionRuntime")
	_runtime.RegisterProducer(_unit, self, _unit.get_script().resource_path)
	if perf_on:
		AiPerfStats.add("spawn_producer", Time.get_ticks_usec() - started)


func size():
	return _queue.size()


func get_elements():
	return _queue


## 只读：供 NetSync 周期快照下发给客户端的队列镜像（服务器侧调用）。
## 带 `scene_path`，客户端无需再解析 definition_id → 场景，直接 `load()` 即可。
func presentation_snapshot() -> Array:
	var out: Array = []
	for element in _queue:
		var scene_path := ""
		if element.unit_prototype is PackedScene:
			scene_path = element.unit_prototype.resource_path
		out.append({
			"item_id": element.item_id,
			"scene_path": scene_path,
			"state": element.state,
			"required_work": element.required_work,
			"completed_work": element.completed_work,
		})
	return out


## 客户端镜像入口：用服务器快照对齐只读队列视图（增/改/删都在这一个入口收敛）。
##
## 为什么需要：C# 生产服务在客户端**被门控**（`ProductionRuntime._PhysicsProcess`
## 非服务器直接 return），`on_authoritative_item_*` 回调永不发生 →
## 客户端 HUD 队列恒空、没有进度动画（用户报"UI 的建造动画"缺失）。
## 这里只维护**只读视图**：客户端下单仍走 `produce()` 转发，权威结算仍全在服务器。
## 走快照而非事件：10Hz、幂等、可自愈（丢包/晚到都不会卡住 HUD）。
func apply_presentation_snapshot(items: Array) -> void:
	if NetSession.is_server():
		return
	var wanted: Dictionary = {}
	for item in items:
		if not (item is Dictionary):
			continue
		var item_id := str(item.get("item_id", ""))
		if item_id.is_empty():
			continue
		wanted[item_id] = true
		# 显式收敛类型：网络回来的 Variant 未必与 ProductionQueueElement 的
		# 推断类型（int）一致，直接赋值会在运行期报类型错误。
		var snapshot := {
			"required_work": int(item.get("required_work", 1)),
			"completed_work": int(item.get("completed_work", 0)),
			"state": str(item.get("state", "Queued")),
		}
		var element = _find_element(item_id)
		if element == null:
			var scene_path := str(item.get("scene_path", ""))
			if scene_path.is_empty():
				continue
			var packed = load(scene_path)
			if packed == null:
				continue
			element = ProductionQueueElement.new()
			element.item_id = item_id
			element.unit_prototype = packed
			_apply_snapshot(element, snapshot)
			_queue.push_back(element)
			element_enqueued.emit(element)
			continue
		_apply_snapshot(element, snapshot)
		element.emit_changed()
	var removed_any := false
	for element in _queue.duplicate():
		if wanted.has(element.item_id):
			continue
		_queue.erase(element)
		element_removed.emit(element)
		removed_any = true
	if removed_any and _queue.is_empty():
		MatchSignals.unit_production_queue_became_empty.emit(_unit)


## 最近一次提交的权威回执；调试端点和 HUD 用它区分接受、拒绝与待确认。
func get_last_result() -> Dictionary:
	return _last_result.duplicate(true)


## 通过统一 C# 服务提交生产；不存在暂停、调序或容量绕过参数。
func produce(unit_prototype):
	if NetSession.should_forward_commands():
		var sync = find_parent("Match").get_node_or_null("NetSync")
		if sync != null:
			var scene_path := ""
			if unit_prototype is PackedScene:
				scene_path = unit_prototype.resource_path
			else:
				scene_path = str(unit_prototype)
			# 客户端生成稳定 command_id 随命令上送，服务器保留同一 ID 落账，
			# 副官下一轮可用 op=commands 按 id 复核最终 Accepted/Rejected。
			var command_id := "%08x-%04x-4%03x-%04x-%012x" % [
				randi(), randi() & 0xFFFF, randi() & 0xFFF,
				randi() & 0xFFFF, Time.get_ticks_msec() * 4096 + (randi() & 0xFFF),
			]
			sync.forward_command(
				"produce", [_unit], Vector3.ZERO, null, _unit.player,
				scene_path + "|" + command_id
			)
			_last_result = {
				"accepted": false,
				"status": "PendingAuthority",
				"command_id": command_id,
				"producer": str(_unit.name),
				"scene": scene_path,
			}
			return null
	var result = _runtime.Enqueue(
		_unit,
		unit_prototype,
		_unit.player
	)
	_last_result = result.duplicate(true)
	if not result["accepted"]:
		if result["status"] == "InsufficientResources":
			MatchSignals.not_enough_resources_for_production.emit(_unit.player)
		return null
	return _find_element(result["item"]["item_id"])


## 取消全部生产：联机客户端必须**转发给服务器**执行
##（本地 C# 生产服务在客户端被门控，没有权威队列条目，直接本地取消会静默失败 — 2026-09-14）。
func cancel_all():
	if NetSession.should_forward_commands():
		var sync = find_parent("Match").get_node_or_null("NetSync")
		if sync != null:
			sync.forward_command("cancel_produce", [_unit], Vector3.ZERO, null, _unit.player, "*")
		return
	_runtime.CancelAll(_unit, _unit.player)


## 取消单个生产项：联机客户端把 item_id 转发给服务器执行（服务器取消后由快照同步队列视图）。
func cancel(element):
	if element == null or not element in _queue:
		return
	if NetSession.should_forward_commands():
		var sync = find_parent("Match").get_node_or_null("NetSync")
		if sync != null:
			sync.forward_command(
				"cancel_produce", [_unit], Vector3.ZERO, null, _unit.player, str(element.item_id)
			)
		return
	_runtime.Cancel(element.item_id, _unit.player)


## 接收权威入队事件并建立只读 HUD 元素。
func on_authoritative_item_queued(item, unit_prototype):
	var element = ProductionQueueElement.new()
	element.item_id = item["item_id"]
	element.unit_prototype = unit_prototype
	_apply_snapshot(element, item)
	_queue.push_back(element)
	element_enqueued.emit(element)


## 项目真正成为队首时刷新视图并兼容发布 Legacy 开始事件。
func on_authoritative_item_started(item):
	var element = _find_element(item["item_id"])
	if element == null:
		return
	_apply_snapshot(element, item)
	element.emit_changed()
	MatchSignals.unit_production_started.emit(element.unit_prototype, _unit)


## 接收权威状态或整数进度变化并刷新 HUD。
func on_authoritative_item_changed(item):
	var element = _find_element(item["item_id"])
	if element == null:
		return
	_apply_snapshot(element, item)
	element.emit_changed()


## 接收权威终态并从活动 HUD 队列移除项目。
func on_authoritative_item_removed(item):
	var element = _find_element(item["item_id"])
	if element == null:
		return
	_queue.erase(element)
	element_removed.emit(element)
	if _queue.is_empty():
		MatchSignals.unit_production_queue_became_empty.emit(_unit)


## 生产建筑模型的 XZ 世界外缘半径（Geometry 子树所有 GeometryInstance3D 的世界 AABB）。
## 【2026-09-29 尺寸口径统一】旧实现先 `global_transform.affine_inverse()` 再乘 instance
## 变换，等于把世界角点搬回**建筑本地空间**——这会连 root scale 一起抵消掉：
## 场景写 scale=3 的建筑，本函数仍按"未缩放模型"算外缘 → 出生点贴着原始模型，
## 视觉上却离实际模型很远（"兵从房子中间/背后冒出来"）。
## 现在直接用 `instance.global_transform * corner` 得到**世界角点**，再对建筑世界原点
## 取 XZ 距离 —— 与视觉完全一致（root scale 生效后尤其重要）。
## 取不到（headless/无 Geometry/未就绪）返回 0，由调用方退回物理 footprint 口径。
func _producer_model_edge() -> float:
	if not (_unit is Node3D):
		return 0.0
	var origin: Vector3 = (_unit as Node3D).global_position
	var edge := 0.0
	for node in _unit.find_children("*", "GeometryInstance3D", true, false):
		var instance := node as GeometryInstance3D
		if instance == null:
			continue
		if instance.has_meta("exclude_from_geometry_measurements"):
			continue
		var aabb: AABB = instance.get_aabb()
		if aabb.size.length() <= 0.0:
			continue
		var to_world: Transform3D = instance.global_transform
		for index in 8:
			var corner := Vector3(
				aabb.position.x + (aabb.size.x if index & 1 else 0.0),
				aabb.position.y + (aabb.size.y if index & 2 else 0.0),
				aabb.position.z + (aabb.size.z if index & 4 else 0.0))
			var world_corner: Vector3 = to_world * corner
			edge = maxf(edge, Vector2(world_corner.x - origin.x, world_corner.z - origin.z).length())
	return edge


## 生产建筑正脸（局部 +Z 的世界朝向，压平 Y）：兵从"门口"出，
## 不再恒为世界 +Z（2026-09-29 用户实报方向与兵营朝向无关）。
func _producer_facing() -> Vector3:
	if not (_unit is Node3D):
		return Vector3(0, 0, 1)
	var basis: Basis = (_unit as Node3D).global_transform.basis
	var facing: Vector3 = basis * Vector3(0, 0, 1)
	facing.y = 0.0
	if facing.length() < 0.001:
		return Vector3(0, 0, 1)
	return facing.normalized()


## 尝试在有限搜索范围内部署完成单位；受阻时返回 null 供 C# 稍后重试。
func try_deploy_authoritative(unit_prototype):
	var produced_unit = unit_prototype.instantiate()
	var match_node = find_parent("Match")
	var occupancy = null
	var navigation_map := RID()
	if match_node != null and match_node.navigation != null \
			and match_node.navigation.has_method("should_skip_runtime_navigation") \
			and match_node.navigation.should_skip_runtime_navigation(match_node.map):
		var map_node = match_node.get_node_or_null("Map")
		if map_node != null and map_node.has_meta("water_occupancy"):
			occupancy = map_node.get_meta("water_occupancy")
	elif match_node != null and match_node.navigation != null:
		navigation_map = match_node.navigation.get_navigation_map_rid_by_domain(
			produced_unit.movement_domain
		)
	# 【2026-09-29 用户实报"兵生产出来的位置有问题"】起始半径改用建筑**模型外缘**
	# 而不是 footprint `radius`：09-27 统一尺寸把 footprint 抬到 6.25（兵营），
	# 于是兵永远落在距中心 6.25+1.35+0.1=7.70m 处（实测），方向还恒为世界 +Z
	# （与兵营朝向无关）。现在：外缘取 Geometry 子树 AABB 的 XZ 最大半宽，
	# 方向取建筑正脸（局部 +Z 的世界朝向），并把建筑自己加进 ignored_units
	# （否则自碰撞判定仍把落点锁在 footprint 外沿，改起始半径也没用）。
	# 【2026-09-29 尺寸口径统一】改用共享出生点算法（与 OreRefinery._grant_free_miner
	# 同一入口，见 UnitPlacementUtils.production_spawn_spot）：世界角点算模型外缘、
	# 方向随建筑正脸、建筑自身进 ignored_units。
	var placement_position = Utils.Match.Unit.Placement.production_spawn_spot(
		_unit, produced_unit, 0.1, navigation_map, get_tree(), 24, occupancy
	)
	if placement_position == Vector3.INF:
		produced_unit.free()
		return null
	if occupancy != null and occupancy.has_method("project_ground"):
		placement_position = occupancy.project_ground(placement_position)
	MatchSignals.setup_and_spawn_unit.emit(
		produced_unit, Transform3D(Basis(), placement_position), _unit.player
	)
	MatchSignals.unit_production_finished.emit(produced_unit, _unit)
	return produced_unit


## 把稳定快照复制到只读 HUD 视图。
func _apply_snapshot(element, item):
	element.required_work = item["required_work"]
	element.completed_work = item["completed_work"]
	element.state = item["state"]
	# ETA 按建筑当前工效折算（成长 × 同类建筑加成）；属性缺失或非法回退 1.0。
	# 每次 authoritative 更新都刷新：加成在对局中途变化（新同类建筑完工/被拆）也能跟上。
	var per_tick = _unit.get("production_work_per_tick")
	element.work_per_tick = (
		float(per_tick) if (per_tick != null and float(per_tick) > 0.0) else 1.0
	)


func _find_element(item_id: String):
	for element in _queue:
		if element.item_id == item_id:
			return element
	return null
