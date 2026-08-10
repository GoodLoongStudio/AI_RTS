extends RefCounted


enum Type { MOVE, ATTACK, DEFEND, SCOUT, RETREAT, STOP }

var squad_id: int
var type: int
var source: String
var raw_text: String
var target_position = null
var target_unit = null
var constraints: Dictionary = {}


func _init(
	a_squad_id: int,
	a_type: int,
	a_source: String = "ui",
	a_raw_text: String = ""
):
	squad_id = a_squad_id
	type = a_type
	source = a_source
	raw_text = a_raw_text


func requires_terrain_target() -> bool:
	return type in [Type.MOVE, Type.SCOUT, Type.RETREAT]


func requires_unit_target() -> bool:
	return type == Type.ATTACK


static func type_label(command_type: int) -> String:
	match command_type:
		Type.MOVE:
			return "移动"
		Type.ATTACK:
			return "攻击"
		Type.DEFEND:
			return "防守"
		Type.SCOUT:
			return "侦察"
		Type.RETREAT:
			return "撤退"
		Type.STOP:
			return "停止"
		_:
			return "未知命令"
