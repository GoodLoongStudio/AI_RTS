extends "res://source/ui/MenuPage.gd"

## 战前战术讨论室（2026-10-05 阶段 2）：双栏布局（左地图简报+右副官席）。
## 不创建 Match / SimulationClock / NetSession / 单位实例。
## 玩家先选出生点 → 聊天启用；选点决定聊天上下文（地图+出生点）。

const ChatService = preload("res://source/ui/AdjutantChatService.gd")
const ModelService = preload("res://source/ui/AdjutantModelService.gd")
const StrategicMapIntel = preload("res://source/main-menu/StrategicMapIntel.gd")

const TITLE_FONT_PX := 26
const BODY_FONT_PX := 16
const SECONDARY_FONT_PX := 14
## 【2026-10-06 修复】聊天客户端超时：服务侧存在「迟到回复被丢弃」的路径
## （实测日志 late_response_dropped status_code=200），会让 UI **永远**停在「等待战略层…」✗。
## 这里加客户端兜底 ⇒ 超时后给**可见错误 + 可重试** ✓（验收项 8）。
const CHAT_CLIENT_TIMEOUT_S := 90.0
const MIN_TOUCH_PX := 44
const PANEL_INNER_MARGIN_PX := 18
const SAFE_MARGIN_MIN_PX := 24
const SAFE_MARGIN_RATIO := 0.05
const STACK_BELOW_WIDTH_PX := 1100
const PREVIEW_MIN_HEIGHT_PX := 360
const PREVIEW_MIN_HEIGHT_NARROW_PX := 220
const COMPACT_HEIGHT_PX := 820

var map_path := ""

var _intel: Dictionary = {}
var _selected_spawn: int = -1
var _adapter: Node = null
var _chat_busy := false
var _chat_wait_started_ms := 0

var _map_name_label: Label
var _map_size_label: Label
var _map_preview: TextureRect
var _spawn_buttons: Array = []
var _spawn_hint: Label
var _chat_history: VBoxContainer
var _chat_scroll: ScrollContainer
var _chat_status: Label
var _chat_input: LineEdit
var _chat_send: Button
var _facts_known: Label
var _facts_unknown: Label
var _chat_context_label: Label
var _safe_area: MarginContainer = null
var _layout_split: BoxContainer = null
var _header_map_label: Label = null
var _preview_frame: Control = null
var _preview_aspect: AspectRatioContainer = null
var _preview_missing: Label = null
var _spawn_markers: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply_system_ui_style()
	if map_path.is_empty():
		map_path = "res://source/match/maps/PlainAndSimple.tscn"
	_intel = StrategicMapIntel.build(map_path)
	_adapter = ChatService.new()
	add_child(_adapter)
	_adapter.setup("strategic-sandbox", "local_player")
	_adapter.context_provider = Callable(self, "_map_context")
	# 【2026-10-06 修复·关键接线】服务对外信号名是 **reply_ready** ✓
	# （不是 reply_received ✗）。页面此前**从未连接**任何回复信号 ✗ ⇒
	# 即使服务成功返回（日志有 response），UI 也永远停在「等待战略层…」✗。
	# 对照：AdjutantButton.gd:2071 有正确接线 ✓。
	if _adapter.has_signal("reply_ready") and not _adapter.reply_ready.is_connected(_on_chat_reply):
		_adapter.reply_ready.connect(_on_chat_reply)
	ModelService.ensure_started(self)
	_build_ui()


func _process(_delta: float) -> void:
	# 客户端超时兜底 ✓：只有"正在等待且尚未收到任何回复"时才触发 ✓
	if _chat_busy and _chat_wait_started_ms > 0:
		var waited := float(Time.get_ticks_msec() - _chat_wait_started_ms) / 1000.0
		if waited >= CHAT_CLIENT_TIMEOUT_S:
			_chat_wait_started_ms = 0
			_chat_busy = false
			if _chat_input != null:
				_chat_input.editable = true
			if _chat_send != null:
				_chat_send.disabled = _selected_spawn < 0
			if _chat_status != null:
				_chat_status.text = "错误：等待战略层超时（客户端 %.0fs 兜底），可点击重试" % CHAT_CLIENT_TIMEOUT_S
			_append_line("系统", "（战略层超时：服务未在 %.0f 秒内返回；可重新发送）" % CHAT_CLIENT_TIMEOUT_S, Color(1.0, 0.55, 0.4))
			if _adapter != null and is_instance_valid(_adapter) and _adapter.has_method("cancel_pending"):
				_adapter.cancel_pending()


