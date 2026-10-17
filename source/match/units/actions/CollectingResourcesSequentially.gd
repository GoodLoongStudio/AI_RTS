extends "res://source/match/units/actions/Action.gd"

signal task_ended(reason)

enum State { NULL, MOVING_TO_RESOURCE, COLLECTING, MOVING_TO_CC, UNLOADING }

## 接近矿点的有界重试次数：超过就放弃本次采集并给出明确原因，避免 carve/避让圈
## 让"到达→贴不上→重走"变成无限循环。
const MAX_RESOURCE_APPROACH_RETRIES := 4

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CollectingResourcesWhileInRange = preload(
	"res://source/match/units/actions/CollectingResourcesWhileInRange.gd"
)
const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")
const ResourceUtils = preload("res://source/match/utils/ResourceUtils.gd")
const DROPOFF_ROTATIONS_BEFORE_OTHER_MINE := 4
const SparklingAnimation = preload("res://source/match/utils/SparklingAnimation.tscn")
## 卸货停留。没有单独的卸货配置，和装满一车的采集时长对齐。
const UNLOAD_DWELL_SECONDS: float = CollectingResourcesWhileInRange.TARGET_FILL_SECONDS

var _state := State.NULL
var _state_locked = false
var _resource_unit = null
var _cc_unit = null
var _sub_action = null
var _is_suspended := false
var _terminal_reason_after_delivery := ""
## 当前这轮"接近矿点"的重试计数（贴合失败时重走；成功采上或换矿点就清零）。
var _approach_retries := 0
var _move_end_reason := ""
var _dropoff_rotations := 0
var _rejected_resources := {}
## 卡住后改去另一座矿场时，进返程不要立刻被「最近矿场」覆盖掉。
var _keep_drop := false
var _unload_timer: Timer = null
var _unload_fx: Node = null
var _unload_paid := false

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(source_unit, target_unit):
	# 【2026-09-30 用户口径】矿车只能把矿交给**矿场**：右键主基地不再是交矿订单
	# （会按普通走近建筑处理）。采集目标仍然只能是矿点。
	return source_unit is Worker and target_unit is ResourceUnit


func _init(unit):
	if unit is ResourceUnit:
		_set_resource_unit(unit)
	elif unit is CommandCenter:
		_set_cc_unit(unit)


var _heal_ticks := 0


func _physics_process(_delta):
	# 自愈(2026-08-31): 子动作因回调竞态丢失时, 重建当前状态的子动作,
	# 消除「采集订单 Accepted 但工人站桩不采矿」的时序竞态。
	# 守卫: 单位死亡拆树时引用可能悬空。
	if not is_inside_tree() or not is_instance_valid(_unit):
		return
	if _is_suspended or _state == State.NULL or _state_locked or _state == State.UNLOADING:
		return
	if _sub_action != null:
		_heal_ticks = 0
		return
	_heal_ticks += 1
	if _heal_ticks < 3:
		return
	_heal_ticks = 0
	match _state:
		State.MOVING_TO_RESOURCE:
			if _resource_unit != null and is_instance_valid(_resource_unit):
				print("[GATHER] 自愈: 重建前往资源点 unit=", _unit.name)
				_change_state_to(State.MOVING_TO_RESOURCE)
		State.COLLECTING:
			if (
				_resource_unit != null
				and is_instance_valid(_resource_unit)
				and CollectingResourcesWhileInRange.is_applicable(_unit, _resource_unit)
			):
				print("[GATHER] 自愈: 重建采集 unit=", _unit.name)
				_change_state_to(State.COLLECTING)
			elif _resource_unit != null and is_instance_valid(_resource_unit):
				_change_state_to(State.MOVING_TO_RESOURCE)
		State.MOVING_TO_CC:
			print("[GATHER] 自愈: 重建回城 unit=", _unit.name)
			_change_state_to(State.MOVING_TO_CC)


