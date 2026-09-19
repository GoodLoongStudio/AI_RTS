extends "res://source/ui/MenuPage.gd"

## 单机与在线匹配共用的对局设置页（共享布局，唯一实现）。
##
## 【2026-09-14 统一大厅 UI】Play.tscn / Online.tscn 不再各写一套布局：
## 两者都是本场景的继承场景，只覆写根脚本与 mode 参数。
##   - mode = "offline"（Play）：单机模式。默认本机房主，隐藏服务器地址/端口/连接状态/
##     准备等在线控件；地图可选、4 个槽位用下拉选 指挥官 / 简单 AI / 中等 AI / 困难 AI / 空位；
##     开始走 NetSession.host() + Loading.tscn 原链路。
##   - mode = "online"（Online）：在线匹配。保留昵称、连接状态、加入局服、准备、
##     房主立即开局、房主增删 AI 槽位、房主改图（服务器权威同步、其他客户端只读）。
##
## 【2026-09-15 地图卡改版】地图下拉从卡片底部移到「地图名」同行右侧（用户指定），
## 下拉弹出菜单加长（下限见 MAP_POPUP_* 常量）；节点路径随之变为 MapBox/MapHeadRow/*。
##
## 地图数据一律从 MatchSetupShared / Constants.Match.ALL_MAPS 读取，
## .tscn 中不得写死地图名称、人数与尺寸。

const MatchSetupShared = preload("res://source/main-menu/MatchSetupShared.gd")
const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const OptionsScene = preload("res://source/main-menu/Options.tscn")

const MODE_OFFLINE := "offline"
const MODE_ONLINE := "online"

const SLOT_OPTIONS := [
	{"id": Constants.PlayerType.NONE, "label": "空位"},
	{"id": Constants.PlayerType.HUMAN, "label": "指挥官"},
	{"id": Constants.PlayerType.AI_EASY, "label": "简单 AI"},
	{"id": Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI, "label": "中等 AI"},
	{"id": Constants.PlayerType.AI_HARD, "label": "困难 AI"},
]

## 地图预览：正方形 256²；缺缩略图时用 4×4 占位棋盘，颜色按地图路径派生。
const PREVIEW_TILE_COUNT := 16
const PREVIEW_TILE_SIZE := Vector2(64, 64)
## 真实预览图的显示框：正方形，地图铺满、不再留 4:3 黑边。
const PREVIEW_BOX_SIZE := Vector2(256, 256)

## 地图下拉弹出菜单的下限尺寸（2026-09-15 用户要求「点击后的下拉菜单长一点」）：
## OptionButton 弹窗默认与按钮同宽、每项行高只有 20 出头——按钮移进标题行后更窄，
## 弹窗会跟着又小又挤。这里把菜单加宽（长地图名不截断）并把每项加高。
const MAP_POPUP_MIN_WIDTH := 300
const MAP_POPUP_FONT_SIZE := 18
const MAP_POPUP_ITEM_SEPARATION := 16

const VBOX_PATH := "CenterContainer/PanelContainer/MarginContainer/VBoxContainer"

@export var mode := MODE_OFFLINE

