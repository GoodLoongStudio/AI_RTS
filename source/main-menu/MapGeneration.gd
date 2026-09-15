extends "res://source/ui/MenuPage.gd"

## 全屏地图工作台：把仓库内 tools/mapgen 的 G1–G4 生成、阶段进度、图层预览和任务历史接到游戏内。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")

const GENERATED_DIR := "res://source/match/maps/generated"
const WORKBENCH_PORTS := [8766, 8765]
const WORKBENCH_PORT := 8766

const STAGE_ORDER := ["g1_input", "g2_terrain", "g3_content", "g4_scene", "engine"]
const STAGE_TEXT := {
	"g1_input": "出生布局",
	"g2_terrain": "地形生成",
	"g3_content": "资源与素材",
	"g4_scene": "游戏场景导出",
	"engine": "引擎加载与导航验收",
}
const STAGE_STATUS_TEXT := {
	"done": "完成",
	"running": "进行中",
	"error": "失败",
	"skipped": "未运行",
}
const LAYERS := [
	{"id": "g4_ortho", "label": "最终顶视"},
	{"id": "g4_iso45", "label": "45°轴测"},
	{"id": "g4_oblique", "label": "斜视参考"},
	{"id": "g3", "label": "资源"},
	{"id": "overview", "label": "地形逻辑"},
	{"id": "strategy", "label": "路线"},
]
const G2_LEGEND := [
	{"color": Color8(28, 102, 188), "label": "水域"},
	{"color": Color8(208, 140, 48), "label": "台地"},
	{"color": Color8(48, 30, 18), "label": "悬崖"},
	{"color": Color8(220, 124, 36), "label": "坡道"},
	{"color": Color8(236, 204, 120), "label": "桥"},
	{"color": Color8(228, 222, 206), "label": "平地"},
	{"color": Color8(192, 57, 43), "label": "P0"},
	{"color": Color8(36, 113, 163), "label": "P1"},
	{"color": Color8(30, 132, 73), "label": "P2"},
	{"color": Color8(214, 137, 16), "label": "P3"},
	{"color": Color8(125, 60, 152), "label": "争夺"},
]
const G2_ROUTE_LEGEND := [
	{"color": Color8(192, 57, 43), "label": "主路"},
	{"color": Color8(36, 113, 163), "label": "侧路"},
	{"color": Color8(30, 132, 73), "label": "经济路"},
]
const CHOICES := [
	{"key": "water_combo", "label": "河湖组合", "options": [
		{"value": "crossed", "label": "交错双河", "controls": {"river_enabled": 1, "river_layout": 2, "lake_count": 0}},
		{"value": "single_lake", "label": "单河一湖", "controls": {"river_enabled": 1, "river_layout": 1, "lake_count": 1}},
		{"value": "single_two_lakes", "label": "单河双湖", "controls": {"river_enabled": 1, "river_layout": 1, "lake_count": 2}},
		{"value": "crossed_lake", "label": "交河一湖", "controls": {"river_enabled": 1, "river_layout": 2, "lake_count": 1}},
		{"value": "separate_lake", "label": "分流一湖", "controls": {"river_enabled": 1, "river_layout": 3, "lake_count": 1}},
		{"value": "two_lakes", "label": "双湖盆地", "controls": {"river_enabled": 0, "river_layout": 2, "lake_count": 2}},
	]},
	{"key": "player_spacing", "label": "玩家距离", "options": [
		{"value": "any", "label": "不限"},
		{"value": "close", "label": "近"},
		{"value": "standard", "label": "适中"},
		{"value": "far", "label": "远"},
	]},
	{"key": "river_enabled", "label": "河流", "options": [
		{"value": 0, "label": "无"},
		{"value": 1, "label": "有"},
	]},
	{"key": "lake_count", "label": "湖泊", "options": [
		{"value": 0, "label": "无"},
		{"value": 1, "label": "一个"},
		{"value": 2, "label": "两个"},
	]},
	{"key": "water_size", "label": "水域大小", "options": [
		{"value": "standard", "label": "标准", "controls": {"lake_area": 5000, "river_width": 18}},
		{"value": "large", "label": "大", "controls": {"lake_area": 6000, "river_width": 24}},
	]},
	{"key": "plateau_max", "label": "高地数量", "options": [
		{"value": 6, "label": "六座"},
		{"value": 7, "label": "七座"},
		{"value": 8, "label": "八座"},
	]},
	{"key": "plateau_ramp_width", "label": "通路宽窄", "options": [
		{"value": 7, "label": "较窄"},
		{"value": 8, "label": "适中"},
		{"value": 12, "label": "较宽"},
	]},
]
const CONTROL_DEFAULTS := {
	"river_layout": 2,
	"river_enabled": 1,
	"lake_count": 0,
	"lake_area": 5000,
	"neutral_plateau_scale": 1.7,
	"plateau_max": 8,
	"landform_elongation": 1.2,
	"landform_recess": 0.2,
	"landform_softness": 0.16,
	"plateau_ramp_width": 8,
	"river_width": 18,
	"river_bend_scale": 1.0,
	"river_crossings": 6,
	"obstacle_percent": 40,
	"cover_cluster_max": 10,
	"layout_attempts": 4,
}

