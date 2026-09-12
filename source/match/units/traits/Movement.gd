extends NavigationAgent3D

signal movement_finished
## 主动移动结束原因：Arrived 或 Unreachable，供命令订单终态回传。
signal movement_ended(reason)
signal passive_movement_started
signal passive_movement_finished

const INITIAL_DISPERSION_FACTOR = 0.1

# --- 停滞检测与轻量脱困（2026-09-11 重构）---
# 旧实现只看「请求速度」是否被避让压小，拥挤里正常减速会误判，
# 而顶在墙边/拐角上请求速度仍是满值、永远检测不到。改为看**实际位移**。
const STALL_CHECK_INTERVAL_S := 0.5
## 一个检测窗口内，距任务目标至少应缩短的平面距离；低于此不算"推进"。
const STALL_MIN_PROGRESS_M := 0.35
## 连续多少个"无推进"窗口后启动脱困（窗口 0.5s）。
## 注意判据是**任务推进**（更接近目标 或 沿路径消耗掉航点），不是"有没有位移"：
## 原地来回打转每帧都在动，旧判据反而识别不出（实测过）。
const STALL_WINDOWS_BEFORE_RECOVERY := 1
## 一次移动任务内最多脱困轮数（重寻路 → 侧移/后退 → 继续原任务 为一轮）。
## 轮数只在「明显更接近任务目标或沿路径推进」时清零，避免侧移本身被误当成推进而无限重试。
const RECOVERY_MAX_ROUNDS := 2
## 重寻路后先观察多久再升级到侧移，避免刚重烘网格就乱动。
const RECOVERY_REPATH_SETTLE_S := 0.3
## 单次侧移/后退持续时间与候选距离。
const RECOVERY_ESCAPE_DURATION_S := 0.5
const RECOVERY_ESCAPE_DISTANCE_M := 1.6
## 脱困候选点允许的导航网格吸附误差；超过说明候选落在网格外。
const RECOVERY_MAX_SNAP_M := 1.0
## 轮数用尽时的"贴边即到达"判定半径（叠加单位半径）。
## 目标本身落在障碍避让区内时，单位物理上只能贴到外侧，这等价于原 clamp 语义。
const RECOVERY_ACCEPT_RADIUS_M := 2.5
## 落点推离静态障碍时在「障碍半径 + 自身半径」之外额外保留的净空。
const OBSTACLE_CLEARANCE_MARGIN_M := 0.2
## 同一目标的判定阈值：任务层反复下发同一/微调目标时不清空脱困进度。
const SAME_TARGET_EPSILON_M := 0.75
## 每物理帧允许的重寻路/脱困候选探测总次数，避免数百单位同帧触发。
const RECOVERY_BUDGET_PER_FRAME := 8
## 路径修复：导航网格重烘/区域同步期间路径查询会短暂返回空，此时以受限频率重发目标，
## 避免"带着有效目标却永久站桩"（实测会让回基地/出兵的开局指令随机不生效）。
const PATH_REPAIR_INTERVAL_FRAMES := 5
## 单个目标最多修复次数，防止真正不可达时无意义重发（脱困状态机负责终态收敛）。
const PATH_REPAIR_MAX_ATTEMPTS := 24

## 诊断计数（只读；测试与性能采样可读取，不影响行为）。
static var recovery_stats := {
	"stall_detections": 0,
	"repaths": 0,
	"escapes": 0,
	"unreachable": 0,
	"budget_skips": 0,
}

static var _budget_frame := -1
static var _budget_left := 0

const ROTATION_LOW_PASS_FILTER_ENABLED = true
const ROTATION_LOW_PASS_FILTER_WINDOW_SIZE = 10  # number of frames for accumulating directions
const ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD = 0.01  # velocities below will be dropped

const PASSIVE_MOVEMENT_TRACKING_ENABLED = true
const NAVIGATION_ALIGNMENT_MAX_FRAMES = 180
## clamp 允许的最大吸附距离：只用于"把障碍内目标贴到边缘"级别的小修正。
const CLAMP_MAX_SNAP_DISTANCE_M = 5.0

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var speed: float = 4.0
## 平滑转向的最大角速度（度/秒）；0 以下视为无效并回退默认。由平衡配置按单位类型注入。
@export var max_turn_speed_deg_per_sec: float = 360.0
@export_range(0.05, 1.0) var reverse_speed_multiplier: float = 0.65

