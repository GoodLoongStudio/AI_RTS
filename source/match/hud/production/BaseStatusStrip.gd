class_name BaseStatusStrip
extends PanelContainer

## 顶部基地状态条（游戏内右侧生产栏）——**纯展示层**：
## 不写任何玩法状态、不发信号、不 produce / 不 cancel / 不改资源 / 不改 hp。
##
## ============================ 9 项与它们的项目现实 ============================
##
## 用户点名要 9 项，但**项目里只有 6 项真有数据源**，另外 3 项根本没有对应概念。
## 所以本文件把「有」与「没有」写进同一张 const 表（CHIPS），缺的项画 "—" + DIM +
## Tooltip 说明"项目无此数据概念"，**绝不拿别的东西假装**（不许用 0 或其他数值顶替）。
##
##   key                数据来源                                             状态
##   -----------------  ---------------------------------------------------  ----------
##   base_name          player 名下的 CommandCenter 节点（scene_file_path     有
##                      含 CommandCenter；退化判据 unit_type_id=="command_center"，
##                      见 _command_center 的注释）→ 目录 display_name / 节点名
##   tech_level         ——                                                    没有
##   hp                 CommandCenter 节点的 hp / hp_max（Unit.gd:60-63）      有
##   energy             ——                                                    没有
##   resource_a         player.resource_a（Player.gd:5，C# 权威账户只读镜像）  有
##   resource_cap       ——                                                    没有
##   production_slots   各生产建筑 production_queue 当前长度 vs queueLimit      有（推导）
##   alerts             context["alerts"] 传入的字符串                        有（调用方给）
##   hermes             ProductionCatalog.hermes_advice(profile, {}, "")       有
##
## 这 3 项为什么是"没有"（已按仓库范围确认，不是我偷懒）：
##   · tech_level   —— 全库没有科技树 / 基地等级；ProductionCatalog 对每个条目
##                     的 tech_level 恒返回 null（见 ProductionCatalog.gd:604-609）。
##   · energy       —— 全库没有"能源"资源；ProductionCatalog.energy_cost 恒为 null。
##                     主菜单体系里也没有任何能源账户。
##   · resource_cap —— 全库无 resourceCap / MaxResources 之类的上限字段；
##                     EconomyRuntime 只登记余额，不登记上限。
## 这 3 项由 static func missing_fields() 暴露，供 UI / 测试断言。
##
## ============================ 尺寸纪律 ============================
##
## 右侧栏宽约 268px 且极挤，本组件高度**硬约束 ≤ 40px**。
## 做法：9 个 chip 按 CHIPS[].width 做**确定性贪心折行**（不依赖父容器宽度），
## 实测折成 2 行（4 + 5），总高 38px。
## 所有 Label 一律 **autowrap = OFF**：Label 开 autowrap 时最小高度按"当前宽度"算，
## 首次布局前宽度为 0 ⇒ get_combined_minimum_size() 会爆到万 px 级（本项目已多次踩到）。
## 本文件改为"按字符数截断 + clip_text"，min size 只取决于文本本身。

const CATALOG := preload("res://source/match/hud/production/ProductionCatalog.gd")
const THEME := preload("res://source/match/hud/production/ProductionTheme.gd")
const TIP := preload("res://source/match/hud/production/ProductionTooltip.gd")

## 目标宽度（右侧栏实测约 268px）。宽度**不依赖外部**，自己声明下限。
const STRIP_WIDTH := 268.0
const STRIP_MAX_HEIGHT := 40.0
const PAD_H := 6.0
const PAD_V := 3.0
const INNER_WIDTH := STRIP_WIDTH - PAD_H * 2.0
const CHIP_H := 15.0
const CHIP_GAP := 3.0
const ROW_GAP := 2.0
const DOT_SIZE := 3.0
## chip 内部横向开销：内边距 1+1 + 色点 3 + 两处间距 1+1 + 小标签(2 个 CJK @ font8 = 16)
## = 23px。数值可用宽度 = width - 23，由 _truncate 保证不超。
const CHIP_INNER_GAP := 1
const CAPTION_FONT := 8
const VALUE_FONT := 9

## 基地节点的识别关键串（用户口径：scene_file_path 含 CommandCenter）。
const COMMAND_CENTER_SCENE_MARK := "CommandCenter"
## 退化判据：Unit.gd:64 的 unit_type_id；与 balance 配置 unitTypes[].id 同口径。
const COMMAND_CENTER_TYPE_ID := "command_center"