var _params_box: VBoxContainer
var _inspect_box: VBoxContainer
var _layer_row: HBoxContainer
var _history_row: HBoxContainer
var _preview: TextureRect
var _empty: Label
var _legend_bar: HFlowContainer
var _progress_banner: PanelContainer
var _progress_phase: Label
var _progress_detail: Label
var _map_status: Label
var _map_title: Label
var _meta: Label
var _title: Label
var _subtitle: Label
var _seed_edit: LineEdit
var _generate_button: Button
var _preview_button: Button
var _replay_button: Button
var _workbench_button: Button
var _retry_button: Button
var _rebuild_button: Button
var _play_button: Button
var _hint: Label
var _result_summary: Label
var _checks_label: Label
var _api: HTTPRequest
var _img: HTTPRequest
var _poll_timer: Timer

var _workbench_url := ""
var _boot: Dictionary = {}
var _controls: Dictionary = {}
var _spacing := "any"
var _jobs: Array = []
var _selected_id := ""
var _active_id := ""
var _layer := "g4_ortho"
var _busy := false
var _polling := false
var _image_token := 0
var _chip_groups: Dictionary = {}
var _layer_buttons: Dictionary = {}
var _stage_rows: Dictionary = {}
var _metric_labels: Dictionary = {}
var _backend_launched := false


func _ready() -> void:
	SystemUIStyle.apply(self)
	_params_box = $SafeMargin/Root/Body/ParamsCard/ParamsCol/ParamsScroll/ParamsBox
	_generate_button = $SafeMargin/Root/Body/ParamsCard/ParamsCol/GenerateFooter/GenerateButton
	_preview_button = $SafeMargin/Root/Body/ParamsCard/ParamsCol/GenerateFooter/PreviewButton
	_replay_button = $SafeMargin/Root/Body/ParamsCard/ParamsCol/GenerateFooter/ReplayButton
	_inspect_box = $SafeMargin/Root/Body/InspectCard/InspectScroll/InspectBox
	_layer_row = $SafeMargin/Root/Body/CenterCol/LayerRow
	_history_row = $SafeMargin/Root/Body/CenterCol/HistoryScroll/HistoryRow
	_preview = $SafeMargin/Root/Body/CenterCol/PreviewAspect/Viewport/Preview
	_empty = $SafeMargin/Root/Body/CenterCol/PreviewAspect/Viewport/Empty
	_legend_bar = $SafeMargin/Root/Body/CenterCol/LegendBar
	_progress_banner = $SafeMargin/Root/Body/CenterCol/ProgressBanner
	_progress_phase = $SafeMargin/Root/Body/CenterCol/ProgressBanner/ProgressBox/ProgressPhase
	_progress_detail = $SafeMargin/Root/Body/CenterCol/ProgressBanner/ProgressBox/ProgressDetail
	_map_status = $SafeMargin/Root/Body/CenterCol/Caption/MapStatus
	_map_title = $SafeMargin/Root/Body/CenterCol/Caption/MapTitle
	_meta = $SafeMargin/Root/TopBar/Meta
	_title = $SafeMargin/Root/TopBar/TitleBox/Title
	_subtitle = $SafeMargin/Root/TopBar/TitleBox/Subtitle
	_workbench_button = $SafeMargin/Root/TopBar/WorkbenchButton
	_controls = CONTROL_DEFAULTS.duplicate()
	_api = HTTPRequest.new()
	_api.timeout = 1.2
	add_child(_api)
	_img = HTTPRequest.new()
	_img.timeout = 8.0
	add_child(_img)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 1.0
	_poll_timer.timeout.connect(_poll_active)
	add_child(_poll_timer)
	_build_params()
	_build_layers()
	_build_inspector()
	_tone()
	SystemUIStyle.apply(self)
	_tone()
	call_deferred("_after_theme")
	_generate_button.grab_focus()
	_refresh_legend()
	_ensure_workbench()


func _after_theme() -> void:
	_tone()
	_refresh_chips()
	_refresh_layers(_selected_job())
	_render_history()


func _tone() -> void:
	_title.add_theme_color_override("font_color", SystemUIStyle.AMBER_HI)
	_subtitle.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	_meta.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	_map_status.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	_map_title.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	_empty.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	_progress_phase.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	_progress_detail.add_theme_color_override("font_color", SystemUIStyle.MUTED)
	for node in [_title, _subtitle, _meta, _map_status, _map_title, _empty, _progress_phase, _progress_detail]:
		node.set_meta("ui_skip", true)