var _interim_speed: float = 0.0
var _last_physics_delta: float = 1.0 / 60.0
var _face_target := Vector3.INF
var _is_tactical_withdrawal := false

var _movement_end_emitted := false

## 上层任务要求的最终目标（已 clamp/推离障碍后的合法落点）；脱困只临时改写
## target_position，绝不覆盖它。
var _committed_target: Variant = null
## 任务层最近一次下发的原始目标；用于识别"同一目标重复下发"以省掉重复导航查询。
var _raw_target: Variant = null
## 停滞检测锚点与实际位移采样。
var _stall_check_timer := 0.0
var _stall_anchor_position := Vector3.ZERO
var _stall_anchor_valid := false
## 连续"无推进"窗口计数。
var _stall_windows := 0
## 上一窗口的路径航点下标；用于识别"沿路径推进"（允许绕路暂时远离目标）。
var _last_path_index := 0
## 脱困状态机："" / "repath" / "escape"。
var _recovery_mode := ""
var _recovery_rounds := 0
var _recovery_timer := 0.0
var _recovery_escape_target := Vector3.INF
## 判定"真实推进"的参照距离：只有明显比它更接近任务目标才算推进。
var _progress_reference_distance := INF
## 当前目标已执行的"缺路径修复"次数。
var _path_repair_attempts := 0

var _rotation_low_pass_filter_window = []
var _total_direction_in_the_low_pass_filter_window = Vector3.ZERO
var _previously_set_global_transform_of_unit = null

var _passive_movement_detected = false
var _navigation_initialized := false
var _pending_target = null
var _skip_initial_dispersion := false

@onready var _match = find_parent("Match")
## 必须显式标注 Node3D：本文件多处用 `var x := _unit.global_position * ...`，
## 未标注类型时 `:=` 无法推断（GDScript 报 "Cannot infer the type ... doesn't have a set type"），
## 整份脚本会解析失败、所有单位无法移动。已核实全部 `_unit.*` 用法都在 Node3D 上。
@onready var _unit: Node3D = get_parent()


func _physics_process(delta):
	_last_physics_delta = delta
	if NetSession.is_client_puppet():
		return
	_update_recovery(delta)
	_repair_missing_path()
	var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
	_interim_speed = speed * speed_multiplier * delta
	var next_path_position: Vector3 = get_next_path_position()
	var current_agent_position: Vector3 = _unit.global_transform.origin
	var new_velocity: Vector3 = (
		(next_path_position - current_agent_position).normalized() * _interim_speed
	)
	set_velocity(new_velocity)


func _ready():
	if _match.navigation == null or not _match.is_node_ready():
		await _match.ready
	velocity_computed.connect(_on_velocity_computed)
	navigation_finished.connect(_on_navigation_finished)
	_apply_crowd_avoidance_defaults()
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	target_position = Vector3.INF
	set_velocity(Vector3.ZERO)
	_stall_check_timer = _initial_stall_check_delay()
	_finish_navigation_initialization()


func move(movement_target: Vector3):
	_is_tactical_withdrawal = false
	_apply_committed_target(movement_target)


## 沿导航路径倒车；车尾对齐每一帧的安全速度方向，因此路径转弯会更新朝向。
func tactical_withdraw(movement_target: Vector3):
	_is_tactical_withdrawal = true
	_apply_committed_target(movement_target)


## 下发/刷新主动移动目标。
## 任务层（跟随、攻击移动、自愈重发）会以同一目标反复调用；只要目标没实质变化，
## 就保留脱困进度与停滞采样，避免"追击目标小幅移动"不断打断临时绕行。
func _apply_committed_target(movement_target: Vector3):
	# 同一原始目标重复下发：直接沿用上次算好的合法落点，省掉导航/障碍查询，
	# 也不打断进行中的脱困绕行（跟随与攻击移动会以同一目标高频重发）。
	if _same_raw_target(movement_target):
		if _recovery_mode != "escape":
			target_position = _committed_target
		return
	var clamped := _clamp_to_reachable(movement_target)
	_raw_target = movement_target
	_committed_target = clamped
	_progress_reference_distance = _planar_distance_to(clamped)
	_path_repair_attempts = 0
	_abort_recovery()
	_reset_stability_state()
	if not _navigation_initialized:
		_pending_target = clamped
		_skip_initial_dispersion = true
	target_position = clamped


