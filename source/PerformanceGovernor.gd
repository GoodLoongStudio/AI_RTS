extends Node

## **帧率治理**（用户 2026-09-15：锁 30 帧减轻负载；单位多仍可再降画质）。
##
## ## 两条腿，缺一条都不稳
## ① **前馈（单位数）**：用户点名的那条 —— "单位多就降低渲染效果"。
##    单位数是**提前量**：等 FPS 掉下来再降，玩家已经卡了一下（而单位数涨是可预见的）。
##    实现为**画质档下限**（`tier_floor_for_units`）：部队规模上去后画质必须先降到那一档，
##    FPS 反馈只能在它之上继续往下降（永远不会比"该有的档"更清晰）。
## ② **反馈（帧时）**：实测能不能守住上限。低于阈值**持续一段时间**才降档（迟滞），
##    避免一帧抖动就换画质；升档更保守（要求长时间富余），否则会来回抖。
##
## ## 为什么不看"FPS 很高就升档"
## 帧率被 `Engine.max_fps` 夹住时，顶满上限 **不代表**有余量（我们看不到真实上限）。
## 所以升档必须同时满足：CPU 帧时小、绘制调用少、**且部队规模低于这一档的门槛**
## （前馈说"人不多"，反馈才允许升回去）。宁可少升，不可抖。
##
## ## 可观测（复盘/验收要能回答"为什么降了"）
## `stats()` 给出档位/缩放/单位数/帧时/绘制调用/最近一次升降原因；
## 随每轮 10Hz 采样上报（`op=perf` 与 `fast_state`），于是**每局档案里都有画质轨迹**。

const CONFIG_PATH := "user://performance.cfg"
##: 默认帧率上限（用户 2026-09-15 要求锁 30）。旧配置里的 60 会迁到 30。
const DEFAULT_MAX_FPS := 30
##: 锁 30 后的升降档：低于约 80% 上限才降，接近上限才升。
const DOWNGRADE_FPS := 24.0
const UPGRADE_FPS := 29.0
const DWELL_SECONDS := 2.5
const UPGRADE_DWELL_SECONDS := 6.0
##: **预热窗口**（秒）：启动/切场景后的加载期帧率必然低（实测真机 `units=0, fps=32`），
##: 那不是负载 —— 拿它降画质会"一开局就白白降两档"（真机复验发现，见 §17.3）。
##: 预热期内**只认前馈**（单位数），不认帧率反馈。
const WARMUP_SECONDS := 6.0
##: 自适应的**稳态判据**（2026-09-14 压测实测定标）：
##: 固定 6 秒不够 —— 客户端"加入对局后的载入阶段"可能在第 **13 秒**还有一次
##: 509ms 的物理卡顿（实测：`FPS=11 / physics=509ms / 单位仅 4 个 / 导航版本没变`，
##: 即**载入卡顿**而不是重烘或部队规模）。判据改为：
##:   ① 距上次切场景 < `WARMUP_MIN_SECONDS`，或
##:   ② 还没见到过 ≥ `WARMUP_READY_FPS` 的采样（= 还没进入稳态），但不超过 `WARMUP_MAX_SECONDS`。
##: 上限必须有：慢机器可能永远达不到就绪帧率，否则治理器永远不工作。
const WARMUP_MIN_SECONDS := 6.0
const WARMUP_MAX_SECONDS := 20.0
const WARMUP_READY_FPS := 27.0
var _warmup_steady := false
var _scene_seconds := 0.0
##: 换档后的冷却：给渲染管线/GPU 重新稳定留时间（否则连续两帧的抖动会连降两档）。
const CHANGE_COOLDOWN_SECONDS := 3.0
##: **降档的"效果验证"窗口**：降完盯 `VERIFY_SECONDS` 秒 —— 帧率回来了说明降对了（保留这一档）；
##: 没回来说明**画质不是瓶颈**（这台机器实测是主线程/逻辑瓶颈）→ **把画质还回去**，
##: 并记住 `INEFFECTIVE_SECONDS` 秒不再自动降档（"白降一次就够了"，不许为守帧白白牺牲画面）。
const VERIFY_SECONDS := 8.0
const INEFFECTIVE_SECONDS := 60.0
##: 档位上限（3 = 最低画质）
const MAX_TIER := 3
##: 采样 EMA 的平滑系数（0.25 ≈ 最近几帧为主，仍能压掉单帧毛刺）。
const FPS_SMOOTHING := 0.25