@onready var _title: Label = get_node(VBOX_PATH + "/TitleRow/Title")
@onready var _name_row: HBoxContainer = get_node(VBOX_PATH + "/TitleRow/NameRow")
@onready var _name_edit: LineEdit = get_node(VBOX_PATH + "/TitleRow/NameRow/NameEdit")
@onready var _random_map_button: Button = get_node(VBOX_PATH + "/TitleRow/RandomMapButton")
@onready var _hint: Label = get_node(VBOX_PATH + "/Hint")
@onready var _main_row: HBoxContainer = get_node(VBOX_PATH + "/MainRow")
@onready var _slots_box: VBoxContainer = get_node(VBOX_PATH + "/MainRow/SlotsBox")
@onready var _map_card: PanelContainer = get_node(VBOX_PATH + "/MainRow/MapCard")
@onready var _map_title: Label = get_node(VBOX_PATH + "/MainRow/MapCard/MapBox/MapHeadRow/MapTitle")
@onready var _map_sub: Label = get_node(VBOX_PATH + "/MainRow/MapCard/MapBox/MapSub")
@onready var _map_preview: GridContainer = get_node(VBOX_PATH + "/MainRow/MapCard/MapBox/MapPreview")
@onready var _map_select: OptionButton = get_node(VBOX_PATH + "/MainRow/MapCard/MapBox/MapHeadRow/MapSelect")
@onready var _map_hint: Label = get_node(VBOX_PATH + "/MainRow/MapCard/MapBox/MapHint")
@onready var _host_row: HBoxContainer = get_node(VBOX_PATH + "/HostRow")
@onready var _host_edit: LineEdit = get_node(VBOX_PATH + "/HostRow/HostEdit")
@onready var _port_edit: LineEdit = get_node(VBOX_PATH + "/HostRow/PortEdit")
@onready var _join_row: HBoxContainer = get_node(VBOX_PATH + "/JoinRow")
@onready var _join_button: Button = get_node(VBOX_PATH + "/JoinRow/JoinButton")
@onready var _local_host_button: Button = get_node(VBOX_PATH + "/JoinRow/LocalHostButton")
@onready var _ready_button: Button = get_node(VBOX_PATH + "/ReadyRow/ReadyButton")
@onready var _start_button: Button = get_node(VBOX_PATH + "/ReadyRow/StartButton")
@onready var _status_label: Label = get_node(VBOX_PATH + "/StatusLabel")
@onready var _back_button: Button = get_node(VBOX_PATH + "/BackButton")

var _map_paths: Array = []
var _slot_rows: Array = []
var _slot_selects: Array = []
var _options_panel: Control = null
var _last_connection_state := false
var _random_map_mode := false


func _ready() -> void:
	_apply_shared_styles()
	_apply_mode()
	_setup_map_selector()
	_build_slot_rows()
	_refresh_map_view()
	_clamp_to_viewport()
	get_viewport().size_changed.connect(_clamp_to_viewport)
	_extend_ready()


func _exit_tree() -> void:
	if mode != MODE_ONLINE:
		return
	if NetSession.status_changed.is_connected(_on_status_changed):
		NetSession.status_changed.disconnect(_on_status_changed)
	if NetSession.lobby_updated.is_connected(_on_lobby_updated):
		NetSession.lobby_updated.disconnect(_on_lobby_updated)
	if NetSession.lobby_map_changed.is_connected(_on_lobby_map_changed):
		NetSession.lobby_map_changed.disconnect(_on_lobby_map_changed)


# ---------------- 子类扩展点（默认空实现） ----------------

## 共享 UI 构建完成后的扩展入口（online 页在此接 NetSession 信号与调试钩子）。
func _extend_ready() -> void:
	pass


## 地图选择变化后的钩子（online 页在此把房主选择广播给服务器）。
func _on_map_changed(_path: String) -> void:
	pass


## 连接状态刷新（online 专用；offline 无连接概念）。
func _refresh_connection_ui() -> void:
	pass


func _on_status_changed(_text: String) -> void:
	pass


## 服务器大厅地图同步（online 页覆写；客户端只读更新展示）。
func _on_lobby_map_changed(_path: String) -> void:
	pass


func _on_join_button_pressed() -> void:
	pass


func _on_ready_button_pressed() -> void:
	pass


func _on_name_edit_text_changed(_new_text: String) -> void:
	pass


func _on_start_button_pressed() -> void:
	pass


# ---------------- 模式与共享布局 ----------------

## 两模式共用的紧凑面板样式：地图卡与通用 glass() 相比边距更小，
## 保证 1280×720 与窗口缩小时内容不顶出面板（面板 clip_contents=true）。
func _apply_shared_styles() -> void:
	var card_style := SystemUIStyle.rounded(
		SystemUIStyle.GLASS, SystemUIStyle.LINE, 1, SystemUIStyle.RADIUS_PANEL
	)
	card_style.content_margin_left = 14
	card_style.content_margin_right = 14
	card_style.content_margin_top = 12
	card_style.content_margin_bottom = 12
	_map_card.add_theme_stylebox_override("panel", card_style)
	# 自管样式：阻止 MenuPage 延迟 apply 的通用 PanelContainer 样式整片覆盖。
	_map_card.set_meta("ui_skip", true)