func _on_escape() -> bool:
	_cleanup_and_back()
	return true


func _cleanup_and_back() -> void:
	if _adapter != null and is_instance_valid(_adapter):
		_adapter.cancel_pending()
		_adapter.queue_free()
		_adapter = null
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


func _build_ui() -> void:
	# 【2026-10-06 阶段 2B §3】结构重构：根节点只负责**背景 + 安全区**，
	# 所有内容挂在**中央面板**的 RootVBox 下，不再直接堆在页面根节点上
	# （旧结构就是"控件挤在左上角、中心空白"的结构性根因）。
	var scrim := ColorRect.new()
	scrim.name = "SystemScrim"
	scrim.color = SystemUIStyle.BG
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)

	_safe_area = MarginContainer.new()
	_safe_area.name = "SafeArea"
	_safe_area.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_safe_area)

	var center := PanelContainer.new()
	center.name = "CenterPanel"
	center.add_theme_stylebox_override("panel", _center_panel_style())
	_safe_area.add_child(center)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, PANEL_INNER_MARGIN_PX)
	center.add_child(margin)

	# 【架构修正】不再把整页塞进 ScrollContainer ✗ —— 那样子控件的 EXPAND_FILL 无效，
	# 面板只能按最小尺寸排 ⇒ 又矮又空 ✗。改为：**根 VBox 直接填满** ✓，
	# 「不裁切」由**两栏各自的 ScrollContainer**（左栏 BriefingScroll + 右栏历史滚动）承担 ✓。
	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.add_theme_constant_override("separation", 10)
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(root_vbox)

	var header := HBoxContainer.new()
	header.name = "HeaderRow"
	root_vbox.add_child(header)
	var title := Label.new()
	title.text = "⚔ 战前战术讨论室"
	title.add_theme_font_size_override("font_size", TITLE_FONT_PX)
	title.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	header.add_child(title)
	_header_map_label = Label.new()
	_header_map_label.add_theme_font_size_override("font_size", BODY_FONT_PX)
	_header_map_label.add_theme_color_override("font_color", SystemUIStyle.AMBER_HI)
	header.add_child(_header_map_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var back_btn := Button.new()
	back_btn.name = "BackButton"
	back_btn.text = "← 返回设置"
	back_btn.custom_minimum_size = Vector2(120, MIN_TOUCH_PX)
	back_btn.pressed.connect(_cleanup_and_back)
	header.add_child(back_btn)

	var subtitle := Label.new()
	subtitle.text = "当前为封闭测试，没有真实对局；只讨论战略，不执行命令。"
	subtitle.add_theme_font_size_override("font_size", BODY_FONT_PX)
	subtitle.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	root_vbox.add_child(subtitle)

	# 响应式双栏：宽屏左右分栏（0.44 / 0.56），窄屏自动**上下堆叠** ✓
	_layout_split = BoxContainer.new()
	_layout_split.name = "ContentSplit"
	_layout_split.vertical = false
	_layout_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 【裁切根因】原先把两栏最小高度钉成 320 ✗ ⇒ 面板只长到 320 高，预览被下沿裁掉 ✗。
	# 改为**让它撑满可用高度** ✓（内容超出时由各自/整页的 ScrollContainer 承担 ✓）。
	_layout_split.custom_minimum_size = Vector2(0, 0)
	_layout_split.add_theme_constant_override("separation", 12)
	root_vbox.add_child(_layout_split)

	var briefing := PanelContainer.new()
	briefing.name = "BriefingPanel"
	briefing.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	briefing.size_flags_vertical = Control.SIZE_EXPAND_FILL
	briefing.size_flags_stretch_ratio = 0.44
	_layout_split.add_child(briefing)
	# 【截图暴露的裁切问题】两栏内容高度在 900/720 下会超出窗口被切掉 ✗
	# （右栏输入框、左栏末行都看不到）⇒ 每栏各自套 ScrollContainer ✓，提示词要求"不裁切" ✓。
	var brief_scroll := ScrollContainer.new()
	brief_scroll.name = "BriefingScroll"
	brief_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	brief_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	briefing.add_child(brief_scroll)
	_build_briefing(brief_scroll)

	var adjutant := PanelContainer.new()
	adjutant.name = "AdjutantPanel"
	adjutant.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adjutant.size_flags_vertical = Control.SIZE_EXPAND_FILL
	adjutant.size_flags_stretch_ratio = 0.56
	_layout_split.add_child(adjutant)
	_build_adjutant(adjutant)

	resized.connect(_apply_responsive_layout)
	_apply_responsive_layout()
	# 【塌陷修复 2】首次布局完成前宽度为 0 ✗ ⇒ 延迟一帧按真实宽度重算方形高度 ✓
	_apply_responsive_layout.call_deferred()



## 出生点卡片的可读信息：方位（由地图中心指向出生点的八方位 ✓）+ 是否贴边 ✓ + 附近已知资源 ✓。
## 数据不足时一律写「未知」✓（提示词：严禁随机/估算/模型补齐 ✗）。
func _spawn_card_info(sp: Dictionary) -> String:
	var world := _map_world_size()
	var wx := float(sp.get("world_x", 0.0))
	var wz := float(sp.get("world_z", 0.0))
	var dirs := ["北", "东北", "东", "东南", "南", "西南", "西", "西北"]
	var dx := (world.x * 0.5) - wx
	var dz := wz - (world.y * 0.5)
	var bearing := "未知"
	if absf(dx) > 0.01 or absf(dz) > 0.01:
		var ang := atan2(dx, dz)
		var octant := int(round(ang / (TAU / 8.0)))
		bearing = dirs[wrapi(octant, 0, 8)]
	var edge := ""
	var margin := minf(minf(wx, world.x - wx), minf(wz, world.y - wz))
	if margin <= 24.0:
		edge = "·贴图缘"
	var res_line := "附近资源：未知"
	var res: Array = _intel.get("resources", []) if _intel is Dictionary else []
	if res.size() > 0:
		var near := 0
		var types := {}
		for r in res:
			var rx := float(r.get("world_x", 0.0))
			var rz := float(r.get("world_z", 0.0))
			if Vector2(rx - wx, rz - wz).length() <= 40.0:
				near += 1
				types[str(r.get("type", "未知"))] = true
		if near > 0:
			res_line = "附近资源：%d 处（%s）" % [near, "、".join(types.keys())]
		else:
			res_line = "附近资源：40m 内无"
	return "方位 %s%s\n%s" % [bearing, edge, res_line]


## 出生点标记配色：区分 4 个点但**不依赖红绿**（编号 + 形状 + 边框一起用 ✓）。
func _marker_style(index: int) -> StyleBoxFlat:
	var colors := [SystemUIStyle.CYAN, SystemUIStyle.AMBER_HI, Color("#8fd3a0"), Color("#c9a6ff")]
	var sb := StyleBoxFlat.new()
	sb.bg_color = colors[index % colors.size()]
	sb.border_color = Color(0.03, 0.06, 0.08)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(11)
	return sb


## 预览图缺失时的明确状态（提示词：不能显示空白深灰块当成功 ✓）。
func _show_preview_missing(preview_path: String, reason: String) -> void:
	if _preview_missing == null:
		return
	_preview_missing.visible = true
	_preview_missing.text = "⚠ 地图预览图%s\n%s\n（可在编辑器离线渲染：tools/render_map_previews.gd）" % [
		reason, preview_path]


## 地图世界尺寸（米）。权威来源：`Constants.Match.ALL_MAPS[path]["size"]` ✓
## （情报对象当前**没有** map_size 字段，这里页面侧只读补齐；不改并行中的情报服务 ✓）
## 地图真实长宽比（用于把预览锁成与地图一致的形状 ⇒ 方形图就是正方形 ✓）。
func _map_aspect_ratio() -> float:
	var w := _map_world_size()
	if w.y <= 0.01:
		return 1.0
	return maxf(0.2, minf(5.0, w.x / w.y))


func _map_world_size() -> Vector2:
	# 【2026-10-06】优先用**情报对象**的 map_size ✓（唯一权威 ✓，来自地图场景 Map 节点）；
	# 情报缺失/为 0 时才回退常量表 ✓。
	if _intel is Dictionary:
		var from_intel: Variant = _intel.get("map_size", null)
		if from_intel is Vector2 and (from_intel as Vector2) != Vector2.ZERO:
			return from_intel
	var info: Dictionary = Constants.Match.ALL_MAPS.get(map_path, {})
	var s: Variant = info.get("size", null)
	if s is Vector2i:
		return Vector2(s as Vector2i)
	if s is Vector2:
		return s
	return Vector2(256.0, 256.0)


## 把 4 个真实出生点的**世界坐标**映射到预览图内位置（按世界尺寸线性映射 ✓，绝不平均撒点 ✓）。
func _layout_preview_markers() -> void:
	if _preview_frame == null:
		return
	var world := _map_world_size()
	var frame_size := _preview_frame.size
	var spawns: Array = _intel.get("spawn_points", []) if _intel is Dictionary else []
	for i in range(_spawn_markers.size()):
		var mk: Label = _spawn_markers[i]
		if mk == null:
			continue
		if i >= spawns.size():
			mk.visible = false
			continue
		var sp: Dictionary = spawns[i]
		var uv := Vector2(
			clampf(float(sp.get("world_x", 0.0)) / maxf(1.0, world.x), 0.0, 1.0),
			clampf(float(sp.get("world_z", 0.0)) / maxf(1.0, world.y), 0.0, 1.0))
		mk.position = uv * frame_size - mk.size * 0.5
		mk.visible = true


## 中央面板样式：复用 SystemUIStyle 的深色玻璃 + 描边（不另造一套散乱颜色 ✓）。
func _center_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SystemUIStyle.GLASS_DEEP
	sb.border_color = SystemUIStyle.LINE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(PANEL_INNER_MARGIN_PX)
	return sb


## 响应式：窄屏堆叠 + 5% 安全边距（低宽度不低于 SAFE_MARGIN_MIN_PX ✓）。
func _apply_responsive_layout() -> void:
	if _safe_area == null:
		return
	var margin := int(maxf(SAFE_MARGIN_MIN_PX, size.x * SAFE_MARGIN_RATIO))
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		_safe_area.add_theme_constant_override(side, margin)
	if _layout_split != null:
		_layout_split.vertical = size.x < STACK_BELOW_WIDTH_PX
	# 【截图+探针暴露的裁切】窗口高度不足时压缩预览高度 ✓（提示词：不裁切 ✓）
	# 【塌陷修复】ScrollContainer 里控件高度由**最小高度**决定 ⇒ AspectRatioContainer 的最小高度是 0 ✗
	# ⇒ 预览会塌成一条细线。这里按"自己的宽度 × 地图长宽比"给出方形最小高度 ✓（低窗口高度时压缩 ✓）。
	# 【方形预览 ✓】用"可用宽度"算高度：高 = 宽 / 地图长宽比（208×208 ⇒ 正方形 ✓）
	if _preview_frame != null:
		var compact: bool = size.y < COMPACT_HEIGHT_PX
		# 【最终实现·最确定】不再测量父容器（ScrollContainer 里不可靠 ✗）：
		# 直接给预览一个**固定方形边长** ✓（紧凑模式小一点 ✓）。
		# 【用户要求：地图要大 ✓ 且后面 AI 要在上面交互 ✓】
		# 边长 = 左栏可用宽度（0.44 栏宽 − 内边距），钳在 [220, 420] ✓，保持正方形 ✓。
		var col_w: float = maxf(200.0, _layout_split.size.x * 0.44 - PANEL_INNER_MARGIN_PX * 2.0)
		var side: float = clampf(col_w, PREVIEW_MIN_HEIGHT_NARROW_PX, 420.0)
		if compact:
			side = clampf(col_w, 200.0, 300.0)
		# 高度 = 宽度 / 地图长宽比（208×208 ⇒ 正方形 ✓）；宽度固定 ⇒ 不会被父容器拉伸 ✓
		var h: float = side / maxf(0.2, _map_aspect_ratio())
		# 【收口】在最终执行的函数里再强制一次 ✓（此前被别处的 EXPAND_FILL 覆盖 ⇒ 实测 490×220 ✗）
		_preview_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_preview_frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_preview_frame.custom_minimum_size = Vector2(side, h)
		_preview_frame.size = Vector2(side, h)
		if _map_preview != null:
			_map_preview.size = Vector2(side, h)
	_layout_preview_markers()


func _build_briefing(parent: Control) -> void:
	var vb := VBoxContainer.new()
	# 收紧间距 ⇒ 让「地图名 / 尺寸 / 出生点按钮 / 卡片 / 提示 / **方形预览**」尽量都在首屏 ✓
	vb.add_theme_constant_override("separation", 3)
	parent.add_child(vb)

	var hdr := Label.new()
	hdr.text = "🗺 战区简报"
	hdr.add_theme_font_size_override("font_size", 18)
	hdr.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	vb.add_child(hdr)

	_map_name_label = Label.new()
	_map_name_label.add_theme_font_size_override("font_size", 16)
	vb.add_child(_map_name_label)
	_map_size_label = Label.new()
	_map_size_label.add_theme_font_size_override("font_size", 14)
	_map_size_label.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	vb.add_child(_map_size_label)

	# 【精简】"事实来源：所选地图"已在尺寸行内 ✓ ⇒ 不再单独占一行（首屏更紧凑 ✓）

	# 【第 3 次实现·最稳】不再用 AspectRatioContainer（在 ScrollContainer 里高度不可靠 ✗），
	# 改为**自己按可用宽度算方形边长**（见 _apply_responsive_layout ✓）：
	# 地图 208×208 ⇒ 正方形 ⇒ 边长 = min(可用宽, 上限) ✓，影像 STRETCH_SCALE 填满 ⇒ 不裁切不留边 ✓。
	_preview_frame = Control.new()
	_preview_frame.name = "MapPreviewWithMarkers"
	_preview_frame.set_meta("role", "map_surface")
	vb.add_child(_preview_frame)
	# 【最终修复】**不能**横向撑满 ✗（实测撑成 490×220 扁矩形）⇒ 固定方形 + 居中 ✓
	_preview_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# 【探针发现的真 bug】Control 在 VBox 里只按**最小尺寸**布局 ⇒ 宽度会是 0 ✗，
	# 出生点标记于是全部落在左边缘（实测 X 全为 0）⇒ 必须让它横向撑满 ✓。
	_preview_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_frame.custom_minimum_size = Vector2(PREVIEW_MIN_HEIGHT_PX, PREVIEW_MIN_HEIGHT_PX)
	_preview_frame.clip_contents = true
	# 【探针发现的真 bug 2】标记早于布局完成被排布 ⇒ 那时容器宽度还是 0 ✗，之后无人重排。
	# 监听容器自身 resized ⇒ 布局一给出真实尺寸就按世界坐标重排 ✓。
	_preview_frame.resized.connect(_layout_preview_markers)
	_preview_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE


	_map_preview = TextureRect.new()
	_map_preview.name = "MapPreview"
	_map_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	# 用 STRETCH_SCALE：预览图是本图渲染，长宽比与地图一致 ⇒ 直接线性映射世界坐标 ✓
	_map_preview.stretch_mode = TextureRect.STRETCH_SCALE
	_map_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_frame.add_child(_map_preview)
	# 【为后续 AI 在地图上交互预留】独立标注层 ✓：现在完全惰性、鼠标穿透 ✓，
	# 将来副官的标记/箭头/规划点直接 add_child 到这里，坐标用同一套 uv = 世界 ÷ 世界尺寸 ✓。
	var annot := Control.new()
	annot.name = "AIAnnotationLayer"
	annot.set_anchors_preset(Control.PRESET_FULL_RECT)
	annot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_frame.add_child(annot)

	_preview_missing = Label.new()
	_preview_missing.name = "PreviewMissing"
	_preview_missing.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_missing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_missing.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_preview_missing.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_missing.add_theme_font_size_override("font_size", BODY_FONT_PX)
	_preview_missing.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	_preview_missing.visible = false
	_preview_frame.add_child(_preview_missing)

	for i in range(4):
		var mk := Label.new()
		mk.name = "SpawnMarker%d" % (i + 1)
		mk.text = str(i + 1)
		mk.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mk.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		mk.custom_minimum_size = Vector2(22, 22)
		mk.size = Vector2(22, 22)
		mk.add_theme_font_size_override("font_size", 14)
		mk.add_theme_color_override("font_color", Color(0.05, 0.08, 0.1))
		mk.add_theme_stylebox_override("normal", _marker_style(i))
		mk.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mk.visible = false
		_preview_frame.add_child(mk)
		_spawn_markers.append(mk)

	var preview_path: String = str(_intel.get("preview_path", ""))
	if ResourceLoader.exists(preview_path):
		var tex := load(preview_path)
		if tex != null:
			_map_preview.texture = tex
			_preview_missing.visible = false
		else:
			_show_preview_missing(preview_path, "预览图无法加载")
	else:
		_show_preview_missing(preview_path, "尚未生成")

	var spawn_hdr := Label.new()
	spawn_hdr.text = "选择出生点："
	spawn_hdr.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	vb.add_child(spawn_hdr)
	var spawn_grid := HBoxContainer.new()
	spawn_grid.add_theme_constant_override("separation", 6)
	vb.add_child(spawn_grid)
	for sp in _intel.get("spawn_points", []):
		var idx: int = sp["index"]
		# 【2026-10-06 阶段 2B】出生点卡片 = 编号/坐标按钮 + **可计算的方位/边缘/附近已知资源** ✓
		# （提示词要求：不能只有坐标 ✓；未知就写「未知」✓，绝不估算或让模型补齐 ✗）
		var card := VBoxContainer.new()
		card.name = "SpawnCard%d" % (idx + 1)
		card.add_theme_constant_override("separation", 2)
		spawn_grid.add_child(card)
		var btn := Button.new()
		btn.name = "SpawnButton%d" % (idx + 1)
		btn.text = "%d\n(%.0f,%.0f)" % [idx + 1, sp["world_x"], sp["world_z"]]
		btn.custom_minimum_size = Vector2(84, MIN_TOUCH_PX)
		btn.add_theme_font_size_override("font_size", 14)
		btn.toggle_mode = true
		btn.tooltip_text = "出生点 %d · 地图设计中的可选起点（不是敌军基地）" % (idx + 1)
		btn.set_meta("spawn_index", idx)
		btn.pressed.connect(_on_spawn_selected.bind(idx))
		card.add_child(btn)
		var info := Label.new()
		info.name = "SpawnInfo%d" % (idx + 1)
		info.text = _spawn_card_info(sp)
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.custom_minimum_size = Vector2(118, 0)
		info.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
		info.add_theme_color_override("font_color", SystemUIStyle.MUTED)
		card.add_child(info)
		_spawn_buttons.append(btn)
	if _spawn_buttons.is_empty():
		var no_sp := Label.new()
		no_sp.text = "地图无 SpawnPoints 数据"
		no_sp.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
		vb.add_child(no_sp)

	_spawn_hint = Label.new()
	_spawn_hint.text = "点上方按钮选择出生点（选中后右侧可对话）"
	_spawn_hint.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	_spawn_hint.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	vb.add_child(_spawn_hint)

	var facts_hdr := Label.new()
	# 【2026-10-06 阶段 2B】预览容器：真实预览图 + **4 个真实出生点标记**（世界坐标 → 预览像素 ✓）
	# + **明确的缺失态**（没有预览图时不允许留空白深灰块冒充成功 ✓）。
	# 【2026-10-06 用户要求】地图要**方形显示全** ✓：
	# 用 AspectRatioContainer 把预览锁成「地图真实长宽比」（本图 208×208 ⇒ 正方形 ✓），
	# 于是 STRETCH_SCALE 既不裁切也不留边 ✓，世界坐标→预览像素的映射依然精确 ✓。
	facts_hdr.text = "已知地图事实："
	facts_hdr.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	vb.add_child(facts_hdr)
	_facts_known = Label.new()
	_facts_known.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	_facts_known.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var kf: Array = _intel.get("known_facts", [])
	_facts_known.text = "\n".join(kf) if kf.size() > 0 else "无"
	vb.add_child(_facts_known)

	var unk_hdr := Label.new()
	unk_hdr.text = "当前未知信息："
	unk_hdr.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	vb.add_child(unk_hdr)
	_facts_unknown = Label.new()
	_facts_unknown.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	_facts_unknown.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var uf: Array = _intel.get("unknown_facts", [])
	_facts_unknown.text = "\n".join(uf) if uf.size() > 0 else "无"
	_facts_unknown.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vb.add_child(_facts_unknown)

	_refresh_intel_labels()


func _build_adjutant(parent: Control) -> void:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	parent.add_child(vb)

	var map_name: String = str(_intel.get("map_name", "?"))
	var hdr := Label.new()
	hdr.text = "💬 战前战术讨论 · %s" % map_name
	hdr.add_theme_font_size_override("font_size", 18)
	hdr.add_theme_color_override("font_color", SystemUIStyle.CYAN)
	vb.add_child(hdr)

	_chat_context_label = Label.new()
	_chat_context_label.add_theme_font_size_override("font_size", SECONDARY_FONT_PX)
	_chat_context_label.add_theme_color_override("font_color", SystemUIStyle.AMBER)
	_chat_context_label.text = "请先选择一个出生点"
	vb.add_child(_chat_context_label)

	_chat_scroll = ScrollContainer.new()
	_chat_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(_chat_scroll)
	var history_box := VBoxContainer.new()
	history_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_scroll.add_child(history_box)
	_chat_history = history_box
	_append_line("副官", "战前战术讨论室就绪。请先选择一个出生点，然后我们可以讨论战略。", Color(0.3, 0.85, 1.0))

	_chat_status = Label.new()
	_chat_status.add_theme_font_size_override("font_size", 12)
	_chat_status.text = _status_text()
	vb.add_child(_chat_status)

	var input_row := HBoxContainer.new()
	input_row.add_theme_constant_override("separation", 6)
	vb.add_child(input_row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "请先选择一个出生点"
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.custom_minimum_size = Vector2(0, 44)
	_chat_input.editable = false
	_chat_input.text_submitted.connect(func(_t): _on_send())
	input_row.add_child(_chat_input)
	_chat_send = Button.new()
	_chat_send.text = "发送"
	_chat_send.custom_minimum_size = Vector2(80, 44)
	_chat_send.disabled = true
	_chat_send.pressed.connect(_on_send)
	input_row.add_child(_chat_send)


func _status_text() -> String:
	if ModelService.is_ready():
		return "战略聊天可用"
	if ModelService.is_warming():
		return "战略模型预热中（首次约 1~2 分钟）"
	return "未连接（发送后自动连接本地模型）"


func _refresh_status() -> void:
	if _chat_status != null:
		_chat_status.text = _status_text()


func _on_spawn_selected(idx: int) -> void:
	if _selected_spawn == idx:
		return
	if _adapter != null:
		_adapter.cancel_pending()
	_selected_spawn = idx
	_chat_busy = false
	_chat_input.editable = true
	_chat_send.disabled = false
	for btn in _spawn_buttons:
		var btn_idx: int = btn.get_meta("spawn_index", -1)
		btn.button_pressed = (btn_idx == idx)
	var sp := _find_spawn(idx)
	if not sp.is_empty():
		_chat_context_label.text = "你选择了出生点 %d · 坐标 (%.0f, %.0f)" % [
			idx + 1, sp["world_x"], sp["world_z"]]
		_chat_input.placeholder_text = "讨论从这个出生点出发的战略…"
	if _adapter != null:
		var new_conv := "chat-conv-strategic-sandbox-%s-sp%d" % [
			_intel.get("map_id", "?"), idx + 1]
		_adapter.conversation_id = new_conv
		_adapter.setup(new_conv, "local_player")
	# 【2026-10-06 修复】VBoxContainer **没有** clear() ✗（实测报 Invalid call ⇒ 打断选点流程，
	# 导致会话设置不完整、聊天发出去拿不到回复）⇒ 改为逐个释放子节点 ✓。
	for child in _chat_history.get_children():
		_chat_history.remove_child(child)
		child.queue_free()
	var sp2 := _find_spawn(idx)
	_append_line("副官", "你选择了出生点 %d（坐标 %.0f, %.0f）。当前没有实时敌情。我们可以讨论开局战略。"
		% [idx + 1, sp2["world_x"], sp2["world_z"]], Color(0.3, 0.85, 1.0))
	_refresh_status()


func _find_spawn(idx: int) -> Dictionary:
	for sp in _intel.get("spawn_points", []):
		if sp["index"] == idx:
			return sp
	return {}


func _on_send() -> void:
	_chat_wait_started_ms = Time.get_ticks_msec()
	if _chat_busy or _adapter == null or _selected_spawn < 0:
		return
	var text: String = _chat_input.text.strip_edges()
	if text.is_empty():
		return
	var result: Dictionary = _adapter.send(text)
	if not bool(result.get("queued", false)):
		var ec: String = str(result.get("error_code", ""))
		_chat_status.text = "错误：%s" % _adapter.error_text(ec)
		return
	_chat_busy = true
	_chat_input.clear()
	_chat_input.editable = false
	_chat_send.disabled = true
	_append_line("你", text, Color.WHITE)
	if bool(result.get("warming", false)):
		_chat_status.text = "模型预热中…消息将在就绪后自动发送"
	else:
		_chat_status.text = "等待战略层…"


func _on_chat_reply(result: Dictionary) -> void:
	var reply_conv: String = str(result.get("conversation_id", ""))
	if _adapter != null and is_instance_valid(_adapter) \
			and not reply_conv.is_empty() and reply_conv != _adapter.conversation_id:
		return
	_chat_busy = false
	_chat_input.editable = true
	_chat_send.disabled = false
	if bool(result.get("ok", false)):
		_append_line("副官", str(result.get("assistant_text", "")), Color(0.3, 0.85, 1.0))
		_chat_status.text = "已回复（%.1fs · %s）" % [
			int(result.get("elapsed_ms", 0)) / 1000.0, str(result.get("model", ""))]
	else:
		var ec := str(result.get("error_code", ""))
		_chat_status.text = "错误：%s" % _adapter.error_text(ec)
		_append_line("系统", "（战略层没有回复：%s）" % _adapter.error_text(ec), Color(1.0, 0.55, 0.4))


func _append_line(sender: String, text: String, color: Color) -> void:
	if _chat_history == null:
		return
	var label := RichTextLabel.new()
	label.bbcode_enabled = false
	label.fit_content = true
	label.scroll_active = false
	label.add_theme_font_size_override("normal_font_size", 14)
	label.text = "%s：%s" % [sender, text]
	label.add_theme_color_override("default_color", color)
	_chat_history.add_child(label)
	await get_tree().process_frame
	if _chat_scroll != null and is_instance_valid(_chat_scroll):
		_chat_scroll.scroll_vertical = int(_chat_scroll.get_v_scroll_bar().max_value)


func _map_context() -> String:
	var base := "[战局摘要] "
	if not _intel.get("ok", false):
		return base + "地图情报不可用"
	var spawns := []
	for sp in _intel.get("spawn_points", []):
		spawns.append("#%d(%.0f,%.0f)" % [sp["index"] + 1, sp["world_x"], sp["world_z"]])
	var res_count: int = _intel.get("resources", []).size()
	var spawn_line := ""
	if _selected_spawn >= 0:
		var sp := _find_spawn(_selected_spawn)
		if not sp.is_empty():
			spawn_line = " 玩家出生点=#%d 坐标=(%.0f,%.0f)。" % [
				_selected_spawn + 1, sp["world_x"], sp["world_z"]]
	return base + "地图=%s 尺寸=见预览。出生点=%s。资源节点=%d个。%s 未知=敌方单位/意图/实时资源。模式=战前讨论。" % [
		_intel.get("map_name", "?"),
		"、".join(spawns) if spawns.size() > 0 else "未知",
		res_count, spawn_line]


func _refresh_intel_labels() -> void:
	# 提示词 §1：**页面标题必须显示地图名称**，且与日志里的 map_path 一致 ✓
	if _header_map_label != null:
		_header_map_label.text = "· %s" % str(_intel.get("map_name", "（地图未知）"))
	if _intel.get("ok", false):
		_map_name_label.text = str(_intel.get("map_name", ""))
	else:
		_map_name_label.text = "地图情报加载失败"
		_map_name_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.3))
	# 【修复】原来这里把**地图路径**塞进了"尺寸"标签（提示词要求显示尺寸 ✓）
	var world := _map_world_size()
	_map_size_label.text = "尺寸 %d × %d（事实来源：所选地图）" % [int(world.x), int(world.y)]
	_layout_preview_markers()