##: 部队规模 → 画质档**下限**（前馈）。**只数本机玩家自己的单位**（`controlled_units`）：
##: 之前数的是全图（含对手/电脑 AI 的兵）→ 玩家看着"这么点兵"却因为对面攒兵而被降画质
##: （2026-09-14 真机复检：全图 41 个单位里一大半是对面的，照样触发降档）。
##: 对面的兵带来真实负载时，由**帧率那条腿**兜住（那才是真的掉帧）。
##: 门槛按"自己的部队"量级定 50/80/120（作战单位上限 60 ⇒ 满编大约落在第 1 档）。
##: 为什么用数组而不是 if 堆：门槛只有一处，测试与文档都读它。
const UNIT_TIER_FLOOR := [
	{"units": 120, "tier": 3},
	{"units": 80, "tier": 2},
	{"units": 50, "tier": 1},
]

##: 全场规模 → 画质档**兜底**下限（前馈第二口径，用户 2026-09-15 批准）。
##: 为什么需要：只数自己的兵时，一局开 2~3 个电脑，它们攒到几百个单位照样拖慢主机，
##: 而玩家的画质一直停在最高档（用户实测："一局开 3 个电脑非常卡"）。
##: 门槛刻意比自军那条**高得多**（自军 50/80/120 ⇒ 全场 200/300/420）：
##: 玩家自己兵不多时不会被误伤，只有真打成大乱斗（全场 200+ 个单位）才兜底降档。
const GLOBAL_UNIT_TIER_FLOOR := [
	{"units": 420, "tier": 3},
	{"units": 300, "tier": 2},
	{"units": 200, "tier": 1},
]

##: 每一档实际改哪些渲染开关。`null` = "不动这项"（保持场景原值）。
##: 顺序 = 从清晰到省，每档只比上一档更省（单调，便于解释与验收）。
const TIERS := [
	{"name": "full", "scale": 1.0, "lod": 1.0, "msaa": 2, "shadows": true,
		"shadow_atlas": 4096, "ssao": true, "glow": true, "fog": true, "sdfgi": true},
	{"name": "high", "scale": 0.9, "lod": 1.5, "msaa": 1, "shadows": true,
		"shadow_atlas": 2048, "ssao": false, "glow": true, "fog": true, "sdfgi": false},
	{"name": "medium", "scale": 0.75, "lod": 2.5, "msaa": 0, "shadows": true,
		"shadow_atlas": 1024, "ssao": false, "glow": false, "fog": false, "sdfgi": false},
	{"name": "low", "scale": 0.6, "lod": 4.0, "msaa": 0, "shadows": false,
		"shadow_atlas": 512, "ssao": false, "glow": false, "fog": false, "sdfgi": false},
]

