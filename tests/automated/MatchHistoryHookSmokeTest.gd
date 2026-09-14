extends Node

## 真实对局接线（`MatchHistoryHook`）的冒烟测试。
##
## **为什么必须有这个测试**：这条链路由 `FeatureFlags.record_match_history` 控制、
## **默认关闭**，所以"钩子写完了"和"钩子跑得起来"是两件事。没有这个测试，
## 提交上去的钩子可能从未执行过一次（信号名写错、对局根找不到、字段编造垃圾值，
## 全都不会被任何现有测试发现）。
##
## **为什么不用整局 Match**：慢（十余秒）、且 `_finish()` 会通过 `sync_growth_store()`
## 写玩家画像。这里造一个**最小对局根**（带 `Players` 子节点）并把它设为
## `current_scene` —— 走的正是 `_match_root()` 在生产里的同一条判据
## （`Loading.gd:56` 把 `current_scene` 设成 Match 根；`Match.tscn` 根下就有 `Players`，
## 本测试也断言这一条）。
##
## 覆盖：开关语义 / 信号接线 / 每局新建 recorder / 报告落盘 / 缺字段仍为 null /
## 重复结算不产生第二份 / 中途退出标 aborted / 跑完还原玩家档案与成长状态。

const MatchScene := preload("res://source/match/Match.tscn")

const PROBE_SAVE := "user://probe_hook_history.json"
const PROBE_LEGACY := "user://probe_hook_legacy.json"
const REAL_SAVE := "user://match_history.json"
const REAL_LEGACY := "user://match_reports.json"
const HOOK_NAME := "MatchHistoryHook"
const RECORDER_NAME := "MatchReportRecorder"

var _fail := 0
var _finished := false

var _store: Node = null
var _flags: Node = null
var _growth: Node = null
var _fake_root: Node = null
var _saved_scene: Node = null
var _growth_state: Dictionary = {}
var _growth_profile: Dictionary = {}
var _growth_reports: Array = []


func _ready() -> void:
	# 看门狗：断言里任何一处 await 卡住都要有结论，不能静默挂死（见 skill 的"假挂起"）。
	get_tree().create_timer(90.0).timeout.connect(_on_failsafe)

	_store = get_node_or_null("/root/MatchReportStore")
	_flags = get_node_or_null("/root/FeatureFlags")
	_growth = get_node_or_null("/root/GrowthStore")
	_check(_store != null, "MatchReportStore autoload 可用")
	_check(_flags != null, "FeatureFlags autoload 可用")
	if _store == null or _flags == null:
		_finish()
		return

	_snapshot_growth()
	_isolate_store()
	_saved_scene = get_tree().current_scene

	await _check_flag_gate()
	await _check_wiring()
	await _check_first_match()
	await _check_double_finish()
	await _check_second_match_aborted()
	_check_real_match_structure()

	_teardown()
	_finish()


# ==================== 1. 开关语义 ====================

func _check_flag_gate() -> void:
	_flags.set("record_match_history", false)
	_remove_hooks()
	_store.call("_install_match_hook")
	await _frames(1)
	_check(_hook() == null, "开关关闭时不安装对局记录钩子")

	_flags.set("record_match_history", true)
	_store.call("_install_match_hook")
	await _frames(1)
	_check(_hook() != null, "开关打开时安装对局记录钩子")
	_check(_hook_count() == 1, "钩子只装一个（实际 %d）" % _hook_count())

	# 幂等：重复安装不应叠加（`_install_match_hook` 由 `_ready` 与测试各调一次）。
	_store.call("_install_match_hook")
	await _frames(1)
	_check(_hook_count() == 1, "重复调用 _install_match_hook 不叠加钩子（实际 %d）" % _hook_count())


# ==================== 2. 信号接线 ====================

func _check_wiring() -> void:
	var hook := _hook()
	if hook == null:
		_check(false, "能取到钩子实例")
		return
	var signals := get_node_or_null("/root/MatchSignals")
	_check(signals != null, "MatchSignals autoload 可用")
	if signals == null:
		return
	for pair in [
		["match_started", "_on_match_started"],
		["match_aborted", "_on_match_aborted"],
		["match_finished_with_victory", "_on_match_victory"],
		["match_finished_with_defeat", "_on_match_defeat"],
	]:
		var signal_name: String = pair[0]
		var method_name: String = pair[1]
		_check(signals.is_connected(signal_name, Callable(hook, method_name)),
			"钩子已订阅 %s" % signal_name)


# ==================== 3. 第一局：开 -> 胜 -> 落盘 ====================

