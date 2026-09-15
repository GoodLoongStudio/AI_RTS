class_name UnitComparePanel
extends PanelContainer

## 单位属性对比面板（对局内 HUD 叠加层）——**纯展示层**：
## 不发信号、不写状态、不碰玩法数据、不接管输入；只读 ProductionCatalog / ProductionTheme。
##
## ============================ 数据纪律 ============================
## · 数值只来自 `ProductionCatalog.entry()` / `stats_of()`（本文件 preload 成 CATALOG），
##   **本文件不硬编码任何单位数值**；
## · 读不到的属性一律画 "—"：ProductionCatalog 对项目里不存在的概念返回 **null 而不是 0**
##   （stats.armor 恒为 null，因为全仓库没有"单位护甲"概念），对应单元格**不画条形**，
##   只放一根等高占位条 —— 绝不用 0 长度 / 满格条形冒充真实数据；
## · 某一维度若**参评单位全部为 null**，整行每格都是 "—" 且条形全部隐藏，
##   并在维度名下标 "全员无数据"；
## · `build_time` 是 ProductionCatalog 的**推导字段**（requiredWork / 60，见该文件头第 5 条），
##   在维度名下打 "推导" 角标，不假装它是实测值；资源消耗取 cost.resource_a + resource_b。
##
## ============================ 优劣判定 ============================
## 条形比例 = 该单位该维度值 / **参评单位中的最大值**（与规格一致，与"优劣"无关：条形画的是量级）。
## 优劣只看方向：生命值 / 攻击 / 护甲 / 移动速度 / 攻击范围 **越大越好**；
##             资源消耗 / 生产时间 **越小越好**（行尾在图例里写明）。
## 每维度：最优那格文字用 GREEN + 文字角标 "best"，最差那格用 RED + 文字角标 "差"
## —— 两个角标都是**文字**，不靠颜色单独表意。
## 只有「≥2 个非空值」且「极值不相等」时才判定：全部相等 = 本维度没有优劣，不硬凑；
## 并列时取**第一个**出现者（不重复标记同一格）。
## 每个单位下方给一行小结 "优势 N / 劣势 M"（N/M = 该单位在上面各维度被判为最优/最差的次数）。
##
## ============================ 尺寸纪律（本项目踩过的坑） ============================
## 1) 宽度恒定 416px（<= 420）、声明最小高度恒 <= 320px：
##    · 单位列宽由个数**反算**：(内容宽 - 维度列 - 间隙) / n ⇒ 行宽恒等于内容宽；
##      4 个单位时列宽 78px，2 个单位时 160px，不论几个单位面板都不会变宽（上限锁死）；
##    · 高度额度是**量出来的**（_apply_height_budget）：先量表头/表尾/内外边距与间距，
##      余额才给滚动区 ⇒ 无论备注是一行还是两行，面板最小高度都 <= MAX_HEIGHT。
## 2) 滚动条 `vertical_scroll_mode = SCROLL_MODE_AUTO`（**禁止 SHOW_ALWAYS**，
##    用户明确抱怨过常驻滚动条）：内容装得下时额度 = 内容真实高度 ⇒ 根本不出现滚动条，
##    只有真的溢出才出现。
## 3) 换行：所有正文 Label 一律 **autowrap = OFF + 先按真实字体度量手动折行**
##    （复用 ProductionTooltip.wrap_text）。原因：Label 开 autowrap 时最小高度按"当前宽度"算，
##    首次布局前宽度是 0 ⇒ get_combined_minimum_size() 会爆到万 px 级（本项目已多次踩到）。
## 4) 每次重建后调 `SystemUIStyle.skip_subtree(self)`：SystemUIStyle.apply_to(PanelContainer)
##    会套 22/18 内边距的 glass()，那套边距会直接把高度预算冲破。
## 5) 行内小角标 / 小按钮全部自建并压掉内边距：SystemUIStyle.make_button() 会强设 44px 最小高，
##    塞进对比行里会把行高翻倍。
##
## ============================ 快捷键提示 ============================
## 顶部右侧用 `ProductionTheme.keycap()` 画「Esc 关闭」「C 对比」键帽。
## ⚠ 本组件**不接管输入**（没有 _input / _unhandled_key_input）：对局里 Esc / C 另有用途，
##   组件抢键会造出难排查的输入冲突。宿主只需在自家快捷键里调 close() / toggle_unit()。