func _build_params() -> void:
	_add_heading(_params_box, "地图设置", SystemUIStyle.AMBER)
	_hint = _add_note(_params_box, "出生点由系统随机安排。完整地图走 G1→G4→引擎验收。")
	for choice in CHOICES:
		_add_choice_group(choice)
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	var seed_label := SystemUIStyle.make_label("地貌编号", 14, SystemUIStyle.TEXT)
	seed_label.custom_minimum_size = Vector2(72, 0)
	seed_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_seed_edit = LineEdit.new()
	_seed_edit.placeholder_text = "0 = 随机"
	_seed_edit.text = "0"
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var roll := SystemUIStyle.make_button("换一个", 40)
	roll.custom_minimum_size.x = 84
	roll.pressed.connect(_on_roll_seed)
	seed_row.add_child(seed_label)
	seed_row.add_child(_seed_edit)
	seed_row.add_child(roll)
	_params_box.add_child(seed_row)
	var reset := SystemUIStyle.make_button("恢复默认", 40)
	reset.pressed.connect(_on_reset_defaults)
	_params_box.add_child(reset)
	_add_note(_params_box, "完整地图：出生布局 → 地形 → 资源 → 游戏场景与导航验收。")


func _build_layers() -> void:
	for spec in LAYERS:
		var button := SystemUIStyle.make_button(str(spec["label"]), 36)
		button.toggle_mode = true
		button.set_meta("layer", spec["id"])
		button.pressed.connect(_on_layer_pressed.bind(str(spec["id"])))
		_layer_row.add_child(button)
		_layer_buttons[spec["id"]] = button
	_refresh_layers(null)


func _build_inspector() -> void:
	_add_heading(_inspect_box, "地图检查", SystemUIStyle.CYAN)
	_result_summary = _add_note(_inspect_box, "生成后会显示阶段进度、指标与验收结果。")
	for stage_id in STAGE_ORDER:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_label := SystemUIStyle.make_label(str(STAGE_TEXT[stage_id]), 13, SystemUIStyle.TEXT)
		name_label.custom_minimum_size = Vector2(110, 0)
		var state_label := SystemUIStyle.make_label("等待", 13, SystemUIStyle.DIM)
		state_label.custom_minimum_size = Vector2(52, 0)
		var detail_label := SystemUIStyle.make_label("", 12, SystemUIStyle.MUTED)
		detail_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		detail_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		row.add_child(name_label)
		row.add_child(state_label)
		row.add_child(detail_label)
		_inspect_box.add_child(row)
		SystemUIStyle.skip_subtree(name_label)
		_stage_rows[stage_id] = {"state": state_label, "detail": detail_label}
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	for key in ["nearest", "plateaus", "rivers", "lakes", "crossings", "width"]:
		var cell := VBoxContainer.new()
		var cap := SystemUIStyle.make_label(_metric_caption(key), 11, SystemUIStyle.DIM)
		var val := SystemUIStyle.make_label("—", 18, SystemUIStyle.TEXT)
		cell.add_child(cap)
		cell.add_child(val)
		grid.add_child(cell)
		SystemUIStyle.skip_subtree(cap)
		_metric_labels[key] = val
	_inspect_box.add_child(grid)
	_checks_label = _add_note(_inspect_box, "检查项：—")
	_retry_button = SystemUIStyle.make_button("重试本任务", 44)
	_retry_button.disabled = true
	_retry_button.pressed.connect(_on_retry_pressed)
	_inspect_box.add_child(_retry_button)
	_rebuild_button = SystemUIStyle.make_button("只重建视觉", 44)
	_rebuild_button.disabled = true
	_rebuild_button.pressed.connect(_on_rebuild_pressed)
	_inspect_box.add_child(_rebuild_button)
	_play_button = SystemUIStyle.make_button("试玩这张地图", 52)
	_play_button.disabled = true
	_play_button.pressed.connect(_on_play_pressed)
	_inspect_box.add_child(_play_button)


func _add_heading(parent: Control, text: String, color: Color) -> void:
	var label := SystemUIStyle.make_label(text, 20, color)
	parent.add_child(label)
	SystemUIStyle.skip_subtree(label)


func _add_note(parent: Control, text: String) -> Label:
	var label := SystemUIStyle.make_label(text, 12, SystemUIStyle.MUTED)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	SystemUIStyle.skip_subtree(label)
	return label


func _add_choice_group(choice: Dictionary) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var title := SystemUIStyle.make_label(str(choice["label"]), 14, SystemUIStyle.TEXT)
	box.add_child(title)
	SystemUIStyle.skip_subtree(title)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 6)
	flow.add_theme_constant_override("v_separation", 6)
	var buttons: Array = []
	for option in choice["options"]:
		var button := SystemUIStyle.make_button(str(option["label"]), 36)
		button.pressed.connect(_on_choice_pressed.bind(str(choice["key"]), option))
		flow.add_child(button)
		buttons.append({"button": button, "option": option})
	box.add_child(flow)
	_params_box.add_child(box)
	_chip_groups[choice["key"]] = buttons