func _check_first_match() -> void:
	_fake_root = _make_fake_root()
	var before := _report_count()
	MatchSignals.match_started.emit()
	await _frames(2)

	var recorder := _recorder()
	_check(recorder != null, "match_started 后在对局根下挂上 recorder")
	if recorder == null:
		return
	_check(bool(recorder.active), "recorder 处于记录中状态")

	var ctx: Dictionary = recorder.context
	var match_id := str(ctx.get("match_id", ""))
	_check(match_id.begins_with("local-"), "match_id 本地生成且带 local- 前缀（%s）" % match_id)
	_check(str(ctx.get("player_id", "")) != "",
		"写入了玩家身份（%s）" % str(ctx.get("player_id", "")))
	_check(ctx.get("difficulty", "missing") == null, "难度留 null —— 对局层没有权威来源")
	var adjutant: Dictionary = ctx.get("adjutant", {})
	_check(adjutant.get("type", "missing") == null, "副官类型留 null —— HUD 上挂的不等于是本局配置")
	var map_ctx: Dictionary = ctx.get("map", {})
	_check(map_ctx.get("name", "missing") != null,
		"地图名取自 NetSession.selected_map_path（%s）" % str(map_ctx.get("name", null)))

	MatchSignals.match_finished_with_victory.emit()
	await _frames(2)

	_check(_report_count() == before + 1,
		"胜利后落盘 1 份报告（%d → %d）" % [before, _report_count()])
	var report := _latest_report()
	if report.is_empty():
		_check(false, "能取到刚落盘的真实报告")
		return

	_check(not bool(report.get("demo", true)), "真实对局报告不带 demo 标记")
	_check(str(report.get("outcome", "")) == "victory",
		"胜负记为 victory（%s）" % str(report.get("outcome", "")))
	_check(str(report.get("match_id", "")).begins_with("local-"), "报告带本地 match_id")
	_check(report.get("difficulty") == null, "报告里难度是 null —— 不把缺失写成分类名")
	var mode: Variant = report.get("mode")
	_check(mode == null or MatchReportSchema.MODES.has(str(mode)),
		"模式要么 null 要么是合法枚举值（%s）" % str(mode))
	_check(not str(report.get("created_at", "")).is_empty(), "报告有生成时间")
	_check(str((report.get("source", {}) as Dictionary).get("generated_by", "")) != "",
		"报告记录生成来源")
	_check(not JSON.stringify(report).contains("<null>"), "报告序列化后不含字面量 <null>")
	_check(float(report["data_completeness"]["ratio"]) < 1.0,
		"稀疏真实报告如实给出低完整度 %.2f" % report["data_completeness"]["ratio"])
	_check(_recorder() == null, "收局后 recorder 已从对局根摘除（不残留死节点）")


# ==================== 4. 重复结算 ====================

func _check_double_finish() -> void:
	var before := _report_count()
	# 胜利之后玩家又点了退出（或结算被重放）：不得再写一份，否则统计翻倍。
	MatchSignals.match_finished_with_victory.emit()
	MatchSignals.match_aborted.emit()
	await _frames(2)
	_check(_report_count() == before,
		"重复结算不新增报告（%d → %d）" % [before, _report_count()])


# ==================== 5. 第二局：开 -> 中途退出 ====================

func _check_second_match_aborted() -> void:
	_fake_root.queue_free()
	await _frames(1)
	_fake_root = _make_fake_root()
	var before := _report_count()

	MatchSignals.match_started.emit()
	await _frames(2)
	_check(_recorder() != null, "第二局同样能新建 recorder（钩子不是一次性的）")

	MatchSignals.match_aborted.emit()
	await _frames(2)
	_check(_report_count() == before + 1, "中途退出落盘 1 份报告")
	var report := _latest_report()
	_check(str(report.get("outcome", "")) == "aborted",
		"中途退出记为 aborted（%s）" % str(report.get("outcome", "")))
	# 按设计：aborted 的 defeat_reason 是**故意留空**的（"中止"不是"失败原因"），
	# 中止原因记在时间线的 match_aborted 事件里。两条都断言，避免以后被当成 bug 改掉。
	_check(str(report.get("defeat_reason", "x")) == "",
		"aborted 的 defeat_reason 按设计留空")
	var aborted_event := _timeline_event(report, "match_aborted")
	_check(not aborted_event.is_empty(), "aborted 报告在时间线里留下 match_aborted 事件")
	_check(not str(aborted_event.get("detail", "")).is_empty(),
		"中止事件写明原因（%s）" % str(aborted_event.get("detail", "")))


# ==================== 6. 与真实 Match 场景的结构一致性 ====================

## `_match_root()` 的判据是"current_scene 带 Players 子节点"。这条判据必须与真实
## Match 场景一致，否则钩子在真游戏里找不到对局根、**静默什么都不做**。
## （另有 `Loading.gd:56` 的 `get_tree().current_scene = a_match` 把 Match 设为当前场景。）
func _check_real_match_structure() -> void:
	var instance := MatchScene.instantiate()
	_check(instance != null, "Match.tscn 可实例化")
	if instance == null:
		return
	_check(instance.get_node_or_null("Players") != null,
		"Match.tscn 根下有 Players —— 与 _match_root() 的判据一致")
	instance.free()


# ==================== 收尾 ====================