## ============================ 驱动表 ============================
##
## 一个 const 表驱动全部 9 项渲染：将来某项补上真数据，**只要改这里的字段**，
## 判断逻辑不散落在代码里（render 只认表）。
##
## 字段：
##   key      —— 解析结果的键（_resolve_values 的返回键），也用于 missing_fields()
##   caption  —— chip 左侧 2 字小标签
##   accent   —— 语义色名（_accent_for 解析成 THEME 里的 Color）
##   width    —— chip 固定宽度（确定性折行的依据，也是尺寸可控的关键）
##   chars    —— 数值最多显示几个字形（含截断用的 "…"），超长就截断而不是被裁
##   absent   —— true = **项目里根本没有这个数据概念**，恒画 "—"
##   derived  —— true = 该值是推导出来的（不是实测值），Tooltip 要写明
##
## width 是按**真实字体度量**定的（Godot 默认字体实测：font9 下 CJK 9.0px/字、
## 数字 5.0px/字、"…"=9.0；font8 下 2 个 CJK = 16.0），
## 公式：width = 23（内部开销） + 最长数值宽度 + 2（余量）。
## 折行取贪心：实测折成 5 + 4 = 2 行，行宽 250 / 206 ≤ 256。
const CHIPS := [
	{
		"key": "base_name", "caption": "基地", "accent": "cyan",
		"width": 61.0, "chars": 4, "absent": false, "derived": false,
	},
	{
		"key": "tech_level", "caption": "等级", "accent": "dim",
		"width": 34.0, "chars": 1, "absent": true, "derived": false,
	},
	{
		"key": "hp", "caption": "生命", "accent": "green",
		"width": 58.0, "chars": 7, "absent": false, "derived": false,
	},
	{
		"key": "energy", "caption": "能源", "accent": "dim",
		"width": 34.0, "chars": 1, "absent": true, "derived": false,
	},
	{
		"key": "resource_a", "caption": "资源", "accent": "amber",
		"width": 51.0, "chars": 5, "absent": false, "derived": false,
	},
	{
		"key": "resource_cap", "caption": "上限", "accent": "dim",
		"width": 34.0, "chars": 1, "absent": true, "derived": false,
	},
	{
		"key": "production_slots", "caption": "生产", "accent": "cyan",
		"width": 50.0, "chars": 5, "absent": false, "derived": true,
	},
	{
		"key": "alerts", "caption": "警报", "accent": "amber",
		"width": 61.0, "chars": 4, "absent": false, "derived": false,
	},
	{
		"key": "hermes", "caption": "副官", "accent": "cyan",
		"width": 52.0, "chars": 3, "absent": false, "derived": false,
	},
]

## "项目无此数据概念"的统一措辞（与 absent=true 的项一一对应）。
## 刻意写成单行字符串：const 里不做跨行拼接，避免常量折叠的边界问题。
const ABSENT_REASON := {
	"tech_level": "项目无此数据概念：全库没有基地等级 / 科技等级字段，ProductionCatalog 里 tech_level 恒为 null（非 0）。",
	"energy": "项目无此数据概念：全库没有「能源」这种资源，ProductionCatalog 里 energy_cost 恒为 null（非 0）。",
	"resource_cap": "项目无此数据概念：全库没有 resourceCap / MaxResources 之类的资源上限字段。",
}

var _body: VBoxContainer = null


# ------------------------------------------------------------------ 公开 API

## 绑定一份上下文并重建状态条。
##
## context 约定字段（**全部可缺**，缺了不报错、对应项画 "—"）：
##   "player":   Node        —— 玩家节点（读 resource_a / 找 CommandCenter / 兜底找生产建筑）
##   "match":    Node        —— 暂未使用（保留，未来读对局级状态）
##   "producers": Array      —— 生产建筑列表（不给就自己从 player 的子节点枚举）
##   "alerts":   String      —— 当前警报文案（不给就画 "—"）
##   "profile":  Dictionary  —— Hermes 画像（不给则 ProductionCatalog 自己读 GrowthStore 快照）
func bind(context: Dictionary) -> void:
	_ensure_built()
	_clear_body()

	var values := _resolve_values(context)
	for row in _pack_rows(CHIPS):
		_body.add_child(_row_control(row, values))

	# 每次 bind 都重建了 chip，必须重新打豁免标记，否则父级若调
	# SystemUIStyle.apply() 会用 glass()（内边距 22/18）覆盖掉本组件的紧凑样式，
	# 高度会直接冲破 40px 上限。
	SystemUIStyle.skip_subtree(self)