func _on_choice_pressed(key: String, option: Dictionary) -> void:
	if key == "player_spacing":
		_spacing = str(option["value"])
	elif option.has("controls"):
		for control_key in option["controls"]:
			_controls[control_key] = option["controls"][control_key]
	else:
		_controls[key] = option["value"]
	_refresh_chips()


func _refresh_chips() -> void:
	for choice in CHOICES:
		var key := str(choice["key"])
		var selected = _choice_value(choice)
		for entry in _chip_groups.get(key, []):
			var button: Button = entry["button"]
			var is_on := str(entry["option"]["value"]) == str(selected)
			_paint_chip(button, is_on)
	if _hint != null:
		var n := 0
		if _boot.has("layouts"):
			for layout in _boot["layouts"]:
				if _spacing == "any" or str(layout.get("spacing", "")) == _spacing:
					n += 1
		_hint.text = "出生点由系统随机安排。当前距离范围内有 %d 套布局。" % n if n > 0 \
			else "出生点由系统随机安排。完整地图走 G1→G4→引擎验收。"


func _choice_value(choice: Dictionary):
	var key := str(choice["key"])
	if key == "player_spacing":
		return _spacing
	if choice["options"][0].has("controls"):
		for option in choice["options"]:
			var ok := true
			for control_key in option["controls"]:
				if float(_controls.get(control_key, -1)) != float(option["controls"][control_key]):
					ok = false
					break
			if ok:
				return option["value"]
		return ""
	return _controls.get(key, choice["options"][0]["value"])


func _paint_chip(button: Button, selected: bool) -> void:
	if button.has_meta("ui_skip"):
		button.remove_meta("ui_skip")
	SystemUIStyle.apply_to(button)
	if not selected:
		return
	button.add_theme_stylebox_override("normal", SystemUIStyle.rounded(Color("#173847"), SystemUIStyle.CYAN, 2, SystemUIStyle.RADIUS))
	button.add_theme_color_override("font_color", Color.WHITE)
	button.set_meta("ui_skip", true)


func _on_roll_seed() -> void:
	_seed_edit.text = str(1 + randi() % 2147483647)


func _on_reset_defaults() -> void:
	_controls = CONTROL_DEFAULTS.duplicate()
	_spacing = "any"
	_seed_edit.text = "0"
	_refresh_chips()
	_set_caption("准备就绪", "已恢复默认地貌参数", SystemUIStyle.CYAN)


func _on_layer_pressed(layer: String) -> void:
	_layer = layer
	_refresh_layers(_selected_job())
	var job := _selected_job()
	if job.get("status", "") == "done":
		_load_layer_image(job)


func _refresh_layers(job: Variant) -> void:
	var has_job: bool = job is Dictionary and not (job as Dictionary).is_empty()
	var job_data: Dictionary = job as Dictionary if has_job else {}
	var full: bool = has_job and str(job_data.get("target", "g2")) == "full"
	var stages: Dictionary = _job_stages(job_data)
	var g3_ok: bool = full and str(stages.get("g3_content", {}).get("status", "")) == "done"
	var g4_ok: bool = full and str(stages.get("engine", {}).get("status", "")) == "done"
	var available: Dictionary = {
		"g4_ortho": g4_ok,
		"g4_iso45": g4_ok,
		"g4_oblique": g4_ok,
		"g3": g3_ok,
		"overview": has_job,
		"strategy": has_job,
	}
	if not has_job:
		for key in available:
			available[key] = true
	elif not full:
		for key in available:
			available[key] = key in ["overview", "strategy"]
	if has_job and not available.get(_layer, false):
		_layer = "g4_ortho" if g4_ok else "overview"
	_refresh_legend()
	for layer_id in _layer_buttons:
		var button: Button = _layer_buttons[layer_id]
		button.visible = bool(available.get(layer_id, false))
		button.button_pressed = layer_id == _layer
		_paint_chip(button, layer_id == _layer)


func _on_generate_full() -> void:
	_start_generate("full", false)


func _on_generate_g2() -> void:
	_start_generate("g2", false)


func _on_replay_pressed() -> void:
	_start_generate(str(_selected_job().get("target", "full")), true)


func _start_generate(target: String, replay: bool) -> void:
	if _busy:
		return
	if _workbench_url.is_empty():
		await _ensure_workbench()
	if _workbench_url.is_empty():
		_set_caption("服务未连接", "本机生成服务没起来，可点右上角重试。", SystemUIStyle.AMBER)
		return
	var payload := _build_payload(target, replay)
	if payload.is_empty():
		return
	_busy = true
	_set_form_disabled(true)
	_set_caption("提交中", "正在把任务交给工作台…", SystemUIStyle.CYAN)
	var job := await _http_json(_api, HTTPClient.METHOD_POST, _workbench_url + "/api/generate", payload, 8.0)
	if job.is_empty() or str(job.get("id", "")).is_empty():
		_busy = false
		_set_form_disabled(false)
		_set_caption("未生成", str(job.get("error", "工作台未返回任务。")), SystemUIStyle.RED)
		return
	_upsert_job(job)
	_select_job(str(job["id"]))
	_start_polling(str(job["id"]))


