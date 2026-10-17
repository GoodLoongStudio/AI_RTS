extends NavigationAgent3D

const _PerfBuckets = preload("res://source/match/PerfBuckets.gd")
const AiPerfStats = preload("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")

signal movement_finished
## 主动移动结束原因：Arrived 或 Unreachable，供命令订单终态回传。
signal movement_ended(reason)
## Terminal facts survive the gap between physics and the adjutant's 10Hz sample.
## Bounded per unit; published only when a real movement segment ends.
const TERMINAL_EVENT_LIMIT := 8
var _terminal_event_seq := 0
var _terminal_events: Array[Dictionary] = []
signal passive_movement_started
signal passive_movement_finished

const INITIAL_DISPERSION_FACTOR = 0.1

# --- 停滞检测与轻量脱困（2026-09-11 重构）---
# 旧实现只看「请求速度」是否被避让压小，拥挤里正常减速会误判，
# 而顶在墙边/拐角上请求速度仍是满值、永远检测不到。改为看**实际位移**。
const STALL_CHECK_INTERVAL_S := 0.5
## 一个检测窗口内，距任务目标至少应缩短的平面距离；低于此不算"推进"。
## 【2026-09-27 单位整体放大】进度/间距类阈值原来按 0.2~0.9m 半径单位定死；
## 单位半径最大 2.8m 后必须同比放大，否则"没动"判定把正常慢速当卡死、
## 脱困接受半径比单位还小、软穿行友军间距抓不到邻居 → stuck→Unreachable 暴涨。
## 统一改为 radius 的相对式（保留 0.9 半径单位的原始数值作为基准）。
const STALL_MIN_PROGRESS_M := 0.35


## 卡死判定的最小进展阈值（2026-09-27：随单位半径放大，2m 半径单位 = 1.15m）。
## 2026-09-29 补上界：阈值必须低于"满速直行一个窗口能走的距离"，否则正常行进本身
## 就不算推进。radius 与 speed 无相关性，又大又慢的单位（重型坦克 r2.25/需 1.294m，
## 实速 2.33/仅 1.166m；apc、运输车同理）会被每个窗口判成卡死 → 反复下发 1.6m 侧移
## 脱困点 → 玩家看到"走不直、扭来扭去"。取 min 只做放宽，不收紧任何现有判据。
func _stall_min_progress_m() -> float:
	var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
	return minf(
		maxf(STALL_MIN_PROGRESS_M, float(radius) * 0.575),
		speed * speed_multiplier * STALL_CHECK_INTERVAL_S * 0.6
	)
## 连续多少个"无推进"窗口后启动脱困（窗口 0.5s）。
## 注意判据是**任务推进**（更接近目标 或 沿路径消耗掉航点），不是"有没有位移"：
## 原地来回打转每帧都在动，旧判据反而识别不出（实测过）。
## 【2026-09-30 A/B 结论：不要把这里改成 3】曾试过 1→3 的单窗口迟滞：脱困开销确实
## 降了 ~45%（repath 7273→4095、escape 3533→1969、stall 5293→2894），但 n=200 对向交叉的
## 收敛耗时几乎不变（160.2s → 159.9s）⇒ churn 是症状不是瓶颈，改它属于无根因调参，已回退。
## 真正的瓶颈是密集双向流的通行能力（收敛曲线在中段近似线性，约 1.3 单位/秒）。
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
## 【2026-10-01 第 27 轮】到达残差补偿：单位最终会停在"钳制目标 + NavigationAgent 到达容差"处
## （独立复核直读实测 +0.257m：钳制 4.715m ⇒ 实停 4.972m）。把 stand_off 预先减去这个残差，
## 让**最终静止位置**恰好落在期望的安全余量上，而不必改移动层（到达/脱困阈值）。
## 下限保护：绝不低于"障碍包含半径 + 个人空间"，因此不存在穿模风险。
const OBSTACLE_ARRIVAL_COMPENSATION_M := 0.25

const OBSTACLE_CLEARANCE_MARGIN_M := 0.1
## 远障碍预剔除用的视觉支撑上界 = 个人半径 + 这个余量。
## 精确 vis47 仍只对进入该带的障碍计算。余量盖过已知的碰撞圆盖不住模型长轴的差
## （工兵约 0.35m）；3m 是故意偏大的上界，只减少骨骼采样，不改变带内推出。
const PUSH_VISUAL_SUPPORT_CAP_SLACK_M := 3.0
## 同一目标的判定阈值：任务层反复下发同一/微调目标时不清空脱困进度。
const SAME_TARGET_EPSILON_M := 0.75
## 每物理帧允许的重寻路/脱困候选探测总次数，避免数百单位同帧触发。
## 【2026-09-30 A/B 结论：不要把这里调大】曾试过 8→32（怀疑 n=200 时恢复被每帧预算
## 串行化，当时 budget_skips ≈15/s）：收敛耗时 160.2s → 169.4s，**没有收益**（budget_skips 归零
## 但总时长更长）。连同"关掉 RVO 避让"（200/200 永不收敛）在内，三次负面实验一致指向：
## 瓶颈是密集双向流本身的通行能力，不是脱困预算/避让参数。
const RECOVERY_BUDGET_PER_FRAME := 8
## 路径修复：导航网格重烘/区域同步期间路径查询会短暂返回空，此时以受限频率重发目标，
## 避免"带着有效目标却永久站桩"（实测会让回基地/出兵的开局指令随机不生效）。
const PATH_REPAIR_INTERVAL_FRAMES := 5
## 单个目标最多修复次数，防止真正不可达时无意义重发（脱困状态机负责终态收敛）。
const PATH_REPAIR_MAX_ATTEMPTS := 24

# --- 受限软穿行（2026-09-14；用户规格：只有"确认被友军顶死"才允许，且必须受限）---
# 背景（真机实测 `m1cong`）：12 个单位被派到同一点制造拥堵后，常规脱困（重寻路 + 侧移）
# 的计数都在动（`stall_detections=78 / escapes=64`），但仍有单位被 5 个友军挤在
# 0.14~0.34m 内、连续 7/14 次采样速度≈0（`reachable=true` 且路径点=5）——
# 这类**同阵营互相顶死**靠现有机制出不来。
# 不变式（任何一条不满足就不启用）：
#   ① 只在脱困状态机**已确认停滞**之后（不是常态移动、不是新指令）；
#   ② 只缩小**自身**的 RVO 半径（绝不 `avoidance_enabled=false`、绝不改别人的半径）；
#   ③ 贴身邻军必须同阵营（同 parent）且同移动域、可机动（工人/建筑不算"顶死"来源）；
#   ④ 附近有敌军时一律不启用（不允许贴着/穿过敌人）；
#   ⑤ 只持续 `SOFT_PHASE_DURATION_S`，到点/新命令/停止/异常都必须**还原半径**。
const SOFT_PHASE_ENABLED := true
const SOFT_PHASE_DURATION_S := 0.4
const SOFT_PHASE_RADIUS_SCALE := 0.25
## 软穿行友军判定间距：≥ 2×半径 + 0.4m（原 1.2m ≈ 1.3×radius，小单位够、大单位抓不到邻居）。
const SOFT_PHASE_FRIEND_GAP_M := 1.2
const SOFT_PHASE_MIN_FRIENDS := 2
## 敌军清场判定距离（2026-09-27：随半径放大；0.9m 单位时保持原 3.0m）。
const SOFT_PHASE_ENEMY_CLEAR_M := 3.0


## 敌军清场判定距离（2026-09-27：随半径放大；0.9m 单位时保持原 3.0m）。
func _soft_phase_enemy_clear_m() -> float:
	return maxf(3.0, float(radius) * 2.0 + 1.2)


## 友军贴身判定距离（2026-09-27：随半径放大；0.9m 单位时保持原 1.2m）。
func _soft_phase_friend_gap_m() -> float:
	return maxf(SOFT_PHASE_FRIEND_GAP_M, float(radius) * 2.0 + 0.4)
const SOFT_PHASE_COOLDOWN_S := 2.0

# 静态窄通道阶段：只在恢复阶段确认“圆形判定挡住、形状判定可过”时启用。
# 这是移动个人空间的短时状态，不改写 Area3D 的物理/命中形状。
# 【2026-10-02 第 2 阶段·口袋逃逸 ✓】单位为"离最近导航面很远"时（走进 carve 洞重叠的
# 无导航面区域）⇒ 常规侧移/软穿行/窄口都无效 ⇒ 直接朝**最近的导航面点**确定性退出 ✓。
const POCKET_OFF_MESH_MIN_M := 1.0
const NARROW_PASS_ENABLED := true
const NARROW_PASS_DURATION_S := 0.65
const NARROW_PASS_RADIUS_SCALE := 0.80
const NARROW_PASS_MIN_CLEARANCE_M := 0.10
const NARROW_PASS_COOLDOWN_S := 1.50
const NARROW_PASS_MAX_PROBE_DISTANCE_M := 1.20
# 己方建筑脱困：已确认停滞、附近无敌军、推出层正被己方建筑顶住时，短时把个人空间与
# RVO 半径降到 navmesh agent 半径（建筑洞按它挖，洞边可走即放得下），允许贴己方建筑
# 小幅穿模过去；敌方建筑永远按正常站距。到点/换令/停止都还原半径。
## 开关（探针可在进程内关掉做对照）；关闭时推出层与旧实现逐项一致。
static var structure_pass_enabled := true
const STRUCTURE_PASS_DURATION_S := 0.6
const STRUCTURE_PASS_COOLDOWN_S := 1.5
## 离己方建筑表面 < 正常站距 + 该值，才算"被这栋建筑顶住"。
const STRUCTURE_PASS_CONTACT_SLACK_M := 0.35
## 建筑窄缝单车穿模。阈值与 GodotStructurePlacementWorldPort 的 Seal/Pass 同源，
## 运行时优先读 StructurePlacementRuntime；读不到时用下面的字面量。
## 缝口附近才排队，避免把远处绕路的单位吸进窄缝。
const GAP_PASS_SEAL_FALLBACK_M := 2.4
const GAP_PASS_CLEAR_FALLBACK_M := 5.6
const GAP_PASS_ENGAGE_M := 8.0
const GAP_PASS_TIMEOUT_S := 6.0
const GAP_PASS_COOLDOWN_S := 1.0
const GAP_PASS_MOUTH_M := 0.75
## 路径没有消耗时，连续这么多次「脱困轮数用尽」就判失败。
## 直线距离变远不算没进展：绕墙时到目标的距离会先变大（movement-recovery）。
const GIVE_UP_MAX_RESETS := 3
## 路径完全不消耗的最长时间。重烘期间路径为空的窗口不计（见采样返回 -1）。
## 必须长于 movement-recovery 的「行进中盖楼」全程（实测约 15s 才到达）。
const GIVE_UP_NO_PROGRESS_SECONDS := 45.0

# ============================================================================
# 流交互策略（问题A：密集对向/交叉流的通行能力，2026-09-30）
# ----------------------------------------------------------------------------
# 背景实测（见 docs/交接_问题A_对向交叉流交互.md）：
#   n=200 对向交叉 ≈139.9~160.0s / 同向平移 19.9s / 自由行进地板 ≈3.1 m/s。
#   已证伪：脱困阈值与滞回、避让 horizon、关 RVO（永不收敛）、恢复预算、carve、分批错峰。
# 本节的四个位只改**本单位自己的期望速度**（方向偏置 / 速度系数），
# RVO 仍是唯一的碰撞仲裁者；不瞬移、不加速、不改任何判定阈值与到达口径。
# **默认 0 = 完全关闭**：不注册、不查询、不进入任何分支，行为与改动前逐帧一致。
const FLOW_OFF := 0
## 右行偏置：预判到冲突航路时把期望方向向右偏一个角度（双方同时右偏 ⇒ 车道化）。
const FLOW_BIT_RIGHT := 1
## 让行优先权：冲突对象位于我右侧（右方来车）时我减速让行。
const FLOW_BIT_YIELD := 2
## 右侧车道保持：以"接单时的起点→目标"连线为基准，把横向位置控制到基准线右侧。
const FLOW_BIT_LANE := 4
## 期望速度量纲修正：把 m/s 的期望速度交给 RVO（而不是现有实现的"每帧步长"，
## 4 m/s 单位实际下发的是 0.067 ⇒ time_horizon 4.5s 只覆盖 0.3m，
## 避让退化成"贴身接触求解器"），并让 velocity_computed 按 速度×delta 落地。
const FLOW_BIT_VEL_UNITS := 8
## 密流软通行：自己在密集友军流里推进时，把**自身**避让半径按比例缩小，
## 让 4m 接触直径的单位能在 2m 净间隙的编队里通过（半径实测：2.0→135s、1.0→36s）。
## 不变式与既有 SOFT_PHASE 一致：只缩自己、附近有敌军不启用、到点/停/换令立刻还原。
const FLOW_BIT_SOFT := 16

static var flow_mode: int = FLOW_OFF
## 右行偏置的最大角（度）；随冲突严重度与"目标附近渐隐"缩放。
static var flow_bias_deg: float = 30.0
## 冲突检测半径（米）与预测时间视野（秒）。
static var flow_detect_m: float = 12.0
static var flow_horizon_s: float = 3.0
## 判定为冲突的最小接近距离（两单位中心，米）。
static var flow_conflict_m: float = 5.0
## 让行时的速度系数（0 = 完全停下等待）。
static var flow_yield_factor: float = 0.15
## 车道宽度与"距目标多少米开始收车道"。
static var flow_lane_m: float = 6.0
static var flow_lane_exit_m: float = 18.0
## 距任务目标小于该距离时完全不干预（保护最后一米手感与到达判定）。
static var flow_goal_zone_m: float = 10.0
## 冲突扫描间隔（物理帧）；按实例 id 错峰，避免 200 单位同帧 O(n²)。
static var flow_eval_interval: int = 3
## 车道保持的前视距离下限/上限（米）。
static var flow_look_ahead_min_m: float = 4.0
static var flow_look_ahead_max_m: float = 20.0
## 避让感知半径/邻居上限的实验覆盖值（<0 = 不覆盖，保持场景默认 3.0/16）。
## 【为什么它属于"量纲"而不是"调参"】RVO 的时间视野只有在
## 感知半径 ≥ 期望速度 × time_horizon 时才可能生效：期望速度按 m/s 下发后
## 4 m/s × 4.5s = 18m，而场景里 neighbor_distance = 3.0m ⇒ 视野再大也看不见。
## 未显式覆盖且 FLOW_BIT_VEL_UNITS 打开时，自动取 speed × time_horizon_agents。
static var flow_neighbor_m: float = -1.0
static var flow_max_neighbors: int = -1
## 只读探针（AIRTS_FLOW_PROBE=1）：记录 RVO 回传速度相对"期望步长"的比值分布，
## 用来区分"避让让单位减速"与"避让只把方向掰弯、单位仍按满速平移"。
## 默认关闭 ⇒ 每帧只多一次 static bool 判断。
static var flow_probe: bool = false
## 密流软通行参数：半径缩放系数、友军贴身判定间距、最少友军数、两次缩放之间的冷却。
static var flow_soft_scale: float = 0.5
static var flow_soft_gap_m: float = 0.0
static var flow_soft_min_friends: int = 2

static var _flow_registry := {}
static var _flow_grid := {}
static var _flow_grid_frame := -1
static var _flow_config_loaded := false
## 只读统计（供探针读取；不影响行为）。
static var flow_stats := {
	"scans": 0, "conflicts": 0, "lane_steers": 0, "yields": 0, "registered": 0,
	"vel_samples": 0, "vel_ratio_sum": 0.0, "vel_lt50": 0, "vel_lt10": 0,
	"vel_dir_sum": 0.0, "vel_dir_lt05": 0,
	"soft_shrinks": 0, "soft_restores": 0,
}


## 一次性读取实验参数（环境变量）；生产环境不设这些变量 ⇒ 仍是默认关闭。
## 只用于 A/B：同一个进程跑一个档位，不需要为了换档改代码。
static func flow_configure_from_env() -> void:
	if _flow_config_loaded:
		return
	_flow_config_loaded = true
	var mode := OS.get_environment("AIRTS_FLOW_MODE").strip_edges().to_lower()
	if mode != "" and mode != "off" and mode != "0":
		var bits := 0
		for token in mode.replace("+", ",").replace("|", ",").split(",", false):
			match token.strip_edges():
				"right": bits |= FLOW_BIT_RIGHT
				"yield": bits |= FLOW_BIT_YIELD
				"lane": bits |= FLOW_BIT_LANE
				"vel", "vel_units": bits |= FLOW_BIT_VEL_UNITS
				"soft": bits |= FLOW_BIT_SOFT
				_: push_warning("[FLOW] 未知的 AIRTS_FLOW_MODE 片段：%s" % token)
		flow_mode = bits
	flow_bias_deg = _flow_env_float("AIRTS_FLOW_BIAS_DEG", flow_bias_deg)
	flow_detect_m = _flow_env_float("AIRTS_FLOW_DETECT_M", flow_detect_m)
	flow_horizon_s = _flow_env_float("AIRTS_FLOW_HORIZON_S", flow_horizon_s)
	flow_conflict_m = _flow_env_float("AIRTS_FLOW_CONFLICT_M", flow_conflict_m)
	flow_yield_factor = _flow_env_float("AIRTS_FLOW_YIELD", flow_yield_factor)
	flow_lane_m = _flow_env_float("AIRTS_FLOW_LANE_M", flow_lane_m)
	flow_lane_exit_m = _flow_env_float("AIRTS_FLOW_LANE_EXIT_M", flow_lane_exit_m)
	flow_goal_zone_m = _flow_env_float("AIRTS_FLOW_GOAL_ZONE_M", flow_goal_zone_m)
	flow_eval_interval = int(_flow_env_float("AIRTS_FLOW_EVAL", float(flow_eval_interval)))
	flow_neighbor_m = _flow_env_float("AIRTS_FLOW_NEIGHBOR_M", flow_neighbor_m)
	flow_max_neighbors = int(_flow_env_float("AIRTS_FLOW_MAX_NEIGHBORS", float(flow_max_neighbors)))
	flow_probe = _flow_env_float("AIRTS_FLOW_PROBE", 0.0) > 0.0
	flow_soft_scale = _flow_env_float("AIRTS_FLOW_SOFT_SCALE", flow_soft_scale)
	flow_soft_gap_m = _flow_env_float("AIRTS_FLOW_SOFT_GAP_M", flow_soft_gap_m)
	flow_soft_min_friends = int(_flow_env_float("AIRTS_FLOW_SOFT_MIN", float(flow_soft_min_friends)))


static func _flow_env_float(name: String, fallback: float) -> float:
	var raw := OS.get_environment(name)
	if raw.strip_edges() == "":
		return fallback
	return float(raw)


## 供探针在同一进程里切换档位（会清掉"已读环境变量"缓存）。
static func flow_set_mode(mode: int) -> void:
	flow_mode = mode
	_flow_config_loaded = true

