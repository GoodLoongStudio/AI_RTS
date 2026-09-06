extends "res://source/match/units/actions/Action.gd"

const Worker = preload("res://source/match/units/Worker.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")

## 采集朝向门槛（度）：车体/身体必须对准矿点才结算采集（2026-09-06 战斗手感）。
const WORKER_AIM_THRESHOLD_DEG = 20.0

var _resource_unit = null
var _timer = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _unit_movement_trait = _unit.find_child("Movement")


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
	if _unit_movement_trait != null:
		# 动作建立时可能已在矿点（被挤开又贴回），主动发起面向矿点的平滑转向
		_unit_movement_trait.face_towards(_resource_unit.global_position)


func _exit_tree():
	_unit.get_node("Sparkling").disable()


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
	_timer.start(balance_runtime.GetCollectionDurationSeconds(resource_name))


func _transfer_single_resource_unit_from_resource_to_worker():
	if _unit.name in ["Unit_2", "Unit_3"]:
		print("[COLLECT] ", _unit.name, " tick adhere=", Utils.Match.Unit.Movement.units_adhere(_unit, _resource_unit), " carried=", _unit.resource_a, "/", _unit.resource_b)
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
	if "resource_a" in _resource_unit:
		_resource_unit.resource_a -= 1
		_unit.resource_a += 1
	if "resource_b" in _resource_unit:
		_resource_unit.resource_b -= 1
		_unit.resource_b += 1
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
