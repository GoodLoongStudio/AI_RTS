extends "res://source/ui/MenuPage.gd"

## 玩家画像页（Item 5）：身份栏 / 五维雷达 / 对局摘要 / Hermes 只读分析卡。
##
## 两条纪律：
## 1. **只呈现真实存在的字段**。数据源只有 `GrowthStore.get_profile_snapshot()`、
##    `GrowthStore.state.levels` 与 `GrowthStore.match_reports`；没有快照就进空状态，
##    绝不拼凑"看起来像分析"的自然语言结论。
## 2. **推断与事实分区**。Hermes 的副官推荐属于推断，单独放在底部 HERMES 分析卡里，
##    并强制带出「数据依据 + 生成时间 + 模型版本」，不与右侧"对局摘要"（事实）混排。
##
## 样式时序：本页先跑一次通用 `apply(self)`，再按语义覆盖颜色，最后 `skip_subtree(self)`
## 把整页置为豁免 —— 否则 MenuPage 基类延迟执行的 apply 会把下面这些语义色整片刷成同色。

const ROOT := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"
const FRAME := "CenterContainer/PanelContainer"
const AVATAR_PATH := "res://assets/ui/icons/growth/profile.svg"
const BRANCH_LABEL := {"combat": "战斗", "economy": "经济", "construction": "建设"}

var _identity: PanelContainer
var _analysis: PanelContainer
var _insights: PanelContainer
var _hermes: PanelContainer
var _radar: Control
var _avatar: TextureRect
var _player_id: Label
var _sample: Label
var _generated: Label
var _dimensions: Label
var _recent: Label
var _strategy: Label
var _growth: Label
var _adjutant: Label
var _recommendation: Label
var _reason: Label
var _evidence: Label
var _time: Label
var _reports: Array = []


func _ready() -> void:
	SystemUIStyle.apply(self)
	_collect()
	_apply_tones()
	_bind()
	var history_button := _node("Body/Insights/InsightsBox/HistoryButton") as Button
	if history_button != null: history_button.pressed.connect(_show_history)
	SystemUIStyle.skip_subtree(self)
	var back := get_node_or_null(ROOT + "/Back") as Button
	if back != null:
		back.grab_focus()


# ---------------- 节点 / 样式 ----------------

func _node(path: String) -> Node:
	return get_node_or_null(ROOT + "/" + path)


func _collect() -> void:
	_identity = _node("Body/Identity") as PanelContainer
	_analysis = _node("Body/Analysis") as PanelContainer
	_insights = _node("Body/Insights") as PanelContainer
	_hermes = _node("HermesCard") as PanelContainer
	_radar = _node("Body/Analysis/AnalysisBox/Radar")
	_avatar = _node("Body/Identity/IdentityBox/Avatar") as TextureRect
	_player_id = _node("Body/Identity/IdentityBox/PlayerId") as Label
	_sample = _node("Body/Identity/IdentityBox/Sample") as Label
	_generated = _node("Body/Identity/IdentityBox/Generated") as Label
	_dimensions = _node("Body/Analysis/AnalysisBox/Dimensions") as Label
	_recent = _node("Body/Insights/InsightsBox/Recent") as Label
	_strategy = _node("Body/Insights/InsightsBox/Strategy") as Label
	_growth = _node("Body/Insights/InsightsBox/GrowthAlignment") as Label
	_adjutant = _node("Body/Insights/InsightsBox/Adjutant") as Label
	_recommendation = _node("HermesCard/HermesBox/Recommendation") as Label
	_reason = _node("HermesCard/HermesBox/HermesReason") as Label
	_evidence = _node("HermesCard/HermesBox/Evidence") as Label
	_time = _node("HermesCard/HermesBox/HermesTime") as Label