const CATALOG := preload("res://source/match/hud/production/ProductionCatalog.gd")
const THEME := preload("res://source/match/hud/production/ProductionTheme.gd")
const TIP := preload("res://source/match/hud/production/ProductionTooltip.gd")

## 缺失值占位符（与 ProductionTooltip.NO_VALUE 同值；这里写死字面量避免 const 表达式跨脚本引用）。
const NO_VALUE := "—"
const TAG_MISSING := "缺"
const TAG_BEST := "best"
const TAG_WORST := "差"

const MIN_UNITS := 2
const MAX_UNITS := 4

## 尺寸预算（硬约束，见文件头第 1 条）。
const MAX_WIDTH := 420.0
const MAX_HEIGHT := 320.0
const PANEL_PADDING := 8.0
const PANEL_WIDTH := 416.0
const BODY_WIDTH := PANEL_WIDTH - PANEL_PADDING * 2.0
## 给可能出现的滚动条预留的宽度（AUTO 模式，出现时才占用）。
const SCROLLBAR_RESERVE := 14.0
const CONTENT_WIDTH := BODY_WIDTH - SCROLLBAR_RESERVE
const CAPTION_COLUMN := 62.0
const CELL_GAP := 4.0
const ROW_SEPARATION := 3
const BAR_HEIGHT := 6.0
const VALUE_FONT_SIZE := 10
const CAPTION_FONT_SIZE := 11
const NAME_FONT_SIZE := 10
const TAG_FONT_SIZE := 8
const NOTE_FONT_SIZE := 9
const KEYCAP_BOX := 20.0
## 滚动区最小高度下限（面板被压得再扁也要留一条可读的窗口）。
const MIN_SCROLL_HEIGHT := 72.0

## 对比维度（顺序 = 行顺序）。key 既是 ProductionCatalog.stats 的键，也是资源/推导字段名。
##   · lower_better = true ⇒ 越小越好（条形照样按量级画，优劣判定反向）
##   · derived      = true ⇒ ProductionCatalog.derived_fields 里的推导值，行首打 "推导"
##   · accent       = "stats"（青蓝）| "resource"（橙金）：非最优/最差格子的条形颜色
const ROW_DIMS := [
	{"key": "hp", "caption": "生命值", "suffix": "", "lower_better": false, "derived": false, "accent": "stats"},
	{"key": "damage", "caption": "攻击", "suffix": "", "lower_better": false, "derived": false, "accent": "stats"},
	{"key": "armor", "caption": "护甲", "suffix": "", "lower_better": false, "derived": false, "accent": "stats"},
	{"key": "speed", "caption": "移动速度", "suffix": " m/s", "lower_better": false, "derived": false, "accent": "stats"},
	{"key": "range", "caption": "攻击范围", "suffix": " m", "lower_better": false, "derived": false, "accent": "stats"},
	{"key": "cost", "caption": "资源消耗", "suffix": "", "lower_better": true, "derived": false, "accent": "resource"},
	{"key": "build_time", "caption": "生产时间", "suffix": " s", "lower_better": true, "derived": true, "accent": "resource"},
]

## 图例（常驻一行，不随状态变化）。用 "—" 的说明 + 越小越好的方向 + 数据源。
const LEGEND := "「—」= 配置中无此数据（不填 0）· 资源消耗/生产时间越小越好 · 源 ProductionCatalog"
## 空状态文案（少于 2 个单位时整表替换成它）。
const EMPTY_HINT := "请选择至少 2 个单位进行对比"
## 单位名 / 小结单元格的折行宽度（真实字体度量折行，autowrap 关闭）。
const CELL_TEXT_PADDING := 2.0


## 内容最小尺寸**不外传**的滚动容器。
##
## 为什么必须有这个内部类：ScrollContainer 会把内容的最小尺寸并入自己的最小尺寸，
## 而本面板的高度硬预算是 320px —— 一张 4 单位的对比表内容高度 ~230px 加上表头/表尾/
## 边距就顶到上限，只要内容再长一点，面板的声明最小高度就会跟着内容一起涨破 320px。
## 重写 _get_minimum_size() 返回 0 后，滚动区的高度完全由调用方（_apply_height_budget）
## 按"总预算 - 固定部分"显式给，超出的部分才会滚。
class BoundedScroll:
	extends ScrollContainer

	func _get_minimum_size() -> Vector2:
		return Vector2.ZERO