func _same_raw_target(movement_target: Vector3) -> bool:
	return (
		_raw_target != null
		and _committed_target != null
		and movement_target.distance_squared_to(_raw_target) < SAME_TARGET_EPSILON_M ** 2
	)


static func _planar_distance_to_point(from: Vector3, to: Vector3) -> float:
	return Vector2(from.x, from.z).distance_to(Vector2(to.x, to.z))


func _planar_distance_to(point: Vector3) -> float:
	return _planar_distance_to_point(_unit.global_position, point)


## 把目标点限制到导航网格最近可达点（2026-09-02）：
## 点击建筑/障碍内部时，阵位散布或手点目标可能落在占位内，导航查询会判
## Unreachable 让单位半路停（"点中间不贴近就停了"）。clamp 后单位走到
## 障碍边缘贴住，等价于从自己一侧贴近点击点。
##
## 关键(2026-09-11 修)：closest 点的 y 是导航网格表面高度，而单位实际运动平面
## 是 `网格高度 - path_height_offset`（见 _align_unit_position_to_navigation）。
## 若直接把 y=0.6 的表面点写回 target_position，NavigationAgent3D 会用
## `(路径末端 - path_height_offset)` 与 target 相差一个 path_height_offset，
## 令 is_target_reachable() 恒为 false —— 每次正常移动都被 _classify_navigation_end
## 误判成 Unreachable（停在中途、订单假失败、依赖 movement_finished 的动作反复重发）。
## 因此这里统一换算回单位的运动平面。
##
## 另一处(2026-09-11 修)：导航网格只表达「路径连通」，与 `NavigationObstacle3D`
## （建筑/资源）的**避让半径**并不一致——网格洞比避让圈小，于是"网格可达"的落点
## 可能仍在避让圈内，单位会被 RVO 顶在外面原地打转（正是"手动往外点一下就能出来"
## 的现象）。这里在吸附之后再把落点推离避让圈。
func _clamp_to_reachable(target: Vector3) -> Vector3:
	var nav_map := get_navigation_map()
	if not nav_map.is_valid():
		return target
	var closest_owner := NavigationServer3D.map_get_closest_point_owner(nav_map, target)
	if not closest_owner.is_valid():
		# 开局竞态防护(2026-09-03): 导航网格尚未烘焙同步时 closest 点可能退化为
		# 原点附近, 把目标钳到 (0,0) 会让 AI 工人开局横穿地图绕到地图角。
		# 网格为空时保持原目标, 导航代理会直线走向目标(平坦地图等价正确)。
		return _push_out_of_static_obstacles(target)
	var closest := NavigationServer3D.map_get_closest_point(nav_map, target)
	if not closest.is_finite():
		return target
	# clamp 的语义是"把目标从障碍内贴到边缘"，只应产生小距离修正；
	# 部分烘焙网格会给出远距离的错误吸附点，此时保持原目标更安全。
	if closest.distance_to(target) > CLAMP_MAX_SNAP_DISTANCE_M:
		return _push_out_of_static_obstacles(target)
	return _push_out_of_static_obstacles(
		Vector3(closest.x, closest.y - path_height_offset, closest.z)
	)


