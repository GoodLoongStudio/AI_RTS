extends Node

## 红警式命令光标（2026-09-14 用户要求）：
## 点「维修」/「出售」后光标立刻变成扳手/金币，再点建筑就生效；
## 退出指定模式（右键、ESC、再点按钮、点空地）时立即恢复系统光标。
##
## 只做表现层：纯监听 MatchSignals.command_targeting_changed，不参与玩法判定，
## 也不持有 UnitActionsController 引用，因此不存在节点时序问题。

## 命令名 → 图标文件。未列出的命令不换光标（保持系统箭头，例如强制移动）。
const ICONS := {
	"Repair": "cursor_repair.png",
	"Sell": "cursor_sell.png",
}
const ICON_DIR := "res://assets/ui/cursors/"
## 热点取图标中心（Godot 的 hotspot 单位是像素，对应 48x48 图标）。
const HOTSPOT := Vector2(24.0, 24.0)

var _active_command := ""
var _textures := {}


func _ready() -> void:
	MatchSignals.command_targeting_changed.connect(_on_command_targeting_changed)
	# 对局结束/中断也要清空，避免把自定义光标带回主菜单。
	MatchSignals.match_finished_with_victory.connect(_reset)
	MatchSignals.match_finished_with_defeat.connect(_reset)
	MatchSignals.match_aborted.connect(_reset)


func _exit_tree() -> void:
	if is_instance_valid(MatchSignals):
		if MatchSignals.command_targeting_changed.is_connected(_on_command_targeting_changed):
			MatchSignals.command_targeting_changed.disconnect(_on_command_targeting_changed)
		if MatchSignals.match_finished_with_victory.is_connected(_reset):
			MatchSignals.match_finished_with_victory.disconnect(_reset)
		if MatchSignals.match_finished_with_defeat.is_connected(_reset):
			MatchSignals.match_finished_with_defeat.disconnect(_reset)
		if MatchSignals.match_aborted.is_connected(_reset):
			MatchSignals.match_aborted.disconnect(_reset)
	_reset()


## 当前生效的命令名（空字符串 = 系统默认光标）。供测试与诊断查询。
func get_active_command() -> String:
	return _active_command


## 供诊断：当前是否已把光标换成自定义图标。
func has_custom_cursor() -> bool:
	return not _active_command.is_empty() and _texture_for(_active_command) != null


func _on_command_targeting_changed(command_name: String) -> void:
	if command_name == _active_command:
		return
	_active_command = command_name
	if command_name.is_empty():
		_restore_system_cursor()
		return
	var texture := _texture_for(command_name)
	if texture == null:
		_restore_system_cursor()
		return
	Input.set_custom_mouse_cursor(texture, Input.CURSOR_ARROW, HOTSPOT)


func _texture_for(command_name: String) -> Texture2D:
	var filename: String = ICONS.get(command_name, "")
	if filename.is_empty():
		return null
	if _textures.has(command_name):
		return _textures[command_name]
	var path := ICON_DIR + filename
	if not ResourceLoader.exists(path):
		push_warning("命令光标图标缺失：%s" % path)
		_textures[command_name] = null
		return null
	var texture := load(path) as Texture2D
	_textures[command_name] = texture
	return texture


## 退出模式：只把光标恢复成系统默认，保留 _active_command 供 UI 判断当前模式。
func _restore_system_cursor() -> void:
	Input.set_custom_mouse_cursor(null)


## 对局结束/节点退出：清空模式并恢复系统光标。
func _reset() -> void:
	_active_command = ""
	_restore_system_cursor()