func _apply_tones() -> void:
	var frame := get_node_or_null(FRAME) as PanelContainer
	if frame != null:
		frame.add_theme_stylebox_override("panel",
			SystemUIStyle.flat(SystemUIStyle.GLASS_DEEP, SystemUIStyle.RADIUS_PANEL,
				SystemUIStyle.LINE_STRONG, 1))

	if _identity != null:
		_identity.add_theme_stylebox_override("panel", _panel_style(
			Color(0.043, 0.114, 0.153, 0.90), SystemUIStyle.LINE))
	if _insights != null:
		_insights.add_theme_stylebox_override("panel", _panel_style(
			Color(0.043, 0.114, 0.153, 0.90), SystemUIStyle.LINE))
	if _analysis != null:
		_analysis.add_theme_stylebox_override("panel", _panel_style(
			Color(0.031, 0.086, 0.118, 0.92), SystemUIStyle.LINE_STRONG))
	if _hermes != null:
		_hermes.add_theme_stylebox_override("panel", _panel_style(
			Color(0.043, 0.114, 0.153, 0.94),
			Color(SystemUIStyle.AMBER.r, SystemUIStyle.AMBER.g, SystemUIStyle.AMBER.b, 0.72)))

	var title := _node("Title") as Label
	if title != null:
		title.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	var subtitle := _node("Hermes") as Label
	if subtitle != null:
		subtitle.add_theme_color_override("font_color", SystemUIStyle.MUTED)

	_tone(_player_id, SystemUIStyle.AMBER_HI)
	_tone(_sample, SystemUIStyle.TEXT)
	_tone(_generated, SystemUIStyle.DIM)
	_tone(_dimensions, SystemUIStyle.CYAN)
	_tone(_recent, SystemUIStyle.TEXT)
	_tone(_strategy, SystemUIStyle.TEXT)
	_tone(_growth, SystemUIStyle.TEXT)
	_tone(_adjutant, SystemUIStyle.TEXT)
	_tone(_recommendation, SystemUIStyle.TEXT)
	_tone(_reason, SystemUIStyle.MUTED)
	_tone(_evidence, SystemUIStyle.MUTED)
	_tone(_time, SystemUIStyle.DIM)

	var insights_title := _node("Body/Insights/InsightsBox/InsightsTitle") as Label
	if insights_title != null:
		insights_title.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	var hermes_title := _node("HermesCard/HermesBox/HermesTitle") as Label
	if hermes_title != null:
		hermes_title.add_theme_color_override("font_color", SystemUIStyle.AMBER)

	if _avatar != null and ResourceLoader.exists(AVATAR_PATH):
		_avatar.texture = load(AVATAR_PATH)


func _panel_style(background: Color, border: Color, width: int = 1) -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(background, border, width, SystemUIStyle.RADIUS_PANEL)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style


func _tone(label: Label, color: Color) -> void:
	if label != null:
		label.add_theme_color_override("font_color", color)


# ---------------- 数据绑定 ----------------

func _bind() -> void:
	var raw_reports = GrowthStore.get("match_reports")
	var reports: Array = raw_reports if raw_reports is Array else []
	_reports = reports
	var profile := GrowthStore.get_profile_snapshot()

	if profile.is_empty():
		_bind_empty(reports)
		return

	var dimensions: Dictionary = profile.get("dimensions", {})
	var combat := float(dimensions.get("combat", 0))
	var economy := float(dimensions.get("economy", 0))
	var construction := float(dimensions.get("construction", 0))
	var aggression := float(dimensions.get("aggression", 0))
	var risk := float(dimensions.get("risk_tolerance", 0))

	if _radar != null and _radar.has_method("set_values"):
		_radar.set_values(PackedFloat32Array([
			combat / 100.0, economy / 100.0, construction / 100.0,
			aggression / 100.0, risk / 100.0,
		]))
	_tone(_dimensions, SystemUIStyle.CYAN)
	if _dimensions != null:
		_dimensions.text = "战斗 %d   经济 %d   建设 %d   进攻倾向 %d   风险偏好 %d" % [
			roundi(combat), roundi(economy), roundi(construction), roundi(aggression), roundi(risk),
		]

	if _player_id != null:
		_player_id.text = str(profile.get("player_id", "local"))
	if _sample != null:
		_sample.text = "样本数：%d 场" % int(profile.get("sample_count", 0))

	var stamp := str(profile.get("generated_at", ""))
	if _generated != null:
		_generated.text = "生成时间：%s" % ("未知" if stamp.is_empty() else stamp)

	if _strategy != null:
		_strategy.text = "常用策略：%s" % _join(profile.get("preferred_strategies", []))
	if _growth != null:
		_growth.text = "成长投入：%s" % _growth_text()
	if _recent != null:
		_recent.text = "近期对局表现：%s" % _recent_text(reports)

	# 推荐属于 Hermes 推断：单独放底部卡片，并强制带出依据与时间。
	var recommendations: Array = profile.get("recommended_adjutants", [])
	if recommendations.is_empty():
		if _adjutant != null:
			_adjutant.text = "推荐副官：暂无"
		if _recommendation != null:
			_recommendation.text = "推荐内容：快照中不含副官推荐"
		if _reason != null:
			_reason.text = "推荐理由：—"
	else:
		var first: Dictionary = recommendations[0]
		var kind := str(first.get("type", "综合副官"))
		if _adjutant != null:
			_adjutant.text = "推荐副官：%s" % kind
		if _recommendation != null:
			_recommendation.text = "推荐内容：%s" % kind
		if _reason != null:
			_reason.text = "推荐理由：%s" % str(first.get("reason", "—"))

	if _evidence != null:
		_evidence.text = "数据依据：%s · 模型 %s" % [
			_evidence_text(profile, reports), str(profile.get("model_version", "未知")),
		]
	if _time != null:
		_time.text = "生成时间：%s" % ("未知" if stamp.is_empty() else stamp)