## 把落点推离静态障碍（建筑/资源）的避让半径。
## 复用引擎既有的 `NavigationObstacle3D` 集合（按域分组的注册表），
## 只做 O(障碍数) 的距离判断，不做全军遍历。
##
## 推出方向用「障碍中心 → 单位当前所在侧」，而不是「障碍中心 → 落点」：
## 导航网格对障碍只挖了一个洞，洞边缘各点到中心等距，吸附结果会**任意**落在
## 远端一侧，单位于是绕大半圈去建筑背面（点击建筑时的经典坏手感）。
## 按单位这一侧推出等价于原 clamp 注释里的"从自己一侧贴近点击点"，
## 同时天然把多个单位分散到建筑的不同侧面，缓解建筑口拥堵。
func _push_out_of_static_obstacles(point: Vector3) -> Vector3:
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
		var obstacle_origin: Vector3 = obstacle.global_position
		var center := Vector2(obstacle_origin.x, obstacle_origin.z)
		var stand_off: float = float(obstacle_radius) + own_radius + OBSTACLE_CLEARANCE_MARGIN_M
		if planar.distance_to(center) >= stand_off:
			continue
		var outward := unit_planar - center
		if outward.length() < 0.001:
			outward = planar - center
		if outward.length() < 0.001:
			outward = Vector2.RIGHT
		planar = center + outward.normalized() * stand_off
	return Vector3(planar.x, point.y, planar.y)


func stop():
	target_position = Vector3.INF
	_committed_target = null
	_raw_target = null
	_progress_reference_distance = INF
	_is_tactical_withdrawal = false
	_abort_recovery()
	_reset_stability_state()
	if not _navigation_initialized:
		_pending_target = null
		_skip_initial_dispersion = true
	set_velocity(Vector3.ZERO)


## 暂停所有主动与避障位移，用于必须保持接敌点的固守交战。
func suspend_motion():
	stop()
	set_velocity(Vector3.ZERO)
	avoidance_enabled = false
	set_physics_process(false)


## 恢复导航与避障更新；调用方随后应重新提交明确导航目标。
func resume_motion():
	avoidance_enabled = true
	set_physics_process(true)


## 温柔避障：只躲近处邻居并提前让行，避免大部队互相顶牛打转（2026-09-02 调参）。
func _apply_crowd_avoidance_defaults():
	avoidance_enabled = true
	if neighbor_distance < 1.0:
		neighbor_distance = 3.0
	if max_neighbors < 8:
		max_neighbors = 16
	if time_horizon_agents < 1.0:
		time_horizon_agents = 4.5


## 等待运行时 NavMesh 出现可用 Region 后再对齐单位，避免空中地图异步烘焙竞态。
func _align_unit_position_to_navigation() -> bool:
	var navigation_map := get_navigation_map()
	var source_position: Vector3 = get_parent().global_transform.origin
	for _frame in range(NAVIGATION_ALIGNMENT_MAX_FRAMES):
		await get_tree().process_frame
		var closest_point_owner := NavigationServer3D.map_get_closest_point_owner(
			navigation_map, source_position
		)
		if not closest_point_owner.is_valid():
			continue
		_unit.global_transform.origin = (
			NavigationServer3D.map_get_closest_point(navigation_map, source_position)
			- Vector3(0, path_height_offset, 0)
		)
		_unit.reset_physics_interpolation()  # 对齐吸附是瞬移，防插值拖影
		return true
	push_warning("Navigation alignment timed out for %s; preserving authored position" % _unit.name)
	return false


## 非阻塞完成导航对齐，并恢复初始化期间收到的最后一个显式移动目标。
func _finish_navigation_initialization():
	await _align_unit_position_to_navigation()
	_navigation_initialized = true
	if _pending_target != null:
		target_position = _pending_target
		_pending_target = null
		return
	if _skip_initial_dispersion:
		return
	move(
		(
			_unit.global_position
			+ Vector3(randf(), 0, randf()).normalized() * INITIAL_DISPERSION_FACTOR
		)
	)


func _is_moving_actively():
	return get_next_path_position() != _unit.global_position


# --- 停滞检测（按实际位移，错峰 0.5s）---