# ------------------------------------------------------------------ 状态

var _open := false
## 参与对比的 item_id（顺序 = 列顺序），已过滤未知 id 并截断到 MAX_UNITS。
var _ids: Array[String] = []
## 与 _ids 同序的 ProductionCatalog 条目（entry() 的深拷贝）。
var _entries: Array[Dictionary] = []
var _names: Array[String] = []
## 与 ROW_DIMS 同序的逐维度分析结果（见 _analyse）。
var _analysis: Array[Dictionary] = []
## 备注计数：open() 截断数 / 被忽略的未知 id 数 / toggle_unit 撞上限被拒。
var _dropped := 0
var _unknown := 0
var _limit_hit := false

var _body: VBoxContainer = null
var _scroll: ScrollContainer = null
var _table: VBoxContainer = null
var _note: Label = null


# ------------------------------------------------------------------ 公开 API

## 进入对比：item_ids 为 2..4 个 item_id。
##   · 少于 2 个（含空数组）→ 仍然可见，显示「请选择至少 2 个单位进行对比」；
##   · 多于 4 个 → 只取前 4 个，并在备注行写明"已截断 N 个"；
##   · 目录里查不到的 id → 忽略并在备注行写明"已忽略 N 个未知单位"（不画全 "—" 的假列）；
##   · 重复 id 去重。
func open(unit_ids: Array) -> void:
	_ensure_built()
	_open = true
	visible = true
	_dropped = 0
	_unknown = 0
	_limit_hit = false

	var wanted: Array[String] = []
	for raw in unit_ids:
		var item_id := str(raw)
		if item_id.is_empty() or wanted.has(item_id):
			continue
		if CATALOG.entry(item_id).is_empty():
			_unknown += 1
			continue
		if wanted.size() >= MAX_UNITS:
			_dropped += 1
			continue
		wanted.append(item_id)

	_ids = wanted
	_load_entries()
	_refresh()


## 关闭：面板隐藏 + 清空对比集合（不残留上一次的数据）。
func close() -> void:
	_open = false
	visible = false
	_ids.clear()
	_entries.clear()
	_names.clear()
	_analysis.clear()
	_dropped = 0
	_unknown = 0
	_limit_hit = false
	if _table != null:
		_clear(_table)
	if _note != null:
		_note.text = ""
	if _scroll != null:
		_scroll.custom_minimum_size.y = 0.0


func is_open() -> bool:
	return _open


## 加入 / 移出对比集合（"C 切换对比"的实际动作）。已满 4 个时不再加入并在备注里写明。
func toggle_unit(unit_id: String) -> void:
	_ensure_built()
	var index := _ids.find(unit_id)
	if index >= 0:
		_ids.remove_at(index)
		_limit_hit = false
		_load_entries()
		_refresh()
		return
	if CATALOG.entry(unit_id).is_empty():
		_unknown += 1
		_refresh()
		return
	if _ids.size() >= MAX_UNITS:
		_limit_hit = true
		_refresh()
		return
	_ids.append(unit_id)
	_limit_hit = false
	_load_entries()
	_refresh()


## 当前参与对比的 item_id（副本，调用方改它不影响面板）。
func compared_ids() -> Array:
	var out: Array = []
	for item_id in _ids:
		out.append(item_id)
	return out


## 列宽（由单位个数反算；供宿主/探针核对宽度预算）。
func column_width() -> float:
	return _cell_width()


# ------------------------------------------------------------------ 构建骨架

func _ensure_built() -> void:
	if _body != null:
		return
	# 自建面板底：**不能**让 SystemUIStyle 的 glass()（22/18 内边距）落到本面板上。
	add_theme_stylebox_override("panel", _panel_style())
	custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	# 吃掉自己范围内的鼠标，避免点穿到战场（纯 UI 行为，不动玩法状态）。
	mouse_filter = Control.MOUSE_FILTER_STOP

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.custom_minimum_size = Vector2(BODY_WIDTH, 0.0)
	_body.add_theme_constant_override("separation", 4)
	add_child(_body)
	_body.add_child(_build_header())

	_scroll = BoundedScroll.new()
	_scroll.name = "Scroll"
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	_body.add_child(_scroll)

	_table = VBoxContainer.new()
	_table.name = "Table"
	_table.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	_table.add_theme_constant_override("separation", ROW_SEPARATION)
	_scroll.add_child(_table)

	_body.add_child(_build_footer())
	SystemUIStyle.skip_subtree(self)