func _build_payload(target: String, replay: bool) -> Dictionary:
	var payload := {
		"target": target,
		"schema_version": 2,
		"player_spacing": _spacing,
		"controls": _controls.duplicate(),
	}
	if replay:
		var job := _selected_job()
		var config: Dictionary = job.get("config", {})
		if config.is_empty():
			_set_caption("无法复现", "请先选中一张已生成的地图。", SystemUIStyle.AMBER)
			return {}
		payload["layout_seed"] = config.get("layout_seed")
		payload["terrain_seed"] = config.get("terrain_seed")
		payload["controls"] = config.get("controls", _controls).duplicate()
		return payload
	var seed_text := _seed_edit.text.strip_edges()
	if seed_text.is_empty() or seed_text == "0":
		return payload
	if not seed_text.is_valid_int():
		_set_caption("参数无效", "地貌编号必须是 0–2147483647 的整数。", SystemUIStyle.RED)
		return {}
	var seed := int(seed_text)
	if seed < 0 or seed > 2147483647:
		_set_caption("参数无效", "地貌编号必须是 0–2147483647 的整数。", SystemUIStyle.RED)
		return {}
	payload["terrain_seed"] = seed
	return payload


func _on_retry_pressed() -> void:
	if _busy or _selected_id.is_empty() or _workbench_url.is_empty():
		return
	_busy = true
	_set_form_disabled(true)
	var job := await _http_json(_api, HTTPClient.METHOD_POST,
		"%s/api/jobs/%s/retry" % [_workbench_url, _selected_id], {}, 8.0)
	if job.is_empty() or str(job.get("id", "")).is_empty():
		_busy = false
		_set_form_disabled(false)
		return
	_upsert_job(job)
	_select_job(str(job["id"]))
	_start_polling(str(job["id"]))


func _on_rebuild_pressed() -> void:
	if _busy or _selected_id.is_empty() or _workbench_url.is_empty():
		return
	_busy = true
	_set_form_disabled(true)
	var job := await _http_json(_api, HTTPClient.METHOD_POST,
		"%s/api/jobs/%s/rebuild_visual" % [_workbench_url, _selected_id], {}, 8.0)
	if job.is_empty() or str(job.get("id", "")).is_empty():
		_busy = false
		_set_form_disabled(false)
		return
	_upsert_job(job)
	_select_job(str(job["id"]))
	_start_polling(str(job["id"]))


func _start_polling(job_id: String) -> void:
	_active_id = job_id
	_busy = true
	_set_form_disabled(true)
	_poll_timer.start()
	_poll_active()


func _poll_active() -> void:
	if _polling or _active_id.is_empty() or _workbench_url.is_empty():
		if _active_id.is_empty():
			_poll_timer.stop()
		return
	_polling = true
	var job := await _http_json(_api, HTTPClient.METHOD_GET, "%s/api/jobs/%s" % [_workbench_url, _active_id])
	_polling = false
	if job.is_empty():
		return
	_upsert_job(job)
	if str(job.get("id", "")) == _selected_id:
		_render_job(job)
	else:
		_render_history()
	if str(job.get("status", "")) == "running":
		return
	_active_id = ""
	_busy = false
	_poll_timer.stop()
	_set_form_disabled(false)


func _upsert_job(job: Dictionary) -> void:
	var job_id := str(job.get("id", ""))
	if job_id.is_empty():
		return
	for i in _jobs.size():
		if str(_jobs[i].get("id", "")) == job_id:
			_jobs[i] = job
			return
	_jobs.push_front(job)


func _selected_job() -> Dictionary:
	for job in _jobs:
		if str(job.get("id", "")) == _selected_id:
			return job
	return {}


func _select_job(job_id: String) -> void:
	_selected_id = job_id
	var job := _selected_job()
	_replay_button.disabled = job.is_empty() or _busy
	_render_history()
	_render_job(job)