## 模式层显示切换：offline 隐藏一切在线控件；online 由 _refresh_connection_ui 细化。
func _apply_mode() -> void:
	var online := mode == MODE_ONLINE
	_title.text = "在线匹配" if online else "单机模式"
	_name_row.visible = online
	_status_label.visible = online
	_ready_button.visible = online
	_host_row.visible = online
	_join_row.visible = online
	_local_host_button.visible = false
	_start_button.text = "立即开局（房主开局）" if online else "开始游戏"
	_map_hint.text = "仅房主可修改地图" if online else "地图可自由切换"
	_random_map_button.visible = not online
	if online:
		_hint.text = "对局一律走腾讯云权威服。房主可改地图、增删 AI，并点「立即开局」开始对局。"
	else:
		_hint.text = "选择地图与槽位后点「开始游戏」。点「随机地图」只是选中随机模式，开局时才会生成。"
		_map_select.disabled = false


func _clamp_to_viewport() -> void:
	var panel := get_node_or_null("CenterContainer/PanelContainer") as Control
	if panel == null:
		return
	var viewport_rect := get_viewport().get_visible_rect()
	var margin := 40.0
	var max_w := maxf(360.0, viewport_rect.size.x - margin * 2.0)
	var max_h := maxf(360.0, viewport_rect.size.y - margin * 2.0)
	var cur: Vector2 = panel.custom_minimum_size
	panel.custom_minimum_size = Vector2(minf(cur.x, max_w), minf(cur.y, max_h))


# ---------------- 地图区 ----------------

func _setup_map_selector() -> void:
	var maps := MatchSetupShared.map_entries()
	_map_paths.clear()
	_map_select.clear()
	for entry in maps:
		_map_paths.append(str(entry[0]))
		_map_select.add_item(MatchSetupShared.map_label(str(entry[0])))
	var idx := _map_paths.find(NetSession.selected_map_path)
	_map_select.select(maxi(idx, 0))
	_style_map_popup()


## 下拉弹出菜单加长（用户 2026-09-15 要求「点击后的下拉菜单长一点，现在的太短了」）：
## 字号与行间距加大 → 每项 ≈ 39px（默认只有 20 出头）；宽度给下限 ≥300px → 比按钮宽、
## 最长地图名完整显示。
##
## ⚠ 样式必须**每次弹出前**重设，所以挂在 about_to_popup 上而不是只在 _ready 里设一次：
## PopupMenu 会缓存上一次的条目布局，只设一次时**首次弹出**用的是旧缓存——表现为
## "弹窗高度够、但最后一项没画出来"；宽度下限也会被每次弹出重置成内容尺寸。
## （均为 Godot 4.7 实测；另外不要直接改 popup.size，同样会打乱条目布局缓存。）
func _style_map_popup() -> void:
	var popup: PopupMenu = _map_select.get_popup()
	if popup == null:
		return
	if not popup.about_to_popup.is_connected(_apply_map_popup_style):
		popup.about_to_popup.connect(_apply_map_popup_style)
	_apply_map_popup_style()


func _apply_map_popup_style() -> void:
	var popup: PopupMenu = _map_select.get_popup()
	if popup == null:
		return
	popup.add_theme_font_size_override("font_size", MAP_POPUP_FONT_SIZE)
	popup.add_theme_constant_override("v_separation", MAP_POPUP_ITEM_SEPARATION)
	popup.min_size = Vector2(MAP_POPUP_MIN_WIDTH, 0)


func _on_random_map_toggled(pressed: bool) -> void:
	_set_random_map_mode(pressed)


func _set_random_map_mode(enabled: bool) -> void:
	_random_map_mode = enabled
	if _random_map_button.button_pressed != enabled:
		_random_map_button.set_pressed_no_signal(enabled)
	_map_select.disabled = enabled and mode != MODE_ONLINE
	if enabled:
		_hint.text = "已进入随机地图模式。点「开始游戏」后才会生成并进入对局。"
		_map_hint.text = "开局时现生成，现在还没有这张图"
	elif mode != MODE_ONLINE:
		_hint.text = "选择地图与槽位后点「开始游戏」。点「随机地图」只是选中随机模式，开局时才会生成。"
		_map_hint.text = "地图可自由切换"
	_refresh_map_view()