func _ready() -> void:
	_ensure_built()
	visible = _open


func _panel_style() -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(THEME.BG_DEEP, THEME.CYAN, 1, THEME.RADIUS)
	style.content_margin_left = PANEL_PADDING
	style.content_margin_right = PANEL_PADDING
	style.content_margin_top = PANEL_PADDING
	style.content_margin_bottom = PANEL_PADDING
	style.shadow_color = Color(0, 0, 0, 0.55)
	style.shadow_size = 6
	return style


func _build_header() -> Control:
	var row := HBoxContainer.new()
	row.name = "Header"
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	row.add_theme_constant_override("separation", 6)

	var mark := ColorRect.new()
	mark.color = THEME.CYAN
	mark.custom_minimum_size = Vector2(3, 13)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(mark)
	row.add_child(SystemUIStyle.make_label("单位属性对比", 12, THEME.CYAN))
	row.add_child(_tag("上限 4 个", THEME.AMBER))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	# 快捷键一律走键帽，不把字母混进正文（本项目统一约定）。
	row.add_child(_hotkey_hint("Esc", "关闭"))
	row.add_child(_hotkey_hint("C", "对比"))
	return row


func _build_footer() -> Control:
	var box := VBoxContainer.new()
	box.name = "Footer"
	box.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	box.add_theme_constant_override("separation", 1)
	# 动态备注（截断 / 忽略 / 撞上限）只在这里出现，且**只写事实**。
	_note = SystemUIStyle.make_label("", NOTE_FONT_SIZE, THEME.AMBER)
	_note.name = "Note"
	_note.autowrap_mode = TextServer.AUTOWRAP_OFF
	box.add_child(_note)
	box.add_child(_fitted_label(LEGEND, NOTE_FONT_SIZE, THEME.DIM, CONTENT_WIDTH))
	return box


# ------------------------------------------------------------------ 刷新

func _refresh() -> void:
	_ensure_built()
	_clear(_table)
	_analysis.clear()
	for dim in ROW_DIMS:
		_analysis.append(_analyse(dim))

	if _ids.size() < MIN_UNITS:
		_table.add_child(_empty_state())
	else:
		_table.add_child(_unit_header_row())
		for index in ROW_DIMS.size():
			_table.add_child(_dim_row(ROW_DIMS[index], _analysis[index]))
		_table.add_child(_summary_row())

	_update_note()
	_apply_height_budget()
	# 自建配色 / 自建内边距的子树必须豁免通用主题，否则 glass() 的 22/18 会把高度顶破。
	SystemUIStyle.skip_subtree(self)


## 高度预算：先量固定部分（表头 / 表尾 / 内外边距 / 间距），余额才给滚动区。
## 这样无论备注一行还是两行，面板声明的最小高度都不会超过 MAX_HEIGHT。
func _apply_height_budget() -> void:
	var separation := float(_body.get_theme_constant("separation"))
	var fixed := PANEL_PADDING * 2.0
	for child in _body.get_children():
		if child == _scroll:
			continue
		fixed += (child as Control).get_combined_minimum_size().y
	fixed += separation * maxf(float(_body.get_child_count() - 1), 0.0)
	var budget := maxf(MAX_HEIGHT - fixed, MIN_SCROLL_HEIGHT)
	var content := _table.get_combined_minimum_size().y
	_scroll.custom_minimum_size = Vector2(CONTENT_WIDTH, clampf(content, 0.0, budget))


func _update_note() -> void:
	var parts: Array[String] = []
	if _ids.size() >= MAX_UNITS:
		parts.append("最多对比 4 个")
	if _dropped > 0:
		parts.append("已截断 %d 个" % _dropped)
	if _unknown > 0:
		parts.append("已忽略 %d 个未知单位" % _unknown)
	if _limit_hit:
		parts.append("已达上限，未加入")
	if _note == null:
		return
	_note.text = "；".join(PackedStringArray(parts))