## 当前项目下**拿不到真值**的项（恒画 "—"）。供 UI 文案与测试断言使用。
##
## 注意：这是**项目级**事实（这些概念在仓库里不存在），与某一次 bind 的 context
## 是否传了字段无关。像 alerts 这种"调用方没传"属于运行期缺失，不在此列。
static func missing_fields() -> PackedStringArray:
	var out := PackedStringArray()
	for chip in CHIPS:
		if bool((chip as Dictionary).get("absent", false)):
			out.append(str((chip as Dictionary).get("key", "")))
	return out


# ------------------------------------------------------------------ 构建

func _ensure_built() -> void:
	if _body != null:
		return
	add_theme_stylebox_override("panel", _strip_style())
	custom_minimum_size = Vector2(STRIP_WIDTH, 0)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", int(ROW_GAP))
	add_child(_body)


func _ready() -> void:
	_ensure_built()


func _strip_style() -> StyleBoxFlat:
	var style := SystemUIStyle.rounded(THEME.BG_DEEP, THEME.LINE, 1, THEME.RADIUS)
	style.content_margin_left = PAD_H
	style.content_margin_right = PAD_H
	style.content_margin_top = PAD_V
	style.content_margin_bottom = PAD_V
	return style


func _clear_body() -> void:
	if _body == null:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


# ------------------------------------------------------------------ 折行（确定性，不依赖父宽度）

## 按 CHIPS[].width 贪心折行：每行总宽（含间距）不超过 INNER_WIDTH。
##
## 刻意不用 FlowContainer / HFlowContainer：它们的换行结果依赖实际宽度，
## 首次布局前宽度为 0 ⇒ 9 个 chip 会各占一行，min height 直接爆掉。
## 这里自己算，行数/行高都与布局顺序无关，40px 上限才是可证的。
static func _pack_rows(specs: Array) -> Array:
	var rows: Array = []
	var current: Array = []
	var used := 0.0
	for raw_spec in specs:
		var spec: Dictionary = raw_spec
		var width := float(spec.get("width", 40.0))
		var need := width if current.is_empty() else width + CHIP_GAP
		if not current.is_empty() and used + need > INNER_WIDTH:
			rows.append(current)
			current = []
			used = 0.0
			need = width
		current.append(spec)
		used += need
	if not current.is_empty():
		rows.append(current)
	return rows


func _row_control(row: Array, values: Dictionary) -> Control:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", int(CHIP_GAP))
	line.custom_minimum_size = Vector2(INNER_WIDTH, CHIP_H)
	for raw_spec in row:
		line.add_child(_chip(raw_spec, values))
	# 行尾留一个弹性空位，把 chip 顶到左边（父栏更宽时也是左对齐）。
	var tail := Control.new()
	tail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(tail)
	return line


# ------------------------------------------------------------------ 单个 chip

func _chip(spec: Dictionary, values: Dictionary) -> Control:
	var key := str(spec.get("key", ""))
	var absent := bool(spec.get("absent", false))
	var text := str(values.get(key, ""))
	var missing := absent or text.is_empty()
	var accent: Color = THEME.DIM if missing else _accent_for(str(spec.get("accent", "cyan")))

	var chip := PanelContainer.new()
	chip.custom_minimum_size = Vector2(float(spec.get("width", 40.0)), CHIP_H)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.tooltip_text = _tooltip(spec, values)

	var style := SystemUIStyle.rounded(Color(0.031, 0.075, 0.102, 0.85), accent, 1, 3)
	style.content_margin_left = 1
	style.content_margin_right = 1
	style.content_margin_top = 0
	style.content_margin_bottom = 0
	chip.add_theme_stylebox_override("panel", style)

	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", CHIP_INNER_GAP)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dot := ColorRect.new()
	dot.color = accent
	dot.custom_minimum_size = Vector2(DOT_SIZE, DOT_SIZE)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(dot)

	var caption := SystemUIStyle.make_label(
		str(spec.get("caption", "")), CAPTION_FONT, THEME.DIM if missing else THEME.MUTED
	)
	caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(caption)

	# 数值 Label：autowrap 保持 OFF（默认），超长按字形数截断 + clip_text。
	# clip_text 会把 Label 的 min width 归零（实测）⇒ chip 宽度永远等于表里写的值，
	# 但"被裁掉"不会体现在尺寸上，所以截断必须在**文本层**做够。
	var value := SystemUIStyle.make_label(
		_truncate(text if not text.is_empty() else TIP.NO_VALUE, int(spec.get("chars", 4))),
		VALUE_FONT,
		THEME.DIM if missing else accent
	)
	value.clip_text = true
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(value)

	chip.add_child(line)
	return chip


