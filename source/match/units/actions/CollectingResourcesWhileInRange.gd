extends "res://source/match/units/actions/Action.gd"

const Worker = preload("res://source/match/units/Worker.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")

## 采集朝向门槛（度）：车体/身体必须对准矿点才结算采集（2026-09-06 战斗手感）。
const WORKER_AIM_THRESHOLD_DEG = 20.0

## 目标「装满一车」耗时（秒）—— 工人从开采到满载的**采集**时长（不含往返路程）。
## 【2026-09-15 用户要求】「现在工人采集矿的时间就 2s，采集一次带回去 400」：
## 单趟携带 400（见 `config/balance/demo.balance.v1.json` 的 `worker.gatherer.carryCapacity`），
## 装满耗时 ≈ 2 秒。
## 口径从上一版「按容量等比放大（装满恒 12 秒）」改成**按目标时长反推每次搬运量**，
## 因此本值**与容量无关**：以后改 `carryCapacity` 只改单趟收益，装满时长恒定 ≈ 本值。
const TARGET_FILL_SECONDS := 2.0

var _resource_unit = null
var _timer = null
## 采集间隔（每个 tick 的秒数），来自 `BalanceConfigRuntime.GetCollectionDurationSeconds`，
## 由 `_setup_timer()` 缓存（`_resource_batch_per_tick()` 用它反推每 tick 搬运量）。
var _seconds_per_item := 0.0

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _unit_movement_trait = _unit.find_child("Movement")


## 每次结算搬运的资源个数（见 `TARGET_FILL_SECONDS` 说明）。
func _resource_batch_per_tick() -> int:
	var capacity := int(_unit.resources_max)
	if capacity <= 0 or _seconds_per_item <= 0.0:
		return 1
	# 装满耗时 = (容量 / 每 tick 搬运量) × 采集间隔 ⇒ 反推每 tick 该搬多少。
	var ticks := maxi(1, int(ceil(TARGET_FILL_SECONDS / _seconds_per_item)))
	return maxi(1, int(ceil(float(capacity) / float(ticks))))


static func is_applicable(source_unit, target_unit):
	return (
		source_unit is Worker
		and target_unit is ResourceUnit
		and not source_unit.is_full()
		and Utils.Match.Unit.Movement.units_adhere(source_unit, target_unit)
	)


func _init(resource_unit):
	_resource_unit = resource_unit


func _ready():
	_resource_unit.tree_exited.connect(queue_free)
	_unit_movement_trait.passive_movement_started.connect(_on_passive_movement_started)
	_unit_movement_trait.passive_movement_finished.connect(_on_passive_movement_finished)
	_setup_timer()
	_unit.get_node("Sparkling").enable()
	# 采集火花是**本地 Action 驱动**的表现：客户端傀儡不跑 Action，
	# 因此必须由权威端补发（否则联机客户端永远看不到采集火花）。只读、不改玩法。
	_unit.broadcast_presentation("gather", {"active": true})
	if _unit_movement_trait != null:
		# 动作建立时可能已在矿点（被挤开又贴回），主动发起面向矿点的平滑转向
		_unit_movement_trait.face_towards(_resource_unit.global_position)


func _exit_tree():
	_unit.get_node("Sparkling").disable()
	_unit.broadcast_presentation("gather", {"active": false})


func _setup_timer():
	_timer = Timer.new()
	_timer.timeout.connect(_transfer_single_resource_unit_from_resource_to_worker)
	add_child(_timer)
	var resource_name := ""
	if "resource_a" in _resource_unit:
		resource_name = "resource_a"
	elif "resource_b" in _resource_unit:
		resource_name = "resource_b"
	assert(not resource_name.is_empty(), "resource unit has no supported resource kind")
	var balance_runtime = find_parent("Match").get_node("BalanceConfigRuntime")
	_seconds_per_item = float(balance_runtime.GetCollectionDurationSeconds(resource_name))
	_timer.start(_seconds_per_item)


func _transfer_single_resource_unit_from_resource_to_worker():
	# 【2026-09-13 移除逐 tick 调试打印】这里原来对 Unit_2/Unit_3 每个采集 tick 打一行
	# `[COLLECT]`（含一次 `units_adhere` 计算），单局刷出 **35 万行** stdout ——
	# 对游戏帧率是白白的 I/O 与格式化开销（玩家反馈掉帧时排查到的固定成本之一）。
	# 采集链路的事实已由观测通道（10Hz 采样 + `[GATHER]` 状态迁移）覆盖，不需要这行。
	if not Utils.Match.Unit.Movement.units_adhere(_unit, _resource_unit):
		# 2026-08-31: 导航停点与贴合阈值(0.3m)相差厘米级, 严格判死会造成
		# 「到达→采不到→重走」死循环(采集时灵时不灵的根因)。2 倍距离内宽限采集。
		if not Utils.Match.Unit.Movement._unit_in_range_of_other(
			_unit, _resource_unit, Constants.Match.Units.ADHERENCE_MARGIN_M * 2.0
		):
			queue_free()
			return
	# 面向矿点才开始采集：未对准则重新发起平滑转向并跳过本次 tick（不中断采集动作）
	if not _is_facing_resource():
		if _unit_movement_trait != null:
			_unit_movement_trait.face_towards(_resource_unit.global_position)
		return
	# 【2026-09-15 一次搬运量按容量等比放大】先按"工人剩余容量"夹紧，避免超出
	# `Worker.is_full()` 的容量断言（旧实现每 tick 只加 1 所以不需要这层保护）。
	var room: int = maxi(0, int(_unit.resources_max) - int(_unit.resource_a) - int(_unit.resource_b))
	if room <= 0:
		queue_free()
		return
	var batch: int = mini(_resource_batch_per_tick(), room)
	if "resource_a" in _resource_unit:
		# 矿不够时最多采到 0；矿已耗尽仍取 1，保持「减到 ≤0 ⇒ is_resource_depleted() 判定移除」的原语义。
		var take_a: int = mini(batch, maxi(1, int(_resource_unit.resource_a)))
		_resource_unit.resource_a -= take_a
		_unit.resource_a += take_a
	if "resource_b" in _resource_unit:
		var take_b: int = mini(batch, maxi(1, int(_resource_unit.resource_b)))
		_resource_unit.resource_b -= take_b
		_unit.resource_b += take_b
	if _unit.is_full():
		queue_free()


## 车体/身体正前方（-Z）与矿点方向的水平夹角是否在采集门槛内。
func _is_facing_resource() -> bool:
	var to_resource: Vector3 = (
		(_resource_unit.global_position - _unit.global_position) * Vector3(1, 0, 1)
	)
	if to_resource.length() < 0.1:
		return true  # 贴得太近无稳定方向，视为已对准
	var forward: Vector3 = (-_unit.global_transform.basis.z) * Vector3(1, 0, 1)
	return rad_to_deg(forward.normalized().angle_to(to_resource.normalized())) <= WORKER_AIM_THRESHOLD_DEG


func _on_passive_movement_started():
	_timer.paused = true


func _on_passive_movement_finished():
	_timer.paused = false
	# 平滑转向面向矿点（2026-09-02）：原 looking_at 瞬时转向在 RVO 反复推挤时
	# 造成矿工持续抖动；改走 Movement 的限速平滑面朝接口。
	_unit_movement_trait.face_towards(_resource_unit.global_position)
