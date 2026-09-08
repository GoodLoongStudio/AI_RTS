extends Node

## UI 音效常驻播放器（2026-09-08 全量接入）：
## click/hover/select/place/error + toggle/dial/tick/drawer/mode/latch/menu_open/close/plate。
## 按音效包规则：变体轮换且不连续重复同一变体；AudioStreamPlayer 非 3D；
## 走 SFX 总线 0dB；音高散布 ≤0.05（变体自带散布）。
## 自动挂接：普通按钮进树即绑定 hover/click；复选框绑定开/关音；
## 滑条绑定拖动 tick + 结束 dial；其余由业务代码调用 play()。
## 注意：warning_banner 暂无挂点（项目内无警告横幅），音效已入库备用。

const SFX_DIR := "res://assets/sfx/ui/"
const BANKS := {
	"click": 5,
	"hover": 3,
	"select": 4,
	"place": 4,
	"error": 3,
	"ui_toggle_on": 3,
	"ui_toggle_off": 3,
	"ui_dial": 4,
	"ui_tick": 4,
	"ui_drawer": 3,
	"ui_plate": 3,
	"ui_latch": 3,
	"ui_mode": 3,
	"ui_menu_open": 2,
	"ui_menu_close": 2,
}
const PITCH_SPREAD := 0.04
## 滑条拖动 tick 的最小间隔（毫秒），防止每次像素级变化都发声
const TICK_MIN_INTERVAL_MSEC := 80

## 测试观察用：最近播放的音效键。
static var played_log: Array[String] = []

var _banks := {}
var _last_index := {}
var _player: AudioStreamPlayer
var _dragging_sliders := {}
var _last_tick_msec := 0


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for key in BANKS:
		var streams: Array[AudioStream] = []
		for index in range(1, int(BANKS[key]) + 1):
			var path := "%s%s_%02d.wav" % [SFX_DIR, key, index]
			if ResourceLoader.exists(path):
				streams.append(load(path))
		_banks[key] = streams
	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	_player.bus = "SFX"
	add_child(_player)
	get_tree().node_added.connect(_on_node_added)
	MatchSignals.unit_selected.connect(func(_unit): play("select"))


## 播放指定角色：随机变体且不连续重复。
func play(key: String) -> void:
	if not _banks.has(key) or _banks[key].is_empty():
		return
	var streams: Array[AudioStream] = _banks[key]
	var index := randi() % streams.size()
	if index == int(_last_index.get(key, -1)):
		index = (index + 1) % streams.size()
	_last_index[key] = index
	_player.stream = streams[index]
	_player.pitch_scale = randf_range(1.0 - PITCH_SPREAD, 1.0 + PITCH_SPREAD)
	_player.play()
	played_log.append(key)


## 控件进树自动绑定：
## - 复选框（CheckBox/CheckButton）→ toggled 开/关音
## - 普通按钮 → hover + click；状态型按钮（toggle_mode，如页签）不绑 click，
##   由各自业务钩子发音（避免与 drawer/mode 叠声）
## - 滑条 → 拖动 tick（限频）+ 拖动结束 dial
func _on_node_added(node: Node):
	if node is CheckBox or node is CheckButton:
		node.toggled.connect(_on_toggle_toggled)
		return
	if node is BaseButton:
		if node.toggle_mode:
			return
		node.mouse_entered.connect(play.bind("hover"))
		node.pressed.connect(play.bind("click"))
	if node is Slider:
		node.drag_started.connect(_on_slider_drag_started.bind(node))
		node.drag_ended.connect(_on_slider_drag_ended.bind(node))
		node.value_changed.connect(_on_slider_value_changed.bind(node))


func _on_toggle_toggled(pressed: bool):
	play("ui_toggle_on" if pressed else "ui_toggle_off")


func _on_slider_drag_started(slider: Slider):
	_dragging_sliders[slider] = true


func _on_slider_drag_ended(value_changed: bool, slider: Slider):
	_dragging_sliders[slider] = false
	if value_changed:
		play("ui_dial")


func _on_slider_value_changed(_value: float, slider: Slider):
	if not _dragging_sliders.get(slider, false):
		return
	var now := Time.get_ticks_msec()
	if now - _last_tick_msec < TICK_MIN_INTERVAL_MSEC:
		return
	_last_tick_msec = now
	play("ui_tick")