func _teardown() -> void:
	_remove_hooks()
	_flags.set("record_match_history", false)
	if _fake_root != null and is_instance_valid(_fake_root):
		_fake_root.queue_free()
	_fake_root = null
	if _saved_scene != null and is_instance_valid(_saved_scene):
		get_tree().current_scene = _saved_scene
	_store.configure_paths(REAL_SAVE, REAL_LEGACY)
	_restore_growth()


## 用临时档案跑断言，绝不污染玩家真实历史（否则"列表应有 N 条"会变成环境依赖）。
func _isolate_store() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROBE_LEGACY))
	_store.configure_paths(PROBE_SAVE, PROBE_LEGACY)
	# 首次运行 store 会播种 Demo；清掉，让"落盘 1 份"这类计数断言是确定的。
	_store.clear_all()
	_check(_report_count() == 0, "隔离档案从 0 条开始（实际 %d）" % _report_count())


func _snapshot_growth() -> void:
	if _growth == null:
		return
	# 深拷贝：`_finish()` 会经 sync_growth_store() 真的改它们。
	var state: Variant = _growth.get("state")
	_growth_state = (state as Dictionary).duplicate(true) if state is Dictionary else {}
	var profile: Variant = _growth.get("profile")
	_growth_profile = (profile as Dictionary).duplicate(true) if profile is Dictionary else {}
	var reports: Variant = _growth.get("match_reports")
	_growth_reports = (reports as Array).duplicate(true) if reports is Array else []


## 还原成长存档。**顺序要紧**：`ingest_match_reports()` 会**同时**重写
## `user://match_reports.json` 与 `user://player_profile.json`（它会按报告重建画像），
## 所以先让它把报告写回去，再用存档前的快照把 profile 盖回原样。
## 不还原的话，跑一次测试就会静默改掉玩家的画像页内容。
func _restore_growth() -> void:
	if _growth == null:
		return
	_growth.set("state", _growth_state)
	_growth.call("ingest_match_reports", _growth_reports)
	_growth.call("save_profile_snapshot", _growth_profile)
	if _growth.has_method("save_state"):
		_growth.call("save_state")


## 最小对局根：形状取自 `Match.tscn`（根下 `Players`，`Players` 下有本地玩家）。
## 设为 current_scene 是为了让 `_match_root()` 走生产同一条路径。
##
## ⚠️ 必须挂到 `get_tree().root` 下，**不能** `add_child(self)`：`current_scene` 有硬约束 ——
## 赋值对象必须是 root 的**直接子节点**，否则 Godot **静默忽略**这次赋值
## （只留一句 `Condition "p_scene && p_scene->get_parent() != root" is true.`），
## 表现就是 `_match_root()` 找不到对局根、钩子什么都不做。实测踩过，故显式断言它生效。
func _make_fake_root() -> Node:
	var root := Node.new()
	root.name = "FakeMatchRoot"
	var players := Node3D.new()
	players.name = "Players"
	root.add_child(players)
	var human := Node3D.new()
	human.name = "HumanPlayer"
	players.add_child(human)
	get_tree().root.add_child(root)
	get_tree().current_scene = root
	_check(get_tree().current_scene == root,
		"最小对局根已设为 current_scene（_match_root 的前提成立）")
	return root


# ==================== 小工具 ====================

func _hook_count() -> int:
	var count := 0
	for child in _store.get_children():
		if str(child.name) == HOOK_NAME:
			count += 1
	return count


func _hook() -> Node:
	for child in _store.get_children():
		if str(child.name) == HOOK_NAME:
			return child
	return null


func _remove_hooks() -> void:
	for child in _store.get_children():
		if str(child.name) == HOOK_NAME:
			_store.remove_child(child)
			child.queue_free()


func _recorder() -> Node:
	if _fake_root == null or not is_instance_valid(_fake_root):
		return null
	return _fake_root.get_node_or_null(RECORDER_NAME)


func _report_count() -> int:
	return (_store.get("reports") as Array).size()


func _latest_report() -> Dictionary:
	var reports: Array = _store.get("reports")
	if reports.is_empty():
		return {}
	var value: Variant = reports[reports.size() - 1]
	return value if value is Dictionary else {}


## 在报告的时间线里按事件类型取第一条（找不到返回空字典）。
func _timeline_event(report: Dictionary, type_key: String) -> Dictionary:
	var timeline: Variant = report.get("timeline", null)
	if not (timeline is Array):
		return {}
	for entry in (timeline as Array):
		if entry is Dictionary and str((entry as Dictionary).get("type", "")) == type_key:
			return entry
	return {}


func _frames(count: int) -> void:
	for index in range(count):
		await get_tree().process_frame


func _on_failsafe() -> void:
	if _finished:
		return
	print("FAIL: 看门狗超时 —— 测试协程中断未收尾")
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	# 回归清单（config/full_regression_suite.json）按这行找 expected_marker。
	print("Match history hook smoke test completed: %d failure(s)" % _fail)
	# 本测试没有引导整局 Match，所以不传 match_root。
	SmokeTestExit.request(get_tree(), 0 if _fail == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  [PASS] %s" % message)
		return
	_fail += 1
	print("FAIL: %s" % message)
