extends "res://source/match/units/actions/Action.gd"

## Worker 的“侵略”姿态：自动寻找最近的可用资源并持续执行采集循环。
## 具体采集、满载回城和资源交付仍复用 CollectingResourcesSequentially。
signal task_updated

const CollectingResourcesSequentially = preload(
	"res://source/match/units/actions/CollectingResourcesSequentially.gd"
)
const ResourceUtils = preload("res://source/match/utils/ResourceUtils.gd")

const SEARCH_INTERVAL_S := 0.5
## 搜索距离只是全图上限。真正的界限是玩家当前视野，不是矿场服务半径，也不是这 30 米。
const SEARCH_RADIUS_M := 4096.0

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

	# 满载且没有己方完工矿场时不接新采集，避免「走到矿点→无法交货→再走」的死循环。
	# 有矿场即可交，不要求这辆车或这颗矿被事先指派。
	# 「有处可交」在本地判断，不静态调用 CollectingResourcesSequentially.find_drop_off：
	# 那个静态调用是编译期依赖，对方一改名，本脚本会连带 Unit.gd / Structure.gd 解析失败。
	if _unit.is_full() and not _has_friendly_drop_off(_unit):
		_search_pending = true
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


## 是否存在己方已完工、能收货的矿场。与 find_drop_off 同口径的本地副本，
## 避免跨脚本静态调用（见 _try_start_gather 内注释）。
static func _has_friendly_drop_off(unit) -> bool:
	if unit == null or not is_instance_valid(unit):
		return false
	var player = unit.get_parent()
	for node in unit.get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if node.get_parent() != player:
			continue
		if not node.has_method("is_drop_off") or not node.is_drop_off():
			continue
		if node.has_method("is_constructed") and not node.is_constructed():
			continue
		return true
	return false


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
	var has_cargo := false
	if "resource_a" in resource and resource.resource_a > 0:
		has_cargo = true
	elif "resource_b" in resource and resource.resource_b > 0:
		has_cargo = true
	if not has_cargo:
		return false
	return _owner_can_see(resource)


func _owner_can_see(resource) -> bool:
	if _unit == null or not is_instance_valid(_unit):
		return true
	if _unit.has_meta("player_hold_auto"):
		return false
	var match_node = _unit.find_parent("Match")
	if match_node == null:
		return true
	var fog = match_node.get_node_or_null("FogOfWar")
	if fog == null or not fog.has_method("player_can_see"):
		return true
	return bool(fog.player_can_see(_unit.get_parent(), resource.global_position, resource))