func _render_job(job: Dictionary) -> void:
	if job.is_empty():
		_progress_banner.visible = false
		_refresh_layers(null)
		_render_stages({})
		_set_metrics({})
		_play_button.disabled = true
		_retry_button.disabled = true
		_rebuild_button.disabled = true
		return
	var status := str(job.get("status", ""))
	_refresh_layers(job)
	_render_stages(job)
	_render_progress(job)
	_retry_button.disabled = _busy or bool(job.get("baseline", false))
	_rebuild_button.disabled = _busy or str(job.get("target", "")) != "full" \
		or str(_job_stages(job).get("g4_scene", {}).get("status", "")) != "done"
	_play_button.disabled = _installed_map_path(job).is_empty()
	if status == "done":
		var full: bool = str(job.get("target", "g2")) == "full"
		var passed: bool = bool(job.get("map_pass", false)) if full else bool(job.get("result", {}).get("all_pass", false))
		_set_caption(
			"地图通过" if passed else "需检查",
			str(job.get("title", "已完成")),
			SystemUIStyle.GREEN if passed else SystemUIStyle.AMBER)
		_result_summary.text = _result_text(job, full, passed)
		_set_metrics(job.get("result", {}))
		_set_checks(job)
		_load_layer_image(job)
	elif status == "running":
		_set_caption("生成中", str(job.get("title", "新任务")), SystemUIStyle.CYAN)
		_result_summary.text = "正在生成。完成前，检查指标不会用旧图冒充新参数。"
		_set_metrics({})
	else:
		_set_caption("未生成", str(job.get("error", "本次没有生成地图")), SystemUIStyle.RED)
		_result_summary.text = str(job.get("error", "生成未完成。"))
		_empty.visible = true
		_preview.texture = null


func _result_text(job: Dictionary, full: bool, passed: bool) -> String:
	var result: Dictionary = job.get("result", {})
	var kind := "完整流水线" if full else "G2 快速预览"
	var headline := "地图完成并通过全部验收" if (full and passed) \
		else ("地图已生成，但有未通过的检查" if full \
		else ("通过全部几何检查" if passed else "有待处理的几何检查"))
	return "%s\n%s · G2 %s · 耗时 %s" % [
		headline, kind, str(result.get("version", "—")), _seconds(job.get("duration", 0)),
	]


func _render_progress(job: Dictionary) -> void:
	var running := str(job.get("status", "")) == "running"
	_progress_banner.visible = running
	if not running:
		return
	var progress: Dictionary = job.get("progress", {})
	var stage := str(progress.get("stage", ""))
	var phase := str(progress.get("phase", ""))
	_progress_phase.text = "%s · %s" % [stage, phase] if not stage.is_empty() else (phase if not phase.is_empty() else "正在生成地图")
	if progress.has("attempt"):
		_progress_detail.text = "候选 %s / %s · %s" % [
			str(progress.get("attempt", 0)), str(progress.get("limit", "—")), _seconds(job.get("duration", 0)),
		]
	else:
		_progress_detail.text = "保持当前预览，完成后自动更新。 · %s" % _seconds(job.get("duration", 0))


func _job_stages(job: Dictionary) -> Dictionary:
	var stages = job.get("stages", {})
	return stages if stages is Dictionary else {}


func _render_stages(job: Dictionary) -> void:
	var stages := _job_stages(job)
	var full := str(job.get("target", "g2")) == "full"
	for stage_id in STAGE_ORDER:
		var row: Dictionary = _stage_rows[stage_id]
		var state_label: Label = row["state"]
		var detail_label: Label = row["detail"]
		if not full and not job.is_empty() and stage_id != "g1_input" and stage_id != "g2_terrain":
			state_label.text = "未运行"
			state_label.add_theme_color_override("font_color", SystemUIStyle.DIM)
			detail_label.text = "快速预览只跑到地形"
			continue
		var stage: Dictionary = stages.get(stage_id, {})
		var status := str(stage.get("status", "等待"))
		state_label.text = str(STAGE_STATUS_TEXT.get(status, status))
		var color := SystemUIStyle.DIM
		if status == "done":
			color = SystemUIStyle.RED if stage.get("pass", true) == false else SystemUIStyle.GREEN
		elif status == "running":
			color = SystemUIStyle.CYAN
		elif status == "error":
			color = SystemUIStyle.RED
		state_label.add_theme_color_override("font_color", color)
		if status == "done" and stage.has("duration_s"):
			detail_label.text = "%ss" % str(stage.get("duration_s"))
		else:
			detail_label.text = str(stage.get("error", stage.get("reason", "")))
		state_label.set_meta("ui_skip", true)


func _set_metrics(result: Dictionary) -> void:
	var values := {
		"nearest": _metric_text(result.get("nearest_pair_m", null), "m"),
		"plateaus": _metric_text(result.get("plateaus", null), "座"),
		"rivers": _metric_text(result.get("rivers", null), "条"),
		"lakes": _metric_text(result.get("lakes", null), "个"),
		"crossings": _metric_text(result.get("crossings", null), "处"),
		"width": _metric_text(result.get("min_route_width", null), "m"),
	}
	for key in values:
		var label: Label = _metric_labels[key]
		label.text = values[key]
		label.add_theme_color_override("font_color", SystemUIStyle.TEXT)
		label.set_meta("ui_skip", true)


func _metric_caption(key: String) -> String:
	return {
		"nearest": "最近玩家距离",
		"plateaus": "高地数量",
		"rivers": "河流",
		"lakes": "湖泊",
		"crossings": "过河点",
		"width": "路线最窄处",
	}.get(key, key)


func _metric_text(value, unit: String) -> String:
	if value == null:
		return "—"
	return "%s %s" % [str(value), unit]