## 每个 Movement 节点独立计时；首次检测的相位按实例 id 打散，
## 避免数百单位在同一帧集中做判断/重寻路。
func _update_recovery(delta: float) -> void:
	if _committed_target == null:
		_stall_anchor_valid = false
		return
	if _recovery_mode != "":
		_recovery_timer -= delta
		if _recovery_timer <= 0.0:
			_advance_recovery()
		return
	_stall_check_timer -= delta
	if _stall_check_timer > 0.0:
		return
	_stall_check_timer = STALL_CHECK_INTERVAL_S
	var planar_position := _unit.global_position * Vector3(1, 0, 1)
	if not _stall_anchor_valid:
		_stall_anchor_position = planar_position
		_last_path_index = get_current_navigation_path_index()
		_stall_anchor_valid = true
		return
	_stall_anchor_position = planar_position
	# "推进"的两个合法形态：明显更接近任务目标，或沿路径消耗掉了航点
	# （后者覆盖正常绕路——绕路时到目标的距离会先变大再变小）。
	var distance := _planar_distance_to(_committed_target)
	var path_index := get_current_navigation_path_index()
	if (
		distance <= _progress_reference_distance - STALL_MIN_PROGRESS_M
		or path_index > _last_path_index
	):
		_progress_reference_distance = minf(_progress_reference_distance, distance)
		_last_path_index = path_index
		_stall_windows = 0
		_recovery_rounds = 0
		return
	_progress_reference_distance = minf(_progress_reference_distance, distance)
	_last_path_index = path_index
	# 没有移动任务时不算停滞（已到达/被暂停/未起步）。
	if not _is_moving_actively():
		return
	_stall_windows += 1
	if _stall_windows < STALL_WINDOWS_BEFORE_RECOVERY:
		return
	_stall_windows = 0
	_begin_recovery()


## 路径修复：有有效目标却查不到路径（网格重烘/区域同步竞态）时以受限频率重发目标。
func _repair_missing_path() -> void:
	if _committed_target == null or _recovery_mode == "escape":
		return
	if not get_current_navigation_path().is_empty():
		_path_repair_attempts = 0
		return
	if _path_repair_attempts >= PATH_REPAIR_MAX_ATTEMPTS:
		return
	if Engine.get_physics_frames() % PATH_REPAIR_INTERVAL_FRAMES != 0:
		return
	if not _consume_recovery_budget():
		return
	_path_repair_attempts += 1
	target_position = _committed_target
	recovery_stats["repaths"] += 1


## 每物理帧统一预算：只有重寻路与候选探测消耗，避免同帧数百次导航查询。
static func _consume_recovery_budget() -> bool:
	var frame := Engine.get_physics_frames()
	if _budget_frame != frame:
		_budget_frame = frame
		_budget_left = RECOVERY_BUDGET_PER_FRAME
	if _budget_left <= 0:
		recovery_stats["budget_skips"] += 1
		return false
	_budget_left -= 1
	return true


## 识别到停滞：先重寻路；重寻路无效再尝试少量合法侧移/后退点；轮数用尽后收敛终态。
func _begin_recovery() -> void:
	if _recovery_mode != "" or _committed_target == null:
		return
	# 每帧预算用尽时本轮不动作，等下一个检测窗口，避免数百单位同帧集中重寻路。
	if not _consume_recovery_budget():
		return
	if _recovery_rounds >= RECOVERY_MAX_ROUNDS:
		_give_up_commitment()
		return
	recovery_stats["stall_detections"] += 1
	_stall_anchor_valid = false
	_recovery_mode = "repath"
	_recovery_timer = RECOVERY_REPATH_SETTLE_S
	# 导航网格刚重烘后路径可能陈旧；对同一目标重新查询即可自愈。
	target_position = _committed_target
	recovery_stats["repaths"] += 1


func _advance_recovery() -> void:
	if _recovery_mode == "repath":
		var escape: Variant = _pick_escape_target()
		if escape != null:
			_recovery_mode = "escape"
			_recovery_escape_target = escape
			_recovery_timer = RECOVERY_ESCAPE_DURATION_S
			target_position = escape
			recovery_stats["escapes"] += 1
			return
		_finish_recovery_cycle()
		return
	# 侧移阶段结束 → 回到原任务目标继续推进。
	_finish_recovery_cycle()


## 一轮脱困结束（重寻路 + 侧移都试过）→ 回到原任务目标并累计轮数。
func _finish_recovery_cycle() -> void:
	_recovery_mode = ""
	_recovery_escape_target = Vector3.INF
	_stall_anchor_valid = false
	_recovery_rounds += 1
	if _committed_target != null:
		target_position = _committed_target