func _empty_state() -> Control:
	var box := VBoxContainer.new()
	box.name = "Empty"
	box.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	box.add_theme_constant_override("separation", 6)
	var title := SystemUIStyle.make_label(EMPTY_HINT, CAPTION_FONT_SIZE, THEME.AMBER)
	title.name = "EmptyHint"
	box.add_child(title)
	box.add_child(
		_fitted_label(
			"从生产面板选中 2..4 个单位后再次打开本面板；最多 4 个，超出会被截断。",
			NOTE_FONT_SIZE,
			THEME.MUTED,
			CONTENT_WIDTH
		)
	)
	return box


# ------------------------------------------------------------------ 表体

## 单位表头行：维度列 + 每个单位的 display_name（真实字体度量折行，autowrap 关闭）。
func _unit_header_row() -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_units"
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	row.add_theme_constant_override("separation", CELL_GAP)
	var caption := SystemUIStyle.make_label("对比单位", NAME_FONT_SIZE, THEME.DIM)
	caption.custom_minimum_size = Vector2(CAPTION_COLUMN, 0.0)
	row.add_child(caption)
	var cell_width := _cell_width()
	for index in _ids.size():
		var cell := VBoxContainer.new()
		cell.name = "Head_%s" % _ids[index]
		cell.custom_minimum_size = Vector2(cell_width, 0.0)
		cell.add_child(
			_fitted_label(_names[index], NAME_FONT_SIZE, THEME.TEXT, cell_width - CELL_TEXT_PADDING)
		)
		cell.add_child(
			_fitted_label(
				TIP.category_name(str(_entries[index].get("category", ""))),
				TAG_FONT_SIZE,
				THEME.DIM,
				cell_width - CELL_TEXT_PADDING
			)
		)
		row.add_child(cell)
	return row