##: 纯逻辑核心（**可单测**：冒烟测试直接驱动 `step`，不需要真帧）。
##: `core` = {tier, low_seconds, high_seconds, cooldown, verify_left, verify_from, no_effect_left}，
##: `sample` = {fps, units(己方), delta, warmup, down_fps?}
##: （`cpu_ms`/`draw_calls` 只用于上报与复盘，**不参与判定** —— 见 `DOWNGRADE_FPS` 的实测依据）。
static func step(core: Dictionary, sample: Dictionary) -> Dictionary:
	var delta := float(sample.get("delta", 0.0))
	var next := {
		"tier": int(core.get("tier", 0)),
		"low_seconds": float(core.get("low_seconds", 0.0)),
		"high_seconds": float(core.get("high_seconds", 0.0)),
		"cooldown": maxf(0.0, float(core.get("cooldown", 0.0)) - delta),
		"reason": str(core.get("reason", "")),
		# 降档效果验证（见 `VERIFY_SECONDS`）：>0 表示正在观察"降完帧率有没有回来"。
		"verify_left": maxf(0.0, float(core.get("verify_left", 0.0)) - delta),
		"verify_from": int(core.get("verify_from", 0)),
		# "降了没用"的记忆（见 `INEFFECTIVE_SECONDS`）：这段时间内不再自动降档。
		"no_effect_left": maxf(0.0, float(core.get("no_effect_left", 0.0)) - delta),
	}
	# 已知帧率被上限夹住 → `fps` 只能证明"掉了没"，不能证明"还有多少余量"（防抖靠迟滞+冷却）。
	var fps := float(sample.get("fps", 0.0))
	var units := int(sample.get("units", 0))
	# 全场规模（含对手/电脑 AI 的兵）：前馈的第二条腿，见 `GLOBAL_UNIT_TIER_FLOOR`。
	var all_units := int(sample.get("all_units", 0))
	var down_fps := float(sample.get("down_fps", DOWNGRADE_FPS))
	var floor_tier := tier_floor_for_scale(units, all_units)
	var changed := false

	# ① 前馈优先：部队规模要求的最低档位（"单位多就降画质"）。它一抬，之前的降档验证就没意义了。
	if next["tier"] < floor_tier:
		next["tier"] = floor_tier
		next["reason"] = "units=%d" % units
		next["verify_left"] = 0.0
		changed = true

	# 预热期（启动/切场景）：**只认前馈**。加载期的低帧不是负载，
	# 拿它降档会一开局就白降（真机实测 units=0 时 fps=32 → 直接掉到 1 档）。
	if bool(sample.get("warmup", false)):
		next["low_seconds"] = 0.0
		next["high_seconds"] = 0.0
		next["changed"] = changed
		return next

	# ② 反馈计时：低帧累积（要降档）、高帧累积（可升档）、中间地带两边都慢慢清零。
	if fps > 0.0:
		if fps < down_fps:
			next["low_seconds"] += delta
			next["high_seconds"] = 0.0
		elif fps >= UPGRADE_FPS:
			next["high_seconds"] += delta
			next["low_seconds"] = 0.0
		else:
			next["low_seconds"] = maxf(0.0, next["low_seconds"] - delta * 0.5)
			next["high_seconds"] = 0.0

	# ③ 降档效果验证：降完帧率没回来 = 画质不是瓶颈 → 把画质还回去，并记住"别再白降"。
	# 注意判据取自**本步开始前**的状态（`was_verifying`）：窗口到点的那一步也要走到"没回来"分支，
	# 否则会出现"验证最后一帧直接跳去再降一档"的漏判。
	var was_verifying := float(core.get("verify_left", 0.0)) > 0.0
	if was_verifying:
		if fps >= UPGRADE_FPS:
			next["verify_left"] = 0.0                  # 降得对：帧率回来了，保留这一档
			next["high_seconds"] = 0.0                 # 升档重新计时（否则刚降就被升回去，画面来回跳）
		elif next["verify_left"] <= 0.0:       # **窗口到点**仍没回来，才判定"白降"
			var restore := maxi(next["verify_from"], floor_tier)
			next["verify_left"] = 0.0
			next["low_seconds"] = 0.0
			next["high_seconds"] = 0.0
			if restore < int(next["tier"]):
				next["tier"] = restore
				next["reason"] = "no_effect"
				next["no_effect_left"] = INEFFECTIVE_SECONDS
				changed = true
	# ④ 降档（持续低帧，且不在冷却 / 验证 / "白降"记忆里）
	elif next["low_seconds"] >= DWELL_SECONDS and next["cooldown"] <= 0.0 \
			and next["tier"] < MAX_TIER and next["no_effect_left"] <= 0.0:
		next["verify_from"] = next["tier"]
		next["tier"] = next["tier"] + 1
		next["low_seconds"] = 0.0
		next["cooldown"] = CHANGE_COOLDOWN_SECONDS
		next["verify_left"] = VERIFY_SECONDS
		next["reason"] = "fps=%.0f" % fps
		changed = true
	# ⑤ 升档（长时间富余，且不许越过部队规模要求的档）
	elif next["high_seconds"] >= UPGRADE_DWELL_SECONDS and next["cooldown"] <= 0.0 \
			and next["tier"] > floor_tier:
		next["tier"] = next["tier"] - 1
		next["high_seconds"] = 0.0
		next["cooldown"] = CHANGE_COOLDOWN_SECONDS
		next["reason"] = "headroom"
		changed = true

	next["changed"] = changed
	return next


## 部队规模 → 画质档下限（前馈·第一口径：**自己的兵**）。0 档 = 最高画质。
static func tier_floor_for_units(units: int) -> int:
	for item in UNIT_TIER_FLOOR:
		if units >= int(item["units"]):
			return int(item["tier"])
	return 0