## 诊断计数（只读；测试与性能采样可读取，不影响行为）。
static var recovery_stats := {
	"stall_detections": 0,
	"repaths": 0,
	"escapes": 0,
	"unreachable": 0,
	"budget_skips": 0,
	# 受限软穿行：进入 / 退出 / 被规则拒绝（只记账，不改行为）。
	"soft_phase_enters": 0,
	"soft_phase_exits": 0,
	"soft_phase_rejects": 0,
	"narrow_pass_enters": 0,
	"narrow_pass_exits": 0,
	"narrow_pass_rejects": 0,
	"pocket_escapes": 0,
	"narrow_pass_shape_fallbacks": 0,
	"structure_pass_enters": 0,
	"structure_pass_exits": 0,
	"structure_pass_rejects": 0,
	"gap_pass_enters": 0,
	"gap_pass_exits": 0,
	"gap_pass_waits": 0,
	"give_up_resets": 0,
	"give_up_limit": 0,
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
## 受限软穿行状态：进入时快照半径（`>=0` 表示正在软穿行，退出必须还原）。
var _soft_phase_saved_radius := -1.0
## 两次软穿行之间的冷却（秒），避免把"缩小半径"当常态移动方式。
var _soft_phase_cooldown := 0.0
## 静态窄通道状态：只缩自身 Movement.radius，绝不修改共享 Shape3D 资源。
var _narrow_pass_saved_radius := -1.0
var _narrow_pass_cooldown := 0.0
var _structure_pass_saved_radius := -1.0
var _structure_pass_cooldown := 0.0
## 窄缝通行证：全局同时只有一名持有者。持有时只忽略形成这条缝的两栋己方建筑的推出。
static var _gap_pass_owner := 0
static var _gap_cache_frame := -1
static var _gap_cache: Array = []
static var _gap_seal_m := -1.0
static var _gap_clear_m := -1.0
var _gap_pass_active := false
var _gap_waiting := false
var _gap_pass_ids: Array = []
var _gap_pass_exit := Vector3.INF
var _gap_wait_point := Vector3.INF
var _gap_pass_timer := 0.0
var _gap_pass_cooldown := 0.0
var _give_up_resets := 0
## 导航路径进展（剩余长度 / 本段航点）。重寻路会把索引打回 0，那一拍只换基线。
var _path_tracked_index := 0
var _path_tracked_remaining := INF
var _path_tracked_position := Vector2.ZERO
var _path_repath_pending := false
var _path_baseline_pending := true
var _no_progress_give_ups := 0
var _no_progress_since_msec := 0
## 大图占用格航点（跳过 Recast 时用）。
var _logic_path: PackedVector3Array = PackedVector3Array()
var _logic_path_i := 0
var _logic_path_pending := false
var _logic_stuck := 0
## 脱困推进锚点：只有比它更接近任务目标 `LOGIC_PROGRESS_STEP_M` 以上才算"有推进"。
## 旧实现每帧位移/小滑动都清零卡住计数 ⇒ 贴障碍的原地微抖永远攒不到重寻路
## （2026-09-21 过桥实测：单位在桥西缘 0.14m 极限环里抖了整局，A* 有绕行路）。
var _logic_progress_anchor := INF
var _logic_repath_cd := 0.0
var _logic_repath_attempts := 0
var _logic_unstick_cd := 0.0
var _ground_visual_planted := false
const LOGIC_REPATH_MAX := 8
const LOGIC_WAYPOINT_RADIUS_M := 1.6
const LOGIC_PATH_BUDGET_PER_FRAME := 6
const LOGIC_UNSTICK_COOLDOWN_S := 0.45
## 判定"有推进"所需的最小接近量（米）。
const LOGIC_PROGRESS_STEP_M := 0.5
static var _logic_budget_frame := -1
static var _logic_budget_left := 0

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
	var t0 := Time.get_ticks_usec()
	if _diag_cached == 1 and not _inter_open:
		var match_stamp := int(_agg_mark_abs.get("match", 0))
		if match_stamp > 0 and t0 >= match_stamp:
			var prefix := int(t0 - match_stamp)
			_prefix_this = prefix
			agg_prefix_sum_us += prefix
			if prefix > agg_prefix_max_us:
				agg_prefix_max_us = prefix
		if _agg_phys_last_us > 0 and t0 >= _agg_phys_last_us:
			agg_window_to_first_us += int(t0 - _agg_phys_last_us)
			agg_window_to_first_n += 1
	if _diag_cached == 1 and _inter_open and _inter_prev_end > 0:
		var inter_gap := int(t0 - _inter_prev_end)
		agg_inter_sum_us += inter_gap
		if inter_gap > agg_inter_max_us:
			agg_inter_max_us = inter_gap
	_last_physics_delta = delta
	if _diag_cached == 1 and not _agg_physics_frame_hooked:
		var tree := get_tree()
		if tree != null:
			tree.physics_frame.connect(Callable(get_script(), "_on_diag_physics_frame"))
			_agg_physics_frame_hooked = true
	if NetSession.is_client_puppet():
		return
	_ensure_ground_combat_contact()
	if _skip_navigation_server():
		_physics_process_logic_move(delta)
		# 静止时也要结算平滑转向请求（face_towards）。逻辑地形单位不动时
		# `_on_velocity_computed` 不会被调用，`_face_target` 永远挂起：
		# 2026-09-23 矿场派工实测——工人背对矿点站桩，采集每 tick 都被
		# 朝向门槛（WORKER_AIM_THRESHOLD_DEG）跳过，resource_a 恒 0、永远采不满。
		if _face_target != Vector3.INF:
			_apply_pending_face_rotation()
	else:
		var _agg_rec := 0
		if _diag_cached == 1:
			_agg_rec = Time.get_ticks_usec()
		_update_recovery(delta)
		if _diag_cached == 1:
			agg_recovery_us += int(Time.get_ticks_usec() - _agg_rec)
			agg_recovery_n += 1
		var _agg_rep := 0
		if _diag_cached == 1:
			_agg_rep = Time.get_ticks_usec()
		_repair_missing_path()
		if _diag_cached == 1:
			agg_repair_us += int(Time.get_ticks_usec() - _agg_rep)
			agg_repair_n += 1
		var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
		_interim_speed = speed * speed_multiplier * delta
		var _agg_nq := 0
		if _diag_cached == 1:
			_agg_nq = Time.get_ticks_usec()
		var next_path_position: Vector3 = get_next_path_position()
		if _diag_cached == 1:
			agg_navquery_us += int(Time.get_ticks_usec() - _agg_nq)
			agg_navquery_n += 1
		var _agg_cl := 0
		if _diag_cached == 1:
			_agg_cl = Time.get_ticks_usec()
		next_path_position = _clamp_through_water(_unit.global_position, next_path_position)
		if _gap_pass_active and _gap_pass_exit.is_finite():
			next_path_position = _gap_pass_exit
		elif _gap_waiting and _gap_wait_point.is_finite():
			next_path_position = _gap_wait_point
		if _diag_cached == 1:
			agg_clamp_us += int(Time.get_ticks_usec() - _agg_cl)
		var _agg_seek := 0
		if _diag_cached == 1:
			_agg_seek = Time.get_ticks_usec()
		var current_agent_position: Vector3 = _unit.global_transform.origin
		# 浮空修复（2026-09-21 用户报"单位浮空"）的两层保障：
		# ① _align_unit_position_to_navigation 已按实测偏移校准 path_height_offset，
		#    寻路平面落在真实地表；
		# ② 这里再把每帧位移限制在水平面（寻路只取 XZ），并用 _snap_to_ground_height
		#    把 Y 压到真实地表（射线/高度场，与逻辑地形路径同源）——兜住斜坡上的
		#    残余量化误差，避免任何"网格面比可视地面高"的组合让单位浮起来。
		var seek_position := next_path_position
		seek_position.y = current_agent_position.y
		var new_velocity: Vector3 = (
			(seek_position - current_agent_position).normalized() * _interim_speed
		)
		if _diag_cached == 1:
			agg_seek_us += int(Time.get_ticks_usec() - _agg_seek)
		var _agg_flow := 0
		if _diag_cached == 1:
			_agg_flow = Time.get_ticks_usec()
		new_velocity = _flow_adjust_preferred(new_velocity, current_agent_position)
		if _diag_cached == 1:
			agg_flow_us += int(Time.get_ticks_usec() - _agg_flow)
			agg_flow_n += 1
		var _agg_setv := 0
		if _diag_cached == 1:
			_agg_setv = Time.get_ticks_usec()
		set_velocity(new_velocity)
		if _diag_cached == 1:
			agg_setvel_us += int(Time.get_ticks_usec() - _agg_setv)
			agg_setvel_n += 1
		var _agg_snap := 0
		if _diag_cached == 1:
			_agg_snap = Time.get_ticks_usec()
		_snap_air_height()
		_snap_to_ground_height()
		if _diag_cached == 1:
			agg_snap_us += int(Time.get_ticks_usec() - _agg_snap)
			agg_snap_n += 1
	if _perf_diag_enabled() and Engine.get_physics_frames() % 40 == 0:
		print("G4PERF movement_us=", Time.get_ticks_usec() - t0, " unit=", _unit.name)
	if _diag_cached == 1:
		var one_us := int(Time.get_ticks_usec() - t0)
		agg_phys_us += one_us
		agg_phys_n += 1
		if one_us > agg_max_one_us:
			agg_max_one_us = one_us
			agg_max_one_name = str(_unit.name) if _unit != null else ""
		_agg_phys_end_us = Time.get_ticks_usec()
		_inter_prev_end = _agg_phys_end_us
		_inter_open = true
		diag_mark("mov")


func _ready():
	_ensure_ground_combat_contact()
	# 每步 reset_physics_interpolation 只是把插值的前后位姿拉成同一个，
	# 画面本来就贴在刚写完的朝向和原点上。400 单位这一下是 5.52 ms/步。
	# 关掉单位根的物理插值后，网格直接用这两次写入的结果，不再每步重置。
	# 朝向和原点仍然分开写，避免插值只记下原点。
	if _unit != null:
		_unit.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	flow_configure_from_env()
	if flow_mode != FLOW_OFF:
		_flow_register()
	# 必须在 await 之前摘掉：等待 Match.ready 的那几秒里 C++ 代理已经在空图上查路。
	if _skip_navigation_server():
		_detach_navigation_agent()
		set_physics_process(false)
	if _match.navigation == null or not _match.is_node_ready():
		await _match.ready
	velocity_computed.connect(_on_velocity_computed)
	navigation_finished.connect(_on_navigation_finished)
	_apply_crowd_avoidance_defaults()
	if _skip_navigation_server():
		_detach_navigation_agent()
		call_deferred("_begin_logic_move")
	else:
		set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	target_position = Vector3.INF
	set_velocity(Vector3.ZERO)
	_stall_check_timer = _initial_stall_check_delay()
	if not _skip_navigation_server():
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
		if _uses_logic_terrain_move() and _logic_path.is_empty() and _logic_repath_cd <= 0.0:
			_request_logic_path()
		# 已贴到目标却仍被同一目标反复派差（贴障碍行走/穿越场景）：到达锁存
		# `_movement_end_emitted` 会把后续 arrival 全部静音，上层永远等不到
		# movement_finished（2026-09-23 实测：工人在避让圈界外 0.5m 永不到达，
		# 满载货物交不出去）。贴脸重派 = 允许再报一次到达。
		if _movement_end_emitted and _committed_target != null 				and _planar_distance_to(_committed_target) <= maxf(float(radius), 0.35):
			_movement_end_emitted = false
		return
	var perf_on := AiPerfStats.enabled()
	var clamp_started := Time.get_ticks_usec() if perf_on else 0
	var clamped := _clamp_to_reachable(movement_target)
	if perf_on:
		AiPerfStats.add("move_clamp", Time.get_ticks_usec() - clamp_started)
	_raw_target = movement_target
	_committed_target = clamped
	# 新的任务目标 ⇒ 车道基准重新锚定、密流软通行半径还原（同目标重发不清）。
	_flow_lane_valid = false
	_flow_restore_soft_radius("new_target")
	_progress_reference_distance = _planar_distance_to(clamped)
	_logic_progress_anchor = _planar_distance_to(clamped)
	_path_repair_attempts = 0
	_reset_path_progress_clock()
	_abort_recovery()
	_reset_stability_state()
	_logic_repath_attempts = 0
	_logic_repath_cd = 0.0
	if not _navigation_initialized:
		_pending_target = clamped
		_skip_initial_dispersion = true
	target_position = clamped
	if _uses_logic_terrain_move() and _navigation_initialized:
		var path_started := Time.get_ticks_usec() if perf_on else 0
		_request_logic_path()
		if perf_on:
			AiPerfStats.add("move_logic", Time.get_ticks_usec() - path_started)


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
func _uses_logic_terrain_move() -> bool:
	if domain != Constants.Match.Navigation.Domain.TERRAIN:
		return false
	return _skip_navigation_server()


## 生成大图不烘 Recast。地面和空中都不能再把 NavigationAgent3D 挂到空图上。
## 空中单位也跳过：空域网格钉在全局 Air.Y=40，对齐后电机会飞出镜头。
func _skip_navigation_server() -> bool:
	if domain == Constants.Match.Navigation.Domain.AIR:
		return true
	if _match != null and _match.navigation != null \
			and _match.navigation.has_method("should_skip_runtime_navigation"):
		return bool(_match.navigation.should_skip_runtime_navigation(_match.get_node_or_null("Map")))
	if _water_occupancy() != null:
		return true
	if _match == null:
		return false
	var map_node: Node = _match.get_node_or_null("Map")
	if map_node == null:
		return false
	if "size" in map_node and (map_node.size.x >= 256.0 or map_node.size.y >= 256.0):
		return true
	# 唯一实现见 MatchUtils.is_logic_terrain_map（旧内联判据把普通地图误判成逻辑地形）。
	return Utils.Match.is_logic_terrain_map(map_node)


func _detach_navigation_agent() -> void:
	avoidance_enabled = false
	set_physics_process_internal(false)
	set_navigation_map(RID())
	target_position = Vector3.INF
	set_velocity(Vector3.ZERO)


func _begin_logic_move() -> void:
	if not is_inside_tree():
		return
	# 贴地只做一次。再读一遍全局包围盒时，插值变换还停在旧高度，会把网格再往下压进地里。
	_snap_logic_height()
	set_physics_process(true)
	_finish_navigation_initialization()


func _plant_ground_visual() -> void:
	if domain == Constants.Match.Navigation.Domain.AIR:
		return
	# 步兵脚底由 AnimationDriver 按脚骨钉；这里只处理载具/工人网格。
	if _unit.find_child("AnimationDriver", false, false) != null:
		return
	var geometry := _unit.get_node_or_null("Geometry") as Node3D
	if geometry == null:
		return
	var min_y := 1.0e9
	for mesh_instance in geometry.find_children("*", "MeshInstance3D", true, false):
		var mi := mesh_instance as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		min_y = minf(min_y, box.position.y)
	if min_y > 1.0e8:
		return
	var gap := min_y - _unit.global_position.y
	if gap <= 0.02 or gap >= 2.5:
		return
	geometry.position.y -= gap


func _snap_logic_height() -> void:
	_snap_to_ground_height()
	if not _ground_visual_planted:
		_plant_ground_visual()
		_ground_visual_planted = true


## 把地形单位压到真实地表：射线（普通图）/ 高度场（生成图）。
## 空中域转交 `_snap_air_height`（地表 + 离地高度）。
## 导航网格路径与逻辑地形路径共用：网格面高度只用于寻路连通性，
## 不作为单位的站立平面（见 `_physics_process` 里的浮空根因说明）。
var _flat_snap_ready := false


func _snap_to_ground_height() -> void:
	if NetSession.is_client_puppet():
		return
	if domain == Constants.Match.Navigation.Domain.AIR:
		_snap_air_height()
		return
	if (
		not _flat_snap_ready
		and _match != null
		and _match._flat_ground_state == 1
		and _water_occupancy() == null
	):
		_flat_snap_ready = true
	if _flat_snap_ready:
		var flat_y := float(_match._flat_ground_y)
		var flat_dy := flat_y - _unit.global_position.y
		if absf(flat_dy) >= 0.0005:
			_unit.global_position.y = flat_y
			if absf(flat_dy) >= 0.15:
				_unit.reset_physics_interpolation()
		return
	var ground_y := _unit.global_position.y
	var occupancy := _water_occupancy()
	if occupancy != null and occupancy.has_method("project_ground"):
		ground_y = occupancy.project_ground(_unit.global_position).y
	elif _match != null and _match.has_method("ground_height_at"):
		ground_y = float(_match.ground_height_at(_unit.global_position))
	var dy := ground_y - _unit.global_position.y
	if absf(dy) >= 0.0005:
		_unit.global_position.y = ground_y
		if absf(dy) >= 0.15:
			_unit.reset_physics_interpolation()


func _snap_air_height() -> void:
	if NetSession.is_client_puppet():
		return
	if domain != Constants.Match.Navigation.Domain.AIR:
		return
	var ground_y := _unit.global_position.y
	if _match != null and _match.has_method("ground_height_at"):
		ground_y = float(_match.ground_height_at(_unit.global_position))
	else:
		var occupancy := _water_occupancy()
		if occupancy != null and occupancy.has_method("project_ground"):
			ground_y = occupancy.project_ground(_unit.global_position).y
	_unit.global_position.y = ground_y + Constants.Match.Air.HOVER_OFFSET


func _physics_process_air_move(delta: float) -> void:
	_snap_air_height()
	if _committed_target == null:
		return
	var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
	_interim_speed = speed * speed_multiplier * delta
	var from := _unit.global_position
	var seek: Vector3 = _committed_target
	var planar := Vector3(seek.x - from.x, 0.0, seek.z - from.z)
	var remain := planar.length()
	var arrive_radius := maxf(float(radius), 0.35)
	if remain <= arrive_radius:
		_snap_air_height()
		_emit_committed_end("Arrived")
		return
	var dir := planar / remain
	var step := minf(_interim_speed, remain)
	_on_velocity_computed(dir * step)
	_snap_air_height()


func _physics_process_logic_move(delta: float) -> void:
	if domain == Constants.Match.Navigation.Domain.AIR:
		_physics_process_air_move(delta)
		return
	if _logic_repath_cd > 0.0:
		_logic_repath_cd = maxf(0.0, _logic_repath_cd - delta)
	if _logic_unstick_cd > 0.0:
		_logic_unstick_cd = maxf(0.0, _logic_unstick_cd - delta)
	var speed_multiplier := reverse_speed_multiplier if _is_tactical_withdrawal else 1.0
	_interim_speed = speed * speed_multiplier * delta
	_update_gap_pass(delta)
	if _committed_target == null:
		if _uses_logic_terrain_move():
			_snap_logic_height()
		return
	if _uses_logic_terrain_move():
		_logic_unstick_if_blocked()
		if _logic_path_pending or _logic_path.is_empty():
			_request_logic_path()
	var from := _unit.global_position
	var seek := _logic_current_seek()
	if _gap_pass_active and _gap_pass_exit.is_finite():
		seek = _gap_pass_exit
	elif _gap_waiting and _gap_wait_point.is_finite():
		seek = _gap_wait_point
	seek.y = from.y
	var planar := Vector3(seek.x - from.x, 0.0, seek.z - from.z)
	var remain := planar.length()
	var arrive_radius := maxf(float(radius), 0.35)
	if _planar_distance_to(_committed_target) <= arrive_radius:
		if _uses_logic_terrain_move():
			_snap_logic_height()
		# 物理上已到达：解锁存再上报。锁存本意是"一次到达只报一次"，
		# 但同目标被反复派差时它会吞掉后续 arrival，上层（采集状态机/
		# GroundAttackMoving 交战转换）永远等不到 movement_finished
		# （2026-09-23 实测：工人贴目标 0.15m、士兵距目标 60m 双双永久站桩）。
		_movement_end_emitted = false
		_emit_committed_end("Arrived")
		return
	if remain <= _logic_waypoint_radius(seek) and not _defer_corner_cut(remain):
		if _logic_advance_waypoint():
			seek = _logic_current_seek()
			planar = Vector3(seek.x - from.x, 0.0, seek.z - from.z)
			remain = planar.length()
		else:
			seek = _committed_target as Vector3
			planar = Vector3(seek.x - from.x, 0.0, seek.z - from.z)
			remain = planar.length()
			if remain <= arrive_radius + 1.25:
				if _uses_logic_terrain_move():
					_snap_logic_height()
				_movement_end_emitted = false
				_emit_committed_end("Arrived")
				return
			# 路走完就直奔目标，不要立刻重寻——新路径的第一格会把人折回去。
	if remain < 0.0001:
		if _uses_logic_terrain_move():
			_snap_logic_height()
		return
	var dir := planar / remain
	var step := minf(_interim_speed, remain)
	var next: Vector3 = from + dir * step
	if _uses_logic_terrain_move():
		var occupancy := _water_occupancy()
		if occupancy != null and occupancy.has_method("clamp_ground_step"):
			next = occupancy.clamp_ground_step(from, next)
		else:
			next = _clamp_through_water(from, next)
		# 逐步落点允许"脱离"：贴建筑行走时不要把每一步按回对侧（震荡卡死）。
		next = _push_out_of_static_obstacles(next, true)
	else:
		next.y = from.y
	var moved := Vector3(next.x - from.x, 0.0, next.z - from.z)
	if moved.length_squared() < 0.0001:
		_handle_logic_blocked(dir)
		return
	_logic_stuck = 0
	var remain_to_goal := _planar_distance_to(_committed_target)
	if remain_to_goal <= _progress_reference_distance - 1.5:
		_progress_reference_distance = remain_to_goal
		_logic_repath_attempts = 0
	_on_velocity_computed(moved.normalized() * _interim_speed)
	if _uses_logic_terrain_move():
		_snap_logic_height()


func _water_occupancy() -> Node:
	if _match == null:
		return null
	var map_node: Node = _match.get_node_or_null("Map")
	if map_node == null or not map_node.has_meta("water_occupancy"):
		return null
	var occupancy: Variant = map_node.get_meta("water_occupancy")
	if occupancy is Node and is_instance_valid(occupancy):
		return occupancy
	return null


func _request_logic_path() -> void:
	if not _uses_logic_terrain_move() or _committed_target == null:
		return
	if _logic_repath_cd > 0.0:
		_logic_path_pending = _logic_path.is_empty()
		return
	var occupancy := _water_occupancy()
	if occupancy == null or not occupancy.has_method("find_ground_path"):
		_logic_path_pending = false
		return
	if not _consume_logic_path_budget():
		_logic_path_pending = true
		return
	_logic_path_pending = false
	_logic_path_i = 0
	_logic_stuck = 0
	_logic_progress_anchor = _planar_distance_to(_committed_target) if _committed_target != null else INF
	_logic_repath_cd = 0.25
	_logic_repath_attempts += 1
	# 净空用移动半径：航点若钻进「推出距离」里，单位会被墙顶住，永远吃不掉这个点。
	var path: Variant = occupancy.find_ground_path(
		_unit.global_position, _committed_target, maxf(float(radius), 0.0)
	)
	if path is PackedVector3Array:
		_logic_path = path
	elif path is Array:
		_logic_path = PackedVector3Array(path)
	else:
		_logic_path = PackedVector3Array()
	_skip_passed_logic_waypoints()


## 记录一次"朝任务目标的推进"：累计接近超过 `LOGIC_PROGRESS_STEP_M` 才清零卡住计数。
## 单帧小步（正常移动 0.07m/帧）不构成推进——否则贴障原地抖永远脱不了困。
func _note_logic_progress() -> void:
	if _committed_target == null:
		return
	var distance := _planar_distance_to(_committed_target)
	if distance < _logic_progress_anchor - LOGIC_PROGRESS_STEP_M:
		_logic_progress_anchor = distance
		_logic_stuck = 0


func _clear_logic_path() -> void:
	_logic_path = PackedVector3Array()
	_logic_path_i = 0
	_logic_path_pending = false
	_logic_stuck = 0
	_logic_repath_cd = 0.0


static func _consume_logic_path_budget() -> bool:
	var frame := Engine.get_physics_frames()
	if _logic_budget_frame != frame:
		_logic_budget_frame = frame
		_logic_budget_left = LOGIC_PATH_BUDGET_PER_FRAME
	if _logic_budget_left <= 0:
		return false
	_logic_budget_left -= 1
	return true


func _skip_passed_logic_waypoints() -> void:
	var goal := _committed_target as Vector3 if _committed_target != null else _unit.global_position
	var to_goal := Vector3(goal.x - _unit.global_position.x, 0.0, goal.z - _unit.global_position.z)
	while _logic_path_i < _logic_path.size():
		var waypoint: Vector3 = _logic_path[_logic_path_i]
		if _planar_distance_to(waypoint) <= LOGIC_WAYPOINT_RADIUS_M:
			_logic_path_i += 1
			continue
		var to_wp := Vector3(waypoint.x - _unit.global_position.x, 0.0, waypoint.z - _unit.global_position.z)
		# 只跳过身边反向的近点（典型是起点格心），远绕行航点即使先往旁边走也要留。
		if to_goal.length_squared() > 0.25 and to_wp.length_squared() < 6.25 and to_wp.dot(to_goal) < 0.0:
			_logic_path_i += 1
			continue
		break


func _logic_current_seek() -> Vector3:
	if _logic_path_i < _logic_path.size():
		return _logic_path[_logic_path_i]
	return _committed_target as Vector3


func _logic_waypoint_radius(seek: Vector3) -> float:
	if _committed_target != null and _planar_distance_to_point(seek, _committed_target) <= 0.8:
		return maxf(float(radius), 0.35)
	return LOGIC_WAYPOINT_RADIUS_M


## 拐角航点还没走到时，不要提前切到下一点：捷径会擦进车身，人又被墙顶在吃不掉的点上。
func _defer_corner_cut(remain: float) -> bool:
	if remain <= 0.45 or _logic_path_i + 1 >= _logic_path.size():
		return false
	var occupancy := _water_occupancy()
	if occupancy == null or not occupancy.has_method("body_segment_blocked"):
		return false
	return bool(occupancy.call(
		"body_segment_blocked",
		_unit.global_position,
		_logic_path[_logic_path_i + 1],
		maxf(float(radius), 0.0)
	))


func _logic_advance_waypoint() -> bool:
	if _logic_path_i < _logic_path.size():
		_logic_path_i += 1
		return _logic_path_i < _logic_path.size()
	return false


func _logic_unstick_if_blocked() -> void:
	if _logic_unstick_cd > 0.0:
		return
	var occupancy := _water_occupancy()
	if occupancy == null:
		return
	# `clearance` 传**本单位自身半径**：足迹是建筑本体，而"楔在楼边"是车体与碰撞体重叠。
	# 以前只问建筑本体（且旧足迹还缩到 0.85），单位明明卡在车厂角上却判"没被挡住"，
	# 于是脱困永远不启动（实测 `stall_detections=0 escapes=0`，卡住 126~171 秒）。
	var blocked := occupancy.has_method("is_ground_blocked") and bool(occupancy.is_ground_blocked(_unit.global_position))
	if not blocked and _logic_stuck < 2:
		return
	if occupancy.has_method("snap_to_bridge_if_near"):
		var on_deck: Vector3 = occupancy.snap_to_bridge_if_near(_unit.global_position, 0.25)
		if _planar_distance_to_point(_unit.global_position, on_deck) > 0.05 \
				and _planar_distance_to_point(_unit.global_position, on_deck) < 0.4:
			var _b1: Vector3 = _unit.global_position
			var deck_land: Vector3 = _clamp_teleport_against_ground_combat(_b1, on_deck)
			_unit.global_position = deck_land
			_pos_trace("UNSTICK-bridge", _b1, deck_land)
			_unit.reset_physics_interpolation()
			_logic_unstick_cd = LOGIC_UNSTICK_COOLDOWN_S
			_logic_repath_cd = 0.0
			_request_logic_path()
			return
	if not blocked or not occupancy.has_method("unstick_ground"):
		return
	var land: Vector3 = occupancy.unstick_ground(_unit.global_position, get_instance_id())
	if _planar_distance_to_point(_unit.global_position, land) < 0.05:
		return
	var _b2: Vector3 = _unit.global_position
	var land_resolved: Vector3 = _clamp_teleport_against_ground_combat(_b2, land)
	_unit.global_position = land_resolved
	_pos_trace("UNSTICK-ground", _b2, land_resolved)
	_unit.reset_physics_interpolation()
	_logic_unstick_cd = LOGIC_UNSTICK_COOLDOWN_S
	_logic_repath_cd = 0.0
	_request_logic_path()


func _handle_logic_blocked(forward: Vector3) -> void:
	if _uses_logic_terrain_move():
		_snap_logic_height()
	if _try_logic_slide(forward):
		_note_logic_progress()
	_logic_stuck += 1
	if _logic_stuck < 3:
		return
	_logic_unstick_if_blocked()
	if _logic_repath_attempts >= LOGIC_REPATH_MAX:
		_fail_as_unreachable()
		return
	_logic_repath_cd = 0.0
	_request_logic_path()
	_logic_stuck = 0


func _try_logic_slide(forward: Vector3) -> bool:
	var occupancy := _water_occupancy()
	var from := _unit.global_position
	var left := Vector3(-forward.z, 0.0, forward.x)
	if left.length_squared() < 0.0001:
		left = Vector3.RIGHT
	var step := maxf(_interim_speed, 0.18)
	var offsets: Array[Vector3] = [
		left, -left, left + forward, -left + forward, -forward
	]
	for offset in offsets:
		if offset.length_squared() < 0.0001:
			continue
		var next: Vector3 = from + offset.normalized() * step
		if occupancy != null and occupancy.has_method("clamp_ground_step"):
			next = occupancy.clamp_ground_step(from, next)
		next = _push_out_of_static_obstacles(next, true)
		var moved := Vector3(next.x - from.x, 0.0, next.z - from.z)
		if moved.length_squared() < 0.0001:
			continue
		_on_velocity_computed(moved.normalized() * _interim_speed)
		if _uses_logic_terrain_move():
			_snap_logic_height()
		return true
	return false


func _clamp_through_water(from: Vector3, target: Vector3) -> Vector3:
	if _flat_snap_ready:
		return target
	if domain != Constants.Match.Navigation.Domain.TERRAIN:
		return target
	var occupancy := _water_occupancy()
	if occupancy == null or not occupancy.has_method("clamp_ground_move"):
		return target
	return occupancy.clamp_ground_move(from, target)


func _clamp_to_reachable(target: Vector3) -> Vector3:
	if _skip_navigation_server():
		if _uses_logic_terrain_move():
			var occupancy := _water_occupancy()
			if occupancy != null and occupancy.has_method("clamp_ground_destination"):
				target = occupancy.clamp_ground_destination(target)
			return _push_out_of_static_obstacles(target)
		return _push_out_of_static_obstacles(_clamp_through_water(_unit.global_position, target))
	var nav_map := get_navigation_map()
	if not nav_map.is_valid():
		return _clamp_through_water(_unit.global_position, target)
	var closest_owner := NavigationServer3D.map_get_closest_point_owner(nav_map, target)
	if not closest_owner.is_valid():
		# 开局竞态防护(2026-09-03): 导航网格尚未烘焙同步时 closest 点可能退化为
		# 原点附近, 把目标钳到 (0,0) 会让 AI 工人开局横穿地图绕到地图角。
		# 网格为空时保持原目标, 导航代理会直线走向目标(平坦地图等价正确)。
		return _clamp_through_water(_unit.global_position, _push_out_of_static_obstacles(target))
	var closest := NavigationServer3D.map_get_closest_point(nav_map, target)
	if not closest.is_finite():
		return _clamp_through_water(_unit.global_position, target)
	# clamp 的语义是"把目标从障碍内贴到边缘"，只应产生小距离修正；
	# 部分烘焙网格会给出远距离的错误吸附点，此时保持原目标更安全。
	if closest.distance_to(target) > CLAMP_MAX_SNAP_DISTANCE_M:
		return _clamp_through_water(_unit.global_position, _push_out_of_static_obstacles(target))
	# Y 取真实地表而不是 `网格面 - path_height_offset`：网格面被 Recast 量化抬高，
	# 旧写法会把目标点写进浮空平面，令单位的运动平面与终态判定整体偏移（浮空根因之一）。
	var clamped := Vector3(closest.x, _ground_height_at(closest), closest.z)
	return _clamp_through_water(
		_unit.global_position,
		_push_out_of_static_obstacles(clamped)
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
##
## `allow_escape=true`（**逐步落点**专用）：只有当这一步会**更深地进入**避让圈时才推回；
## 已经在圈内、且这一步正在往外走（或切向通过）的，一律放行。
## 2026-09-21 生成图实测：工人贴在自己建筑边缘时，每一步都被径向推回对侧，
## 单位在两个相距 0.2m 的点之间来回瞬移、永远逃不出去（整局卡死）。
## 目标点/脱困候选点仍用默认的 `false`（那里要的是"落点必须在圈外"）。
## 【2026-10-01 逐单位碰撞包围任务】障碍的水平占地**最近点**，替代"一律当圆"。
## 返回 {ok, closest:Vector2, kind:String}：
##   BoxShape3D   ⇒ 把点变换到形状本地、对 ±size/2 夹取，得到真实 OBB 最近点（yaw 生效）；
##   Cylinder/Capsule/Sphere ⇒ 圆（半径语义本来就对）；
##   其它形状（凸体/凹网格等）⇒ **显式不受支持**：ok=false，调用方按 AABB 保守处理并告警，
##   绝不静默回退成"没有障碍"或"一个大圆"（提示词第 24/75 行要求）。


func _obstacle_footprint_closest(obstacle: Node, point: Vector2) -> Dictionary:
	var cs: CollisionShape3D = null
	# 【第 48 轮·真凶修复】CollisionShape3D 与 MovementObstacle 在单位场景里是**兄弟节点**
	# （同在单位根下）⇒ 只在 obstacle 内部找会**永远找不到** ⇒ 一直退化成"圆心" ✓
	# （追踪实测 kind=无碰撞体(退化为圆心) 8146/8149 ✗，这解释了此前全部"零响应" ✓）。
	# 改为：先在本节点内找，再在**父节点**范围内找。
	var search_root: Node = obstacle
	for attempt in range(2):
		for child in search_root.find_children("*", "CollisionShape3D", true, false):
			var candidate := child as CollisionShape3D
			if candidate != null and candidate.shape != null and not candidate.disabled:
				cs = candidate
				break
		if cs != null:
			break
		search_root = obstacle.get_parent()
		if search_root == null:
			break
	if cs == null or cs.shape == null:
		return {"ok": true, "closest": Vector2(obstacle.global_position.x, obstacle.global_position.z), "kind": "无碰撞体(退化为圆心)"}
	var xf: Transform3D = cs.global_transform
	var local: Vector3 = xf.affine_inverse() * Vector3(point.x, xf.origin.y, point.y)
	var shape := cs.shape
	if shape is BoxShape3D:
		var half: Vector3 = (shape as BoxShape3D).size * 0.5
		# 【第 47 轮·未验证改进】点在盒子内部时 clamp 返回点本身 ⇒ 推出层从内部量 stand_off ⇒
		# 理论上推不出去；此处改为投到最近盒面 ✓。注意：该分支在当前（包含圆）配置下不被调用 ✗，
		# 且追踪显示改动后读数未变 ⇒ 标注「未验证」，启用贴形前必须先验证 ✓。
		if absf(local.x) <= half.x and absf(local.z) <= half.z:
			var dx: float = half.x - absf(local.x)
			var dz: float = half.z - absf(local.z)
			var exit_local := local
			if dx <= dz:
				exit_local.x = half.x if local.x >= 0.0 else -half.x
			else:
				exit_local.z = half.z if local.z >= 0.0 else -half.z
			var world_in: Vector3 = xf * Vector3(exit_local.x, 0.0, exit_local.z)
			return {"ok": true, "closest": Vector2(world_in.x, world_in.z), "kind": "Box(贴盒·内部投面)", "inside": true}
		var clamped := Vector3(clampf(local.x, -half.x, half.x), 0.0, clampf(local.z, -half.z, half.z))
		var world: Vector3 = xf * clamped
		return {"ok": true, "closest": Vector2(world.x, world.z), "kind": "Box(贴盒)", "inside": false}
	if shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		var dir2 := Vector2(local.x, local.z)
		var was_inside := dir2.length() < c.radius
		if dir2.length() < 0.0001:
			dir2 = Vector2.RIGHT
		var pt: Vector3 = xf * Vector3(dir2.normalized().x * c.radius, 0.0, dir2.normalized().y * c.radius)
		return {"ok": true, "closest": Vector2(pt.x, pt.z), "kind": "Cylinder(圆)", "inside": was_inside}
	if shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		var d2 := Vector2(local.x, local.z)
		var cap_inside := d2.length() < cap.radius
		if d2.length() < 0.0001:
			d2 = Vector2.RIGHT
		var pt2: Vector3 = xf * Vector3(d2.normalized().x * cap.radius, 0.0, d2.normalized().y * cap.radius)
		return {"ok": true, "closest": Vector2(pt2.x, pt2.z), "kind": "Capsule(圆)", "inside": cap_inside}
	if shape is SphereShape3D:
		var sp := shape as SphereShape3D
		var d3 := Vector2(local.x, local.z)
		var sphere_inside := d3.length() < sp.radius
		if d3.length() < 0.0001:
			d3 = Vector2.RIGHT
		var pt3: Vector3 = xf * Vector3(d3.normalized().x * sp.radius, 0.0, d3.normalized().y * sp.radius)
		return {"ok": true, "closest": Vector2(pt3.x, pt3.z), "kind": "Sphere(圆)", "inside": sphere_inside}
	# 不支持：用整个世界 AABB 的半宽做保守圆，并告警（不静默漏读）
	var aabb: AABB = _obstacle_world_aabb(cs)
	var half_span: float = maxf(aabb.size.x, aabb.size.z) * 0.5
	push_warning("[Movement] 障碍形状 %s 不受支持，按 AABB 保守圆 %.2fm 推出（实体=%s）" % [shape.get_class(), half_span, str(obstacle.name)])
	return {"ok": false, "closest": Vector2(point.x, point.y), "kind": "不支持-AABB保守", "fallback_radius": half_span, "origin": Vector2(cs.global_position.x, cs.global_position.z)}


## 近地视觉 hull 沿 dir（xz 平面）的半宽。独立复核 D2 指出：碰撞形状可能**覆盖不了模型长轴**
## （工兵圆柱 r=0.92 vs 模型长轴半长 1.262，车头露出 0.342m）⇒ 贴形占位必须取
## max(碰撞形状, 本函数) 才能保证「贴边不穿模」。蒙皮网格走骨骼点（绑定姿态 AABB 会退化）。
func _ground_hull_half_xz(node: Node3D, dir: Vector2, ground_band: float = 0.6) -> float:
	return _ground_hull_support(_ground_hull_points_xz(node, ground_band), dir)


func _ground_hull_support(points: PackedVector2Array, dir: Vector2) -> float:
	var out := 0.0
	for point in points:
		out = maxf(out, point.dot(dir))
	return out


# Sample the current pose once per push, not once per obstacle. Do not retain
# these world-relative points across rotations, animation updates or movement.
func _ground_hull_points_xz(node: Node3D, ground_band: float = 0.6) -> PackedVector2Array:
	var origin: Vector3 = node.global_position
	var points := PackedVector2Array()
	for gi in node.find_children("*", "GeometryInstance3D", true, false):
		var path := str(gi.get_path())
		if path.contains("Selection") or path.contains("Highlight") or path.contains("Targetability") \
				or path.contains("HealthBar") or path.contains("RallyPoint"):
			continue
		# 注意：MeshInstance3D.skeleton 是 **NodePath**（不是 Skeleton3D 引用），必须解析成节点。
		var skel_path: NodePath = (gi as MeshInstance3D).skeleton if gi is MeshInstance3D else NodePath()
		var skel: Skeleton3D = null
		if skel_path != NodePath():
			skel = gi.get_node_or_null(skel_path) as Skeleton3D
		if skel != null:
			var xf_skel: Transform3D = (gi as Node3D).global_transform
			for b in range(skel.get_bone_count()):
				var bp: Vector3 = xf_skel * skel.get_bone_global_pose(b).origin
				if bp.y - origin.y > ground_band:
					continue
				points.append(Vector2(bp.x - origin.x, bp.z - origin.z))
			continue
		var local: AABB = (gi as GeometryInstance3D).get_aabb()
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null and local.size.length() < 0.01:
			local = (gi as MeshInstance3D).mesh.get_aabb()
		if local.size.length() < 0.001:
			continue
		var xf: Transform3D = (gi as Node3D).global_transform
		for i in range(8):
			var pt: Vector3 = xf * local.get_endpoint(i)
			if pt.y - origin.y > ground_band:
				continue
			points.append(Vector2(pt.x - origin.x, pt.z - origin.z))
	return points

func _obstacle_world_aabb(cs: CollisionShape3D) -> AABB:
	var shape := cs.shape
	var local := AABB()
	if shape is BoxShape3D:
		var b := shape as BoxShape3D
		local = AABB(-b.size * 0.5, b.size)
	elif shape is CylinderShape3D:
		var c := shape as CylinderShape3D
		local = AABB(Vector3(-c.radius, -c.height * 0.5, -c.radius), Vector3(c.radius * 2, c.height, c.radius * 2))
	elif shape is CapsuleShape3D:
		var cap := shape as CapsuleShape3D
		local = AABB(Vector3(-cap.radius, -cap.height * 0.5, -cap.radius), Vector3(cap.radius * 2, cap.height, cap.radius * 2))
	elif shape is SphereShape3D:
		var sp := shape as SphereShape3D
		local = AABB(Vector3.ONE * -sp.radius, Vector3.ONE * sp.radius * 2.0)
	else:
		return AABB()
	var xf: Transform3D = cs.global_transform
	var out := AABB()
	var first := true
	for i in range(8):
		var pt: Vector3 = xf * local.get_endpoint(i)
		if first:
			out = AABB(pt, Vector3.ZERO); first = false
		else:
			out = out.expand(pt)
	return out


## 【第 7 轮】位置写入追踪：AIRTS_POS_TRACE=1 时打印每处写位置点的"改前→改后"，用于定位
## "谁把单位放进了 stand_off 之内"。限流 400 行，避免刷屏掩盖其它输出。
## 【2026-10-01 第 8 轮】推出让位于到达：当落点已经贴着任务目标（这个距离内）时，推出层不再把单位推开，
## 否则"推出"与"到达判定"互相拉扯 ⇒ 单位永远到不了目标、订单永不结束（navigation-stability 实测三条红）。
const OBSTACLE_ARRIVAL_YIELD_M := 0.6

var _pos_trace_lines := 0
## 环境变量只读一次（每步调用 OS.get_environment 是系统调用，实测拖垮移动、套件超时）。
var _pos_trace_on := OS.get_environment("AIRTS_POS_TRACE") == "1"
var _push_trace_on := OS.get_environment("AIRTS_PUSH_TRACE") == "1"
var _narrow_trace_on := OS.get_environment("AIRTS_NARROW_TRACE") == "1"
var _narrow_trace_lines := 0
var _velocity_trace_on := OS.get_environment("AIRTS_VELOCITY_TRACE") == "1"
var _velocity_trace_lines := 0


func _pos_trace(tag: String, before: Vector3, after: Vector3, extra: String = "") -> void:
	if not _pos_trace_on or _pos_trace_lines > 400:
		return
	_pos_trace_lines += 1
	print("[POS] %s unit=%s before=(%.2f,%.2f) after=(%.2f,%.2f) %s" % [
		tag, _unit.name, before.x, before.z, after.x, after.z, extra])


static var _obs_frame: int = -1
static var _obs_group: String = ""
static var _gap_empty_frame: int = -1
static var _obs_xy := PackedFloat32Array()
static var _obs_r := PackedFloat32Array()
static var _obs_id := PackedInt64Array()


func _refresh_obstacle_precull(group_name: String) -> void:
	var frame := Engine.get_physics_frames()
	if frame == _obs_frame and group_name == _obs_group:
		return
	_obs_frame = frame
	_obs_group = group_name
	var nodes := get_tree().get_nodes_in_group(group_name)
	var count := nodes.size()
	_obs_xy.resize(count * 2)
	_obs_r.resize(count)
	_obs_id.resize(count)
	var written := 0
	for obstacle in nodes:
		if not is_instance_valid(obstacle):
			continue
		var pre_radius = obstacle.get("radius")
		if pre_radius == null:
			continue
		var pos: Vector3 = obstacle.global_position
		_obs_xy[written * 2] = pos.x
		_obs_xy[written * 2 + 1] = pos.z
		_obs_r[written] = float(pre_radius)
		_obs_id[written] = int(obstacle.get_instance_id())
		written += 1
	_obs_xy.resize(written * 2)
	_obs_r.resize(written)
	_obs_id.resize(written)


func _precull_needs_exact(planar: Vector2, own_radius: float, vis_cap: float) -> bool:
	var self_id := int(_unit.get_instance_id())
	var count := _obs_r.size()
	var index := 0
	while index < count:
		if _obs_id[index] == self_id:
			index += 1
			continue
		var pre_radius := _obs_r[index]
		if pre_radius <= own_radius:
			index += 1
			continue
		var pre_c := Vector2(_obs_xy[index * 2], _obs_xy[index * 2 + 1])
		var pre_limit := pre_radius + own_radius + vis_cap + OBSTACLE_CLEARANCE_MARGIN_M + pre_radius
		if planar.distance_to(pre_c) <= pre_limit:
			return true
		index += 1
	return false


func _push_out_of_static_obstacles(point: Vector3, allow_escape: bool = false) -> Vector3:
	diag_bump("pushout")
	var group_name: String = (
		Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(domain, "")
	)
	if group_name == "" or not is_inside_tree():
		return point
	var _agg_gt := 0
	if _diag_cached == 1:
		_agg_gt = Time.get_ticks_usec()
	_refresh_obstacle_precull(group_name)
	if _diag_cached == 1:
		agg_group_us += int(Time.get_ticks_usec() - _agg_gt)
		agg_group_n += 1
		agg_obs_n += _obs_r.size()
	if _obs_r.is_empty():
		return point
	var own_radius: float = maxf(float(radius), 0.0)
	var unit_planar := Vector2(_unit.global_position.x, _unit.global_position.z)
	var planar := Vector2(point.x, point.z)
	var hull_points := PackedVector2Array()
	var hull_sampled := false
	# 远障碍不可能推动：上界 vis_cap >= 任意朝向的 vis47 时，超出该距离的障碍
	# 在原判据下也会 continue。先整批判定，避免为远处建筑采样骨骼。
	var vis_cap := own_radius + PUSH_VISUAL_SUPPORT_CAP_SLACK_M
	var needs_exact := _precull_needs_exact(planar, own_radius, vis_cap)
	if not needs_exact:
		if _diag_cached == 1:
			agg_precull_n += 1
		return point
	var obstacles := get_tree().get_nodes_in_group(group_name)
	for obstacle in obstacles:
		if obstacle == _unit or not is_instance_valid(obstacle):
			continue
		# 窄缝通行证只跳过形成这条缝的两栋建筑，其它障碍、矿点、墙仍推出。
		if _gap_pass_active and _gap_pass_ids.has(int(obstacle.get_instance_id())):
			continue
		var obstacle_radius = obstacle.get("radius")
		if obstacle_radius == null:
			continue
		# 只有比单位本身更大的障碍才需要推出去：建筑（半径 1.5~2.0）会把落点吞进避让圈，
		# 而矿点/小炮塔（半径 0.6）本来就该被贴近——推出去反而会超出采集/交互的贴合距离，
		# 让工人卡在"到达→贴不上→重走"的循环里（实测过）。
		if float(obstacle_radius) <= own_radius:
			if _diag_cached == 1:
				agg_radius_skip_n += 1
			continue
		# 【2026-10-01 逐单位碰撞包围任务】障碍占地从"一律当圆"改为**贴形最近点**：
		#   长方体 ⇒ 真实 OBB 最近点（yaw 生效；窄轴不再白留 (maxHalf−minHalf) 的余量）；
		#   圆柱/胶囊/球 ⇒ 圆；不支持的形状 ⇒ 显式告警 + AABB 保守圆（不静默漏读）。
		# 【2026-10-01 回退说明】贴盒最近点（_obstacle_footprint_closest）已实现并保留，
		# 但当前配置下"贴盒 carve + 每步硬占位"会在盒的**宽轴**方向产生 −0.9m 穿模
		# （四方向实测），根因尚未定位 ⇒ 先回到**实测全安全**的"包含圆"口径：
		# stand_off = 障碍包含半径 + 个人空间 + margin（所有方向间隙 ≥ 0，代价是窄轴多留余量）。
		# 下一轮：定位"每步硬占位未生效"后再启用贴盒路径。
		# 贴形最近点（OBB/圆）；不支持形状显式告警 + AABB 兜底
		# 【2026-10-01 第 8 轮结论】贴形推出已验证可把工兵间隙从 1.66m 降到 1.02m（无穿模），
		# 但启用后 navigation-stability 三条断言转红（到达后仍被推动 ⇒ 订单不结束），
		# 且 carve 圆（包含半径+agent）成为新限制层 ⇒ 单靠贴形推出到不了目标带。
		# 下一轮需"贴形 carve + 贴形推出 + 到达优先"三者一起上并重新标定 navigation-stability。
		# 【2026-10-01 状态：未启用，勿按"已实现"计数】贴形最近点已实现（函数 _obstacle_footprint_closest），
		# 但**当前没有任何调用点**；历史上三次启用实验（含 carve 最小中心距约束）都让
		# navigation-stability 或 movement-recovery 转红 ⇒ 全部回退。启用前的硬前置（独立复核 D2）：
		#   工兵碰撞圆柱 r=0.92 **覆盖不了模型长轴 1.262**（车头各露出 0.342m）
		#   ⇒ 贴形推出必须取 max(碰撞形状, 近地视觉 hull 沿朝向) 作为占位半宽，否则车头会插进建筑。
		# 【2026-10-01 第 20 轮实测定量】贴形 + carve 约束 + D2（max(碰撞,视觉)）组合下：
		#   单位**能到达但慢约 3 倍**（building-mid-move 38.6s vs 基线 11.5s；stall 44 / escape 44），
		#   ⇒ 贴形推出在障碍附近产生微振荡，让 movement-recovery / navigation-stability 的**时序**断言失败。
		#   要落地必须同步重标定移动层脱困/到达阈值（超出碰撞层范围）⇒ 暂缓启用。
		var obstacle_origin: Vector3 = obstacle.global_position
		var closest := Vector2(obstacle_origin.x, obstacle_origin.z)
		# 【第 46 轮·推出发追踪实测（AIRTS_PUSH_TRACE=1）】兵营：r=3.11 own=1.36 ⇒ stand_off=4.47
		# ⇒ **恰好等于物理下限**（3.105+1.36=4.465，与 committed 实测逐位吻合 ✓）⇒ 说明
		# margin(0.1) − 补偿(0.25) = −0.15 < 0 ⇒ maxf 永远返回物理下限 ⇒ **安全余量与到达补偿完全抵消** ✓。
		# 含义：① 推出层目前**没有**额外白留 ✓（痛点不在这里）；② 想调余量必须让 margin > 补偿 ✓。
		# 【第 47 轮】贴形实验（带数值追踪）：
		var physical_min: float = float(obstacle_radius) + own_radius
		var obstacle_c := Vector2(obstacle.global_position.x, obstacle.global_position.z)
		var dir_c := planar - obstacle_c
		var dir_n := dir_c.normalized() if dir_c.length() > 0.0001 else Vector2.RIGHT
		if not hull_sampled:
			var _agg_ht := 0
			if _diag_cached == 1:
				_agg_ht = Time.get_ticks_usec()
			hull_points = _ground_hull_points_xz(_unit)
			if _diag_cached == 1:
				agg_hull_us += int(Time.get_ticks_usec() - _agg_ht)
				agg_hull_n += 1
				var hull_reach := 0.0
				for hull_point in hull_points:
					hull_reach = maxf(hull_reach, hull_point.length())
				if hull_reach > agg_hull_reach_max:
					agg_hull_reach_max = hull_reach
				if hull_reach > vis_cap:
					agg_cap_exceeded_n += 1
			hull_sampled = true
		var vis47: float = _ground_hull_support(hull_points, dir_n)
		# 窄通道阶段的“允许短暂小穿模”只放宽移动个人空间到真实物理形状，
		# 不把动画/炮管 hull 再叠加一次；正常阶段仍保留视觉 hull 防穿模。
		if _narrow_pass_saved_radius >= 0.0:
			var narrow_collision_half := _unit_ground_half_extent(dir_n, false)
			if narrow_collision_half > 0.01:
				vis47 = narrow_collision_half
		if vis47 <= 0.01:
			var cs48: CollisionShape3D = null
			for ch in obstacle.get_parent().find_children("*", "CollisionShape3D", true, false):
				var c48 := ch as CollisionShape3D
				if c48 != null and c48.shape != null and not c48.disabled:
					cs48 = c48
					break
			if cs48 != null:
				if cs48.shape is BoxShape3D:
					var b48 := cs48.shape as BoxShape3D
					var xf48: Transform3D = cs48.global_transform
					var local_dir := xf48.basis.inverse() * Vector3(dir_n.x, 0.0, dir_n.y)
					vis47 = maxf(absf(local_dir.x) * b48.size.x * 0.5, absf(local_dir.z) * b48.size.z * 0.5)
				elif cs48.shape is CylinderShape3D:
					vis47 = (cs48.shape as CylinderShape3D).radius
		if _structure_pass_saved_radius >= 0.0 and _is_own_structure_obstacle(obstacle):
			vis47 = 0.0
		# 【R16·C1 保守前置剔除】昂贵调用（footprint/AABB）之前先按可证上界剔除 ✓
		# 证明：stand_off ≤ physical_min + vis47 + MARGIN；step_distance ≥ |planar−obstacle_c| − obstacle_radius
		# ⇒ 距离超过 physical_min + vis47 + MARGIN + obstacle_radius 时**不可能推动** ⇒ 输出不变 ✓
		if dir_c.length() > physical_min + vis47 + OBSTACLE_CLEARANCE_MARGIN_M + float(obstacle_radius):
			if _diag_cached == 1:
				agg_dist_cull_n += 1
			continue

		# 【R16】把昂贵的 footprint 查询放到**保守剔除之后** ✓（这正是本次优化的意义 ✓）
		var _agg_ft := 0
		if _diag_cached == 1:
			_agg_ft = Time.get_ticks_usec()
		var fp47 := _obstacle_footprint_closest(obstacle, planar)
		if _diag_cached == 1:
			agg_fp_us += int(Time.get_ticks_usec() - _agg_ft)
			agg_fp_n += 1
		var shaped_inside := bool(fp47.get("inside", false))
		var current_shape_inside := false
		var shaped_closest: Vector2 = fp47.get("closest", obstacle_c)
		# 【第 51 轮·实验结论】把"单位侧也方向感知"（用单位 hull 替代个人空间）虽然让工兵间隙
		# 0.147 → **0.084m** ✓，但会让 navigation-stability 转红 ✗（到达后仍被推动 ⇒ 订单不结束）。
		# ⇒ 已回退：保留"障碍贴形 + 单位用个人空间"的组合（工兵 0.147 ✓ 在带内、全绿 ✓）。
		# 【第 52 轮·实验结论】"方向感知（单位 hull）+ 到达让位"组合**仍**会让 navigation-stability 转红 ✗
		# （12.6s，到达后仍被推动 ⇒ 订单不结束）⇒ 已回退 ✓。
		# 说明：瓶颈是**推出层与到达判定在同一帧的互相拉扯** ✓，不是让位阈值能解决的 ✓
		# ⇒ 下一步须改"到达判定的口径"（例如到达时冻结推出），而不是继续收 stand_off ✓。
		# 【第 53 轮·实验结论】"到达后冻结推出（让位 2.0m）+ 方向感知"**仍**让 navigation-stability 转红 ✗
		# ⇒ 该耦合**不是距离参数能解决的** ✓（0.6m 与 2.0m 都试过 ✗）⇒ 需改**到达判定本身**（与推出解耦）✓。
		var shaped_stand_off: float = maxf(own_radius, vis47) + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M
		var shaped_ok: bool = bool(fp47.get("ok", false))
		if _push_trace_on:
			print("[PUSH-SHAPE] obstacle=%s r=%.2f own=%.2f vis=%.2f 圆形so=%.2f 贴形so=%.2f 贴形closest=(%.2f,%.2f) ok=%s" % [
				str(obstacle.name), float(obstacle_radius), own_radius, vis47, physical_min, shaped_stand_off,
				shaped_closest.x, shaped_closest.y, str(fp47.get("kind", "?"))])
		# 【第 48 轮·正式启用贴形】stand_off 从**障碍表面**起算 = max(单位个人空间, 单位视觉 hull) + 余量 − 补偿
		# （D2 要求取 max(碰撞形状, 近地视觉 hull) —— 对象是**单位**自己 ✗ 不是障碍 ✓）。
		var stand_off: float = maxf(
			physical_min + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M,
			physical_min
		)
		if shaped_ok:
			closest = shaped_closest
			stand_off = maxf(shaped_stand_off, own_radius * 0.0)
		var step_distance: float = planar.distance_to(closest)
		if _push_trace_on:
			print("[PUSH] unit=%s obstacle=%s r=%.2f own=%.2f stand_off=%.2f step_d=%.2f escape=%s" % [
				_unit.name, str(obstacle.name), float(obstacle_radius), own_radius, stand_off, step_distance, str(allow_escape)])
		if step_distance >= stand_off:
			continue
		if allow_escape:
			# The original distance gate also preceded escape handling. Only
			# query the current footprint if this obstacle can actually push.
			if shaped_ok:
				var current_fp := _obstacle_footprint_closest(obstacle, unit_planar)
				current_shape_inside = bool(current_fp.get("inside", false))
			# 脱困时允许沿障碍外侧离开，但不能把目标在障碍外误当成穿墙许可。
			# 如果当前位置或候选落点已进入真实形状，先推出到最近边界；只有
			# 两者都在形状外时才要求这一步不能继续向障碍中心靠近。
			if not shaped_inside and not current_shape_inside:
				var current_distance: float = unit_planar.distance_to(closest)
				if step_distance >= current_distance:
					continue
		var outward := unit_planar - closest
		if shaped_inside or current_shape_inside:
			# closest→unit 在 inside 情况下指向盒内，取反才是安全推出方向。
			outward = closest - unit_planar
		if outward.length() < 0.001:
			outward = planar - closest
		if outward.length() < 0.001:
			outward = Vector2.RIGHT
		planar = closest + outward.normalized() * stand_off
	return Vector3(planar.x, point.y, planar.y)


func stop():
	_flow_restore_soft_radius("stop")
	target_position = Vector3.INF
	_committed_target = null
	_raw_target = null
	_progress_reference_distance = INF
	_is_tactical_withdrawal = false
	_abort_recovery()
	_reset_stability_state()
	_clear_logic_path()
	_logic_repath_attempts = 0
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
	if _skip_navigation_server():
		_detach_navigation_agent()
		set_physics_process(true)
		return
	avoidance_enabled = true
	set_physics_process(true)


## 温柔避障：只躲近处邻居并提前让行，避免大部队互相顶牛打转（2026-09-02 调参）。
func _apply_crowd_avoidance_defaults():
	if _skip_navigation_server():
		avoidance_enabled = false
		return
	avoidance_enabled = true
	# 【2026-09-30 A/B 结论：不要把 neighbor_distance 按半径放大】曾试过
	# max(3.0, radius*2+1.5)（半径 2.0 → 5.5m，理由是"接触距离已达 4.0m"）：
	# n=200 对向交叉反而更慢（200.7s vs 对照 160.2s），提前让行把路口堵死。已回退。
	# 两次负面 A/B（stall 迟滞、避让感知）都指向同一结论：瓶颈不在脱困/避让参数，
	# 而在密集双向流的通行能力本身。
	if neighbor_distance < 1.0:
		neighbor_distance = 3.0
	if max_neighbors < 8:
		max_neighbors = 16
	if time_horizon_agents < 1.0:
		time_horizon_agents = 4.5
	# 【流交互/量纲一致性，默认不生效】只在实验开关打开时改写感知半径：
	# 期望速度按 m/s 下发时，感知半径必须覆盖 速度×time_horizon，否则 RVO 的
	# 时间视野形同虚设（场景默认 3.0m 只够"贴身接触求解"）。
	if flow_neighbor_m > 0.0:
		neighbor_distance = maxf(flow_neighbor_m, neighbor_distance)
	elif (flow_mode & FLOW_BIT_VEL_UNITS) != 0:
		neighbor_distance = maxf(neighbor_distance, speed * time_horizon_agents)
	if flow_max_neighbors > 0:
		max_neighbors = maxi(flow_max_neighbors, max_neighbors)


## 等待运行时 NavMesh 出现可用 Region 后再对齐单位，避免空中地图异步烘焙竞态。
func _align_unit_position_to_navigation() -> bool:
	if domain == Constants.Match.Navigation.Domain.AIR:
		_snap_air_height()
		return true
	if _skip_navigation_server():
		_snap_logic_height()
		return true
	var navigation_map := get_navigation_map()
	var source_position: Vector3 = get_parent().global_transform.origin
	for _frame in range(NAVIGATION_ALIGNMENT_MAX_FRAMES):
		await get_tree().process_frame
		var closest_point_owner := NavigationServer3D.map_get_closest_point_owner(
			navigation_map, source_position
		)
		if not closest_point_owner.is_valid():
			continue
		var closest := NavigationServer3D.map_get_closest_point(navigation_map, source_position)
		# 空网格最近点常是原点。生成图若误走 Recast，会把所有新单位吸到左上角。
		if Vector2(closest.x, closest.z).length() < 0.75 \
				and Vector2(source_position.x, source_position.z).length() > 8.0:
			_snap_logic_height()
			return true
		# 2026-09-21 用户报"单位浮空"根因修复：Recast 体素量化会把可走面抬到
		# 碰撞体顶面之上（实测本图参数 cell_height=0.6/agent_height=1.8/agent_radius=0.9
		# 下，可视地面 y=0 的平地图烘出的网格面恒在 y=1.2），场景里写死的
		# path_height_offset=0.6 只补得了一半 ⇒ 单位连同选中圈一起悬空 0.6m。
		# 且该偏移随烘焙 AABB 与引擎版本漂移（同参数实测 +1.0~+1.2），不能写死。
		# 这里按"网格面 - 真实地表"实测当前偏移并写回代理：寻路平面、目标点、
		# 路径点随之全部落到真实地表，可达/到达判定保持同一平面（2026-09-11 踩过
		# "目标点 Y 与运动平面不一致 ⇒ is_target_reachable 恒 false"的坑）。
		# ⚠ 不能改成"只把单位按到地面"：代理的路径点仍浮在旧平面上，3D 距离下
		# 航点永远推进不了，实测 MovementRecovery 假红 10+ 条（假 Unreachable）。
		_calibrate_path_height_offset(closest)
		var _b3: Vector3 = _unit.global_transform.origin
		_unit.global_transform.origin = (
			closest - Vector3(0, path_height_offset, 0)
		)
		_pos_trace("ALIGN-navmesh", _b3, _unit.global_transform.origin)
		_unit.reset_physics_interpolation()  # 对齐吸附是瞬移，防插值拖影
		return true
	push_warning("Navigation alignment timed out for %s; preserving authored position" % _unit.name)
	return false


## 某 XZ 处的真实地表高度（射线/高度场）；取不到时退回归一化运动平面，
## 保持与 NavigationAgent3D 的 path_height_offset 约定一致。
func _ground_height_at(at: Vector3) -> float:
	if _match != null and _match.has_method("ground_height_at"):
		return float(_match.ground_height_at(at))
	return at.y - path_height_offset


## 按实测的"网格面 - 真实地表"偏移校正 path_height_offset，让 NavigationAgent3D 的
## 寻路平面（路径点/目标点/到达判定）落在真实地表上。只在能测到正偏移时改写；
## 测不到（射线打空等）保持场景配置值，行为与修复前一致。
func _calibrate_path_height_offset(navmesh_point: Vector3) -> void:
	var ground_y := _ground_height_at(navmesh_point)
	var measured: float = navmesh_point.y - ground_y
	if measured > 0.05:
		path_height_offset = measured


## 非阻塞完成导航对齐，并恢复初始化期间收到的最后一个显式移动目标。
func _finish_navigation_initialization():
	await _align_unit_position_to_navigation()
	_navigation_initialized = true
	if _pending_target != null:
		target_position = _pending_target
		_pending_target = null
		if _uses_logic_terrain_move():
			_request_logic_path()
		return
	# 大图空网格上不要再发开局散布：那会立刻触发 C++ 代理每帧查路。
	if _skip_navigation_server() or _skip_initial_dispersion:
		return
	move(
		(
			_unit.global_position
			+ Vector3(randf(), 0, randf()).normalized() * INITIAL_DISPERSION_FACTOR
		)
	)


func _is_moving_actively():
	if _skip_navigation_server():
		return _committed_target != null
	return get_next_path_position() != _unit.global_position


# --- 停滞检测（按实际位移，错峰 0.5s）---

## 每个 Movement 节点独立计时；首次检测的相位按实例 id 打散，
## 避免数百单位在同一帧集中做判断/重寻路。
func _update_recovery(delta: float) -> void:
	diag_bump("recovery")
	# 冷却必须在任何 early-return 之前推进，否则停止/无目标期间冷却会永远冻结。
	if _soft_phase_cooldown > 0.0:
		_soft_phase_cooldown = maxf(0.0, _soft_phase_cooldown - delta)
	if _narrow_pass_cooldown > 0.0:
		_narrow_pass_cooldown = maxf(0.0, _narrow_pass_cooldown - delta)
	if _structure_pass_cooldown > 0.0:
		_structure_pass_cooldown = maxf(0.0, _structure_pass_cooldown - delta)
	_update_gap_pass(delta)
	if _committed_target == null:
		_exit_narrow_pass("no_target")
		_exit_structure_pass("no_target")
		_stall_anchor_valid = false
		return
	if _gap_pass_active or _gap_waiting:
		# 排队或穿模期间不算停滞，也不把原订单判成不可达。
		_exit_soft_phase("gap")
		_exit_narrow_pass("gap")
		_exit_structure_pass("gap")
		_recovery_mode = ""
		_recovery_timer = 0.0
		_no_progress_since_msec = Time.get_ticks_msec()
		_stall_windows = 0
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
	# 直线距离变近，或导航路径真的被吃掉（绕路时直线距离会先变大）。
	# 硬上限只认路径：剩余长度缩短，或同一段路径上航点前进且人确实走了。
	var distance := _planar_distance_to(_committed_target)
	var path_index := get_current_navigation_path_index()
	var path_sample := _sample_path_progress()
	if path_sample > 0:
		_no_progress_give_ups = 0
		_no_progress_since_msec = Time.get_ticks_msec()
	elif path_sample < 0:
		# 重寻路/网格未就绪：这一拍不累计硬上限，但直线距离和脱困仍按原逻辑走。
		_no_progress_since_msec = Time.get_ticks_msec()
	elif _path_stuck_elapsed_s() >= GIVE_UP_NO_PROGRESS_SECONDS:
		recovery_stats["give_up_limit"] += 1
		print("[MOV][放弃上限] %s 路径 %.0fs 无消耗，判 Unreachable" % [
			_unit.name, GIVE_UP_NO_PROGRESS_SECONDS])
		_fail_as_unreachable()
		return
	if (
		distance <= _progress_reference_distance - _stall_min_progress_m()
		or path_index > _last_path_index
		or path_sample > 0
	):
		_progress_reference_distance = minf(_progress_reference_distance, distance)
		_last_path_index = path_index
		_stall_windows = 0
		_recovery_rounds = 0
		if path_sample > 0:
			_give_up_resets = 0
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
	if _skip_navigation_server():
		return
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
	_path_repath_pending = true
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
	_path_repath_pending = true
	recovery_stats["stall_detections"] += 1
	_stall_anchor_valid = false
	_recovery_mode = "repath"
	_recovery_timer = RECOVERY_REPATH_SETTLE_S
	# 导航网格刚重烘后路径可能陈旧；对同一目标重新查询即可自愈。
	target_position = _committed_target
	recovery_stats["repaths"] += 1


func _advance_recovery() -> void:
	if _recovery_mode == "narrow_pass":
		# 静态窄口窗口结束：还原个人空间后继续原任务。
		_exit_narrow_pass("timeout")
		_finish_recovery_cycle()
		return
	if _recovery_mode == "soft_phase":
		# 受限软穿行窗口结束：先还原半径，再回到原任务继续推进。
		_exit_soft_phase("timeout")
		_finish_recovery_cycle()
		return
	if _recovery_mode == "structure_pass":
		_exit_structure_pass("timeout")
		_finish_recovery_cycle()
		return
	if _recovery_mode == "repath":
		# 第一优先级是“真实形状能通过”的静态窄口；它不要求附近有友军，
		# 但必须已经经过停滞确认，且不能把敌方当成可穿过的障碍。
		if _try_narrow_pass():
			return
		if _try_structure_pass():
			return
		# 第一轮优先沿用常规侧移/后退（改动最小、对非拥堵场景零影响）；
		# 上一轮已经试过常规脱困仍无进展（`_recovery_rounds >= 1`）才允许受限软穿行。
		if _recovery_rounds >= 1 and _try_soft_phase():
			return
		# 【口袋逃逸 ✓】已确认停滞（本函数只在 _begin_recovery 之后的 repath 阶段进入 ✓），
		# 且单位明显不在导航面上 ⇒ 常规侧移/软穿行都到不了 ⇒ 直接朝最近导航面点退出 ✓。
		var pocket: Variant = _pocket_escape_target()
		if pocket != null:
			_recovery_mode = "escape"
			_recovery_escape_target = pocket
			_recovery_timer = RECOVERY_ESCAPE_DURATION_S
			target_position = pocket
			recovery_stats["pocket_escapes"] += 1
			return
		var escape: Variant = _pick_escape_target()
		if escape != null:
			_recovery_mode = "escape"
			_recovery_escape_target = escape
			_recovery_timer = RECOVERY_ESCAPE_DURATION_S
			target_position = escape
			recovery_stats["escapes"] += 1
			return
		# 连侧移候选都没有（候选落在网格外/障碍里）时，也允许软穿行兜底。
		if _try_soft_phase():
			return
		_finish_recovery_cycle()
		return
	# 侧移阶段结束 → 回到原任务目标继续推进。
	_finish_recovery_cycle()


## 一轮脱困结束（重寻路 + 侧移都试过）→ 回到原任务目标并累计轮数。
func _finish_recovery_cycle() -> void:
	# 兜底还原：任何路径结束脱困周期时都不允许留下"缩小半径"的状态。
	_exit_soft_phase("cycle")
	_exit_narrow_pass("cycle")
	_exit_structure_pass("cycle")
	_recovery_mode = ""
	_recovery_escape_target = Vector3.INF
	_stall_anchor_valid = false
	_recovery_rounds += 1
	if _committed_target != null:
		target_position = _committed_target


## 取消进行中的脱困并回到任务目标（新命令/停止/新目标时调用）。
func _abort_recovery() -> void:
	# 新命令/停止/换目标 = 软穿行必须立刻退出（不能让短时窗口跨命令存在）。
	_release_gap_pass("abort")
	_exit_soft_phase("abort")
	_exit_narrow_pass("abort")
	_exit_structure_pass("abort")
	_recovery_mode = ""
	_recovery_escape_target = Vector3.INF
	_recovery_timer = 0.0
	_recovery_rounds = 0
	_give_up_resets = 0
	_stall_anchor_valid = false
	_stall_windows = 0


func _reset_path_progress_clock() -> void:
	_path_repath_pending = false
	_path_baseline_pending = true
	_path_tracked_index = 0
	_path_tracked_remaining = INF
	_path_tracked_position = Vector2(_unit.global_position.x, _unit.global_position.z)
	_no_progress_give_ups = 0
	_no_progress_since_msec = Time.get_ticks_msec()


func _path_stuck_elapsed_s() -> float:
	if _no_progress_since_msec <= 0:
		_no_progress_since_msec = Time.get_ticks_msec()
		return 0.0
	return float(Time.get_ticks_msec() - _no_progress_since_msec) / 1000.0


## 1 = 这条路径被吃掉了；0 = 没吃掉；-1 = 重寻路后的基线拍，本窗口不记停滞。
## 大图不走导航服务时返回 0，硬上限在调用处另行跳过。
func _sample_path_progress() -> int:
	if _skip_navigation_server():
		return 0
	var path := get_current_navigation_path()
	if path.is_empty():
		return -1
	var index := get_current_navigation_path_index()
	var remain := _remaining_path_length(path, index)
	var here := Vector2(_unit.global_position.x, _unit.global_position.z)
	if _path_repath_pending or index < _path_tracked_index:
		_path_repath_pending = false
		_path_baseline_pending = true
		_path_tracked_index = index
		_path_tracked_remaining = remain
		_path_tracked_position = here
		return -1
	if _path_baseline_pending:
		_path_baseline_pending = false
		_path_tracked_index = index
		_path_tracked_remaining = remain
		_path_tracked_position = here
		return -1
	var progressed := false
	var moved := here.distance_to(_path_tracked_position)
	if index > _path_tracked_index and moved >= _stall_min_progress_m():
		_path_tracked_index = index
		progressed = true
	if remain < _path_tracked_remaining - _stall_min_progress_m():
		_path_tracked_remaining = remain
		progressed = true
	if progressed:
		_path_tracked_position = here
	return 1 if progressed else 0


func _remaining_path_length(path: PackedVector3Array, index: int) -> float:
	var total := 0.0
	var prev := _unit.global_position
	var start := clampi(index, 0, path.size())
	for i in range(start, path.size()):
		var point: Vector3 = path[i]
		total += Vector2(point.x - prev.x, point.z - prev.z).length()
		prev = point
	return total


## 脱困轮数用尽时的收敛判定：
##   - 已经贴到"力所能及"的位置 → Arrived（等价原 clamp 的贴边语义）；
##   - 导航层面确实不可达 → Unreachable（合理失败）；
##   - 目标可达、只是被拥堵反复拖住 → 不清空任务，重置轮数继续努力。
## 关键：**只有真实不可达才判失败**。实测过按"离目标还有多远"判失败会在
## 大部队交叉拥堵时产生假 Unreachable，玩家会看到莫名其妙的失败提示。
func _give_up_commitment() -> void:
	if _committed_target == null:
		return
	# 2026-09-27：接受半径随单位半径放大（原 2.5m 是为 0.9m 半径单位定的）。
	var accept_radius: float = maxf(float(radius), 0.5) + maxf(
		RECOVERY_ACCEPT_RADIUS_M, float(radius) * 2.0 + 0.5
	)
	if _planar_distance_to(_committed_target) <= accept_radius:
		_emit_committed_end("Arrived")
		return
	if not is_target_reachable():
		_fail_as_unreachable()
		return
	# 直线距离变远不再单独判死。只有导航剩余路径和航点都不前进，才累计硬上限。
	_no_progress_give_ups += 1
	_give_up_resets += 1
	recovery_stats["give_up_resets"] += 1
	if (
		_no_progress_give_ups >= GIVE_UP_MAX_RESETS
		or _path_stuck_elapsed_s() >= GIVE_UP_NO_PROGRESS_SECONDS
	):
		recovery_stats["give_up_limit"] += 1
		print("[MOV][放弃上限] %s 路径无进展 %d 轮 / %.1fs，判 Unreachable：位置=(%.2f,%.2f) 距目标 %.2fm" % [
			_unit.name, _no_progress_give_ups, _path_stuck_elapsed_s(),
			_unit.global_position.x, _unit.global_position.z,
			_planar_distance_to(_committed_target)])
		_fail_as_unreachable()
		return
	_recovery_rounds = 0


## 选取一个落在导航网格上的合法脱困候选点：优先两侧中净空更好的一侧，其次后退。
## 只在网格外或吸附误差过大时丢弃候选，不做穿墙/瞬移。
## 返回逃生目标位置；无法逃生时返回 null（所以返回类型是 Variant 而不是 Vector3）。
## 必须显式标注：调用处用 `var escape: Variant = ...`，未标注时 GDScript 会因
## "null 字面量没有静态类型" 而整份脚本解析失败。
## 单位是否站在"无导航面的口袋"里：离最近导航面的平面距离 > POCKET_OFF_MESH_MIN_M ✓
## ⇒ 返回该最近点（保持单位当前高度 ✓）作为**确定性退出目标**；否则返回 null ✓。
## 只在脱困（已确认停滞）阶段被调用 ✓，正常移动帧零开销 ✓。
func _pocket_escape_target() -> Variant:
	if not is_inside_tree():
		return null
	var here: Vector3 = _unit.global_position
	# Movement 是 trait（非 Node3D ✗）⇒ 世界必须从**单位**取 ✓（补丁首版在此处解析失败 ✗）。
	var map: RID = _unit.get_world_3d().navigation_map
	if not map.is_valid():
		return null
	var closest: Vector3 = NavigationServer3D.map_get_closest_point(map, here)
	# 导航图未就绪时会返回原点 ⇒ 防御性判空（本项目里踩过 ✓）。
	if closest == Vector3.ZERO and here.length() > 1.0:
		return null
	if Vector2(closest.x - here.x, closest.z - here.z).length() < POCKET_OFF_MESH_MIN_M:
		return null
	return Vector3(closest.x, here.y, closest.z)


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
			# Y 同样取真实地表：脱困候选点也要落在单位的站立平面上。
			best = _push_out_of_static_obstacles(
				Vector3(closest.x, _ground_height_at(closest), closest.z)
			)
	return best


## 窄通道准入：只在“包含圆会阻挡、真实形状仍有净空”时返回候选。
## 该函数只在恢复状态机调用，不进入正常移动帧，避免把 O(障碍数) 形状查询变成常态开销。
func _try_narrow_pass() -> bool:
	if not NARROW_PASS_ENABLED or _narrow_pass_saved_radius >= 0.0:
		recovery_stats["narrow_pass_rejects"] += 1
		return false
	if _narrow_pass_cooldown > 0.0 or _soft_phase_saved_radius >= 0.0 or _flow_soft_saved_radius >= 0.0 \
			or _structure_pass_saved_radius >= 0.0:
		recovery_stats["narrow_pass_rejects"] += 1
		return false
	if _committed_target == null or _uses_logic_terrain_move():
		recovery_stats["narrow_pass_rejects"] += 1
		return false
	var nearby := _nearby_unit_stats()
	if int(nearby.get("enemies", 0)) > 0:
		# 静态窄口可以贴形，但绝不允许借此穿过敌军。
		recovery_stats["narrow_pass_rejects"] += 1
		return false
	var candidate := _narrow_pass_candidate()
	if not bool(candidate.get("ok", false)):
		recovery_stats["narrow_pass_rejects"] += 1
		return false
	_begin_narrow_pass(candidate)
	return true


## 计算窄口候选。normal_* 是正常移动使用的视觉 hull 余量，physical_* 是真实
## CollisionShape3D 余量；只有同一个真实障碍脚印的前者阻挡、后者通过时才放行。
## 不能用“单位到建筑中心的圆距离”代替这里的判断：矩形建筑的角点会先于中心圆
## 触发推出，正是窄口误判的来源。
func _narrow_pass_candidate() -> Dictionary:
	var result := {"ok": false}
	var target := _committed_target as Vector3
	var to_target := Vector2(target.x - _unit.global_position.x, target.z - _unit.global_position.z)
	if to_target.length() < 0.05:
		return result
	var forward := to_target.normalized()
	var probe_distance := clampf(maxf(speed * _last_physics_delta, 0.25), 0.25, NARROW_PASS_MAX_PROBE_DISTANCE_M)
	var probe := Vector2(_unit.global_position.x, _unit.global_position.z) + forward * probe_distance
	var base_radius := maxf(float(radius), 0.05)
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(domain, "")
	if group_name.is_empty() or not is_inside_tree():
		return result
	var obstacles := get_tree().get_nodes_in_group(group_name)
	for obstacle in obstacles:
		if obstacle == _unit or not is_instance_valid(obstacle):
			continue
		var obstacle_radius_variant = obstacle.get("radius")
		if obstacle_radius_variant == null:
			continue
		var obstacle_radius := maxf(float(obstacle_radius_variant), 0.0)
		if obstacle_radius <= base_radius:
			continue
		var origin := Vector2(obstacle.global_position.x, obstacle.global_position.z)
		var circle_distance := probe.distance_to(origin)
		var circle_standoff := maxf(
			obstacle_radius + base_radius + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M,
			obstacle_radius + base_radius
		)
		if _narrow_trace_on and _narrow_trace_lines < 80:
			_narrow_trace_lines += 1
			print("[NARROW-TRACE] %s obs=%s pos=(%.2f,%.2f) probe=(%.2f,%.2f) circle=%.2f stand=%.2f base=%.2f" % [
				_unit.name, obstacle.name, _unit.global_position.x, _unit.global_position.z,
				probe.x, probe.y, circle_distance, circle_standoff, base_radius])
		var footprint := _obstacle_footprint_closest(obstacle, probe)
		if not bool(footprint.get("ok", false)):
			recovery_stats["narrow_pass_shape_fallbacks"] += 1
			continue
		if bool(footprint.get("inside", false)):
			if _narrow_trace_on and _narrow_trace_lines < 80:
				_narrow_trace_lines += 1
				print("[NARROW-TRACE] skip probe inside footprint kind=%s" % str(footprint.get("kind", "?")))
			continue
		var closest: Vector2 = footprint.get("closest", origin)
		var away := probe - closest
		if away.length_squared() < 0.0001:
			away = probe - origin
		if away.length_squared() < 0.0001:
			away = Vector2.RIGHT
		var physical_half := _unit_ground_half_extent(away.normalized(), false)
		var visual_half := _unit_ground_half_extent(away.normalized(), true)
		# 当前窄口合同针对矩形建筑角点。圆柱/胶囊/球的视觉包围差异不
		# 能证明存在“角点保守空气墙”，先走保守安全路径，避免在圆形建筑
		# 周边把普通贴边绕行误判为窄口。
		if not str(footprint.get("kind", "")).begins_with("Box"):
			if _narrow_trace_on and _narrow_trace_lines < 80:
				_narrow_trace_lines += 1
				print("[NARROW-TRACE] skip non-box narrow candidate kind=%s" % str(footprint.get("kind", "?")))
			continue
		var normal_required_radius := maxf(
			maxf(base_radius, visual_half) + OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M,
			base_radius
		)
		var required_radius := maxf(
			physical_half + NARROW_PASS_MIN_CLEARANCE_M,
			base_radius * NARROW_PASS_RADIUS_SCALE
		)
		var shape_distance := probe.distance_to(closest)
		if _narrow_trace_on and _narrow_trace_lines < 80:
			_narrow_trace_lines += 1
			print("[NARROW-TRACE] shape=%s closest=(%.2f,%.2f) dist=%.2f normal=%.2f physical=%.2f visual_half=%.2f physical_half=%.2f" % [
				str(footprint.get("kind", "?")), closest.x, closest.y, shape_distance,
				normal_required_radius, required_radius, visual_half, physical_half])
		# 同一个形状查询同时证明“正常层确实会把这一步推回去”。
		if shape_distance >= normal_required_radius:
			if _narrow_trace_on and _narrow_trace_lines < 80:
				_narrow_trace_lines += 1
				print("[NARROW-TRACE] skip normal clearance already sufficient")
			continue
		if shape_distance < required_radius:
			if _narrow_trace_on and _narrow_trace_lines < 80:
				_narrow_trace_lines += 1
				print("[NARROW-TRACE] skip shape clearance")
			continue
		# 只允许“确实因圆形保守量被挡”的候选，避免普通边缘移动频繁进入窄阶段。
		return {
			"ok": true,
			"obstacle": obstacle,
			"kind": str(footprint.get("kind", "shape")),
			"circle_distance": circle_distance,
			"circle_standoff": circle_standoff,
			"shape_distance": shape_distance,
			"required_radius": required_radius,
			"probe": probe,
		}
	return result


## 取单位真实地面碰撞形状沿方向的半宽，并用近地视觉 hull 兜底/补齐。
## 炮管、血条、选择圈和悬空部件由 _ground_hull_half_xz 的地面带过滤。
func _unit_ground_half_extent(direction: Vector2, include_visual: bool = true) -> float:
	var dir := direction.normalized()
	if dir.length_squared() < 0.0001:
		dir = Vector2.RIGHT
	var best := 0.0
	for child in _unit.find_children("*", "CollisionShape3D", true, false):
		var shape_node := child as CollisionShape3D
		if shape_node == null or shape_node.shape == null or shape_node.disabled:
			continue
		var basis := shape_node.global_transform.basis
		var shape_half := 0.0
		if shape_node.shape is BoxShape3D:
			var box := shape_node.shape as BoxShape3D
			shape_half = absf(basis.x.dot(Vector3(dir.x, 0.0, dir.y))) * box.size.x * 0.5
			shape_half += absf(basis.z.dot(Vector3(dir.x, 0.0, dir.y))) * box.size.z * 0.5
		elif shape_node.shape is CylinderShape3D:
			shape_half = maxf(basis.x.length(), basis.z.length()) * (shape_node.shape as CylinderShape3D).radius
		elif shape_node.shape is CapsuleShape3D:
			shape_half = maxf(basis.x.length(), basis.z.length()) * (shape_node.shape as CapsuleShape3D).radius
		elif shape_node.shape is SphereShape3D:
			shape_half = maxf(basis.x.length(), basis.z.length()) * (shape_node.shape as SphereShape3D).radius
		else:
			# 实际采用的未知形状不能静默当成零；视觉 hull 仍是保守兜底。
			push_warning("[Movement] 单位 %s 的地面形状 %s 未支持，窄口使用视觉 hull 兜底" % [
				_unit.name, shape_node.shape.get_class()])
			continue
		best = maxf(best, shape_half)
	if include_visual:
		var visual_half := _ground_hull_half_xz(_unit, dir)
		best = maxf(best, visual_half)
	return best


func _begin_narrow_pass(candidate: Dictionary) -> void:
	var base_radius := maxf(float(radius), 0.05)
	var required_radius := maxf(float(candidate.get("required_radius", base_radius)), 0.05)
	if required_radius >= base_radius - 0.01:
		recovery_stats["narrow_pass_rejects"] += 1
		return
	_narrow_pass_saved_radius = base_radius
	radius = required_radius
	_recovery_mode = "narrow_pass"
	_recovery_timer = NARROW_PASS_DURATION_S
	recovery_stats["narrow_pass_enters"] += 1
	print("[MOV][窄通道] %s 进入：%s 圆形 %.2f/%.2f 形状 %.2f 有效半径 %.2f→%.2f 历时=%.2fs" % [
		_unit.name, str(candidate.get("kind", "shape")),
		float(candidate.get("circle_distance", 0.0)), float(candidate.get("circle_standoff", 0.0)),
		float(candidate.get("shape_distance", 0.0)), base_radius, float(radius), NARROW_PASS_DURATION_S])


func _exit_narrow_pass(reason: String) -> void:
	if _narrow_pass_saved_radius < 0.0:
		return
	var restored := _narrow_pass_saved_radius
	radius = restored
	_narrow_pass_saved_radius = -1.0
	if _recovery_mode == "narrow_pass":
		_recovery_mode = ""
		_recovery_timer = 0.0
	_narrow_pass_cooldown = NARROW_PASS_COOLDOWN_S
	recovery_stats["narrow_pass_exits"] += 1
	print("[MOV][窄通道] %s 退出（%s）：半径还原 %.2f" % [_unit.name, reason, restored])


func _try_structure_pass() -> bool:
	if _gap_pass_active or _gap_waiting:
		return false
	if not structure_pass_enabled or _structure_pass_saved_radius >= 0.0 or _structure_pass_cooldown > 0.0:
		return false
	if _soft_phase_saved_radius >= 0.0 or _narrow_pass_saved_radius >= 0.0 or _flow_soft_saved_radius >= 0.0:
		return false
	if _committed_target == null or _uses_logic_terrain_move() or domain != Constants.Match.Navigation.Domain.TERRAIN:
		return false
	if float(radius) <= Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS + 0.01:
		return false
	if not _blocked_by_own_structure() or int(_nearby_unit_stats().get("enemies", 0)) > 0:
		recovery_stats["structure_pass_rejects"] += 1
		return false
	_structure_pass_saved_radius = float(radius)
	radius = Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS
	_recovery_mode = "structure_pass"
	_recovery_timer = STRUCTURE_PASS_DURATION_S
	recovery_stats["structure_pass_enters"] += 1
	print("[MOV][己方建筑脱困] %s 进入：半径 %.2f→%.2f 历时=%.2fs" % [
		_unit.name, _structure_pass_saved_radius, float(radius), STRUCTURE_PASS_DURATION_S])
	return true


## 推出层是否正被己方建筑顶住（且没有贴着敌方建筑）。只在脱困阶段调用。
func _blocked_by_own_structure() -> bool:
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(domain, "")
	if group_name.is_empty() or not is_inside_tree():
		return false
	var own_radius := maxf(float(radius), 0.0)
	var here := Vector2(_unit.global_position.x, _unit.global_position.z)
	var hull := _ground_hull_points_xz(_unit)
	var own_contact := false
	for obstacle in get_tree().get_nodes_in_group(group_name):
		if obstacle == _unit or not is_instance_valid(obstacle) or not bool(obstacle.get("affect_navigation_mesh")):
			continue
		var footprint := _obstacle_footprint_closest(obstacle, here)
		if not bool(footprint.get("ok", false)):
			continue
		var closest: Vector2 = footprint.get("closest", here)
		var away := here - closest
		var dir := away.normalized() if away.length() > 0.0001 else Vector2.RIGHT
		var stand_off := maxf(own_radius, _ground_hull_support(hull, dir)) \
			+ OBSTACLE_CLEARANCE_MARGIN_M - OBSTACLE_ARRIVAL_COMPENSATION_M
		var distance := 0.0 if bool(footprint.get("inside", false)) else away.length()
		if distance >= stand_off + STRUCTURE_PASS_CONTACT_SLACK_M:
			continue
		if not _is_own_structure_obstacle(obstacle):
			return false
		own_contact = true
	return own_contact


func _is_own_structure_obstacle(obstacle: Node) -> bool:
	var owner_unit := obstacle.get_parent()
	return owner_unit != null and owner_unit.get_parent() == _unit.get_parent() \
		and bool(obstacle.get("affect_navigation_mesh"))


func _exit_structure_pass(reason: String) -> void:
	if _structure_pass_saved_radius < 0.0:
		return
	radius = _structure_pass_saved_radius
	_structure_pass_saved_radius = -1.0
	if _recovery_mode == "structure_pass":
		_recovery_mode = ""
		_recovery_timer = 0.0
	_structure_pass_cooldown = STRUCTURE_PASS_COOLDOWN_S
	recovery_stats["structure_pass_exits"] += 1
	print("[MOV][己方建筑脱困] %s 退出（%s）：半径还原 %.2f" % [_unit.name, reason, float(radius)])


## 窄缝：直线要穿过两栋己方建筑之间、且正常站距过不去时，全局只放一辆车穿模。
## 穿过后还原推出。不忽略敌军、矿点或其它障碍。
func _update_gap_pass(delta: float) -> void:
	if _gap_pass_cooldown > 0.0:
		_gap_pass_cooldown = maxf(0.0, _gap_pass_cooldown - delta)
	if domain != Constants.Match.Navigation.Domain.TERRAIN:
		return
	if _unit == null or _committed_target == null:
		_release_gap_pass("no_target")
		return
	# 这一帧已经确认没有窄缝，且本单位不在穿模/排队里：结果与空缓存选缝相同。
	if (
		not _gap_pass_active
		and not _gap_waiting
		and _gap_empty_frame == Engine.get_physics_frames()
	):
		return
	_ensure_gap_thresholds()
	_refresh_gap_cache()
	if not _gap_pass_active and _gap_cache.is_empty():
		_gap_empty_frame = Engine.get_physics_frames()
		_gap_waiting = false
		_gap_wait_point = Vector3.INF
		return
	if _gap_pass_active:
		_gap_pass_timer -= delta
		var here := Vector2(_unit.global_position.x, _unit.global_position.z)
		var exit_xz := Vector2(_gap_pass_exit.x, _gap_pass_exit.z)
		if here.distance_to(exit_xz) <= maxf(target_desired_distance, 0.5):
			_release_gap_pass("crossed")
			return
		if _gap_pass_timer <= 0.0:
			_gap_pass_cooldown = GAP_PASS_COOLDOWN_S
			_release_gap_pass("timeout")
		return
	var chosen := _pick_blocking_gap()
	if chosen.is_empty():
		_gap_waiting = false
		_gap_wait_point = Vector3.INF
		return
	if _gap_pass_cooldown <= 0.0 and not _gap_pass_held_by_other():
		_begin_gap_pass(chosen)
		return
	_set_gap_wait(chosen)


func _ensure_gap_thresholds() -> void:
	if _gap_seal_m > 0.0 and _gap_clear_m > 0.0:
		return
	_gap_seal_m = GAP_PASS_SEAL_FALLBACK_M
	_gap_clear_m = GAP_PASS_CLEAR_FALLBACK_M
	if _match == null:
		return
	var runtime := _match.get_node_or_null("StructurePlacementRuntime")
	if runtime != null and runtime.has_method("StructureSealGapMeters"):
		_gap_seal_m = float(runtime.call("StructureSealGapMeters"))
		_gap_clear_m = float(runtime.call("StructurePassGapMeters"))


func _gap_blocks_unit(gap: float) -> bool:
	# 身体过不去，或缝窄到导航面断开（Seal）。最宽单位的上限是 Pass。
	var body := 2.0 * maxf(float(radius), 0.05) + 0.1
	var limit := maxf(_gap_seal_m, minf(_gap_clear_m, body))
	return gap > 0.05 and gap < limit - 0.001


func _refresh_gap_cache() -> void:
	var frame := Engine.get_physics_frames()
	if _gap_cache_frame == frame:
		return
	_gap_cache_frame = frame
	_gap_cache.clear()
	if not is_inside_tree():
		return
	var group_name: String = Constants.Match.Navigation.DOMAIN_TO_OBSTACLE_GROUP_MAPPING.get(
		Constants.Match.Navigation.Domain.TERRAIN, "")
	if group_name.is_empty():
		return
	var structures: Array = []
	for obstacle in get_tree().get_nodes_in_group(group_name):
		if _is_structure_obstacle(obstacle):
			structures.append(obstacle)
	var count := structures.size()
	for i in count:
		var left: Node = structures[i]
		var left_radius := float(left.get("radius"))
		var left_xz := Vector2(left.global_position.x, left.global_position.z)
		for j in range(i + 1, count):
			var right: Node = structures[j]
			var right_xz := Vector2(right.global_position.x, right.global_position.z)
			var reach := left_radius + float(right.get("radius")) + _gap_clear_m + 1.0
			if left_xz.distance_to(right_xz) > reach:
				continue
			var measured := _structure_surface_gap(left, right)
			if measured.is_empty():
				continue
			var gap := float(measured["gap"])
			if gap <= 0.05 or gap >= _gap_clear_m:
				continue
			_gap_cache.append({
				"a": int(left.get_instance_id()),
				"b": int(right.get_instance_id()),
				"pa": measured["pa"],
				"pb": measured["pb"],
				"gap": gap,
			})


func _is_structure_obstacle(obstacle: Node) -> bool:
	if not is_instance_valid(obstacle) or not bool(obstacle.get("affect_navigation_mesh")):
		return false
	var owner_unit := obstacle.get_parent()
	if owner_unit == null or not owner_unit.is_in_group("units"):
		return false
	# 会自己走的单位不是缝的墙。矿点不挖导航，进不了这条。
	return owner_unit.find_child("Movement", false, false) == null


func _structure_surface_gap(left: Node, right: Node) -> Dictionary:
	var left_xz := Vector2(left.global_position.x, left.global_position.z)
	var right_xz := Vector2(right.global_position.x, right.global_position.z)
	var toward_right := _obstacle_footprint_closest(left, right_xz)
	var toward_left := _obstacle_footprint_closest(right, left_xz)
	if not bool(toward_right.get("ok", false)) or not bool(toward_left.get("ok", false)):
		return {}
	if bool(toward_right.get("inside", false)) or bool(toward_left.get("inside", false)):
		return {}
	var pa: Vector2 = toward_right.get("closest", left_xz)
	var pb: Vector2 = toward_left.get("closest", right_xz)
	return {"pa": pa, "pb": pb, "gap": pa.distance_to(pb)}


func _pick_blocking_gap() -> Dictionary:
	var here := Vector2(_unit.global_position.x, _unit.global_position.z)
	var goal := Vector2(_committed_target.x, _committed_target.z)
	var best := {}
	var best_distance := GAP_PASS_ENGAGE_M
	for entry in _gap_cache:
		if not _gap_blocks_unit(float(entry["gap"])):
			continue
		var left := instance_from_id(int(entry["a"]))
		var right := instance_from_id(int(entry["b"]))
		if left == null or right == null:
			continue
		if not is_instance_valid(left) or not is_instance_valid(right):
			continue
		if not _is_own_structure_obstacle(left) or not _is_own_structure_obstacle(right):
			continue
		var pa: Vector2 = entry["pa"]
		var pb: Vector2 = entry["pb"]
		var mouth := _distance_to_segment(here, pa, pb)
		if mouth > GAP_PASS_ENGAGE_M:
			continue
		if not _segment_wants_gap(here, goal, pa, pb):
			continue
		if mouth < best_distance:
			best_distance = mouth
			best = entry
	return best


func _segment_wants_gap(here: Vector2, goal: Vector2, pa: Vector2, pb: Vector2) -> bool:
	if _segments_intersect(here, goal, pa, pb):
		return true
	if _distance_to_segment(here, pa, pb) > GAP_PASS_MOUTH_M:
		return false
	var side := (pb - pa).cross(goal - pa)
	return absf(side) > 0.05


func _segments_intersect(p: Vector2, q: Vector2, a: Vector2, b: Vector2) -> bool:
	var d1 := (q - p).cross(a - p)
	var d2 := (q - p).cross(b - p)
	var d3 := (b - a).cross(p - a)
	var d4 := (b - a).cross(q - a)
	return d1 * d2 < 0.0 and d3 * d4 < 0.0


func _distance_to_segment(point: Vector2, start: Vector2, end: Vector2) -> float:
	var edge := end - start
	var length_squared := edge.length_squared()
	if length_squared < 0.00000001:
		return point.distance_to(start)
	var t := clampf((point - start).dot(edge) / length_squared, 0.0, 1.0)
	return point.distance_to(start + edge * t)


func _gap_pass_held_by_other() -> bool:
	if _gap_pass_owner == 0 or _gap_pass_owner == get_instance_id():
		if _gap_pass_owner == get_instance_id() and not _gap_pass_active:
			_gap_pass_owner = 0
		return false
	var holder = instance_from_id(_gap_pass_owner)
	if holder == null or not is_instance_valid(holder) or not bool(holder.get("_gap_pass_active")):
		_gap_pass_owner = 0
		return false
	return true


func _begin_gap_pass(entry: Dictionary) -> void:
	var here := Vector2(_unit.global_position.x, _unit.global_position.z)
	var goal := Vector2(_committed_target.x, _committed_target.z)
	var pa: Vector2 = entry["pa"]
	var pb: Vector2 = entry["pb"]
	var mid := (pa + pb) * 0.5
	var travel := goal - mid
	if travel.length() < 0.001:
		travel = here - mid
	if travel.length() < 0.001:
		travel = Vector2.RIGHT
	travel = travel.normalized()
	var past := float(entry["gap"]) * 0.5 + maxf(float(radius), 0.05) + 0.4
	var exit_xz := mid + travel * past
	if mid.distance_to(goal) <= past:
		exit_xz = goal
	_gap_pass_owner = get_instance_id()
	_gap_pass_active = true
	_gap_waiting = false
	_gap_wait_point = Vector3.INF
	_gap_pass_ids = [int(entry["a"]), int(entry["b"])]
	_gap_pass_exit = Vector3(exit_xz.x, _unit.global_position.y, exit_xz.y)
	_gap_pass_timer = GAP_PASS_TIMEOUT_S
	recovery_stats["gap_pass_enters"] += 1
	print("[MOV][窄缝穿模] %s 取得通行证：间隙 %.2f 米，%.0f 秒内须穿过" % [
		_unit.name, float(entry["gap"]), GAP_PASS_TIMEOUT_S])


func _set_gap_wait(entry: Dictionary) -> void:
	var here := Vector2(_unit.global_position.x, _unit.global_position.z)
	var pa: Vector2 = entry["pa"]
	var pb: Vector2 = entry["pb"]
	var mid := (pa + pb) * 0.5
	var away := here - mid
	if away.length() < 0.001:
		away = Vector2.RIGHT
	away = away.normalized()
	var back := float(entry["gap"]) * 0.5 + maxf(float(radius), 0.05) + 0.4
	var wait := mid + away * back
	var starting := not _gap_waiting
	_gap_waiting = true
	_gap_wait_point = Vector3(wait.x, _unit.global_position.y, wait.y)
	if starting:
		recovery_stats["gap_pass_waits"] += 1
		print("[MOV][窄缝穿模] %s 在缝外等待，通行证已被占用" % _unit.name)


func _release_gap_pass(reason: String) -> void:
	var holding := _gap_pass_active
	_gap_pass_active = false
	_gap_waiting = false
	_gap_pass_ids.clear()
	_gap_pass_exit = Vector3.INF
	_gap_wait_point = Vector3.INF
	_gap_pass_timer = 0.0
	if _gap_pass_owner == get_instance_id():
		_gap_pass_owner = 0
	if holding:
		recovery_stats["gap_pass_exits"] += 1
		var who: String = str(_unit.name) if _unit != null else "?"
		print("[MOV][窄缝穿模] %s 交还通行证（%s），推出已恢复" % [who, reason])


## 受限软穿行的准入判定（返回 true = 已进入，脱困周期交给软穿行窗口）。
## 只做事实判定，不做"看不见的放宽"：任何一条不变式不满足都计数拒绝。
func _try_soft_phase() -> bool:
	if not SOFT_PHASE_ENABLED:
		return false
	if _soft_phase_saved_radius >= 0.0 or _soft_phase_cooldown > 0.0 or _structure_pass_saved_radius >= 0.0:
		recovery_stats["soft_phase_rejects"] += 1
		return false
	var stats := _nearby_unit_stats()
	if int(stats["friends"]) < SOFT_PHASE_MIN_FRIENDS or int(stats["enemies"]) > 0:
		recovery_stats["soft_phase_rejects"] += 1
		return false
	_begin_soft_phase(stats)
	return true


## 统计贴身范围内的友军/敌军数量（只在脱困时调用，频率极低）。
## 友军口径 = 同 parent（同阵营）+ 有 Movement 子节点（可机动）+ 同移动域；
## 敌军口径 = 任意其它阵营单位进入 `SOFT_PHASE_ENEMY_CLEAR_M` 即计数（>0 就不启用）。
func _nearby_unit_stats() -> Dictionary:
	diag_bump("nearby")
	var friends: int = 0
	var enemies: int = 0
	var here: Vector3 = _unit.global_position
	for other in get_tree().get_nodes_in_group("units"):
		if other == _unit or not is_instance_valid(other):
			continue
		var other_3d := other as Node3D
		if other_3d == null:
			continue
		var distance: float = here.distance_to(other_3d.global_position)
		if other_3d.get_parent() != _unit.get_parent():
			if distance <= _soft_phase_enemy_clear_m():
				enemies += 1
			continue
		if distance > _soft_phase_friend_gap_m():
			continue
		var other_movement := other_3d.find_child("Movement", false, false)
		if other_movement == null or other_movement.get("domain") != domain:
			continue
		friends += 1
	return {"friends": friends, "enemies": enemies}


## 进入受限软穿行：只把**自身**半径缩到 `SOFT_PHASE_RADIUS_SCALE`，
## 避开窗口结束后由 `_exit_soft_phase` 还原（不变式见文件头部 `SOFT_PHASE_*`）。
func _begin_soft_phase(stats: Dictionary) -> void:
	var base_radius: float = maxf(float(radius), 0.05)
	_soft_phase_saved_radius = base_radius
	radius = maxf(0.05, base_radius * SOFT_PHASE_RADIUS_SCALE)
	_recovery_mode = "soft_phase"
	_recovery_timer = SOFT_PHASE_DURATION_S
	recovery_stats["soft_phase_enters"] += 1
	print("[MOV][软穿行] %s 进入：友军贴身=%d 敌军近处=%d 半径 %.2f→%.2f 历时=%.2fs"
		% [_unit.name, int(stats.get("friends", 0)), int(stats.get("enemies", 0)),
		   base_radius, float(radius), SOFT_PHASE_DURATION_S])


## 退出受限软穿行并**还原半径**（幂等：不在软穿行时什么都不做）。
func _exit_soft_phase(reason: String) -> void:
	if _soft_phase_saved_radius < 0.0:
		return
	radius = _soft_phase_saved_radius
	_soft_phase_saved_radius = -1.0
	if _recovery_mode == "soft_phase":
		_recovery_mode = ""
	_recovery_timer = 0.0
	_soft_phase_cooldown = SOFT_PHASE_COOLDOWN_S
	recovery_stats["soft_phase_exits"] += 1
	print("[MOV][软穿行] %s 退出（%s）：半径还原 %.2f" % [_unit.name, reason, float(radius)])


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


func _rotate_in_direction(direction: Vector3) -> void:
	if ROTATION_LOW_PASS_FILTER_ENABLED:
		direction = _get_filtered_rotation_direction(direction)
	if is_zero_approx(direction.length()):
		return
	# 平滑转向：按单位类型注入的最大角速度逐步逼近目标朝向，
	# 消除 looking_at 瞬时掉头（含 180° 调头/倒车切换）造成的视觉跳变。
	# 显式 float：经未类型化节点链取值在此上下文返回 Variant，:= 无法推断类型。
	var turn_speed: float = maxf(max_turn_speed_deg_per_sec, 1.0)
	var target_yaw: float = atan2(-direction.x, -direction.z)
	var _agg_eu := 0
	if _diag_cached == 1:
		_agg_eu = Time.get_ticks_usec()
	var current_yaw: float = _unit.global_transform.basis.get_euler().y
	if _diag_cached == 1:
		agg_euler_us += int(Time.get_ticks_usec() - _agg_eu)
	var yaw_diff: float = angle_difference(current_yaw, target_yaw)
	if absf(yaw_diff) < 0.01:
		return
	var max_step: float = deg_to_rad(turn_speed) * _last_physics_delta
	var new_yaw: float = current_yaw + clampf(yaw_diff, -max_step, max_step)
	# 朝向必须单独写入。和位移合成同一次 global_transform 时，
	# 物理插值只记下原点，飞机和地面单位都会保持出生朝向滑行。
	# 纯旋转基会把根缩放写成 1；插值再从旧缩放混过去时，网格会缩没。
	var kept_scale: Vector3 = _unit.global_transform.basis.get_scale()
	if not kept_scale.is_finite() or kept_scale.length_squared() < 0.0001:
		kept_scale = Vector3.ONE
	_unit.global_transform = Transform3D(
		Basis(Vector3.UP, new_yaw).scaled(kept_scale), _unit.global_transform.origin
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
	diag_bump("callback")
	var _agg_cb := 0
	if _diag_cached == 1:
		_agg_cb = Time.get_ticks_usec()
		var gap_frame := Engine.get_physics_frames()
		if gap_frame != _agg_gap_frame and _agg_phys_end_us > 0:
			_agg_gap_frame = gap_frame
			agg_nav_gap_us += int(_agg_cb - _agg_phys_end_us)
			agg_nav_gap_n += 1
			if (
				_agg_physics_frame_us > 0
				and _agg_script_tail_frame == gap_frame
				and _agg_cb >= _agg_physics_frame_us
			):
				agg_post_frame_us += int(_agg_cb - _agg_physics_frame_us)
				agg_post_frame_n += 1
	var _agg_prep := 0
	if _diag_cached == 1:
		_agg_prep = Time.get_ticks_usec()
	if _velocity_trace_on and (_velocity_trace_lines < 120 or Engine.get_physics_frames() % 30 == 0):
		_velocity_trace_lines += 1
		print("[VELOCITY-TRACE] unit=%s pos=(%.2f,%.2f) safe=(%.3f,%.3f) interim=%.3f target=(%.2f,%.2f)" % [
			_unit.name, _unit.global_position.x, _unit.global_position.z, safe_velocity.x, safe_velocity.z,
			_interim_speed, _committed_target.x if _committed_target is Vector3 else INF,
			_committed_target.z if _committed_target is Vector3 else INF])
	var chassis_direction := -safe_velocity if _is_tactical_withdrawal else safe_velocity
	var planar_direction := chassis_direction * Vector3(1, 0, 1)
	# 没有移动任务时的位移只是 RVO 被动推挤：不能覆盖 face_towards（采矿朝向门槛靠它）。
	var passive_push: bool = _committed_target == null and _face_target != Vector3.INF
	if not planar_direction.is_zero_approx() and not passive_push:
		_face_target = Vector3.INF
		var _agg_rot := 0
		if _diag_cached == 1:
			_agg_rot = Time.get_ticks_usec()
		_rotate_in_direction(planar_direction)
		if _diag_cached == 1:
			agg_rot_us += int(Time.get_ticks_usec() - _agg_rot)
			agg_rot_n += 1
	elif _face_target != Vector3.INF:
		_apply_pending_face_rotation()
	if _diag_cached == 1:
		agg_cb_prep_us += int(Time.get_ticks_usec() - _agg_prep)
	var _agg_stepm := 0
	if _diag_cached == 1:
		_agg_stepm = Time.get_ticks_usec()
	# 【量纲】FLOW_BIT_VEL_UNITS 打开时期望速度按 m/s 下发，RVO 回传的也是 m/s：
	# 这里按 速度×delta 落地，RVO 的"减速"信号才不会被 _interim_speed 上限吃掉。
	# 逻辑地形/空中路径直接调用本函数并传"步长"，因此只有导航服务路径需要换算。
	if flow_probe:
		_flow_note_safe_velocity(safe_velocity)
	var flow_step: Vector3 = safe_velocity
	if _flow_velocity_in_mps():
		flow_step = safe_velocity * _last_physics_delta
	# 先按本帧位移上限截断再推出：RVO 躲友军时可能给出数米长、指向建筑内的安全速度，
	# 对超长步推出会把落点甩到建筑另一侧，下面的 move_toward 再沿弦线切进建筑。
	var step_origin: Vector3 = _unit.global_transform.origin
	var wanted_step: Vector3 = step_origin + flow_step.limit_length(_interim_speed)
	if _diag_cached == 1:
		agg_cb_step_us += int(Time.get_ticks_usec() - _agg_stepm)
	var _agg_push := 0
	if _diag_cached == 1:
		_agg_push = Time.get_ticks_usec()
	var pushed_step: Vector3 = _push_out_of_static_obstacles(wanted_step, true)
	if _diag_cached == 1:
		agg_push_us += int(Time.get_ticks_usec() - _agg_push)
		agg_push_n += 1
	var origin_before: Vector3 = step_origin
	if _push_trace_on and wanted_step.distance_to(pushed_step) > 0.001:
		print("[PUSH-STEP] unit=%s wanted=(%.2f,%.2f) pushed=(%.2f,%.2f) 差=%.3f" % [
			_unit.name, wanted_step.x, wanted_step.z, pushed_step.x, pushed_step.z, wanted_step.distance_to(pushed_step)])
	# 建筑足迹推出之后再挡地面作战单位。非作战单位这里等价于原来的 move_toward。
	var resolved_origin: Vector3 = _resolve_ground_combat_step(step_origin, pushed_step)
	var _agg_wr := 0
	if _diag_cached == 1:
		_agg_wr = Time.get_ticks_usec()
	_unit.global_transform.origin = resolved_origin
	if _diag_cached == 1:
		var _wrote: int = int(Time.get_ticks_usec() - _agg_wr)
		agg_origin_us += _wrote
		agg_write_us += _wrote
		agg_write_n += 1
		agg_cb_us += int(Time.get_ticks_usec() - _agg_cb)
		agg_cb_n += 1
		if _PerfBuckets.enabled:
			_PerfBuckets.on_callback(int(Time.get_ticks_usec() - _agg_cb))
	_previously_set_global_transform_of_unit = _unit.global_transform
	# 按真实位移判被动移动：建筑不参与 RVO 时，RVO 推向楼的速度会被推出层整段抵消，
	# 单位没动却一直算"被推着走"，采集/攻击计时被永久暂停。
	_update_passive_movement_tracking((_unit.global_transform.origin - origin_before) * Vector3(1, 0, 1))


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
	# 目标点落在网格外、人已经贴到最近点时，导航结束应算到达，而不是 Unreachable。
	var goal: Vector3 = _committed_target if _committed_target is Vector3 else target_position
	if goal.is_finite() and _planar_distance_to(goal) <= maxf(target_desired_distance, 0.35) + 0.25:
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
	var resolved_goal: Vector3 = _committed_target if _committed_target is Vector3 else target_position
	var requested_goal: Vector3 = _raw_target if _raw_target is Vector3 else resolved_goal
	if requested_goal.is_finite() and is_instance_valid(_unit):
		_terminal_event_seq += 1
		_terminal_events.append({"movement_sequence":_terminal_event_seq,"reason":reason,
			"target":requested_goal,"resolved_target":resolved_goal,"pos":_unit.global_position,
			"server_tick":Engine.get_physics_frames()})
		if _terminal_events.size()>TERMINAL_EVENT_LIMIT:
			_terminal_events.pop_front()
	_flow_restore_soft_radius("end:" + reason)
	target_position = Vector3.INF
	_committed_target = null
	_raw_target = null
	_progress_reference_distance = INF
	_is_tactical_withdrawal = false
	_abort_recovery()
	_clear_logic_path()
	_logic_repath_attempts = 0
	set_velocity(Vector3.ZERO)
	_emit_movement_end(reason)


func terminal_events_since(sequence: int) -> Array:
	if sequence >= _terminal_event_seq:
		return []
	return _terminal_events.filter(func(event): return int(event["movement_sequence"])>sequence).duplicate(true)


func _fail_as_unreachable():
	recovery_stats["unreachable"] += 1
	_emit_committed_end("Unreachable")


func _emit_movement_end(reason: String):
	if _movement_end_emitted:
		return
	_movement_end_emitted = true
	movement_ended.emit(reason)
	movement_finished.emit()

# ============================================================================
# 流交互实现（问题A）—— 只改本单位自己的期望速度；RVO 仍是唯一的碰撞仲裁者。
# 关闭（flow_mode = 0）时下列函数全部在第一个分支返回，不注册、不查询。
# ============================================================================

## 本单位的期望运动（平面单位向量 + 速度 m/s），供邻居扫描读取。
var _flow_dir := Vector2.ZERO
var _flow_mps := 0.0
## 上一次冲突扫描结果（严重度 0~1；冲突对象是否在我右侧）。
var _flow_conflict_severity := 0.0
var _flow_conflict_on_right := false
## 扫描错峰相位与上次扫描帧号。
var _flow_phase := 0
var _flow_last_scan := -1000000
## 车道基准（接单时锚定："起点→目标"连线及其右法向）。
var _flow_lane_origin := Vector2.ZERO
var _flow_lane_right := Vector2.ZERO
var _flow_lane_valid := false
## 密流软通行：扫描得到的贴身友军/近处敌军计数，以及进入缩放前的半径快照。
var _flow_friends_near := 0
var _flow_enemies_near := 0
var _flow_soft_saved_radius := -1.0


## 只读探针：RVO 回传速度 vs 期望步长的 幅值比 + 方向余弦。
## 幅值比≈1 且方向余弦<1 ⇒ "避让没有让单位减速，只是把方向掰弯"（churn 的直接证据）。
func _flow_note_safe_velocity(safe_velocity: Vector3) -> void:
	# 只统计"有任务目标"的在途单位：已到达单位会被置零，混进来会把比值/余弦拉偏。
	if _committed_target == null:
		return
	var pref := maxf(_interim_speed, 1.0e-9)
	var safe_len := safe_velocity.length()
	flow_stats["vel_samples"] += 1
	flow_stats["vel_ratio_sum"] += safe_len / pref
	if safe_len < pref * 0.5:
		flow_stats["vel_lt50"] += 1
	if safe_len < pref * 0.1:
		flow_stats["vel_lt10"] += 1
	var pref_dir := Vector3.ZERO
	if _committed_target != null:
		var to_target: Vector3 = _committed_target - _unit.global_position
		pref_dir = Vector3(to_target.x, 0.0, to_target.z)
	if pref_dir.length_squared() > 1.0e-6 and safe_len > 1.0e-6:
		var cosine := pref_dir.normalized().dot(safe_velocity / safe_len)
		flow_stats["vel_dir_sum"] += cosine
		if cosine < 0.5:
			flow_stats["vel_dir_lt05"] += 1


## 密流软通行：贴身友军判定间距（0 = 自动取 2×当前半径 + 1.0m）。
func _flow_soft_gap() -> float:
	if flow_soft_gap_m > 0.0:
		return flow_soft_gap_m
	return maxf(float(radius) * 2.0 + 1.0, 3.0)


## 是否处于"密集友军流"：贴身友军足够多、且近处没有敌军（与 SOFT_PHASE 同一不变式）。
func _flow_soft_wanted() -> bool:
	if _committed_target == null:
		return false
	return _flow_friends_near >= flow_soft_min_friends and _flow_enemies_near <= 0


func _flow_update_soft_radius() -> void:
	var want := _flow_soft_wanted()
	if want and _flow_soft_saved_radius < 0.0 and _structure_pass_saved_radius < 0.0:
		_flow_soft_saved_radius = maxf(float(radius), 0.05)
		radius = maxf(0.05, _flow_soft_saved_radius * clampf(flow_soft_scale, 0.05, 1.0))
		flow_stats["soft_shrinks"] += 1
	elif not want:
		_flow_restore_soft_radius("crowd_clear")


## 还原密流软通行半径（幂等；到点/停/换令/离开密流都必须还原）。
func _flow_restore_soft_radius(reason: String) -> void:
	if _flow_soft_saved_radius < 0.0:
		return
	radius = _flow_soft_saved_radius
	_flow_soft_saved_radius = -1.0
	flow_stats["soft_restores"] += 1


func _exit_tree() -> void:
	_release_gap_pass("exit")
	_flow_unregister()
	_gcc_members.erase(get_instance_id())


func _flow_register() -> void:
	_flow_registry[get_instance_id()] = self
	_flow_phase = get_instance_id() % maxi(flow_eval_interval, 1)
	flow_stats["registered"] = _flow_registry.size()


func _flow_unregister() -> void:
	if _flow_registry.is_empty():
		return
	_flow_registry.erase(get_instance_id())
	flow_stats["registered"] = _flow_registry.size()


func _flow_is_active_mover() -> bool:
	return flow_mode != FLOW_OFF and _committed_target != null


## RVO 回传速度的量纲换算开关：只对"经导航服务避让"的路径生效。
## 逻辑地形与空中路径直接调用 _on_velocity_computed 并传步长，不能换算。
func _flow_velocity_in_mps() -> bool:
	if (flow_mode & FLOW_BIT_VEL_UNITS) == 0:
		return false
	if domain == Constants.Match.Navigation.Domain.AIR:
		return false
	return not _uses_logic_terrain_move()


## 把"每帧步长"形态的期望速度按流交互策略调整后返回。
## 输入 desired 的量纲 = 每帧步长（现状实现）；返回值的量纲见 FLOW_BIT_VEL_UNITS。
func _flow_adjust_preferred(desired: Vector3, position: Vector3) -> Vector3:
	if flow_mode == FLOW_OFF or _committed_target == null:
		_flow_restore_soft_radius("no_target")
		return desired
	var planar := Vector2(desired.x, desired.z)
	var step_len := planar.length()
	if step_len < 1.0e-9:
		return desired
	var dir := planar / step_len
	var mps := step_len / maxf(_last_physics_delta, 1.0e-6)
	# 先发布本帧自己的期望运动：邻居扫描只读，不写别人的状态。
	_flow_dir = dir
	_flow_mps = mps
	var remaining := _planar_distance_to(_committed_target)
	# 目标附近完全不干预：到达判定与"最后一米"手感必须与默认实现逐帧一致。
	if remaining <= flow_goal_zone_m:
		# 目标附近一律还原半径：最后一米的贴合手感与到达判定必须与默认一致。
		_flow_restore_soft_radius("goal_zone")
		return desired
	var interval := maxi(flow_eval_interval, 1)
	var frames := Engine.get_physics_frames()
	if frames - _flow_last_scan >= interval and (frames + _flow_phase) % interval == 0:
		_flow_last_scan = frames
		_flow_scan(position, dir, mps)
	var out_dir := dir
	var speed_scale := 1.0
	# 目标附近渐隐：偏置在进入 goal_zone 之前就收敛到 0，避免终点抖动。
	var fade := clampf(
		(remaining - flow_goal_zone_m) / maxf(flow_goal_zone_m, 1.0), 0.0, 1.0
	)
	if (flow_mode & FLOW_BIT_SOFT) != 0:
		_flow_update_soft_radius()
	if (flow_mode & FLOW_BIT_LANE) != 0:
		out_dir = _flow_lane_dir(out_dir, position, remaining)
	if _flow_conflict_severity > 0.0:
		if (flow_mode & FLOW_BIT_RIGHT) != 0:
			out_dir = out_dir.rotated(
				deg_to_rad(flow_bias_deg) * _flow_conflict_severity * fade
			)
		if (flow_mode & FLOW_BIT_YIELD) != 0 and _flow_conflict_on_right:
			speed_scale = lerpf(1.0, flow_yield_factor, _flow_conflict_severity)
			flow_stats["yields"] += 1
	var out_len := step_len
	if (flow_mode & FLOW_BIT_VEL_UNITS) != 0:
		out_len = mps
	return Vector3(out_dir.x, 0.0, out_dir.y) * out_len * speed_scale


static func _flow_uses_neighbor_scan() -> bool:
	return (flow_mode & (FLOW_BIT_RIGHT | FLOW_BIT_YIELD | FLOW_BIT_SOFT)) != 0


static func _flow_cell_m() -> float:
	return maxf(flow_detect_m, 8.0)


## 每物理帧最多重建一次邻居网格；查询只扫 3×3 格。
static func _flow_rebuild_grid_if_needed() -> void:
	var frame := Engine.get_physics_frames()
	if _flow_grid_frame == frame:
		return
	_flow_grid_frame = frame
	_flow_grid.clear()
	var cell_m := _flow_cell_m()
	for key in _flow_registry.keys():
		var mover: Variant = _flow_registry[key]
		if mover == null or not is_instance_valid(mover):
			_flow_registry.erase(key)
			continue
		if not mover._flow_is_active_mover():
			continue
		var pos: Vector3 = mover._unit.global_position
		var cell := Vector2i(int(floor(pos.x / cell_m)), int(floor(pos.z / cell_m)))
		var bucket: Variant = _flow_grid.get(cell)
		if bucket == null:
			_flow_grid[cell] = [mover]
		else:
			(bucket as Array).append(mover)


## 冲突扫描：以"相对运动 → 最近接近点"判断是否会在 flow_horizon_s 内擦身而过。
## 严重度 = 接近程度 × 时间紧迫度；冲突对象在我右侧时 _flow_conflict_on_right 为真
## （右方来车 ⇒ 让行优先权方案里由我减速）。
func _flow_scan(position: Vector3, dir: Vector2, mps: float) -> void:
	_flow_conflict_severity = 0.0
	_flow_conflict_on_right = false
	_flow_friends_near = 0
	_flow_enemies_near = 0
	if not _flow_uses_neighbor_scan():
		return
	_flow_rebuild_grid_if_needed()
	var cell_m := _flow_cell_m()
	var pc := Vector2(position.x, position.z)
	var my_v := dir * mps
	var right2 := Vector2(-dir.y, dir.x)
	var base := Vector2i(int(floor(pc.x / cell_m)), int(floor(pc.y / cell_m)))
	var best := 0.0
	var best_right := false
	for ox in [-1, 0, 1]:
		for oz in [-1, 0, 1]:
			var bucket: Variant = _flow_grid.get(base + Vector2i(ox, oz))
			if bucket == null:
				continue
			for other in (bucket as Array):
				if other == self or not is_instance_valid(other):
					continue
				var other_pos: Vector3 = other._unit.global_position
				var rel := Vector2(other_pos.x, other_pos.z) - pc
				# 密流软通行：统计贴身友军/近处敌军（与既有 SOFT_PHASE 同口径）。
				if other._unit.get_parent() == _unit.get_parent():
					if rel.length_squared() <= _flow_soft_gap() * _flow_soft_gap():
						_flow_friends_near += 1
				elif rel.length_squared() <= _soft_phase_enemy_clear_m() * _soft_phase_enemy_clear_m():
					_flow_enemies_near += 1
				if other._committed_target == null:
					continue
				if rel.length_squared() > flow_detect_m * flow_detect_m:
					continue
				# 相对速度（各自按"若不受阻则满速"估计）；小于 0.5m/s 视为同向同速编队。
				var rv: Vector2 = other._flow_dir * other._flow_mps - my_v
				var rv2 := rv.length_squared()
				if rv2 < 0.25:
					continue
				var t := -rel.dot(rv) / rv2
				if t <= 0.0 or t > flow_horizon_s:
					continue
				var cd := (rel + rv * t).length()
				if cd > flow_conflict_m:
					continue
				var severity := (1.0 - cd / flow_conflict_m) * (1.0 - t / flow_horizon_s)
				if severity > best:
					best = severity
					best_right = rel.dot(right2) > 0.0
	_flow_conflict_severity = clampf(best, 0.0, 1.0)
	_flow_conflict_on_right = best_right
	flow_stats["scans"] += 1
	if best > 0.0:
		flow_stats["conflicts"] += 1


## 右侧车道保持：把横向位置控制到"接单起点→目标"基准线右侧 flow_lane_m 处；
## 距目标 flow_lane_exit_m 内线性收车道，保证终点仍精确落在目标上。
## 只叠加横向修正量，航向主体仍是导航路径方向（不绕过路径规划）。
func _flow_lane_dir(dir: Vector2, position: Vector3, remaining: float) -> Vector2:
	var pc := Vector2(position.x, position.z)
	if not _flow_lane_valid:
		var goal := Vector2(_committed_target.x, _committed_target.z)
		var axis := goal - pc
		if axis.length() < 1.0:
			return dir
		var lane_axis := axis.normalized()
		_flow_lane_origin = pc
		_flow_lane_right = Vector2(-lane_axis.y, lane_axis.x)
		_flow_lane_valid = true
	var target_offset := flow_lane_m * clampf(
		(remaining - flow_lane_exit_m) / maxf(flow_lane_exit_m, 1.0), 0.0, 1.0
	)
	var lateral := (pc - _flow_lane_origin).dot(_flow_lane_right)
	var look_ahead := clampf(remaining, flow_look_ahead_min_m, flow_look_ahead_max_m)
	var steer := dir * look_ahead + _flow_lane_right * (target_offset - lateral)
	if steer.length_squared() < 1.0e-6:
		return dir
	flow_stats["lane_steers"] += 1
	return steer.normalized()


## 【R44·2026-10-07】逐单位 G4PERF 打印原先**无条件**执行（每个 mover 每 40 物理帧一次，
## 102 单位会在同一帧爆发 102 次同步 stdout 写入 ⇒ 实测 ~103 行/秒、并发长帧 >500ms）。
## 改为需显式开关（默认关闭）：设 AIRTS_MOV_PERF=1 时才打印。行为不变，只减少日志 I/O。
static var _perf_diag_cached: int = -1


func _perf_diag_enabled() -> bool:
	if _perf_diag_cached < 0:
		_perf_diag_cached = 1 if OS.get_environment("AIRTS_MOV_PERF") != "" else 0
	return _perf_diag_cached == 1

## 【R52·2026-10-07】真实执行路径**计数**插桩（GPT-6 复核口径：计数后再修 ✓）
## 只计数、不计时；O(1)、主线程、无锁；默认关闭（AIRTS_MOV_DIAG=1 才计）；
## 由探针读取并以 inclusive 计数聚合，不做逐单位打印。
static var diag_counts: Dictionary = {}
static var _diag_cached: int = -1
## 聚合计时只在 AIRTS_MOV_DIAG=1 时累加。cb 含 push，push 含 hull/footprint，phys 不含回调。
## 禁止把这些微秒相加成帧时间。
static var agg_phys_us: int = 0
static var agg_phys_n: int = 0
static var agg_navquery_us: int = 0
static var agg_navquery_n: int = 0
static var agg_cb_us: int = 0
static var agg_cb_n: int = 0
static var agg_push_us: int = 0
static var agg_push_n: int = 0
static var agg_hull_us: int = 0
static var agg_hull_n: int = 0
static var agg_fp_us: int = 0
static var agg_fp_n: int = 0
static var agg_rot_us: int = 0
static var agg_rot_n: int = 0
static var agg_write_us: int = 0
static var agg_write_n: int = 0
static var agg_origin_us: int = 0
static var agg_has_method_us: int = 0
static var agg_interp_us: int = 0
static var agg_group_us: int = 0
static var agg_group_n: int = 0
static var agg_obs_n: int = 0
static var agg_radius_skip_n: int = 0
static var agg_dist_cull_n: int = 0
static var agg_precull_n: int = 0
static var agg_cap_exceeded_n: int = 0
static var agg_hull_reach_max: float = 0.0
static var agg_recovery_us: int = 0
static var agg_recovery_n: int = 0
static var agg_repair_us: int = 0
static var agg_repair_n: int = 0
static var agg_flow_us: int = 0
static var agg_flow_n: int = 0
static var agg_setvel_us: int = 0
static var agg_setvel_n: int = 0
static var agg_snap_us: int = 0
static var agg_snap_n: int = 0
static var agg_clamp_us: int = 0
static var agg_seek_us: int = 0
static var agg_cb_prep_us: int = 0
static var agg_cb_step_us: int = 0
static var agg_euler_us: int = 0
static var agg_max_one_us: int = 0
static var agg_max_one_name: String = ""
static var agg_worst_script_us: int = 0
static var agg_worst_frame: int = -1
static var agg_worst_phys_us: int = 0
static var agg_worst_clamp_us: int = 0
static var agg_worst_seek_us: int = 0
static var agg_worst_repair_us: int = 0
static var agg_worst_recovery_us: int = 0
static var agg_worst_snap_us: int = 0
static var _step_phys: int = 0
static var _step_clamp: int = 0
static var _step_seek: int = 0
static var _step_repair: int = 0
static var _step_recovery: int = 0
static var _step_snap: int = 0
static var _inter_open := false
static var _inter_prev_end: int = 0
static var agg_inter_sum_us: int = 0
static var agg_inter_max_us: int = 0
static var agg_prefix_sum_us: int = 0
static var agg_prefix_max_us: int = 0
static var _prefix_this: int = 0
static var agg_worst_prefix_us: int = 0
static var agg_worst_suffix_us: int = 0
static var agg_suffix_sum_us: int = 0
static var agg_suffix_n: int = 0
static var agg_window_to_first_us: int = 0
static var agg_window_to_first_n: int = 0
static var agg_worst_inter_us: int = 0
static var _step_inter: int = 0
static var agg_nav_gap_us: int = 0
static var agg_nav_gap_n: int = 0
static var agg_script_tail_us: int = 0
static var agg_script_tail_n: int = 0
static var agg_post_frame_us: int = 0
static var agg_post_frame_n: int = 0
static var agg_pre_units_us: int = 0
static var agg_units_span_us: int = 0
static var agg_post_units_us: int = 0
static var agg_after_tree_us: int = 0
static var agg_span_n: int = 0
static var agg_inside_us: int = 0
static var agg_outside_us: int = 0
static var agg_outside_n: int = 0
static var _agg_phys_last_us: int = 0
static var _agg_mark_abs := {}
static var _agg_mark_frame := {}
static var _agg_phys_end_us: int = 0
static var _agg_gap_frame: int = -1
static var _agg_script_tail_frame: int = -1
static var _agg_physics_frame_us: int = 0
static var _agg_physics_frame_hooked := false


static func _diag_on() -> bool:
	if _diag_cached < 0:
		_diag_cached = 1 if OS.get_environment("AIRTS_MOV_DIAG") != "" else 0
	return _diag_cached == 1


static func _on_diag_physics_frame() -> void:
	_inter_open = false
	if _diag_cached != 1 or _agg_phys_end_us <= 0:
		return
	var frame := Engine.get_physics_frames()
	if frame == _agg_script_tail_frame:
		return
	_agg_script_tail_frame = frame
	_agg_physics_frame_us = Time.get_ticks_usec()
	agg_script_tail_us += int(_agg_physics_frame_us - _agg_phys_end_us)
	agg_script_tail_n += 1
	# physics_frame 信号里 Engine.get_physics_frames() 比脚本里看到的大 1。
	var mark_frame := frame - 1
	var match_us := int(_agg_mark_abs.get("match", 0))
	var units_in := int(_agg_mark_abs.get("units_in", 0))
	var units_out := int(_agg_mark_abs.get("units_out", 0))
	var match_out := int(_agg_mark_abs.get("match_out", 0))
	if (
		int(_agg_mark_frame.get("match", -2)) == mark_frame
		and int(_agg_mark_frame.get("units_in", -2)) == mark_frame
		and int(_agg_mark_frame.get("units_out", -2)) == mark_frame
		and int(_agg_mark_frame.get("match_out", -2)) == mark_frame
		and units_in >= match_us
		and units_out >= units_in
		and match_out >= units_out
		and _agg_physics_frame_us >= match_out
	):
		agg_pre_units_us += units_in - match_us
		agg_units_span_us += units_out - units_in
		agg_post_units_us += match_out - units_out
		agg_after_tree_us += int(_agg_physics_frame_us - match_out)
		agg_span_n += 1
		var script_us := match_out - match_us
		var d_phys := agg_phys_us - _step_phys
		var d_clamp := agg_clamp_us - _step_clamp
		var d_seek := agg_seek_us - _step_seek
		var d_repair := agg_repair_us - _step_repair
		var d_recovery := agg_recovery_us - _step_recovery
		var d_snap := agg_snap_us - _step_snap
		var d_inter := agg_inter_sum_us - _step_inter
		var suffix := 0
		if _inter_prev_end > 0 and match_out >= _inter_prev_end:
			suffix = int(match_out - _inter_prev_end)
			agg_suffix_sum_us += suffix
			agg_suffix_n += 1
		if script_us > agg_worst_script_us:
			agg_worst_script_us = script_us
			agg_worst_frame = mark_frame
			agg_worst_phys_us = d_phys
			agg_worst_clamp_us = d_clamp
			agg_worst_seek_us = d_seek
			agg_worst_repair_us = d_repair
			agg_worst_recovery_us = d_recovery
			agg_worst_snap_us = d_snap
			agg_worst_inter_us = d_inter
			agg_worst_prefix_us = _prefix_this
			agg_worst_suffix_us = suffix
	_prefix_this = 0
	_step_phys = agg_phys_us
	_step_clamp = agg_clamp_us
	_step_seek = agg_seek_us
	_step_repair = agg_repair_us
	_step_recovery = agg_recovery_us
	_step_snap = agg_snap_us
	_step_inter = agg_inter_sum_us


static func diag_mark(tag: String) -> void:
	if _diag_cached != 1:
		return
	var frame := Engine.get_physics_frames()
	if int(_agg_mark_frame.get(tag, -1)) == frame:
		return
	_agg_mark_frame[tag] = frame
	_agg_mark_abs[tag] = Time.get_ticks_usec()


static func diag_bookend(tag: String) -> void:
	if _diag_cached != 1:
		return
	var now := Time.get_ticks_usec()
	if tag == "phys_first":
		if _agg_phys_last_us > 0:
			agg_outside_us += int(now - _agg_phys_last_us)
			agg_outside_n += 1
		_agg_mark_abs["phys_first"] = now
	elif tag == "phys_last":
		var started := int(_agg_mark_abs.get("phys_first", 0))
		if started > 0 and now >= started:
			agg_inside_us += int(now - started)
		_agg_phys_last_us = now


static func diag_bump(key: String) -> void:
	if _diag_cached != 1:
		return
	diag_counts[key] = int(diag_counts.get(key, 0)) + 1


static func diag_reset() -> void:
	diag_counts = {}


static func diag_report() -> String:
	var keys: Array = diag_counts.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		parts.append(str(k) + "=" + str(diag_counts[k]))
	return " ".join(parts)


static func agg_reset() -> void:
	_diag_on()
	agg_phys_us = 0
	agg_phys_n = 0
	agg_navquery_us = 0
	agg_navquery_n = 0
	agg_cb_us = 0
	agg_cb_n = 0
	agg_push_us = 0
	agg_push_n = 0
	agg_hull_us = 0
	agg_hull_n = 0
	agg_fp_us = 0
	agg_fp_n = 0
	agg_rot_us = 0
	agg_rot_n = 0
	agg_write_us = 0
	agg_write_n = 0
	agg_origin_us = 0
	agg_has_method_us = 0
	agg_interp_us = 0
	agg_group_us = 0
	agg_group_n = 0
	agg_obs_n = 0
	agg_radius_skip_n = 0
	agg_dist_cull_n = 0
	agg_precull_n = 0
	agg_cap_exceeded_n = 0
	agg_hull_reach_max = 0.0
	agg_recovery_us = 0
	agg_recovery_n = 0
	agg_repair_us = 0
	agg_repair_n = 0
	agg_flow_us = 0
	agg_flow_n = 0
	agg_setvel_us = 0
	agg_setvel_n = 0
	agg_snap_us = 0
	agg_snap_n = 0
	agg_clamp_us = 0
	agg_seek_us = 0
	agg_cb_prep_us = 0
	agg_cb_step_us = 0
	agg_euler_us = 0
	agg_max_one_us = 0
	agg_max_one_name = ""
	agg_worst_script_us = 0
	agg_worst_frame = -1
	agg_worst_phys_us = 0
	agg_worst_clamp_us = 0
	agg_worst_seek_us = 0
	agg_worst_repair_us = 0
	agg_worst_recovery_us = 0
	agg_worst_snap_us = 0
	_step_phys = 0
	_step_clamp = 0
	_step_seek = 0
	_step_repair = 0
	_step_recovery = 0
	_step_snap = 0
	_inter_open = false
	_inter_prev_end = 0
	agg_inter_sum_us = 0
	agg_inter_max_us = 0
	agg_prefix_sum_us = 0
	agg_prefix_max_us = 0
	_prefix_this = 0
	agg_worst_prefix_us = 0
	agg_worst_suffix_us = 0
	agg_suffix_sum_us = 0
	agg_suffix_n = 0
	agg_window_to_first_us = 0
	agg_window_to_first_n = 0
	agg_worst_inter_us = 0
	_step_inter = 0
	agg_nav_gap_us = 0
	agg_nav_gap_n = 0
	agg_script_tail_us = 0
	agg_script_tail_n = 0
	agg_post_frame_us = 0
	agg_post_frame_n = 0
	agg_pre_units_us = 0
	agg_units_span_us = 0
	agg_post_units_us = 0
	agg_after_tree_us = 0
	agg_span_n = 0
	agg_inside_us = 0
	agg_outside_us = 0
	agg_outside_n = 0
	_agg_phys_last_us = 0
	_agg_mark_abs.clear()
	_agg_mark_frame.clear()
	_agg_phys_end_us = 0
	_agg_gap_frame = -1
	_agg_script_tail_frame = -1
	_agg_physics_frame_us = 0


static func agg_line() -> String:
	return "phys_us=%d snap_us=%d repair_us=%d recovery_us=%d navquery_us=%d flow_us=%d setvel_us=%d clamp_us=%d seek_us=%d cb_us=%d push_us=%d rot_us=%d euler_us=%d write_us=%d origin_us=%d has_method_us=%d interp_us=%d group_us=%d hull_us=%d cb_prep_us=%d cb_step_us=%d pre_units_us=%d units_span_us=%d post_units_us=%d after_tree_us=%d span_n=%d script_tail_us=%d script_tail_n=%d inside_us=%d outside_us=%d outside_n=%d nav_gap_us=%d nav_gap_n=%d post_frame_us=%d precull_n=%d max_one_us=%d worst_script_us=%d worst_frame=%d worst_phys_us=%d worst_clamp_us=%d worst_seek_us=%d worst_repair_us=%d worst_recovery_us=%d worst_snap_us=%d inter_sum_us=%d inter_max_us=%d worst_inter_us=%d prefix_sum_us=%d prefix_max_us=%d worst_prefix_us=%d worst_suffix_us=%d window_to_first_us=%d window_to_first_n=%d suffix_sum_us=%d suffix_n=%d" % [
		agg_phys_us, agg_snap_us, agg_repair_us, agg_recovery_us,
		agg_navquery_us, agg_flow_us, agg_setvel_us, agg_clamp_us, agg_seek_us,
		agg_cb_us, agg_push_us, agg_rot_us, agg_euler_us, agg_write_us,
		agg_origin_us, agg_has_method_us, agg_interp_us,
		agg_group_us, agg_hull_us,
		agg_cb_prep_us, agg_cb_step_us,
		agg_pre_units_us, agg_units_span_us, agg_post_units_us, agg_after_tree_us, agg_span_n,
		agg_script_tail_us, agg_script_tail_n,
		agg_inside_us, agg_outside_us, agg_outside_n,
		agg_nav_gap_us, agg_nav_gap_n, agg_post_frame_us, agg_precull_n, agg_max_one_us,
		agg_worst_script_us, agg_worst_frame, agg_worst_phys_us, agg_worst_clamp_us,
		agg_worst_seek_us, agg_worst_repair_us, agg_worst_recovery_us, agg_worst_snap_us,
		agg_inter_sum_us, agg_inter_max_us, agg_worst_inter_us,
		agg_prefix_sum_us, agg_prefix_max_us, agg_worst_prefix_us, agg_worst_suffix_us,
		agg_window_to_first_us, agg_window_to_first_n, agg_suffix_sum_us, agg_suffix_n,
	]


# 地面作战单位的硬碰撞。大地图会摘掉 NavigationAgent 避让，位移又直接写原点；
# 单位根是 collision_mask=0 的 Area3D，物理层不会互相挡住。这里在权威落点上
# 用碰撞形状的平面半径封顶，不改 RVO、不缩碰撞盒、不改速度。半径取形状而不是
# Movement.radius，避免软穿行/窄缝把个人空间缩小后穿模。
const _GCC_CELL_M := 6.0
const _GCC_TYPES := {
	"tank": true,
	"heavy_tank": true,
	"apc": true,
	"soldier": true,
	"sniper": true,
	"rocketeer": true,
}
const _GCC_SCENES := {
	"res://source/match/units/Tank.tscn": true,
	"res://source/match/units/HeavyTank.tscn": true,
	"res://source/match/units/APC.tscn": true,
	"res://source/match/units/Infantry.tscn": true,
	"res://source/match/units/Sniper.tscn": true,
	"res://source/match/units/Rocketeer.tscn": true,
}
static var _gcc_members := {}
static var _gcc_grid := {}
static var _gcc_grid_frame := -1
var _gcc_state := 0
var _gcc_radius := 0.0
var _gcc_height := 0.0
var ground_combat_blocks := 0


func ground_combat_collision_radius() -> float:
	_ensure_ground_combat_contact()
	if _gcc_state != 1:
		return 0.0
	return _gcc_radius


func _ensure_ground_combat_contact() -> void:
	if _gcc_state != 0:
		return
	if NetSession.is_client_puppet():
		_gcc_state = 2
		return
	if _unit == null or domain != Constants.Match.Navigation.Domain.TERRAIN:
		if _unit == null:
			return
		_gcc_state = 2
		return
	var type_id := str(_unit.get("unit_type_id"))
	var scene_path := str(_unit.scene_file_path)
	var combat := _GCC_TYPES.has(type_id) or _GCC_SCENES.has(scene_path)
	if not combat:
		if type_id.is_empty() and scene_path.is_empty():
			return
		_gcc_state = 2
		return
	_measure_ground_combat_body()
	if _gcc_radius <= 0.05:
		_gcc_state = 2
		push_warning("地面作战单位没有可用碰撞半径：%s" % str(_unit.name))
		return
	_gcc_state = 1
	_gcc_members[get_instance_id()] = self


func _measure_ground_combat_body() -> void:
	_gcc_radius = 0.0
	_gcc_height = 0.0
	if _unit == null:
		return
	for child in _unit.get_children():
		if not (child is CollisionShape3D):
			continue
		var shape_node := child as CollisionShape3D
		if shape_node.disabled or shape_node.shape == null:
			continue
		var shape: Shape3D = shape_node.shape
		var local_r := 0.0
		var local_h := 0.0
		if shape is CylinderShape3D:
			local_r = shape.radius
			local_h = shape.height
		elif shape is CapsuleShape3D:
			local_r = shape.radius
			local_h = shape.height
		elif shape is SphereShape3D:
			local_r = shape.radius
			local_h = shape.radius * 2.0
		elif shape is BoxShape3D:
			local_r = maxf(shape.size.x, shape.size.z) * 0.5
			local_h = shape.size.y
		else:
			continue
		var scale := shape_node.global_transform.basis.get_scale()
		var world_r := local_r * maxf(absf(scale.x), absf(scale.z))
		var world_h := local_h * absf(scale.y)
		if world_r > _gcc_radius:
			_gcc_radius = world_r
			_gcc_height = world_h
	if _gcc_radius > 0.05 and _gcc_height <= 0.05:
		_gcc_height = maxf(_gcc_radius * 2.0, 1.2)


func _resolve_ground_combat_step(origin: Vector3, building_safe: Vector3) -> Vector3:
	_ensure_ground_combat_contact()
	var limit := maxf(_interim_speed, 0.0)
	if _gcc_state != 1 or _gcc_radius <= 0.0:
		return origin.move_toward(building_safe, limit)
	var unblocked := origin.move_toward(building_safe, limit)
	var before := _worst_combat_penetration(origin)
	if _step_keeps_contact(before, _worst_combat_penetration(unblocked)):
		return unblocked
	var best := origin
	var lo := 0.0
	var hi := limit
	for _i in 8:
		var mid := (lo + hi) * 0.5
		var sample := origin.move_toward(building_safe, mid)
		if _step_keeps_contact(before, _worst_combat_penetration(sample)):
			lo = mid
			best = sample
		else:
			hi = mid
	if _planar_distance_to_point(unblocked, best) > 0.001:
		ground_combat_blocks += 1
	return best


func _step_keeps_contact(before_pen: float, after_pen: float) -> bool:
	# 从分离状态出发时，穿透上限是常数，避免每帧放行 0.1mm 慢慢叠进对方。
	if before_pen <= 0.0002:
		return after_pen <= 0.0002
	return after_pen <= before_pen + 0.00005


func _clamp_teleport_against_ground_combat(origin: Vector3, proposed: Vector3) -> Vector3:
	_ensure_ground_combat_contact()
	if _gcc_state != 1 or _gcc_radius <= 0.0:
		return proposed
	if _step_keeps_contact(_worst_combat_penetration(origin), _worst_combat_penetration(proposed)):
		return proposed
	return origin


func _worst_combat_penetration(at: Vector3) -> float:
	if _gcc_state != 1 or _gcc_radius <= 0.0:
		return 0.0
	_rebuild_ground_combat_grid()
	var worst := 0.0
	var base := Vector2i(
		int(floor(at.x / _GCC_CELL_M)),
		int(floor(at.z / _GCC_CELL_M))
	)
	for ox in [-1, 0, 1]:
		for oz in [-1, 0, 1]:
			var bucket: Variant = _gcc_grid.get(base + Vector2i(ox, oz))
			if bucket == null:
				continue
			for other in bucket:
				if other == self or not is_instance_valid(other):
					continue
				var gap := _combat_gap_shortfall(at, other)
				if gap > worst:
					worst = gap
	return worst


func _combat_gap_shortfall(at: Vector3, other) -> float:
	if other._gcc_radius <= 0.0 or other._unit == null or not is_instance_valid(other._unit):
		return 0.0
	if other.domain != Constants.Match.Navigation.Domain.TERRAIN:
		return 0.0
	var other_pos: Vector3 = other._unit.global_position
	var vertical_limit := _gcc_height * 0.5 + float(other._gcc_height) * 0.5 + 0.05
	if absf(at.y - other_pos.y) > vertical_limit:
		return 0.0
	var dist := Vector2(at.x, at.z).distance_to(Vector2(other_pos.x, other_pos.z))
	return maxf(0.0, _gcc_radius + float(other._gcc_radius) - dist)


func _rebuild_ground_combat_grid() -> void:
	var frame := Engine.get_physics_frames()
	if _gcc_grid_frame == frame:
		return
	_gcc_grid_frame = frame
	_gcc_grid.clear()
	var stale: Array = []
	for key in _gcc_members.keys():
		var mover: Variant = _gcc_members[key]
		if mover == null or not is_instance_valid(mover) or mover._unit == null \
				or not is_instance_valid(mover._unit) or mover._gcc_state != 1:
			stale.append(key)
			continue
		var pos: Vector3 = mover._unit.global_position
		var cell := Vector2i(int(floor(pos.x / _GCC_CELL_M)), int(floor(pos.z / _GCC_CELL_M)))
		var bucket: Variant = _gcc_grid.get(cell)
		if bucket == null:
			_gcc_grid[cell] = [mover]
		else:
			(bucket as Array).append(mover)
	for key in stale:
		_gcc_members.erase(key)