func _set_checks(job: Dictionary) -> void:
	var checks: Dictionary = job.get("result", {}).get("checks", {})
	if checks.is_empty():
		_checks_label.text = "检查项：—"
		return
	var failed: PackedStringArray = []
	var labels: Dictionary = _boot.get("check_labels", {})
	for key in checks:
		if not bool(checks[key]):
			failed.append(str(labels.get(key, key)))
	_checks_label.text = "检查 %d/%d 通过" % [checks.size() - failed.size(), checks.size()] \
		if failed.is_empty() else "未通过：%s" % "；".join(failed)


func _render_history() -> void:
	for child in _history_row.get_children():
		child.queue_free()
	$SafeMargin/Root/Body/CenterCol/HistoryHead.text = "生成记录  %d" % _jobs.size()
	for job in _jobs:
		var button := SystemUIStyle.make_button(_history_label(job), 80)
		button.custom_minimum_size = Vector2(220, 80)
		button.pressed.connect(_select_job.bind(str(job.get("id", ""))))
		_paint_chip(button, str(job.get("id", "")) == _selected_id)
		_history_row.add_child(button)


func _history_label(job: Dictionary) -> String:
	var status := str(job.get("status", ""))
	var tag := "完整" if str(job.get("target", "g2")) == "full" else "地形"
	if status == "running":
		return "%s\n%s · 生成中" % [str(job.get("title", "任务")), tag]
	if status == "error":
		return "%s\n%s · 未生成" % [str(job.get("title", "任务")), tag]
	var result: Dictionary = job.get("result", {})
	return "%s\n%s · %s 河 · %s 湖" % [
		str(job.get("title", "任务")), tag,
		str(result.get("rivers", "—")), str(result.get("lakes", "—")),
	]


func _load_layer_image(job: Dictionary) -> void:
	if _workbench_url.is_empty() or str(job.get("status", "")) != "done":
		return
	_image_token += 1
	var token := _image_token
	var url := "%s/artifacts/%s/%s.png" % [_workbench_url, str(job.get("id", "")), _layer]
	var bytes := await _http_bytes(_img, url)
	if token != _image_token:
		return
	if bytes.is_empty():
		_preview.texture = null
		_empty.visible = true
		_empty.text = "这张预览图还没有生成，或当前图层不可用。"
		return
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		_empty.visible = true
		return
	_preview.texture = ImageTexture.create_from_image(_crop_g2_frame(image))
	_empty.visible = false
	_refresh_legend()


func _crop_g2_frame(image: Image) -> Image:
	## G2 总览把图例画在 64px 边框里，缩到预览格就看不见。裁掉边框让地形铺满，图例改由下方 LegendBar 显示。
	if _layer != "overview" and _layer != "strategy":
		return image
	if image.get_width() != 2048 or image.get_height() != 2048:
		return image
	return image.get_region(Rect2i(64, 64, 1920, 1920))


func _refresh_legend() -> void:
	if _legend_bar == null:
		return
	for child in _legend_bar.get_children():
		child.queue_free()
	var items: Array = []
	if _layer == "overview" or _layer == "strategy":
		items = G2_LEGEND.duplicate()
		if _layer == "strategy":
			items.append_array(G2_ROUTE_LEGEND)
	_legend_bar.visible = not items.is_empty()
	for item in items:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var rim := StyleBoxFlat.new()
		rim.bg_color = item["color"]
		rim.set_border_width_all(2)
		rim.border_color = Color(0.08, 0.08, 0.08)
		var chip := Panel.new()
		chip.custom_minimum_size = Vector2(18, 18)
		chip.add_theme_stylebox_override("panel", rim)
		var lab := SystemUIStyle.make_label(str(item["label"]), 14, SystemUIStyle.TEXT)
		lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(chip)
		row.add_child(lab)
		_legend_bar.add_child(row)


func _installed_map_path(job: Dictionary) -> String:
	var map_id := str(job.get("map_id", ""))
	if map_id.is_empty():
		return ""
	var path := "%s/%s/map_%s.tscn" % [GENERATED_DIR, map_id, map_id]
	return path if ResourceLoader.exists(path) else ""


func _on_play_pressed() -> void:
	var path := _installed_map_path(_selected_job())
	if path.is_empty():
		_set_caption("无法试玩", "这张图还没有安装进游戏工程。", SystemUIStyle.AMBER)
		return
	NetSession.clear_auto_start_intent()
	NetSession.disconnect_if_networked()
	var loading = LoadingScene.instantiate()
	loading.match_settings = _make_local_settings(4)
	loading.map_path = path
	get_parent().add_child(loading)
	get_tree().current_scene = loading
	queue_free()


func _make_local_settings(player_count: int) -> Resource:
	var settings := MatchSettings.new()
	for i in range(clampi(player_count, 2, 4)):
		var player := PlayerSettings.new()
		player.controller = Constants.PlayerType.HUMAN if i == 0 else Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		player.color = Constants.Player.COLORS[i]
		settings.players.append(player)
	settings.visible_player = 0
	settings.local_player_index = 0
	return settings