## 全场规模 → 画质档下限（前馈·第二口径：**含对手/电脑 AI 的兵**）。
static func global_tier_floor_for_units(all_units: int) -> int:
	for item in GLOBAL_UNIT_TIER_FLOOR:
		if all_units >= int(item["units"]):
			return int(item["tier"])
	return 0


## 前馈最终下限 = 两条腿取严（用户 2026-09-15 批准第二条腿）。
## 单方对局（all_units 小）行为与从前完全一致；一局 2~3 个电脑攒到几百个单位时才兜底降档。
static func tier_floor_for_scale(own_units: int, all_units: int) -> int:
	return maxi(tier_floor_for_units(own_units), global_tier_floor_for_units(all_units))


static func tier_name(tier: int) -> String:
	var index := clampi(tier, 0, TIERS.size() - 1)
	return str(TIERS[index].get("name", "?"))


##: 画质档的**中文名**（玩家看的就是这个，不是 `full/high/medium/low`）。
const TIER_LABELS := ["极高", "高", "中", "低"]


## 画质那一小段文字，**接在游戏原有的右上角状态行后面**（用户 2026-09-14：
## "这个不要，游戏原来不就在右上角有延时和帧率显示？"）—— 不另开一行，复用既有显示。
## 例：`单机 · 30 FPS · 画质 高（90%）`
static func quality_suffix(stats: Dictionary) -> String:
	if not bool(stats.get("enabled", true)):
		return ""                       # 治理关掉时不显示（没有"自动画质"这回事）
	var index := clampi(int(stats.get("tier", 0)), 0, TIER_LABELS.size() - 1)
	var scale_percent := int(round(100.0 * float(stats.get("scale", 1.0))))
	var text := "画质 %s（%d%%）" % [TIER_LABELS[index], scale_percent]
	if bool(stats.get("warmup", false)):
		text += "（载入中）"
	return text


## 换档时那句提示（显示几秒）：**说清方向与原因**（部队多 / 帧率掉 / 有余量）。
static func change_text(tier: int, stats: Dictionary, previous: int) -> String:
	var index := clampi(tier, 0, TIER_LABELS.size() - 1)
	var direction := "降到" if tier > previous else "升回"
	var reason := str(stats.get("reason", ""))
	var why := ""
	if reason.begins_with("units="):
		why = "（部队 %s 个）" % reason.substr(6)
	elif reason.begins_with("fps="):
		why = "（帧率掉到 %s）" % reason.substr(4)
	elif reason == "headroom":
		why = "（帧率有余量）"
	elif reason == "no_effect":
		why = "（降画质没能换来帧率）"      # 画质还回去的理由必须说清，否则玩家以为功能在乱动
	return "画质%s「%s」%s" % [direction, TIER_LABELS[index], why]


##: 当前档位（0 = 最高画质）。
var tier := 0
##: 是否启用（headless 专用服恒为 false：没有渲染可调）。
var enabled := true
##: 帧率上限（写进 `Engine.max_fps`）。
var max_fps := DEFAULT_MAX_FPS
##: 降档门槛（帧率低于它才算"真卡"）。`user://performance.cfg` 的 `down_fps` 可覆盖。
var down_fps := DOWNGRADE_FPS
##: 上一帧的采样结果（给 `stats()`/DCS 读，避免二次查询）。
var _fps_ema := 0.0
var _cpu_ms := 0.0
##: 前馈口径的单位数（**自己的兵**；取不到己方单位时才退回全图，见 `_process`）。
var _units := 0
##: 自己的单位数（`controlled_units`）与全图单位数（含对手/电脑 AI）—— 复盘要能分开看。
var _units_own := 0
var _units_all := 0
var _draw_calls := 0
var _last_reason := "start"
##: 未启用时用来还原画质的原始值快照。
var _original := {}
var _core := {"tier": 0, "low_seconds": 0.0, "high_seconds": 0.0, "cooldown": 0.0,
	"reason": "start", "verify_left": 0.0, "verify_from": 0, "no_effect_left": 0.0}