## 单机页覆写：按当前槽位开局；随机模式在加载页里现生成。
func _on_random_match_requested() -> void:
	_set_random_map_mode(true)


func _on_map_selected(index: int) -> void:
	if index < 0 or index >= _map_paths.size():
		return
	if _random_map_mode:
		_set_random_map_mode(false)
		return
	_refresh_map_view()
	_on_map_changed(str(_map_paths[index]))


func _refresh_map_view() -> void:
	if _random_map_mode:
		_map_title.text = "随机地图"
		_map_sub.text = "开局时生成 · 4人"
		_rebuild_random_map_preview()
		return
	var index := _map_select.selected
	if index < 0 or index >= _map_paths.size():
		return
	var path := str(_map_paths[index])
	_map_title.text = MatchSetupShared.map_label(path)
	_map_sub.text = MatchSetupShared.map_summary(path)
	_rebuild_map_preview(path)


func _rebuild_random_map_preview() -> void:
	for child in _map_preview.get_children():
		_map_preview.remove_child(child)
		child.free()
	var frame := Control.new()
	frame.custom_minimum_size = PREVIEW_BOX_SIZE
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(bg)
	var mark := Label.new()
	mark.text = "?"
	mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mark.add_theme_font_size_override("font_size", 108)
	mark.add_theme_color_override("font_color", Color(0.86, 0.90, 0.93))
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(mark)
	_map_preview.add_child(frame)


## 地图预览：优先用 tools/render_map_previews.gd **离线渲染真实地图**得到的缩略图
## （512² PNG，见 assets/map_previews/）；缺图时退回下面按路径派生颜色的占位棋盘，
## 保证【新地图还没重跑生成器】时页面依然不空白、也不报错。
func _rebuild_map_preview(path: String) -> void:
	for child in _map_preview.get_children():
		_map_preview.remove_child(child)
		child.free()
	var preview := _load_map_preview_texture(path)
	if preview != null:
		var shot := TextureRect.new()
		shot.texture = preview
		shot.custom_minimum_size = PREVIEW_BOX_SIZE
		shot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		shot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		shot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_map_preview.add_child(shot)
		return
	_rebuild_map_preview_placeholder(path)


## 取地图预览图。先走【已导入的 Texture2D】；导入产物缺失（刚生成、还没跑
## `--headless --import`）时 `ResourceLoader.exists` 为 false，但磁盘上已经有图，
## 所以再用 `Image.load_from_file` 直读兜底，避免【图明明在却显示占位棋盘】。
func _load_map_preview_texture(path: String) -> Texture2D:
	var res_path := MatchSetupShared.preview_path(path)
	var abs_path := ProjectSettings.globalize_path(res_path)
	# 必须先读盘：覆盖 PNG 后 Godot 的 .ctex 常常还是旧卡通图，
	# ResourceLoader.exists + load() 会让大厅预览看起来“完全没变”。
	if FileAccess.file_exists(abs_path):
		var image := Image.load_from_file(abs_path)
		if image != null and not image.is_empty():
			return ImageTexture.create_from_image(image)
	if ResourceLoader.exists(res_path):
		var resource = load(res_path)
		if resource is Texture2D:
			return resource
	return null


## 占位棋盘（旧行为，保留为兜底）：颜色由地图路径确定性派生，同图同色、切图变色。
func _rebuild_map_preview_placeholder(path: String) -> void:
	var base := Color.from_hsv(0.24 + float(abs(hash(path)) % 5) * 0.012, 0.34, 0.46)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(path)
	for i in range(PREVIEW_TILE_COUNT):
		var tile := ColorRect.new()
		tile.custom_minimum_size = PREVIEW_TILE_SIZE
		var tint := rng.randf_range(-0.07, 0.07)
		tile.color = Color(
			clampf(base.r + tint * 0.6, 0.0, 1.0),
			clampf(base.g + tint, 0.0, 1.0),
			clampf(base.b + tint * 0.4, 0.0, 1.0)
		)
		_map_preview.add_child(tile)