func _ready():
	print("[GATHER] action _ready unit=", _unit.name, " resource=", _resource_unit != null)
	if _resource_unit != null:
		_change_state_to(State.MOVING_TO_RESOURCE)
	elif _cc_unit != null:
		_change_state_to(State.MOVING_TO_CC)


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func get_resource_unit():
	return _resource_unit


func _change_state_to(new_state):
	assert(not _state_locked, "changing state during transition is not implemented")
	_state_locked = true
	var old_state = _state
	_exit_state(old_state)
	_enter_state(new_state)
	_state = new_state
	_state_locked = false


func _exit_state(a_state):
	if a_state != State.UNLOADING:
		return
	_stop_unload_presentation()
	if _unload_timer != null:
		_unload_timer.stop()


func _enter_state(state):
	match state:
		State.MOVING_TO_RESOURCE:
			print("[GATHER] 进入 MOVING_TO_RESOURCE, resource=", _resource_unit)
			if _resource_unit == null:
				_finish_task(
					_terminal_reason_after_delivery
					if not _terminal_reason_after_delivery.is_empty()
					else "TargetLost"
				)
				return
			_sub_action = MovingToUnit.new(_resource_unit)
			_sub_action.ended.connect(_remember_move_reason)
			_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
			add_child(_sub_action)
			_unit.action_updated.emit()
		State.COLLECTING:
			assert(
				CollectingResourcesWhileInRange.is_applicable(_unit, _resource_unit),
				"the action should apply at this point"
			)
			_sub_action = CollectingResourcesWhileInRange.new(_resource_unit)
			_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
			add_child(_sub_action)
			_unit.action_updated.emit()
		State.MOVING_TO_CC:
			print("[GATHER] ", _unit.name, " 满载回城")
			var drop_off = null
			if _keep_drop and _cc_unit != null and is_instance_valid(_cc_unit) \
					and _cc_unit.is_inside_tree() and _cc_unit.has_method("is_drop_off") \
					and _cc_unit.is_drop_off() and _cc_unit.has_method("is_constructed") \
					and _cc_unit.is_constructed():
				drop_off = _cc_unit
			_keep_drop = false
			if drop_off == null:
				drop_off = find_drop_off(_unit)
			if drop_off == null:
				# 没有己方已完工、能收这种资源的矿场：不回主基地。满载就地持货。
				_finish_task("NoDropOff")
				return
			_set_cc_unit(drop_off)
			_start_drop_move()
		State.UNLOADING:
			# 钱在停留开始时入账，车留下看完卸货特效再走。自愈不能在这段空子动作里重建回城。
			var movement = _unit.find_child("Movement")
			if movement != null and is_instance_valid(movement) and movement.has_method("stop"):
				movement.stop()
			_unload_paid = _transfer_collected_resources_to_player()
			_play_unload_presentation()
			_ensure_unload_timer()
			_unload_timer.start(UNLOAD_DWELL_SECONDS)
			_unit.action_updated.emit()


func _set_resource_unit(resource_unit):
	if resource_unit == null:
		queue_free()
		return false
	assert(resource_unit != _resource_unit, "it's not possible to set the same unit")
	_resource_unit = resource_unit
	_resource_unit.tree_exited.connect(_on_resource_unit_removed)
	return true


func _set_cc_unit(cc_unit):
	if cc_unit == null:
		queue_free()
		return false
	if cc_unit != _cc_unit:
		cc_unit.tree_exited.connect(_on_cc_unit_removed)
	_cc_unit = cc_unit
	return true