var _window_seconds := 0.0
var _applied_tier := -1
##: G4 大地图进局后禁止把阴影/高度雾加回去。离开对局必须解锁。
var _large_map_lock := false
##: 预热剩余时间（启动/切场景后重置）：见 `WARMUP_SECONDS`。
var _warmup_left := WARMUP_SECONDS
var _last_scene: Node = null
##: 换档提示（几秒后消失）：**只在画质真的变了**时告诉玩家"变了、为什么"。
##: 常驻的帧率/画质由游戏原有的右上角状态行显示（`NetSync._hud_tick` 调 `quality_suffix()`），
##: 这里**不再另开一行**（用户 2026-09-14 明确否掉了重复显示）。
var show_toast := true
var _toast_layer: CanvasLayer
var _toast_label: Label
var _toast_left := 0.0
const TOAST_SECONDS := 4.0
const LIVE_PERF_PATH := "user://g4_live_perf.json"
var _live_dump_left := 0.0


func _ready() -> void:
	_load_config()
	# 专用服（headless）没有渲染栈：一律不动，也不设帧率上限（省 CPU 给模拟）。
	if DisplayServer.get_name() == "headless":
		enabled = false
		_last_reason = "headless"
		set_process(false)
		return
	_original = _snapshot()
	if enabled:
		Engine.max_fps = int(max_fps)
		_apply_tier(0, "start")
	else:
		Engine.max_fps = int(_original.get("max_fps", 0))
	if show_toast:
		_build_toast()
	print("[PERF] 帧率治理已启动：上限 %d 帧，动态画质=%s，换档提示=%s"
		% [Engine.max_fps, str(enabled), str(show_toast)])


## 是否还在"载入/未进入稳态"阶段（见 `WARMUP_MIN/MAX_SECONDS` 的实测依据）。
func _in_warmup() -> bool:
	if _warmup_left > 0.0:
		return true
	if _warmup_steady:
		return false
	return _scene_seconds < WARMUP_MAX_SECONDS


## 建"换档提示"（只这一个 Label；常驻行复用游戏原有的右上角状态显示）。
func _build_toast() -> void:
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 90                   # 在游戏 UI 之上、弹窗之下
	add_child(_toast_layer)
	_toast_label = _make_hud_label(26, Color(1.0, 0.92, 0.6, 0.95))
	_toast_label.text = ""
	_toast_label.visible = false


func _make_hud_label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE      # 绝不吃玩家点击
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 4)
	label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.offset_left = -320.0
	label.offset_top = 34.0
	label.offset_right = -12.0
	_toast_layer.add_child(label)
	return label


## 刷新"换档提示"（到点自动消失）。常驻的帧率/画质走游戏原有状态行（`quality_suffix`）。
func _refresh_hud(delta: float) -> void:
	if not show_toast or _toast_label == null or not is_instance_valid(_toast_label):
		return
	_toast_left = maxf(0.0, _toast_left - delta)
	_toast_label.visible = _toast_left > 0.0
	if _toast_label.visible:
		_toast_label.offset_top = 34.0
		_toast_label.offset_bottom = 70.0


func _process(delta: float) -> void:
	# 切场景（大厅 → 对局）→ 重置 EMA 与预热窗口：加载期的帧率不代表对局负载。
	var scene := get_tree().current_scene
	if scene != _last_scene:
		_last_scene = scene
		_warmup_left = WARMUP_SECONDS
		_scene_seconds = 0.0
		_warmup_steady = false
		_fps_ema = 0.0
	_warmup_left = maxf(0.0, _warmup_left - delta)
	_scene_seconds += delta
	var fps_now := float(Engine.get_frames_per_second())
	if fps_now >= WARMUP_READY_FPS:
		_warmup_steady = true                     # 见过稳态帧率 → 之后的低帧才算"负载"
	_fps_ema = fps_now if _fps_ema <= 0.0 else lerpf(_fps_ema, fps_now, FPS_SMOOTHING)
	_cpu_ms = float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	_draw_calls = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	# 前馈口径：**只数自己的兵**（见 `UNIT_TIER_FLOOR`）。观战/取不到己方单位时退回全图 ——
	# 宁可多算，也不要"一个都不算"（那会让治理在某些模式下彻底失灵）。
	_units_own = get_tree().get_nodes_in_group("controlled_units").size()
	_units_all = get_tree().get_nodes_in_group("units").size()
	_units = _units_own if _units_own > 0 else _units_all
	_refresh_hud(delta)                      # 屏上反馈每帧刷新（内部自带 0.25s 节流）
	_live_dump_left -= delta
	if _live_dump_left <= 0.0:
		_live_dump_left = 2.0
		_dump_live_perf()
	_window_seconds += delta
	if _window_seconds < 0.25:
		return
	var step_delta := _window_seconds
	_window_seconds = 0.0
	if not enabled:
		return
	var result := step(_core, {"fps": _fps_ema, "cpu_ms": _cpu_ms, "draw_calls": _draw_calls,
		"units": _units, "all_units": _units_all, "delta": step_delta,
		"warmup": _in_warmup(), "down_fps": down_fps})
	var new_tier := int(result["tier"])
	_core = {"tier": new_tier, "low_seconds": float(result["low_seconds"]),
		"high_seconds": float(result["high_seconds"]),
		"cooldown": float(result["cooldown"]), "reason": str(result["reason"]),
		"verify_left": float(result["verify_left"]), "verify_from": int(result["verify_from"]),
		"no_effect_left": float(result["no_effect_left"])}
	if bool(result["changed"]) or new_tier != _applied_tier:
		_apply_tier(new_tier, str(result["reason"]))