## 取消进行中的脱困并回到任务目标（新命令/停止/新目标时调用）。
func _abort_recovery() -> void:
	_recovery_mode = ""
	_recovery_escape_target = Vector3.INF
	_recovery_timer = 0.0
	_recovery_rounds = 0
	_stall_anchor_valid = false
	_stall_windows = 0


## 脱困轮数用尽时的收敛判定：
##   - 已经贴到"力所能及"的位置 → Arrived（等价原 clamp 的贴边语义）；
##   - 导航层面确实不可达 → Unreachable（合理失败）；
##   - 目标可达、只是被拥堵反复拖住 → 不清空任务，重置轮数继续努力。
## 关键：**只有真实不可达才判失败**。实测过按"离目标还有多远"判失败会在
## 大部队交叉拥堵时产生假 Unreachable，玩家会看到莫名其妙的失败提示。
func _give_up_commitment() -> void:
	if _committed_target == null:
		return
	var accept_radius: float = maxf(float(radius), 0.5) + RECOVERY_ACCEPT_RADIUS_M
	if _planar_distance_to(_committed_target) <= accept_radius:
		_emit_committed_end("Arrived")
		return
	if not is_target_reachable():
		_fail_as_unreachable()
		return
	_recovery_rounds = 0


## 选取一个落在导航网格上的合法脱困候选点：优先两侧中净空更好的一侧，其次后退。
## 只在网格外或吸附误差过大时丢弃候选，不做穿墙/瞬移。
## 返回逃生目标位置；无法逃生时返回 null（所以返回类型是 Variant 而不是 Vector3）。
## 必须显式标注：调用处用 `var escape: Variant = ...`，未标注时 GDScript 会因
## "null 字面量没有静态类型" 而整份脚本解析失败。
func _pick_escape_target() -> Variant:
	var nav_map := get_navigation_map()
	if not nav_map.is_valid():
		return null
	if not _consume_recovery_budget():
		return null
	var here := _unit.global_position
	# _committed_target 可为 null（无任务目标），所以这里显式标注目标类型而非用 `:=`。
	var to_target: Vector3 = (_committed_target - here) * Vector3(1, 0, 1)
	if to_target.length() < 0.05:
		return null
	var forward := to_target.normalized()
	var lateral := forward.rotated(Vector3.UP, PI / 2.0)
	var candidates := [
		here + lateral * RECOVERY_ESCAPE_DISTANCE_M,
		here - lateral * RECOVERY_ESCAPE_DISTANCE_M,
		here - forward * RECOVERY_ESCAPE_DISTANCE_M,
	]
	var best = null
	var best_clearance := -INF
	for candidate in candidates:
		var closest := NavigationServer3D.map_get_closest_point(nav_map, candidate)
		if not closest.is_finite():
			continue
		var snap := closest.distance_to(candidate)
		if snap > RECOVERY_MAX_SNAP_M:
			continue
		var clearance := -snap
		if clearance > best_clearance:
			best_clearance = clearance
			best = _push_out_of_static_obstacles(
				Vector3(closest.x, closest.y - path_height_offset, closest.z)
			)
	return best


func _get_filtered_rotation_direction(safe_velocity: Vector3):
	var direction = safe_velocity.normalized()
	if (
		_previously_set_global_transform_of_unit != null
		and not _previously_set_global_transform_of_unit.is_equal_approx(_unit.global_transform)
	):
		# reset filter if a global_transform of unit was altered from the outside
		_rotation_low_pass_filter_window = []
		_total_direction_in_the_low_pass_filter_window = Vector3.ZERO
	if safe_velocity.length() >= ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD:
		_rotation_low_pass_filter_window.append(direction)
		_total_direction_in_the_low_pass_filter_window += direction
	if _rotation_low_pass_filter_window.size() > ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		_total_direction_in_the_low_pass_filter_window -= (
			_rotation_low_pass_filter_window.pop_front()
		)
	if _rotation_low_pass_filter_window.size() == ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		return (
			_total_direction_in_the_low_pass_filter_window
			/ float(ROTATION_LOW_PASS_FILTER_WINDOW_SIZE)
		)
	return direction


