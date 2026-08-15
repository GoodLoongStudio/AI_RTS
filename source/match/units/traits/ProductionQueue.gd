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
	var time_total:
		get:
			return float(required_work) / 60.0
	var time_left:
		get:
			return float(required_work - completed_work) / 60.0

	## 返回仅用于 HUD 的归一化进度。
	func progress():
		return float(completed_work) / float(required_work)


var _queue := []
var _runtime = null

@onready var _unit = get_parent()


func _ready():
	_runtime = find_parent("Match").get_node("ProductionRuntime")
	_runtime.RegisterProducer(_unit, self, _unit.get_script().resource_path)


func size():
	return _queue.size()


func get_elements():
	return _queue


## 通过统一 C# 服务提交生产；不存在暂停、调序或容量绕过参数。
func produce(unit_prototype):
	var result = _runtime.Enqueue(
		_unit,
		unit_prototype,
		_unit.player
	)
	if not result["accepted"]:
		if result["status"] == "InsufficientResources":
			MatchSignals.not_enough_resources_for_production.emit(_unit.player)
		return null
	return _find_element(result["item"]["item_id"])


func cancel_all():
	_runtime.CancelAll(_unit, _unit.player)


func cancel(element):
	if element == null or not element in _queue:
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


## 尝试在有限搜索范围内部署完成单位；受阻时返回 null 供 C# 稍后重试。
func try_deploy_authoritative(unit_prototype):
	var produced_unit = unit_prototype.instantiate()
	var navigation_map = find_parent("Match").navigation.get_navigation_map_rid_by_domain(
		produced_unit.movement_domain
	)
	var placement_position = (
		Utils
		. Match
		. Unit
		. Placement
		. find_valid_position_radially_yet_skip_starting_radius(
			_unit.global_position,
			_unit.radius,
			produced_unit.radius,
			0.1,
			Vector3(0, 0, 1),
			false,
			navigation_map,
			get_tree(),
			24
		)
	)
	if placement_position == Vector3.INF:
		produced_unit.free()
		return null
	MatchSignals.setup_and_spawn_unit.emit(
		produced_unit, Transform3D(Basis(), placement_position), _unit.player
	)
	MatchSignals.unit_production_finished.emit(produced_unit, _unit)
	var rally_point = _unit.find_child("RallyPoint")
	if rally_point != null:
		MatchSignals.navigate_unit_to_rally_point.emit(produced_unit, rally_point)
	return produced_unit


## 把稳定快照复制到只读 HUD 视图。
func _apply_snapshot(element, item):
	element.required_work = item["required_work"]
	element.completed_work = item["completed_work"]
	element.state = item["state"]


func _find_element(item_id: String):
	for element in _queue:
		if element.item_id == item_id:
			return element
	return null