func _transfer_collected_resources_to_player() -> bool:
	var delivery = {
		"resource_a": _unit.resource_a,
		"resource_b": _unit.resource_b,
	}
	print("[GATHER] 交付 resource_a=%s resource_b=%s player=%s" % [str(_unit.resource_a), str(_unit.resource_b), _unit.player.name])
	var delivery_a := int(delivery.get("resource_a", 0))
	var match_root = _unit.find_parent("Match")
	# 采集交付倍率只有**一处**乘法：局内海克斯 × 成长（永久加点）。
	# 成长倍率的换算只认 `GrowthModifiers.gather_multiplier`（别处不许自己乘）。
	var gather_mult := 1.0
	var runtime = match_root.get_node_or_null("AugmentRuntime") if match_root != null else null
	if runtime != null and runtime.has_method("gather_multiplier"):
		gather_mult *= float(runtime.gather_multiplier(_unit.player))
	gather_mult *= GrowthModifiers.gather_multiplier(_unit.player)
	if gather_mult > 1.0:
		delivery["resource_a"] = preload(
			"res://source/match/augments/AugmentModifiers.gd"
		).scale_gather(delivery_a, gather_mult)
	var accepted = _unit.player.add_resources(delivery, "WorkerDelivery", _unit)
	assert(accepted, "a valid Worker delivery must reach its authoritative resource account")
	if not accepted:
		return false
	# 矿场运营的结果证据：只有"记在矿场账上的实际交付"才能证明矿场真的在产出。
	# 交付目标是 `_cc_unit`（find_drop_off 选出的最近己方完工矿场）。
	if _cc_unit != null and _cc_unit.has_method("record_delivery"):
		_cc_unit.record_delivery(_unit, int(delivery.get("resource_a", 0)))
	_unit.resource_a = 0
	_unit.resource_b = 0
	return true


## 交货点：水平距离最近的己方已完工矿场（is_drop_off）。不要求事先接管这颗矿或这辆车。
## 指挥中心不是交货点。没有任何可用矿场时返回 null，满车持货，不回主基地。
static func find_drop_off(unit):
	if unit == null or not is_instance_valid(unit):
		return null
	var player = unit.get_parent()
	var best = null
	var best_d := INF
	for node in unit.get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node.get_parent() != player:
			continue
		if not node.has_method("is_drop_off") or not node.is_drop_off():
			continue
		if node.has_method("is_constructed") and not node.is_constructed():
			continue
		var d: float = Vector2(
			unit.global_position.x - node.global_position.x,
			unit.global_position.z - node.global_position.z
		).length()
		if d < best_d:
			best = node
			best_d = d
	return best


func _handle_sub_action_finished_while_moving_to_resource():
	if _resource_unit == null:
		if _unit.resource_a + _unit.resource_b > 0:
			_change_state_to(State.MOVING_TO_CC)
		else:
			_finish_task(
				_terminal_reason_after_delivery
				if not _terminal_reason_after_delivery.is_empty()
				else "TargetLost"
			)
		return
	# 【2026-10-07 幻影采矿修复】走到矿点才发现它已采空（在途中被采完/本就已耗尽）：
	# 与矿点消失同口径收尾，不进 COLLECTING——否则"到空矿→采集 tick 立刻结束→回城→
	# 再回空矿"会变成无效往返（用户实测采空后矿车还在往返空矿）。
	if _is_resource_exhausted(_resource_unit):
		print("[GATHER] ", _unit.name, " 目标矿点已耗尽，结束采集")
		_wind_down_resource_gone("Completed")
		return
	# resource reached
	if not _unit.is_full():
		# 【2026-09-29】"移动结束"不等于"贴上了矿点"：矿点周围有 carve/避让圈时，
		# 单位可能停在贴合阈值之外（2026-09-23 实测工人被挡在 3.2m、阈值 3.1m）。
		# 直接进 COLLECTING 会撞 `CollectingResourcesWhileInRange.is_applicable` 的断言
		# （实测：出生点 carve 修复后矿车绕开 24m 洞，到达点偏离阈值，日志刷 SCRIPT ERROR）。
		# 与 `_handle_sub_action_finished_while_collecting` 同一套口径：不贴合就重新接近，
		# 有界重试，超限才放弃（不把问题掩成静默失败）。
		if not Utils.Match.Unit.Movement.units_adhere(_unit, _resource_unit):
			_approach_retries += 1
			if _approach_retries > MAX_RESOURCE_APPROACH_RETRIES:
				print("[GATHER] ", _unit.name, " 多次接近仍贴不上矿点，放弃本次采集")
				_finish_task("ResourceUnreachable")
				return
			print("[GATHER] ", _unit.name, " 到达矿点但未贴合，重新接近（第 ", _approach_retries, " 次）")
			_change_state_to(State.MOVING_TO_RESOURCE)
			return
		_approach_retries = 0
		print("[GATHER] 到达资源点, 开始采集 unit=", _unit.name)
		_change_state_to(State.COLLECTING)
	else:
		_change_state_to(State.MOVING_TO_CC)


