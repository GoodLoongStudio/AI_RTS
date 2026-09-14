extends Node

const Options = preload("res://source/data-model/Options.gd")
const OPTION_PROPERTIES := ["screen", "resolution", "mouse_restricted"]
const CAMERA_CONFIG_PATH := "user://camera.cfg"
const CAMERA_CONFIG_SECTION := "camera"
const CAMERA_DEFAULTS := {
	"edge_scroll_enabled": true,
	"movement_speed": 1.1,
	"edge_margin": 48.0,
	"bottom_edge_margin": 72.0,
	"smoothing": 10.0,
	"zoom_step": 1.0,
}

var options = _load_and_migrate_options()
var camera_options: Dictionary = _load_camera_options()
var god_mode = false
var cache = {}


func _load_and_migrate_options():
	# Display/mouse settings keep using the legacy Resource. We instantiate the latest
	# schema first so old user://options.tres files cannot remove newly expected fields.
	var current_options = Options.new()
	if not ResourceLoader.exists(Constants.OPTIONS_FILE_PATH):
		return current_options

	var stored_options = load(Constants.OPTIONS_FILE_PATH)
	if stored_options == null:
		return current_options

	var stored_property_names := {}
	for property in stored_options.get_property_list():
		stored_property_names[str(property.get("name", ""))] = true

	for property_name in OPTION_PROPERTIES:
		if stored_property_names.has(property_name):
			current_options.set(property_name, stored_options.get(property_name))

	var save_error = ResourceSaver.save(current_options, Constants.OPTIONS_FILE_PATH)
	if save_error != OK:
		push_warning("无法保存迁移后的显示设置：%s" % error_string(save_error))
	return current_options


func _load_camera_options() -> Dictionary:
	var loaded := CAMERA_DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	var load_error := config.load(CAMERA_CONFIG_PATH)
	if load_error != OK:
		return loaded

	for key in CAMERA_DEFAULTS.keys():
		loaded[key] = config.get_value(CAMERA_CONFIG_SECTION, key, CAMERA_DEFAULTS[key])
	return _sanitize_camera_options(loaded)


func _sanitize_camera_options(values: Dictionary) -> Dictionary:
	return {
		"edge_scroll_enabled": bool(values.get("edge_scroll_enabled", true)),
		"movement_speed": clamp(float(values.get("movement_speed", 1.1)), 0.4, 3.0),
		"edge_margin": clamp(float(values.get("edge_margin", 48.0)), 16.0, 96.0),
		"bottom_edge_margin": clamp(float(values.get("bottom_edge_margin", 72.0)), 24.0, 128.0),
		"smoothing": clamp(float(values.get("smoothing", 10.0)), 3.0, 24.0),
		"zoom_step": clamp(float(values.get("zoom_step", 1.0)), 0.25, 3.0),
	}


func get_camera_option(key: String):
	return camera_options.get(key, CAMERA_DEFAULTS.get(key))


func set_camera_option(key: String, value):
	if not CAMERA_DEFAULTS.has(key):
		push_warning("未知镜头设置：%s" % key)
		return
	camera_options[key] = value
	camera_options = _sanitize_camera_options(camera_options)


func save_camera_options():
	var config := ConfigFile.new()
	for key in CAMERA_DEFAULTS.keys():
		config.set_value(CAMERA_CONFIG_SECTION, key, camera_options[key])
	var save_error := config.save(CAMERA_CONFIG_PATH)
	if save_error != OK:
		push_warning("无法保存镜头设置：%s" % error_string(save_error))


func reset_camera_options():
	camera_options = CAMERA_DEFAULTS.duplicate(true)
	save_camera_options()


## 音量设置：按音频总线（Music/Voice）持久化并实时生效（2026-09-08）。
const AUDIO_CONFIG_PATH := "user://audio.cfg"
const AUDIO_CONFIG_SECTION := "audio"
const AUDIO_DEFAULTS := {
	"music_volume": 0.9,
	"voice_volume": 1.0,
}

var audio_options: Dictionary = _load_audio_options()


func _ready():
	_apply_audio_volumes()


