extends "res://source/match/units/actions/Action.gd"

## Worker 的“侵略”姿态：自动寻找最近的可用资源并持续执行采集循环。
## 具体采集、满载回城和资源交付仍复用 CollectingResourcesSequentially。
signal task_updated

const CollectingResourcesSequentially = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)
const ResourceUtils = preload("res://source/match/utils/ResourceUtils.gd")

const SEARCH_INTERVAL_S := 0.5
const SEARCH_RADIUS_M := 30.0

var _sub_action = null
var _search_timer: Timer = null
var _search_pending := false

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _ready():
	if _unit == null and get_parent() != null:
		_unit = get_parent()
	_search_timer = Timer.new()
	_search_timer.one_shot = false
	_search_timer.wait_time = SEARCH_INTERVAL_S
	_search_timer.timeout.connect(_try_start_gather)
	add_child(_search_timer)
	_search_timer.start()
	call_deferred("_try_start_gather")


func refresh_combat_policy():
	if _unit == null:
		return
	var match_node = _unit.find_parent("Match")
	var runtime = match_node.get_node_or_null("CommandRuntime") if match_node != null else null
	if runtime == null or runtime.GetEngagementStance(_unit) != "Aggressive":
		queue_free()


func _physics_process(_delta):
	if _unit == null or not is_instance_valid(_unit) or _sub_action != null:
		return
	if not _search_pending:
		_try_start_gather()


func _try_start_gather():
	_search_pending = false
	if _unit == null or not is_instance_valid(_unit) or not _unit.is_inside_tree():
		return
	if _sub_action != null:
		return
	if not _is_aggressive():
		queue_free()
		return

	var resource = ResourceUtils.find_resource_unit_closest_to_unit_yet_no_further_than(
		_unit,
		SEARCH_RADIUS_M,
		_is_available_resource
	)
	if resource == null:
		_search_pending = true
		return

	_sub_action = CollectingResourcesSequentially.new(resource)
	_sub_action.tree_exited.connect(_on_sub_action_exited, CONNECT_DEFERRED)
	add_child(_sub_action)
	task_updated.emit()
	_unit.action_updated.emit()


func _on_sub_action_exited():
	_sub_action = null
	_search_pending = true
	if is_inside_tree() and _unit != null and is_instance_valid(_unit):
		task_updated.emit()
		_unit.action_updated.emit()


func _is_aggressive() -> bool:
	var match_node = _unit.find_parent("Match")
	var runtime = match_node.get_node_or_null("CommandRuntime") if match_node != null else null
	return runtime != null and runtime.GetEngagementStance(_unit) == "Aggressive"


func _is_available_resource(resource) -> bool:
	if resource == null or not is_instance_valid(resource) or not resource.is_inside_tree():
		return false
	if "resource_a" in resource:
		return resource.resource_a > 0
	return false