func _handle_sub_action_finished_while_collecting():
	if _resource_unit == null:
		if _unit.resource_a + _unit.resource_b > 0:
			_change_state_to(State.MOVING_TO_CC)
		else:
			_finish_task(
				_terminal_reason_after_delivery
				if not _terminal_reason_after_delivery.is_empty()
				else "TargetLost"
			)
		return
	# 【2026-10-07 幻影采矿修复】矿点在采集途中耗尽（存量 ≤0、进入 depleted 等待再生）：
	# 采集动作会自行结束（不再从空矿取矿），这里按"矿点消失"同口径收尾——
	# 当前载荷能送则送，任务以 Completed 终态结束，不再对空矿反复往返。
	if _is_resource_exhausted(_resource_unit):
		print("[GATHER] ", _unit.name, " 矿点采空，结算后结束采集")
		_wind_down_resource_gone("Completed")
		return
	# react to resource not being in range anymore
	if not _unit.is_full() and not Utils.Match.Unit.Movement.units_adhere(_unit, _resource_unit):
		_change_state_to(State.MOVING_TO_RESOURCE)
		return
	# finished collecting
	_change_state_to(State.MOVING_TO_CC)


func _handle_sub_action_finished_while_moving_to_cc():
	# react to cc removal
	if _cc_unit == null or not _cc_unit.is_constructed():
		var drop_off = find_drop_off(_unit)
		if drop_off == null:
			# 交货途中矿场没了又没有别的矿场可交：以 NoDropOff 终止（不回退主基地）。
			_finish_task("NoDropOff")
			return
		_set_cc_unit(drop_off)
		_change_state_to(State.MOVING_TO_CC)
		return
	if _unit.resource_a + _unit.resource_b <= 0:
		if not _terminal_reason_after_delivery.is_empty():
			_finish_task(_terminal_reason_after_delivery)
		else:
			_change_state_to(State.MOVING_TO_RESOURCE)
		return
	_change_state_to(State.UNLOADING)


func _remember_move_reason(reason: String) -> void:
	_move_end_reason = reason


func _on_sub_action_finished():
	if not is_inside_tree() or _is_suspended:
		return
	var reason := _move_end_reason
	_move_end_reason = ""
	_sub_action = null
	_unit.action_updated.emit()
	if reason == "Unreachable":
		if _state == State.MOVING_TO_RESOURCE:
			_retarget_stuck_resource()
		elif _state == State.MOVING_TO_CC:
			_retarget_stuck_dropoff()
		return
	match _state:
		State.MOVING_TO_RESOURCE:
			_handle_sub_action_finished_while_moving_to_resource()
		State.COLLECTING:
			_handle_sub_action_finished_while_collecting()
		State.MOVING_TO_CC:
			_handle_sub_action_finished_while_moving_to_cc()


func _retarget_stuck_resource() -> void:
	if _resource_unit != null:
		_rejected_resources[_resource_unit.get_instance_id()] = true
	var nxt = ResourceUtils.find_resource_unit_closest_to_unit_yet_no_further_than(
		_unit, 48.0, _is_unrejected_resource
	)
	if nxt == null:
		_finish_task("ResourceUnreachable")
		return
	if _resource_unit != null and is_instance_valid(_resource_unit) \
			and _resource_unit.tree_exited.is_connected(_on_resource_unit_removed):
		_resource_unit.tree_exited.disconnect(_on_resource_unit_removed)
	_resource_unit = null
	_approach_retries = 0
	_set_resource_unit(nxt)
	_change_state_to(State.MOVING_TO_RESOURCE)