func _dim_row(dim: Dictionary, analysis: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % str(dim.get("key", ""))
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	row.add_theme_constant_override("separation", CELL_GAP)
	row.add_child(_dim_caption(dim, analysis))
	var cell_width := _cell_width()
	for index in _ids.size():
		row.add_child(_dim_cell(dim, index, analysis, cell_width))
	return row


## 维度名（+ 推导角标 / 全员无数据标注）。宽度恒为 CAPTION_COLUMN：竖排不横排，避免撑宽行。
func _dim_caption(dim: Dictionary, analysis: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.name = "Caption_%s" % str(dim.get("key", ""))
	box.custom_minimum_size = Vector2(CAPTION_COLUMN, 0.0)
	box.add_theme_constant_override("separation", 0)
	box.add_child(
		SystemUIStyle.make_label(str(dim.get("caption", "")), CAPTION_FONT_SIZE, THEME.MUTED)
	)
	if bool(dim.get("derived", false)):
		box.add_child(SystemUIStyle.make_label("推导", TAG_FONT_SIZE, THEME.CYAN))
	if int(analysis.get("present", 0)) == 0:
		# 全员 null ⇒ 整行 "—" + 条形全隐藏，这里是文字证据（不靠颜色）。
		box.add_child(SystemUIStyle.make_label("全员无数据", TAG_FONT_SIZE, THEME.DIM))
	return box


## 单个单位在该维度的一格：数值 + 文字角标 + 条形（null 时条形换成等高占位，不画 0）。
func _dim_cell(dim: Dictionary, index: int, analysis: Dictionary, cell_width: float) -> Control:
	var values: Array = analysis.get("values", [])
	var raw = values[index]
	var has_value := raw is int or raw is float
	var best := int(analysis.get("best", -1)) == index
	var worst := int(analysis.get("worst", -1)) == index

	var cell := VBoxContainer.new()
	cell.name = "Cell_%s_%s" % [str(dim.get("key", "")), _ids[index]]
	cell.custom_minimum_size = Vector2(cell_width, 0.0)
	cell.add_theme_constant_override("separation", 2)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 3)

	if not has_value:
		# 缺失值：文字 "—"，不给条形（绝不用 0 充数）。
		line.add_child(SystemUIStyle.make_label(NO_VALUE, VALUE_FONT_SIZE, THEME.DIM))
		line.add_child(_tag(TAG_MISSING, THEME.DIM))
		cell.add_child(line)
		cell.add_child(_bar_placeholder(cell_width))
		return cell

	var text := TIP.fmt_num(raw, str(dim.get("suffix", "")))
	var color := THEME.TEXT
	if best:
		color = THEME.GREEN
	elif worst:
		color = THEME.RED
	line.add_child(SystemUIStyle.make_label(text, VALUE_FONT_SIZE, color))
	if best:
		line.add_child(_tag(TAG_BEST, THEME.GREEN))
	elif worst:
		line.add_child(_tag(TAG_WORST, THEME.RED))
	cell.add_child(line)

	var max_value := float(analysis.get("max", 0.0))
	var ratio := 0.0
	if max_value > 0.0:
		ratio = float(raw) / max_value
	var accent := THEME.GREEN if best else (THEME.RED if worst else _dim_accent(dim))
	var bar := THEME.bar(ratio, accent, cell_width, BAR_HEIGHT)
	bar.name = "Bar_%s_%s" % [str(dim.get("key", "")), _ids[index]]
	# SHRINK_BEGIN ⇒ 实际宽度 == custom_minimum_size，条形不会被 HBox 拉伸（比例才可信）。
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# 机器可判的取证钩子：比例 / 整条宽度 / 实际填充宽度（= 整条宽 × 比例）。
	bar.set_meta("compare_dim", str(dim.get("key", "")))
	bar.set_meta("compare_unit", _ids[index])
	bar.set_meta("compare_ratio", ratio)
	bar.set_meta("compare_full_width", cell_width)
	bar.set_meta("compare_drawn_width", cell_width * ratio)
	cell.add_child(bar)
	return cell


## 小结行：每个单位一格 "优势 N / 劣势 M"。
func _summary_row() -> Control:
	var row := HBoxContainer.new()
	row.name = "Row_summary"
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, 0.0)
	row.add_theme_constant_override("separation", CELL_GAP)
	var caption := SystemUIStyle.make_label("小结", CAPTION_FONT_SIZE, THEME.MUTED)
	caption.custom_minimum_size = Vector2(CAPTION_COLUMN, 0.0)
	row.add_child(caption)
	var cell_width := _cell_width()
	for index in _ids.size():
		var best_count := 0
		var worst_count := 0
		for analysis in _analysis:
			if int(analysis.get("best", -1)) == index:
				best_count += 1
			if int(analysis.get("worst", -1)) == index:
				worst_count += 1
		var color := THEME.MUTED
		if best_count > worst_count:
			color = THEME.GREEN
		elif worst_count > best_count:
			color = THEME.RED
		var cell := VBoxContainer.new()
		cell.name = "Summary_%s" % _ids[index]
		cell.custom_minimum_size = Vector2(cell_width, 0.0)
		cell.add_child(
			_fitted_label(
				"优势 %d / 劣势 %d" % [best_count, worst_count],
				NOTE_FONT_SIZE,
				color,
				cell_width - CELL_TEXT_PADDING
			)
		)
		row.add_child(cell)
	return row


# ------------------------------------------------------------------ 逐维度分析

## 一个维度的全部数值 + 极值 + 最优/最差下标。
## 返回 { values: Array（与 _ids 同序，null 保留）, present: int（非空个数）,
##        max: float, best: int, worst: int }。
func _analyse(dim: Dictionary) -> Dictionary:
	var values: Array = []
	var present := 0
	var max_value := 0.0
	var min_value := 0.0
	for index in _ids.size():
		var raw = _value_of(_entries[index], dim)
		values.append(raw)
		if not (raw is int or raw is float):
			continue
		var number := float(raw)
		if present == 0:
			max_value = number
			min_value = number
		else:
			max_value = maxf(max_value, number)
			min_value = minf(min_value, number)
		present += 1

	var best := -1
	var worst := -1
	# 全相等（含只剩 1 个非空值）时不判定优劣：没有差别就没有"最优/最差"。
	if present >= MIN_UNITS and not is_equal_approx(max_value, min_value):
		var higher_is_better := not bool(dim.get("lower_better", false))
		var best_value := max_value if higher_is_better else min_value
		var worst_value := min_value if higher_is_better else max_value
		for index in values.size():
			var raw = values[index]
			if not (raw is int or raw is float):
				continue
			if best < 0 and is_equal_approx(float(raw), best_value):
				best = index
			if worst < 0 and is_equal_approx(float(raw), worst_value):
				worst = index

	return {
		"values": values,
		"present": present,
		"max": max_value,
		"best": best,
		"worst": worst,
	}