func _bind_empty(reports: Array) -> void:
	if _player_id != null:
		_player_id.text = "LOCAL COMMANDER"
	if _sample != null:
		_sample.text = "暂无 Hermes 画像快照\n完成对局后 Hermes 会基于真实档案生成画像。"
	if _generated != null:
		_generated.text = "生成时间：—"
	if _radar != null and _radar.has_method("set_empty"):
		_radar.set_empty()
	if _dimensions != null:
		_dimensions.text = "战斗 —   经济 —   建设 —   进攻倾向 —   风险偏好 —"
	if _recent != null:
		_recent.text = "近期对局表现：%s" % _recent_text(reports)
	if _strategy != null:
		_strategy.text = "常用策略：等待样本"
	if _growth != null:
		_growth.text = "成长投入：%s" % _growth_text()
	if _adjutant != null:
		_adjutant.text = "推荐副官：暂无"
	if _recommendation != null:
		_recommendation.text = "推荐内容：暂无快照，Hermes 不会在无数据时给出建议"
	if _reason != null:
		_reason.text = "推荐理由：—"
	if _evidence != null:
		_evidence.text = "数据依据：暂无（本地尚无 Hermes 画像快照，不生成推断）"
	if _time != null:
		_time.text = "生成时间：—"


# ---------------- 文本工具 ----------------

func _recent_text(reports: Array) -> String:
	if reports.is_empty():
		return "暂无本地对局档案"
	var wins := 0
	var losses := 0
	var marks := PackedStringArray()
	for index in range(reports.size()):
		var report = reports[index]
		if not (report is Dictionary):
			continue
		var outcome := str((report as Dictionary).get("outcome", "unknown"))
		if outcome == "victory":
			wins += 1
		elif outcome == "defeat":
			losses += 1
		if index >= reports.size() - 3:
			marks.append(_outcome_mark(outcome))
	return "共 %d 场 · 胜 %d / 负 %d   最近：%s" % [
		reports.size(), wins, losses, " ".join(marks),
	]


func _outcome_mark(outcome: String) -> String:
	if outcome == "victory":
		return "胜"
	if outcome == "defeat":
		return "负"
	return "—"


func _growth_text() -> String:
	var levels: Dictionary = GrowthStore.state.get("levels", {})
	if levels.is_empty():
		return "尚未投入成长点"
	var parts := PackedStringArray()
	for branch in ["combat", "economy", "construction"]:
		var total := 0
		for definition in GrowthStore.DEFINITIONS.get(branch, []):
			total += int(levels.get(str(definition.get("id", "")), 0))
		parts.append("%s %d 级" % [BRANCH_LABEL.get(branch, branch), total])
	return "、".join(parts)


func _evidence_text(profile: Dictionary, reports: Array) -> String:
	var sources: Array = profile.get("source_reports", [])
	var names := PackedStringArray()
	for source in sources.slice(0, 3):
		names.append(str(source))
	var count := sources.size() if not sources.is_empty() else reports.size()
	if names.is_empty():
		return "本地对局档案 %d 场" % count
	return "对局 %s（共 %d 场）" % ["、".join(names), count]


func _join(value) -> String:
	if not (value is Array) or (value as Array).is_empty():
		return "暂无"
	var parts := PackedStringArray()
	for item in value:
		parts.append(str(item))
	return "、".join(parts)

func _show_history() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "历史对局记录"
	dialog.size = Vector2(760, 520)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 8)
	for item in _reports:
		if not item is Dictionary: continue
		var r: Dictionary = item
		var combat: Dictionary = r.get("combat", {})
		var resources: Dictionary = r.get("resources", {})
		var build: Dictionary = r.get("construction", {})
		var label := Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = "%s · %s\n资源 %d | 生产 %d | 建造 %.0f%% | 伤害 %d | 损失 %d\n关键事件：%s" % [str(r.get("match_id", "对局")), _outcome_mark(str(r.get("outcome", ""))), int(resources.get("gathered", 0)), int(r.get("production", {}).get("units", 0)), float(build.get("value", 0.0)) * 100.0, int(combat.get("damage_dealt", 0)), int(combat.get("units_lost", 0)), _join(r.get("key_events", []))]
		list.add_child(label)
	dialog.add_child(list)
	add_child(dialog)
	dialog.popup_centered()


# ---------------- 导航 ----------------

func _on_back() -> void:
	get_tree().change_scene_to_file("res://source/main-menu/Growth.tscn")


func _on_escape() -> bool:
	_on_back()
	return true