func _is_unrejected_resource(resource) -> bool:
	if resource == null or not is_instance_valid(resource):
		return false
	if _rejected_resources.has(resource.get_instance_id()):
		return false
	if "resource_a" in resource and int(resource.resource_a) <= 0:
		return false
	if "resource_b" in resource and not ("resource_a" in resource) and int(resource.resource_b) <= 0:
		return false
	if not ("resource_a" in resource) and not ("resource_b" in resource):
		return false
	return _owner_can_see(resource)


func _owner_can_see(resource) -> bool:
	if _unit == null or not is_instance_valid(_unit):
		return true
	var match_node = _unit.find_parent("Match")
	if match_node == null:
		return true
	var fog = match_node.get_node_or_null("FogOfWar")
	if fog == null or not fog.has_method("player_can_see"):
		return true
	return bool(fog.player_can_see(_unit.get_parent(), resource.global_position, resource))


func _retarget_stuck_dropoff() -> void:
	_dropoff_rotations += 1
	Utils.Match.Unit.Movement.rotate_approach_slot(_unit)
	if _dropoff_rotations >= DROPOFF_ROTATIONS_BEFORE_OTHER_MINE:
		var other = _nearest_other_refinery()
		_dropoff_rotations = 0
		if other != null:
			_keep_drop = true
			_unit.set_meta("ore_refinery_assignment", other)
			_set_cc_unit(other)
	_change_state_to(State.MOVING_TO_CC)


func _nearest_other_refinery():
	var best = null
	var best_d := INF
	for node in _unit.get_tree().get_nodes_in_group("units"):
		if node == _cc_unit or not is_instance_valid(node):
			continue
		var script = node.get_script()
		if script == null or not str(script.resource_path).ends_with("OreRefinery.gd"):
			continue
		if node.get_parent() != _unit.get_parent():
			continue
		if not node.has_method("is_constructed") or not node.is_constructed():
			continue
		var d: float = Vector2(
			_unit.global_position.x - node.global_position.x,
			_unit.global_position.z - node.global_position.z
		).length()
		if d < best_d:
			best = node
			best_d = d
	return best


func _on_resource_unit_removed():
	_terminal_reason_after_delivery = "Completed" if _is_resource_depleted() else "TargetLost"
	_resource_unit = null


## 矿点"耗尽"判定：剩余存量 ≤0（已转入 depleted 等待再生，实体仍在树上）。
## 与 `_is_resource_depleted()`（面向"实体被移除时区分 Completed/TargetLost"）互补：
## 那个回答"它为什么消失"，这个回答"它现在还有没有矿"。
static func _is_resource_exhausted(resource_unit) -> bool:
	if resource_unit == null or not is_instance_valid(resource_unit):
		return false
	if resource_unit.has_method("total_ore"):
		return int(resource_unit.total_ore()) <= 0
	if "resource_a" in resource_unit:
		return int(resource_unit.resource_a) <= 0
	if "resource_b" in resource_unit:
		return int(resource_unit.resource_b) <= 0
	return false


## 矿点"没了"（实体移除或耗尽等待再生）时的统一收尾：当前载荷能送则送，
## 随后任务以给定原因终态结束。不再对空矿重走无效往返（2026-10-07 修复）。
func _wind_down_resource_gone(reason: String) -> void:
	if _resource_unit != null and _resource_unit.tree_exited.is_connected(_on_resource_unit_removed):
		_resource_unit.tree_exited.disconnect(_on_resource_unit_removed)
	_terminal_reason_after_delivery = reason
	_resource_unit = null
	if _unit.resource_a + _unit.resource_b > 0:
		_change_state_to(State.MOVING_TO_CC)
	else:
		_finish_task(reason)


func _on_cc_unit_removed():
	_cc_unit = null


func _exit_tree() -> void:
	_stop_unload_presentation()