## 记录当前渲染设置（关掉动态画质时原样还原 —— 绝不把用户的设置弄丢）。
func _snapshot() -> Dictionary:
	var viewport := get_viewport()
	var environment := _environment()
	return {
		"max_fps": Engine.max_fps,
		"scaling_3d_scale": viewport.scaling_3d_scale if viewport != null else 1.0,
		"scaling_3d_mode": viewport.scaling_3d_mode if viewport != null else 0,
		"msaa_3d": viewport.msaa_3d if viewport != null else 0,
		"mesh_lod_threshold": viewport.mesh_lod_threshold if viewport != null else 1.0,
		"ssao": environment.ssao_enabled if environment != null else false,
		"glow": environment.glow_enabled if environment != null else false,
		"fog": environment.fog_enabled if environment != null else false,
		"sdfgi": environment.sdfgi_enabled if environment != null else false,
	}


func lock_large_map_presentation() -> void:
	_large_map_lock = true
	var apply_tier := _applied_tier if _applied_tier >= 0 else tier
	_apply_tier(apply_tier, "large_map_lock")
	print("[PERF] large_map_lock volumetric=off sdfgi=off shadows=tier")


func unlock_large_map_presentation() -> void:
	if not _large_map_lock:
		return
	_large_map_lock = false
	if enabled and _applied_tier >= 0:
		_apply_tier(_applied_tier, "large_map_unlock")


## 应用某一档（幂等）。**只读场景、只改渲染开关**，不碰游戏逻辑。
func _apply_tier(new_tier: int, reason: String) -> void:
	var index := clampi(new_tier, 0, TIERS.size() - 1)
	var spec: Dictionary = TIERS[index]
	var viewport := get_viewport()
	if viewport != null:
		viewport.scaling_3d_scale = float(spec["scale"])
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.msaa_3d = int(spec["msaa"])
		viewport.mesh_lod_threshold = float(spec["lod"])
	var use_shadows := bool(spec["shadows"])
	var use_fog := bool(spec["fog"])
	var environment := _environment()
	if environment != null:
		environment.ssao_enabled = bool(spec["ssao"])
		environment.glow_enabled = bool(spec["glow"])
		environment.fog_enabled = use_fog
		environment.sdfgi_enabled = bool(spec["sdfgi"]) and not _large_map_lock
		if _large_map_lock:
			environment.volumetric_fog_enabled = false
			environment.ssr_enabled = false
			environment.sdfgi_enabled = false
			environment.ssao_enabled = false
	RenderingServer.directional_shadow_atlas_set_size(int(spec["shadow_atlas"]), true)
	for light in _directional_lights():
		light.shadow_enabled = use_shadows
		if _large_map_lock and light is DirectionalLight3D:
			(light as DirectionalLight3D).directional_shadow_max_distance = 80.0
	var previous := _applied_tier
	tier = index
	_applied_tier = index
	_last_reason = reason
	# 换档必须给玩家一句话（否则他看到画面变了却不知道是功能在起作用）。
	if show_toast and previous >= 0 and previous != index \
			and _toast_label != null and is_instance_valid(_toast_label):
		_toast_label.text = change_text(index, stats(), previous)
		_toast_left = TOAST_SECONDS
	print("[PERF] 画质 → %s（tier=%d scale=%.2f units=%d fps=%.0f）原因=%s"
		% [tier_name(index), index, float(spec["scale"]), _units, _fps_ema, reason])


