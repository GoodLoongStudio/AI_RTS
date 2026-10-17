extends Node

const _PerfBuckets = preload("res://source/match/PerfBuckets.gd")

## 视锥外只停动画、血条和绑定脚本的 _process。碰撞体和 NavigationAgent 继续跑。
## 网格、高亮和选择圈不进这个名单：停掉它们的 _process 时，正交镜头的视锥
## 误判会把单位模型和选择圈冻在看不见的状态。画面内以及视锥外 12m 的单位保持原样。

const VISUAL_ROOTS: Array[String] = [
	"HealthBar",
	"AnimationDriver",
	"UnitVisualBindings",
]
const MARGIN_M := 12.0

var _shown := {}
var _saved_mode := {}


func _process(_delta: float) -> void:
	var t0 := 0
	if _PerfBuckets.enabled:
		t0 = Time.get_ticks_usec()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		if t0 != 0:
			_PerfBuckets.add("visual_cull", int(Time.get_ticks_usec() - t0))
		return
	for unit in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(unit) or not (unit is Node3D):
			continue
		var body := unit as Node3D
		var show := _near_frustum(cam, body)
		var id := body.get_instance_id()
		if _shown.has(id) and bool(_shown[id]) == show:
			continue
		_shown[id] = show
		for child_name in VISUAL_ROOTS:
			var child := body.get_node_or_null(child_name)
			if child != null:
				_apply(child, show)
	if t0 != 0:
		_PerfBuckets.add("visual_cull", int(Time.get_ticks_usec() - t0))


func _apply(node: Node, show: bool) -> void:
	var id := node.get_instance_id()
	if show:
		if _saved_mode.has(id):
			node.process_mode = int(_saved_mode[id])
			_saved_mode.erase(id)
	elif not _saved_mode.has(id):
		_saved_mode[id] = node.process_mode
		node.process_mode = Node.PROCESS_MODE_DISABLED
	for child in node.get_children():
		_apply(child, show)


func _near_frustum(cam: Camera3D, unit: Node3D) -> bool:
	var origin := unit.global_position
	if cam.is_position_in_frustum(origin):
		return true
	return (
		cam.is_position_in_frustum(origin + Vector3(MARGIN_M, 0.0, 0.0))
		or cam.is_position_in_frustum(origin + Vector3(-MARGIN_M, 0.0, 0.0))
		or cam.is_position_in_frustum(origin + Vector3(0.0, 0.0, MARGIN_M))
		or cam.is_position_in_frustum(origin + Vector3(0.0, 0.0, -MARGIN_M))
	)