func _set_form_disabled(disabled: bool) -> void:
	_generate_button.disabled = disabled
	_preview_button.disabled = disabled
	_replay_button.disabled = disabled or _selected_id.is_empty()
	_generate_button.text = "正在生成…" if disabled else "生成完整地图"


func _set_caption(status: String, title: String, color: Color) -> void:
	_map_status.text = status
	_map_title.text = title
	_map_status.add_theme_color_override("font_color", color)
	_map_status.set_meta("ui_skip", true)


func _on_start_workbench() -> void:
	_backend_launched = false
	await _ensure_workbench()


func _map_tool_root() -> String:
	return ProjectSettings.globalize_path("res://tools/mapgen").trim_suffix("/").trim_suffix("\\")


func _ensure_workbench() -> void:
	if await _probe_workbench():
		return
	_set_caption("启动中", "正在拉起本机生成服务…", SystemUIStyle.CYAN)
	if not _launch_backend_silent():
		_set_caption("无法启动", "找不到 tools/mapgen/.venv-g2，请先跑 setup.ps1。", SystemUIStyle.RED)
		_render_history()
		return
	for _i in range(10):
		await get_tree().create_timer(1.0).timeout
		if await _probe_workbench():
			return
	_set_caption("服务未连接", "生成服务没有响应。可点右上角重试。已安装地图仍可试玩。", SystemUIStyle.AMBER)
	_render_history()


func _launch_backend_silent() -> bool:
	if _backend_launched:
		return true
	var root := _map_tool_root()
	var script := root.path_join("serve_g2.py")
	if not FileAccess.file_exists(script):
		return false
	var scripts := root.path_join(".venv-g2").path_join("Scripts")
	var pyw := scripts.path_join("pythonw.exe")
	var py := scripts.path_join("python.exe")
	var exe := pyw if FileAccess.file_exists(pyw) else py
	if not FileAccess.file_exists(exe):
		return false
	var args := PackedStringArray([script, "--port", str(WORKBENCH_PORT)])
	if OS.create_process(exe, args, false) < 0:
		return false
	_backend_launched = true
	return true


func _probe_workbench() -> bool:
	for port in WORKBENCH_PORTS:
		var url := "http://127.0.0.1:%d" % port
		var data := await _http_json(_api, HTTPClient.METHOD_GET, url + "/api/bootstrap")
		if data.is_empty() or not data.has("version"):
			continue
		_workbench_url = url
		_boot = data
		_jobs = data.get("jobs", [])
		if _jobs is Array:
			_jobs = _jobs.duplicate()
		else:
			_jobs = []
		_meta.text = "256 × 256 m    4 人对战    本地服务 · G2 %s" % str(data.get("version", ""))
		_set_caption("服务已连接", "可以在本页生成完整地图或快速预览地形", SystemUIStyle.GREEN)
		_refresh_chips()
		var active := str(data.get("active", ""))
		var selected := ""
		if not active.is_empty():
			selected = active
		else:
			for job in _jobs:
				if str(job.get("status", "")) == "done":
					selected = str(job.get("id", ""))
					break
		_render_history()
		if not selected.is_empty():
			_select_job(selected)
		if not active.is_empty():
			_start_polling(active)
		return true
	_workbench_url = ""
	return false


func _http_json(http: HTTPRequest, method: HTTPClient.Method, url: String, body: Dictionary = {}, timeout_sec := 1.2) -> Dictionary:
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	http.timeout = timeout_sec
	var headers := PackedStringArray()
	var payload := ""
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	if http.request(url, headers, method, payload) != OK:
		return {}
	var completed: Array = await http.request_completed
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		return {}
	var raw: PackedByteArray = completed[3]
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _http_bytes(http: HTTPRequest, url: String, method: HTTPClient.Method = HTTPClient.METHOD_GET, body: Dictionary = {}, timeout_sec := 8.0) -> PackedByteArray:
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		http.cancel_request()
	http.timeout = timeout_sec
	var headers := PackedStringArray()
	var payload := ""
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	if http.request(url, headers, method, payload) != OK:
		return PackedByteArray()
	var completed: Array = await http.request_completed
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS or int(completed[1]) >= 400:
		return PackedByteArray()
	return completed[3]


func _seconds(value) -> String:
	var total := int(round(float(value)))
	if total < 60:
		return "%ds" % total
	return "%dm %ds" % [int(total / 60.0), total % 60]


func _exit_tree() -> void:
	if _poll_timer != null:
		_poll_timer.stop()
	if _api != null:
		_api.cancel_request()
	if _img != null:
		_img.cancel_request()


func _on_back_pressed() -> void:
	if _poll_timer != null:
		_poll_timer.stop()
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


func _on_escape() -> bool:
	_on_back_pressed()
	return true