func _dump_live_perf() -> void:
	var file := FileAccess.open(LIVE_PERF_PATH, FileAccess.WRITE)
	if file == null:
		return
	var payload := stats()
	payload["scene"] = str(_last_scene.name) if _last_scene != null else ""
	payload["written_at"] = Time.get_datetime_string_from_system()
	file.store_string(JSON.stringify(payload))


func _environment() -> Environment:
	var viewport := get_viewport()
	if viewport == null:
		return null
	var world := viewport.find_world_3d()
	return world.environment if world != null else null


func _directional_lights() -> Array:
	var scene := get_tree().current_scene
	if scene == null:
		return []
	return scene.find_children("*", "DirectionalLight3D", true, false)


## 供 DCS `op=perf` / `fast_state` / 验收报告读（**不猜**：字段名与含义固定）。
func stats() -> Dictionary:
	var viewport := get_viewport()
	return {
		"enabled": enabled,
		"tier": tier,
		"tier_name": tier_name(tier),
		"scale": float(viewport.scaling_3d_scale) if viewport != null else 0.0,
		"max_fps": Engine.max_fps,
		"fps": int(_fps_ema),
		"cpu_ms": snappedf(_cpu_ms, 0.01),
		# `units` = 前馈真正用的那个数（自己的兵）；`units_own`/`units_all` 分开留档，
		# 才能回答"降档到底是自己兵多，还是对面兵多"（2026-09-14 的真实误判）。
		"units": _units,
		"units_own": _units_own,
		"units_all": _units_all,
		"draw_calls": _draw_calls,
		# `floor` = 两条前馈腿取严（自军 + 全场兜底）；`floor_own` 便于复盘"是哪条腿在压档"。
		"floor": tier_floor_for_scale(_units, _units_all),
		"floor_own": tier_floor_for_units(_units),
		"reason": _last_reason,
		# 降档效果验证 / "白降"记忆的实时状态（复盘要能看出"为什么画质还回去了"）。
		"verify_left": snappedf(float(_core.get("verify_left", 0.0)), 0.1),
		"no_effect_left": snappedf(float(_core.get("no_effect_left", 0.0)), 0.1),
		"down_fps": down_fps,
		# 载入/未进入稳态（给右上角状态行加"（载入中）"，解释"为什么现在帧率低、画质没动"）。
		"warmup": _in_warmup(),
		"large_map_lock": _large_map_lock,
	}


## 运行时可关（面板/验收用）：关掉会**还原**原始画质与帧率上限。
func set_enabled(value: bool) -> void:
	enabled = value
	if value:
		Engine.max_fps = int(max_fps)
		_apply_tier(tier, "re-enabled")
		return
	if not _original.is_empty():
		var viewport := get_viewport()
		if viewport != null:
			viewport.scaling_3d_scale = float(_original.get("scaling_3d_scale", 1.0))
			viewport.scaling_3d_mode = int(_original.get("scaling_3d_mode", 0))
			viewport.msaa_3d = int(_original.get("msaa_3d", 0))
			viewport.mesh_lod_threshold = float(_original.get("mesh_lod_threshold", 1.0))
		Engine.max_fps = int(_original.get("max_fps", 0))
		_last_reason = "disabled"
		tier = 0
		_applied_tier = -1


func _load_config() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) != OK:
		return
	enabled = bool(config.get_value("performance", "dynamic_quality", true))
	var loaded_fps := int(config.get_value("performance", "max_fps", DEFAULT_MAX_FPS))
	max_fps = mini(loaded_fps, DEFAULT_MAX_FPS)
	# 旧锁 60 的降档门槛 50 会把锁 30 误判成掉帧，一并迁到新默认。
	var loaded_down := float(config.get_value("performance", "down_fps", DOWNGRADE_FPS))
	down_fps = loaded_down
	if down_fps > float(DEFAULT_MAX_FPS) or is_equal_approx(down_fps, 50.0):
		down_fps = DOWNGRADE_FPS
	if loaded_fps != max_fps or not is_equal_approx(loaded_down, down_fps):
		config.set_value("performance", "max_fps", max_fps)
		config.set_value("performance", "down_fps", down_fps)
		config.save(CONFIG_PATH)
	# 换档提示默认开（用户要"玩家能看到反馈"）；常驻画质显示接在游戏原有状态行上。
	show_toast = bool(config.get_value("performance", "change_toast", true))