## 【退出追踪 · 2026-09-13】进程**自己关停**时留下一条带上下文的事实（只打印，不改行为）。
##
## 为什么需要：验收里服端会在对局中途消失（24592 拒连），日志里只剩"资源在退出时泄漏"
## 这类引擎收尾噪音，**没有任何原因**；全仓 GDScript/C# 也搜不到"对局期间可达"的 `quit()`
## （只有主菜单按钮与大厅调试截图两处）。到底是"有人正常 quit"还是"进程被外部终止"，
## 只有现场能分辨：
##   - 走到 `PREDELETE` → 引擎确实在跑收尾（= 有人调了 quit / 主循环正常结束）；
##   - 进程没了但这里**没有**打印 → 外部终止（taskkill / 控制台关闭），与游戏逻辑无关。
## Autoload 在每个进程（含 headless 专用服）都存在，所以追踪点放在这里。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		print("[EXIT-TRACE] WM_CLOSE_REQUEST：有人请求关闭窗口/控制台")
	elif what == NOTIFICATION_EXIT_TREE:
		print("[EXIT-TRACE] EXIT_TREE：场景树收尾（tick=%s，场景=%s，对局结果=%s）"
			% [_trace_tick(), _trace_scene(), _trace_outcome()])
	elif what == NOTIFICATION_PREDELETE:
		print("[EXIT-TRACE] PREDELETE：引擎收尾（Globals 释放，tick=%s）" % _safe_tick())


## 退出那一刻的**当前场景**（判断"退出前场景被换走了吗"——换场景=收局/回大厅的那条路）。
func _trace_scene() -> String:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return "unknown"
	return str(tree.current_scene.name)


## 退出那一刻是否已有对局结果（`MatchOutcomeRuntime` 发的终态）。
## 有结果 ⇒ "退出发生在收局之后"（正常收局路）；没有 ⇒ 中途退出，与胜负无关。
func _trace_outcome() -> String:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return "unknown"
	for node in tree.root.find_children("*", "MatchOutcomeRuntime", true, false):
		var resolution = node.get("_resolution")
		if resolution is Dictionary and not (resolution as Dictionary).is_empty():
			return str((resolution as Dictionary).get("kind", "resolved"))
		return "无"
	return "无该节点"


## 收尾期安全的 tick 文本。
##
## **PREDELETE 阶段节点已经脱离场景树**：此时调 `get_tree()` 会让引擎自己打印
## `ERROR: Parameter "data.tree" is null`（实测：每局退出都多一行红字，把退出痕迹弄脏）。
## `is_inside_tree()` 是安全判据（不访问 tree 指针），脱离时直接给"未知"。
func _safe_tick() -> String:
	if not is_inside_tree():
		return "unknown(已脱离场景树)"
	return _trace_tick()


## 尽力拿当前 server_tick（收尾期节点可能已经没了 → 拿不到就返回 "unknown"，绝不抛错）。
func _trace_tick() -> String:
	var tree := get_tree()
	if tree == null:
		return "unknown"
	var dcs := tree.root.get_node_or_null("DebugControlServer") if tree.root != null else null
	if dcs != null and dcs.has_method("server_tick"):
		return str(dcs.call("server_tick"))
	return "unknown"


func _load_audio_options() -> Dictionary:
	var loaded := AUDIO_DEFAULTS.duplicate(true)
	var config := ConfigFile.new()
	var load_error := config.load(AUDIO_CONFIG_PATH)
	if load_error != OK and load_error != ERR_FILE_NOT_FOUND:
		push_warning("读取音频设置失败：%s" % error_string(load_error))
	for key in AUDIO_DEFAULTS.keys():
		loaded[key] = clampf(
			float(config.get_value(AUDIO_CONFIG_SECTION, key, AUDIO_DEFAULTS[key])), 0.0, 1.0
		)
	return loaded


func get_audio_volume(key: String) -> float:
	return float(audio_options.get(key, AUDIO_DEFAULTS.get(key, 1.0)))


func set_audio_volume(key: String, linear: float):
	if not AUDIO_DEFAULTS.has(key):
		push_warning("未知音频设置：%s" % key)
		return
	audio_options[key] = clampf(linear, 0.0, 1.0)
	_apply_audio_volumes()


func save_audio_options():
	var config := ConfigFile.new()
	for key in AUDIO_DEFAULTS.keys():
		config.set_value(AUDIO_CONFIG_SECTION, key, audio_options[key])
	var save_error := config.save(AUDIO_CONFIG_PATH)
	if save_error != OK:
		push_warning("无法保存音频设置：%s" % error_string(save_error))


## 把音频设置应用到总线（线性音量 → 分贝；0 = 静音）。
func _apply_audio_volumes():
	for key in AUDIO_DEFAULTS.keys():
		var bus_name := "Music" if key == "music_volume" else "Voice"
		var bus_index := AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			continue
		var linear := float(audio_options[key])
		AudioServer.set_bus_volume_db(
			bus_index, linear_to_db(maxf(linear, 0.0001)) if linear > 0.0 else -80.0
		)
		AudioServer.set_bus_mute(bus_index, linear <= 0.0)


func _unhandled_input(event):
	if event.is_action_pressed("toggle_god_mode"):
		_toggle_god_mode()


func _toggle_god_mode():
	if not FeatureFlags.god_mode:
		return
	god_mode = not god_mode
	if god_mode:
		Signals.god_mode_enabled.emit()
	else:
		Signals.god_mode_disabled.emit()