## Tooltip：把"这个数从哪来 / 为什么是 —"讲清楚。
func _tooltip(spec: Dictionary, values: Dictionary) -> String:
	var key := str(spec.get("key", ""))
	var absent := bool(spec.get("absent", false))
	if absent:
		return str(ABSENT_REASON.get(key, "项目无此数据概念。"))
	var text := str(values.get(key, ""))
	if text.is_empty():
		return "%s（本次 bind 未拿到数据，画「—」而不是 0）" % str(
			values.get("%s.note" % key, "无数据来源")
		)
	var note := str(values.get("%s.note" % key, ""))
	if note.is_empty():
		return text
	return "%s · %s" % [note, text]


# ------------------------------------------------------------------ 数据解析

## 把 context 解析成 { key: 显示文本 }；任何一项拿不到就是空串（渲染层画 "—"）。
## 另附 "<key>.note" 说明该项的数据来源，供 Tooltip 使用。
func _resolve_values(context: Dictionary) -> Dictionary:
	var player = context.get("player", null)
	var profile = _profile_of(context)
	var producers := _producers_of(context, player)
	var base := _command_center(player)

	var out: Dictionary = {}

	# 1) 基地名称：优先目录里的 display_name（真实配置文案），退化到节点名。
	out["base_name"] = ""
	out["base_name.note"] = "player 名下 scene_file_path 含 CommandCenter 的节点"
	if _valid(base):
		var type_id := _unit_type_id_of(base)
		var row: Dictionary = {}
		if not type_id.is_empty():
			row = CATALOG.entry(type_id)
		if row.is_empty():
			out["base_name"] = str(base.name)
			out["base_name.note"] = "未收录进 ProductionCatalog，退回节点名"
		else:
			out["base_name"] = str(row.get("display_name", ""))
	else:
		out["base_name.note"] = "未找到 CommandCenter 节点（基地尚未建立或已失去）"

	# 2) 基地等级 / 科技等级：项目没有这个概念。
	out["tech_level"] = ""

	# 3) 基地生命值：活节点 hp / hp_max，读法容错（缺字段就画 "—"）。
	out["hp"] = _hp_text(base)
	out["hp.note"] = "读自基地节点 hp / hp_max（Unit.gd:60-63）"

	# 4) 当前能源：项目没有这个概念。
	out["energy"] = ""

	# 5) 当前资源：Player.gd:5 的 resource_a，**只读镜像**（禁止赋值）。
	out["resource_a"] = _resource_text(player)
	out["resource_a.note"] = "读自 player.resource_a（Player.gd:5，C# 权威账户的只读镜像）"

	# 6) 资源上限：项目没有这个概念。
	out["resource_cap"] = ""

	# 7) 生产能力（并行生产槽位）：各生产建筑队列长度之和 / queueLimit 之和。
	var slots := _production_slots(producers)
	out["production_slots"] = str(slots["text"])
	out["production_slots.note"] = str(slots["note"])

	# 8) 警报：纯由调用方通过 context["alerts"] 传入；没传就画 "—"（不编造"正常"）。
	out["alerts"] = ""
	out["alerts.note"] = "由调用方通过 context[\"alerts\"] 传入；未传入时画「—」"
	var raw_alerts = context.get("alerts", null)
	if raw_alerts is String and not (raw_alerts as String).strip_edges().is_empty():
		out["alerts"] = (raw_alerts as String).strip_edges()

	# 9) Hermes 副官：available / source / 生成时间的真实取值。
	var hermes := _hermes_text(profile)
	out["hermes"] = str(hermes["text"])
	out["hermes.note"] = str(hermes["note"])

	return out