func selected_map_path() -> String:
	var index := _map_select.selected
	if index < 0 or index >= _map_paths.size():
		return NetSession.MAP_PATH
	return str(_map_paths[index])


# ---------------- 玩家槽位区 ----------------

func _build_slot_rows() -> void:
	var online := mode == MODE_ONLINE
	for i in range(NetSession.MAX_PLAYERS):
		var card := PanelContainer.new()
		card.name = "Slot%d" % i
		card.add_theme_stylebox_override("panel", _slot_card_style(i))
		# 槽位卡自管样式（玩家色描边 + 紧凑边距）：阻止通用 PanelContainer 样式覆盖。
		card.set_meta("ui_skip", true)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var color_rect := ColorRect.new()
		color_rect.custom_minimum_size = Vector2(8, 30)
		color_rect.color = _slot_color(i)
		row.add_child(color_rect)
		var index_label := Label.new()
		index_label.text = "%d" % (i + 1)
		row.add_child(index_label)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text = ""
		# 动态 Label 必须裁切 + 省略号（联机长昵称不得顶出卡片）。
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(name_label)
		var state_label := Label.new()
		state_label.text = ""
		row.add_child(state_label)
		var entry := {"color": color_rect, "name": name_label, "state": state_label}
		if online:
			var toggle := Button.new()
			toggle.text = "＋AI"
			toggle.visible = false
			toggle.pressed.connect(_on_slot_toggle_pressed.bind(i))
			row.add_child(toggle)
			entry["toggle"] = toggle
		else:
			var select := OptionButton.new()
			select.name = "SlotSelect%d" % i
			for option in SLOT_OPTIONS:
				select.add_item(str(option["label"]), int(option["id"]))
			_set_slot_controller_id(select, _default_offline_slot_kind(i))
			select.item_selected.connect(_on_offline_slot_selected.bind(i))
			row.add_child(select)
			# 【2026-09-15 用户要求】下拉弹出要**完整显示所有选项**（共 5 个：空位/指挥官/
			# 简单 AI/中等 AI/困难 AI），"非必要不要让用户去滚轮"。运行时新建的控件不会被
			# `MenuPage` 的 apply 覆盖（它只遍历建树时已存在的节点），所以这里单独套统一口径。
			SystemUIStyle.style_option_popup(select)
			_slot_selects.append(select)
			entry["select"] = select
		card.add_child(row)
		_slots_box.add_child(card)
		_slot_rows.append(entry)
		if not online:
			_sync_offline_slot_label(i)


func _slot_card_style(i: int) -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(SystemUIStyle.PANEL_ALT, _slot_color(i), 1, 6)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style


func _slot_color(i: int) -> Color:
	var colors = Constants.Player.COLORS
	if i < colors.size():
		return colors[i]
	return Color(0.5, 0.5, 0.5)


## 单机槽位默认：1 号指挥官，3 号简单 AI，其余空。
func _default_offline_slot_kind(i: int) -> int:
	match i:
		0:
			return Constants.PlayerType.HUMAN
		2:
			return Constants.PlayerType.AI_EASY
		_:
			return Constants.PlayerType.NONE


func _slot_controller_id(select: OptionButton) -> int:
	if select.selected < 0:
		return Constants.PlayerType.NONE
	return select.get_item_id(select.selected)


func _set_slot_controller_id(select: OptionButton, controller: int) -> void:
	for i in range(select.item_count):
		if select.get_item_id(i) == controller:
			select.select(i)
			return