## 读取一个维度在某个条目上的数值。**只读 ProductionCatalog 的条目**：
##   stats.*  ← entry()["stats"][key]（读不到就是 null）
##   cost     ← entry()["cost"].resource_a + resource_b（成本形状与 C# ToLegacyCosts 一致）
##   build_time ← entry()["build_time"]（ProductionCatalog 的推导值 requiredWork/60）
## 任何一步拿不到数值就返回 null —— 调用方据此画 "—"，绝不退化成 0。
func _value_of(item: Dictionary, dim: Dictionary) -> Variant:
	var key := str(dim.get("key", ""))
	if key == "cost":
		var cost = item.get("cost", null)
		if not (cost is Dictionary):
			return null
		var row: Dictionary = cost
		return float(int(row.get("resource_a", 0)) + int(row.get("resource_b", 0)))
	if key == "build_time":
		var raw_time = item.get("build_time", null)
		if raw_time is int or raw_time is float:
			return float(raw_time)
		return null
	return TIP.stat_at(item, key)


func _dim_accent(dim: Dictionary) -> Color:
	return THEME.AMBER if str(dim.get("accent", "stats")) == "resource" else THEME.CYAN


## 单位列宽 = (内容宽 - 维度列 - 全部间隙) / 单位个数。
## 反算保证"行宽 == 内容宽"恒定：2 个单位时列宽 160px，4 个单位时 78px，面板不变宽。
func _cell_width() -> float:
	var count := maxi(_ids.size(), 1)
	var gaps := CELL_GAP * maxf(float(count - 1), 0.0)
	return (CONTENT_WIDTH - CAPTION_COLUMN - gaps) / float(count)


func _bar_placeholder(width: float) -> Control:
	# 缺失值不留白：放一根**等高的空占位**（只占位、不画任何颜色），
	# 这样"某行没有条形"是明确的视觉信号，而不是被误读成"值为 0 所以条长为 0"。
	var spacer := Control.new()
	spacer.name = "BarPlaceholder"
	spacer.custom_minimum_size = Vector2(width, BAR_HEIGHT)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return spacer


# ------------------------------------------------------------------ 小控件

func _hotkey_hint(key: String, caption: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	row.add_child(THEME.keycap(key, THEME.AMBER, KEYCAP_BOX))
	row.add_child(SystemUIStyle.make_label(caption, NOTE_FONT_SIZE, THEME.DIM))
	return row


## 角标：自建 PanelContainer 并压掉内边距（SystemUIStyle.make_button 会强设 44px 最小高）。
func _tag(text: String, accent: Color) -> Control:
	var holder := PanelContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var style := SystemUIStyle.rounded(Color(0.043, 0.114, 0.153, 0.9), accent, 1, 3)
	style.content_margin_left = 3
	style.content_margin_right = 3
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	holder.add_theme_stylebox_override("panel", style)
	holder.add_child(SystemUIStyle.make_label(text, TAG_FONT_SIZE, accent))
	return holder


## 定宽正文：**先按真实字体度量手动折行，再把 autowrap 关掉**。
## 见文件头第 3 条：开着 autowrap 的 Label 在首次布局前会把最小高度算成"一字一行"，
## get_combined_minimum_size() 直接爆到万 px 级，高度预算当场失守。
func _fitted_label(text: String, size: int, color: Color, width: float) -> Label:
	var label := SystemUIStyle.make_label(text, size, color)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.text = TIP.wrap_text(text, width, _font_for(label), size)
	return label


func _font_for(control: Control) -> Font:
	var font: Font = null
	if control.is_inside_tree():
		font = control.get_theme_font("font")
	if font == null:
		font = ThemeDB.fallback_font
	return font


func _load_entries() -> void:
	_entries.clear()
	_names.clear()
	for item_id in _ids:
		var row := CATALOG.entry(item_id)
		_entries.append(row)
		_names.append(TIP.fmt_text(row.get("display_name", null)))


func _clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()