func _hp_text(base) -> String:
	if not _valid(base):
		return ""
	var current = null
	var maximum = null
	if "hp" in base:
		current = base.get("hp")
	if "hp_max" in base:
		maximum = base.get("hp_max")
	if (current is int or current is float) and (maximum is int or maximum is float):
		return "%s/%s" % [TIP.fmt_num(current), TIP.fmt_num(maximum)]
	if current is int or current is float:
		return TIP.fmt_num(current)
	return ""


func _resource_text(player) -> String:
	if not _valid(player):
		return ""
	if not ("resource_a" in player):
		return ""
	var raw = player.get("resource_a")
	if raw is int or raw is float:
		return TIP.fmt_num(raw)
	return ""


## 生产槽位：Σ 队列当前长度 / Σ queueLimit。
## 一座生产建筑都没找到 → 空串（画 "—"），**不显示 0/0 假装有数据**。
func _production_slots(producers: Array) -> Dictionary:
	var used := 0
	var limit := 0
	var counted := 0
	var fallback_used := false
	for producer in producers:
		if not _valid(producer):
			continue
		if not ("production_queue" in producer):
			continue
		var queue = producer.get("production_queue")
		if not _valid_object(queue):
			continue
		if not queue.has_method("size"):
			continue
		used += int(queue.size())
		var limit_row := _queue_limit_of(producer)
		limit += int(limit_row["limit"])
		fallback_used = fallback_used or bool(limit_row["fallback"])
		counted += 1
	if counted == 0:
		return {
			"text": "",
			"note": "未找到带 production_queue 的生产建筑，无法统计生产能力",
		}
	var note: String = "推导值：%d 座生产建筑的 production_queue.size() 之和 / queueLimit 之和" % counted
	if fallback_used:
		note += "；部分建筑读不到 queueLimit，按默认值 %d 计" % CATALOG.QUEUE_LIMIT_DEFAULT
	note += "（权威判定在 C# ProductionService）"
	return {"text": "%d/%d" % [used, limit], "note": note}


func _hermes_text(profile: Dictionary) -> Dictionary:
	var advice := CATALOG.hermes_advice(profile, {}, "")
	var available := bool(advice.get("available", false))
	var source := str(advice.get("source", "none"))
	var text: String = "就绪" if available else "未就绪"
	var note: String = "ProductionCatalog.hermes_advice：available=%s · 来源 %s · 生成时间 %s" % [
		"true" if available else "false",
		TIP.source_label(source),
		TIP.fmt_text(advice.get("generated_at", null)),
	]
	return {"text": text, "note": note}


# ------------------------------------------------------------------ 节点查找

## 玩家名下的主基地。
##
## 主判据按用户口径：scene_file_path 含 "CommandCenter"。
## 退化判据（**同一份真实数据，不是猜的**）：Unit.gd:64 的 unit_type_id
## 等于 balance 配置里的 "command_center"。加它的原因有两个：
##   1) 测试/探针里手工 new 出来的节点没有 scene_file_path，只有 unit_type_id；
##   2) 未来基地若从别的场景文件加载，unit_type_id 仍然稳定。
static func _command_center(player) -> Node:
	if not _valid(player):
		return null
	for child in (player as Node).get_children():
		if not _valid(child):
			continue
		var scene := str((child as Node).scene_file_path)
		if scene.contains(COMMAND_CENTER_SCENE_MARK):
			return child
	for child in (player as Node).get_children():
		if not _valid(child):
			continue
		if _unit_type_id_of(child) == COMMAND_CENTER_TYPE_ID:
			return child
	return null


## 生产建筑列表：context["producers"] 优先；没给就从 player 的直接子节点里找带
## production_queue 的（与 Match.gd:422 / :474 的单位挂载层级一致）。
static func _producers_of(context: Dictionary, player) -> Array:
	var out: Array = []
	var raw = context.get("producers", null)
	if raw is Array and not (raw as Array).is_empty():
		for item in (raw as Array):
			if _valid(item):
				out.append(item)
		return out
	if _valid(player):
		for child in (player as Node).get_children():
			if not _valid(child):
				continue
			if "production_queue" in child:
				out.append(child)
	return out


static func _unit_type_id_of(node) -> String:
	if not _valid(node):
		return ""
	if not ("unit_type_id" in node):
		return ""
	return str(node.get("unit_type_id"))


