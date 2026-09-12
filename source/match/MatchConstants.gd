const OWNED_PLAYER_CIRCLE_COLOR = Color.GREEN
const ADVERSARY_PLAYER_CIRCLE_COLOR = Color.RED
const RESOURCE_CIRCLE_COLOR = Color.YELLOW
const DEFAULT_CIRCLE_COLOR = Color.WHITE
const MAPS = {
	"res://source/match/maps/PlainAndSimple.tscn":
	{
		"name": "Plain & Simple",
		"players": 4,
		"size": Vector2i(50, 50),
	},
	"res://source/match/maps/BigArena.tscn":
	{
		"name": "Big Arena",
		"players": 8,
		"size": Vector2i(100, 100),
	},
}

# 自定义对局地图清单**默认只保留 4 人与 8 人两张**（用户要求，2026-09-11）。
# 之前的清单混入 3 张旧平面 seed 地图 + 13 张工作台生成的 4 人地图，共 18 项，
# 选择成本高且对实战测试没有价值。
# 采用**开关**而不是删除文件：地图资源与工作台的 map_index.json 原样保留，
# 需要时把 DISCOVER_GENERATED_MAPS 改成 true 即可恢复自动发现。
# 注意：静态初始化依赖 DirAccess 运行时读文件，不是常量表达式；
# Godot 4 的 const 只接受常量表达式，必须用 static var（访问方式不变）。
const DISCOVER_GENERATED_MAPS := false

static var GENERATED_MAPS := _load_generated_maps()
static var ALL_MAPS := _merged_maps()


static func _merged_maps() -> Dictionary:
	var merged := MAPS.duplicate()
	merged.merge(GENERATED_MAPS, true)
	return merged


static func _load_generated_maps() -> Dictionary:
	var result := {}
	if not DISCOVER_GENERATED_MAPS:
		return result
	var base := "res://source/match/maps/generated"
	var dir := DirAccess.open(base)
	if dir == null:
		return result
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if dir.current_is_dir() and not entry.begins_with("."):
			var index_path := base.path_join(entry).path_join("map_index.json")
			if FileAccess.file_exists(index_path):
				var f := FileAccess.open(index_path, FileAccess.READ)
				if f != null:
					var parsed = JSON.parse_string(f.get_as_text())
					f.close()
					if parsed is Dictionary and parsed.has("path"):
						var size_arr: Array = parsed.get("size", [256, 256])
						result[parsed["path"]] = {
							"name": str(parsed.get("name", entry)),
							"players": int(parsed.get("players", 4)),
							"size": Vector2i(int(size_arr[0]), int(size_arr[1])),
						}
		entry = dir.get_next()
	dir.list_dir_end()
	return result


class Navigation:
	enum Domain { AIR, TERRAIN }

	const DOMAIN_TO_GROUP_MAPPING = {
		Domain.AIR: "air_navigation_input",
		Domain.TERRAIN: "terrain_navigation_input",
	}
	## 静态障碍（建筑/资源）的**持久**注册表。
	## DOMAIN_TO_GROUP_MAPPING 只是"下次烘焙的输入清单"，TerrainNavigation.bake()
	## 每次烘焙后都会清空它，因此不能当障碍清单用。移动侧需要按障碍半径
	## 校验落点是否落在避让圈内，故单独维护一份不会被清空的注册表。
	const DOMAIN_TO_OBSTACLE_GROUP_MAPPING = {
		Domain.AIR: "navigation_obstacles_air",
		Domain.TERRAIN: "navigation_obstacles_terrain",
	}


class Air:
	const Y = 1.5
	const PLANE = Plane(Vector3.UP, Y)

	class Navmesh:
		const CELL_SIZE = 0.4
		const CELL_HEIGHT = 0.4
		const MAX_AGENT_RADIUS = 0.8


class Terrain:
	const PLANE = Plane(Vector3.UP, 0)

	class Navmesh:
		const CELL_SIZE = 0.3
		const CELL_HEIGHT = 0.3
		const MAX_AGENT_RADIUS = 0.9  # max radius of movable units


class Resources:
	class A:
		const COLOR = Color.BLUE
		const MATERIAL_PATH = "res://source/match/resources/materials/resource_a.material.tres"
		const COLLECTING_TIME_S = 1.0

	class B:
		const COLOR = Color.RED
		const MATERIAL_PATH = "res://source/match/resources/materials/resource_b.material.tres"
		const COLLECTING_TIME_S = 2.0


class Units:
	# 0.5: 建筑 Movement 半径(1.8)与 MovementObstacle 半径(2.0)错位 0.2m + 导航停驻抖动,
	# 0.3 时贴合判定在厘米级临界上随机失败——工人采不到矿/交付不了(2026-08-31 E2E 实测)。
	const ADHERENCE_MARGIN_M = 0.5
	const NEW_RESOURCE_SEARCH_RADIUS_M = 30
	const MOVING_UNIT_RADIUS_MAX_M = 1.0
	const EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M = MOVING_UNIT_RADIUS_MAX_M * 2.5
	const STRUCTURE_CONSTRUCTING_SPEED = 0.3  # progress [0.0..1.0] per second


class VoiceNarrator:
	enum Events {
		MATCH_STARTED,
		MATCH_ABORTED,
		MATCH_FINISHED_WITH_VICTORY,
		MATCH_FINISHED_WITH_DEFEAT,
		BASE_UNDER_ATTACK,
		UNIT_UNDER_ATTACK,
		UNIT_LOST,
		UNIT_PRODUCTION_STARTED,
		UNIT_PRODUCTION_FINISHED,
		UNIT_CONSTRUCTION_FINISHED,
		UNIT_HELLO,
		UNIT_ACK_1,
		UNIT_ACK_2,
		NOT_ENOUGH_RESOURCES,
	}

	const EVENT_TO_ASSET_MAPPING = {
		Events.MATCH_STARTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/battle_control_online.ogg"),
		Events.MATCH_ABORTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/battle_control_offline.ogg"),
		Events.MATCH_FINISHED_WITH_VICTORY:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/you_are_victorious.ogg"),
		Events.MATCH_FINISHED_WITH_DEFEAT:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/you_have_lost.ogg"),
		Events.BASE_UNDER_ATTACK:
		preload(
			"res://assets/voice/english/ttsmaker-com-148-alayna-us/your_base_is_under_attack.ogg"
		),
		Events.UNIT_UNDER_ATTACK:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_under_attack.ogg"),
		Events.UNIT_LOST:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_lost.ogg"),
		Events.UNIT_PRODUCTION_STARTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/training.ogg"),
		Events.UNIT_PRODUCTION_FINISHED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_ready.ogg"),
		Events.UNIT_CONSTRUCTION_FINISHED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/construction_complete.ogg"),
		Events.UNIT_HELLO:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/sir.ogg"),
		Events.UNIT_ACK_1:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/yes_sir.ogg"),
		Events.UNIT_ACK_2:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/acknowledged.ogg"),
		Events.NOT_ENOUGH_RESOURCES:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/not_enough_resources.ogg"),
	}