func _rotate_in_direction(direction: Vector3):
	if ROTATION_LOW_PASS_FILTER_ENABLED:
		direction = _get_filtered_rotation_direction(direction)
	if is_zero_approx(direction.length()):
		return
	# 平滑转向：按单位类型注入的最大角速度逐步逼近目标朝向，
	# 消除 looking_at 瞬时掉头（含 180° 调头/倒车切换）造成的视觉跳变。
	# 显式 float：经未类型化节点链取值在此上下文返回 Variant，:= 无法推断类型。
	var turn_speed: float = maxf(max_turn_speed_deg_per_sec, 1.0)
	var target_yaw: float = atan2(-direction.x, -direction.z)
	var current_yaw: float = _unit.global_transform.basis.get_euler().y
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < 0.01:
		return
	var max_step: float = deg_to_rad(turn_speed) * _last_physics_delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	_unit.global_transform = Transform3D(
		Basis(Vector3.UP, new_yaw), _unit.global_transform.origin
	)


func _update_passive_movement_tracking(safe_velocity):
	if not PASSIVE_MOVEMENT_TRACKING_ENABLED:
		return
	if _is_moving_actively() or safe_velocity.is_zero_approx():
		if _passive_movement_detected:
			_passive_movement_detected = false
			passive_movement_finished.emit()
		return
	if not _passive_movement_detected:
		_passive_movement_detected = true
		passive_movement_started.emit()


func _on_velocity_computed(safe_velocity: Vector3):
	var chassis_direction := -safe_velocity if _is_tactical_withdrawal else safe_velocity
	var planar_direction := chassis_direction * Vector3(1, 0, 1)
	if not planar_direction.is_zero_approx():
		_face_target = Vector3.INF
		_rotate_in_direction(planar_direction)
	elif _face_target != Vector3.INF:
		_apply_pending_face_rotation()
	_unit.global_transform.origin = _unit.global_transform.origin.move_toward(
		_unit.global_transform.origin + safe_velocity, _interim_speed
	)
	_previously_set_global_transform_of_unit = _unit.global_transform
	_update_passive_movement_tracking(safe_velocity)


## 请求单位平滑转向面向指定位置（采集/交战对齐用）；移动开始后自动失效。
func face_towards(target_position: Vector3) -> void:
	_face_target = target_position


## 站定（速度为零）时按转速上限平滑逼近 face_towards 目标朝向。
func _apply_pending_face_rotation():
	var face_direction: Vector3 = (
		_face_target - _unit.global_transform.origin
	) * Vector3(1, 0, 1)
	if face_direction.length() < 0.2:
		_face_target = Vector3.INF
		return
	_rotate_in_direction(face_direction)


func _on_navigation_finished():
	# 脱困侧移只是临时绕行点：到达后立刻恢复原任务目标，不能当作任务结束。
	if _recovery_mode == "escape":
		_finish_recovery_cycle()
		return
	_emit_committed_end(_classify_navigation_end())


## 导航结束时区分真正到达与最近可达点停下。
func _classify_navigation_end() -> String:
	if target_position == Vector3.INF:
		return "Arrived"
	if is_target_reachable():
		return "Arrived"
	return "Unreachable"


func _reset_stability_state():
	_movement_end_emitted = false
	_stall_check_timer = _initial_stall_check_delay()
	_stall_anchor_valid = false
	_stall_windows = 0


## 首次停滞检测相位错峰：让数百个单位分散在不同帧做 O(1) 判断。
func _initial_stall_check_delay() -> float:
	return STALL_CHECK_INTERVAL_S * (float(get_instance_id() % 97) / 97.0)


## 结束当前主动移动任务：清空任务目标与脱困状态，再广播终态。
func _emit_committed_end(reason: String):
	if _movement_end_emitted:
		return
	target_position = Vector3.INF
	_committed_target = null
	_raw_target = null
	_progress_reference_distance = INF
	_is_tactical_withdrawal = false
	_abort_recovery()
	set_velocity(Vector3.ZERO)
	_emit_movement_end(reason)


func _fail_as_unreachable():
	recovery_stats["unreachable"] += 1
	_emit_committed_end("Unreachable")


func _emit_movement_end(reason: String):
	if _movement_end_emitted:
		return
	_movement_end_emitted = true
	movement_ended.emit(reason)
	movement_finished.emit()