func _start_drop_move() -> void:
	var action = MovingToUnit.new(_cc_unit)
	action.ended.connect(_remember_move_reason)
	_swap_sub_action(action)


func _swap_sub_action(next_action) -> void:
	if _sub_action != null and is_instance_valid(_sub_action):
		if _sub_action.tree_exited.is_connected(_on_sub_action_finished):
			_sub_action.tree_exited.disconnect(_on_sub_action_finished)
		if _sub_action.has_signal("ended") and _sub_action.ended.is_connected(_remember_move_reason):
			_sub_action.ended.disconnect(_remember_move_reason)
		var old = _sub_action
		_sub_action = null
		old.queue_free()
	_sub_action = next_action
	_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _ensure_unload_timer() -> void:
	if _unload_timer != null and is_instance_valid(_unload_timer):
		return
	_unload_timer = Timer.new()
	_unload_timer.one_shot = true
	_unload_timer.timeout.connect(_on_unload_dwell_finished)
	add_child(_unload_timer)


func _on_unload_dwell_finished() -> void:
	if not is_inside_tree() or _state != State.UNLOADING:
		return
	if not _unload_paid:
		_change_state_to(State.MOVING_TO_CC)
		return
	if not _terminal_reason_after_delivery.is_empty():
		_finish_task(_terminal_reason_after_delivery)
		return
	_change_state_to(State.MOVING_TO_RESOURCE)


## 卸货表现复用采集闪光：矿车上的 Sparkling，加上矿场身上同一套粒子。
func _play_unload_presentation() -> void:
	if _unit != null and is_instance_valid(_unit):
		var sparkling = _unit.get_node_or_null("Sparkling")
		if sparkling != null and sparkling.has_method("enable"):
			sparkling.enable()
		if _unit.has_method("broadcast_presentation"):
			_unit.broadcast_presentation("gather", {"active": true})
	if _unload_fx != null and is_instance_valid(_unload_fx):
		return
	if _cc_unit == null or not is_instance_valid(_cc_unit):
		return
	_unload_fx = SparklingAnimation.instantiate()
	_unload_fx.position = Vector3(0, 2.0, 0)
	_cc_unit.add_child(_unload_fx)


func _stop_unload_presentation() -> void:
	if _unit != null and is_instance_valid(_unit):
		var sparkling = _unit.get_node_or_null("Sparkling")
		if sparkling != null and sparkling.has_method("disable"):
			sparkling.disable()
		if _unit.has_method("broadcast_presentation"):
			_unit.broadcast_presentation("gather", {"active": false})
	if _unload_fx != null and is_instance_valid(_unload_fx):
		_unload_fx.queue_free()
	_unload_fx = null


## 暂停整个采集任务并保留当前阶段、目标与 Worker 已携带资源。
func suspend_task() -> bool:
	if _is_suspended:
		return true
	_is_suspended = true
	_stop_unload_presentation()
	if _unload_timer != null:
		_unload_timer.stop()
	if _sub_action != null:
		if _sub_action.tree_exited.is_connected(_on_sub_action_finished):
			_sub_action.tree_exited.disconnect(_on_sub_action_finished)
		remove_child(_sub_action)
		_sub_action.queue_free()
		_sub_action = null
	_unit.find_child("Movement").stop()
	_unit.action_updated.emit()
	return true


## 返回当前采集任务是否已由统一 Stop 暂停，供测试与迁移期诊断读取。
func is_task_suspended() -> bool:
	return _is_suspended


## 判断正在退出的资源节点是否因为存量归零而正常耗尽。
func _is_resource_depleted() -> bool:
	if _resource_unit == null:
		return false
	if "resource_a" in _resource_unit:
		return _resource_unit.resource_a <= 0
	if "resource_b" in _resource_unit:
		return _resource_unit.resource_b <= 0
	return false


## 发布采集任务终态并结束组合 Action；资源入账只允许在返程交付函数中发生。
func _finish_task(reason: String):
	if not is_inside_tree():
		return
	task_ended.emit(reason)
	queue_free()