## 单机槽位下拉：唯一 Human 顶掉其他 Human；不足 2 个玩家禁开局。
func _on_offline_slot_selected(_selected_index: int, slot: int) -> void:
	_start_button.disabled = false
	var selected_option_id := _slot_controller_id(_slot_selects[slot])
	if selected_option_id == Constants.PlayerType.HUMAN:
		for i in range(_slot_selects.size()):
			if i != slot and _slot_controller_id(_slot_selects[i]) == Constants.PlayerType.HUMAN:
				_set_slot_controller_id(_slot_selects[i], Constants.PlayerType.AI_EASY)
				_sync_offline_slot_label(i)
	elif selected_option_id == Constants.PlayerType.NONE:
		var active := 0
		for select in _slot_selects:
			if _slot_controller_id(select) != Constants.PlayerType.NONE:
				active += 1
		if active < 2:
			_start_button.disabled = true
	_sync_offline_slot_label(slot)


func _sync_offline_slot_label(i: int) -> void:
	if i >= _slot_selects.size():
		return
	var select: OptionButton = _slot_selects[i]
	var name_label: Label = _slot_rows[i]["name"]
	match _slot_controller_id(select):
		Constants.PlayerType.HUMAN:
			name_label.text = "指挥官（你）" if i == 0 else "指挥官 %d" % (i + 1)
		Constants.PlayerType.AI_EASY:
			name_label.text = "简单 AI"
		Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI:
			name_label.text = "中等 AI"
		Constants.PlayerType.AI_HARD:
			name_label.text = "困难 AI"
		_:
			name_label.text = "空位"


## 联机槽位状态刷新（服务器大厅广播，全量覆盖）。
func _on_lobby_updated(slots: Array) -> void:
	if mode != MODE_ONLINE:
		return
	var am_host := NetSession.is_room_owner()
	for i in range(_slot_rows.size()):
		if i >= slots.size():
			continue
		var entry: Dictionary = slots[i]
		var kind := int(entry.get("kind", NetSession.SLOT_EMPTY))
		var row: Dictionary = _slot_rows[i]
		var name_label: Label = row["name"]
		var state_label: Label = row["state"]
		var toggle: Button = row["toggle"]
		match kind:
			NetSession.SLOT_HUMAN:
				name_label.text = str(entry.get("name", "指挥官"))
				state_label.text = "已准备" if bool(entry.get("ready", false)) else "未准备"
			NetSession.SLOT_AI:
				name_label.text = "简单 AI"
				state_label.text = "补位"
			_:
				name_label.text = "空位"
				state_label.text = ""
		# 只有房主能切空槽 ↔ AI；人类占用的槽不可动。
		if am_host and not NetSession.is_dedicated_server():
			toggle.visible = kind != NetSession.SLOT_HUMAN
			toggle.text = "撤 AI" if kind == NetSession.SLOT_AI else "＋AI"
		else:
			toggle.visible = false
	_refresh_connection_ui()


func _on_slot_toggle_pressed(slot: int) -> void:
	if slot >= NetSession.last_lobby_slots.size():
		return
	var kind := int(NetSession.last_lobby_slots[slot].get("kind", NetSession.SLOT_EMPTY))
	var next_kind := NetSession.SLOT_EMPTY if kind == NetSession.SLOT_AI else NetSession.SLOT_AI
	NetSession.host_set_slot_kind(slot, next_kind)


# ---------------- 返回 / ESC / 设置面板（主菜单统一契约） ----------------

func _on_back_button_pressed() -> void:
	# 返回在任何连接状态下都必须生效；先断会话（幂等安全），切场景排到帧末。
	if NetSession.is_networked() and not NetSession.is_dedicated_server():
		NetSession.disconnect_session()
	get_tree().change_scene_to_file.call_deferred("res://source/main-menu/Main.tscn")


func _on_escape() -> bool:
	if _options_panel != null:
		_close_options_panel()
		return true
	_on_back_button_pressed()
	return true


## 注：页面**不再**注入「设置」按钮（主菜单已有设置入口）；本管线保留：
## EscReturnSmokeTest 直接驱动「ESC 只关面板、不越级返回」的契约。
func _open_options_panel() -> void:
	if _options_panel != null:
		return
	_options_panel = OptionsScene.instantiate()
	_options_panel.embedded_mode = true
	_options_panel.close_requested.connect(_close_options_panel)
	add_child(_options_panel)


func _close_options_panel() -> void:
	if _options_panel == null:
		return
	_options_panel.queue_free()
	_options_panel = null