## 生产建筑队列上限。**这不是 ProductionCatalog 的公开能力**（它只有私有的
## _queue_limit_for），所以这里按用户给的路径自己读一次配置：
## config/balance/demo.balance.v1.json → unitTypes[].producer.queueLimit。
## 读不到就返回 CATALOG.QUEUE_LIMIT_DEFAULT(=5) 并标 fallback=true，由调用方注明"默认值"。
static func _queue_limit_of(producer) -> Dictionary:
	if not _valid(producer):
		return {"limit": CATALOG.QUEUE_LIMIT_DEFAULT, "fallback": true}
	var type_id := _unit_type_id_of(producer)
	if type_id.is_empty():
		type_id = _type_id_by_scene(str((producer as Node).scene_file_path))
	var limits := _queue_limits()
	if not type_id.is_empty() and limits.has(type_id):
		return {"limit": int(limits[type_id]), "fallback": false}
	return {"limit": CATALOG.QUEUE_LIMIT_DEFAULT, "fallback": true}


static var _limit_cache: Dictionary = {}


static func _queue_limits() -> Dictionary:
	if not _limit_cache.is_empty():
		return _limit_cache
	var config := _load_json(_balance_config_path())
	var limits: Dictionary = {}
	for raw_type in _array_of(config.get("unitTypes", null)):
		if not (raw_type is Dictionary):
			continue
		var row: Dictionary = raw_type
		var producer = row.get("producer", null)
		if not (producer is Dictionary):
			continue
		var id := str(row.get("id", ""))
		if id.is_empty():
			continue
		limits[id] = int((producer as Dictionary).get("queueLimit", CATALOG.QUEUE_LIMIT_DEFAULT))
	# 读不到就**不写缓存**，下次调用重试（避免把一次失败永久固化，与 ProductionCatalog 同约定）。
	if not limits.is_empty():
		_limit_cache = limits
	return limits


## 场景路径 → unit_type_id：走 ProductionCatalog 的公开条目（scene_path 字段）。
static func _type_id_by_scene(scene_path: String) -> String:
	if scene_path.is_empty():
		return ""
	for raw_category in CATALOG.categories():
		var category: Dictionary = raw_category
		for raw_item in CATALOG.entries(str(category.get("id", ""))):
			var item: Dictionary = raw_item
			if str(item.get("scene_path", "")) == scene_path:
				return str(item.get("unit_id", ""))
	return ""


static func _load_json(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text := file.get_as_text()
	file.close()
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


## 允许 --balance-config= 覆盖，与 ProductionCatalog / C# BalanceConfigRuntime 同一份数据。
static func _balance_config_path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--balance-config="):
			return argument.substr("--balance-config=".length())
	return CATALOG.BALANCE_CONFIG_DEFAULT


# ------------------------------------------------------------------ 小工具

func _accent_for(name: String) -> Color:
	match name:
		"amber":
			return THEME.AMBER
		"green":
			return THEME.GREEN
		"red":
			return THEME.RED
		"text":
			return THEME.TEXT
		"muted":
			return THEME.MUTED
		"dim":
			return THEME.DIM
		_:
			return THEME.CYAN


## 按**字形数**截断：超长时保留 (max_chars - 1) 个字形 + "…"，
## 这样输出宽度上界 ≈ max_chars × 单字宽（"…" 实测 9.0px ≈ 1 个 CJK 宽），
## 表里的 width 才是一个可证的上界，而不是"大概"。
static func _truncate(text: String, max_chars: int) -> String:
	if max_chars <= 0 or text.length() <= max_chars:
		return text
	if max_chars == 1:
		return "…"
	return text.substr(0, max_chars - 1) + "…"


static func _profile_of(context: Dictionary) -> Dictionary:
	var raw = context.get("profile", null)
	if raw is Dictionary:
		return raw
	return {}


static func _array_of(value) -> Array:
	if value is Array:
		return value
	return []


## 节点有效性：null / 已 free 都算无效（读属性前必须先过这一关）。
static func _valid(value) -> bool:
	if value == null:
		return false
	if not is_instance_valid(value):
		return false
	return value is Node


## 非节点对象（例如 ProductionQueue 这个 Node）也要判有效性。
static func _valid_object(value) -> bool:
	if value == null:
		return false
	if not is_instance_valid(value):
		return false
	return value is Object
