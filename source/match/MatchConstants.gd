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


class Navigation:
	enum Domain { AIR, TERRAIN }

	const DOMAIN_TO_GROUP_MAPPING = {
		Domain.AIR: "air_navigation_input",
		Domain.TERRAIN: "terrain_navigation_input",
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
	const ADHERENCE_MARGIN_M = 0.3  # TODO: try lowering while fixing a 'push' problem
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
		preload("res://assets/voice/zh-CN/narrator/battle_control_online.mp3"),
		Events.MATCH_ABORTED:
		preload("res://assets/voice/zh-CN/narrator/battle_control_offline.mp3"),
		Events.MATCH_FINISHED_WITH_VICTORY:
		preload("res://assets/voice/zh-CN/narrator/you_are_victorious.mp3"),
		Events.MATCH_FINISHED_WITH_DEFEAT:
		preload("res://assets/voice/zh-CN/narrator/you_have_lost.mp3"),
		Events.BASE_UNDER_ATTACK:
		preload("res://assets/voice/zh-CN/narrator/your_base_is_under_attack.mp3"),
		Events.UNIT_UNDER_ATTACK:
		preload("res://assets/voice/zh-CN/narrator/unit_under_attack.mp3"),
		Events.UNIT_LOST:
		preload("res://assets/voice/zh-CN/narrator/unit_lost.mp3"),
		Events.UNIT_PRODUCTION_STARTED:
		preload("res://assets/voice/zh-CN/narrator/training.mp3"),
		Events.UNIT_PRODUCTION_FINISHED:
		preload("res://assets/voice/zh-CN/narrator/unit_ready.mp3"),
		Events.UNIT_CONSTRUCTION_FINISHED:
		preload("res://assets/voice/zh-CN/narrator/construction_complete.mp3"),
		Events.UNIT_HELLO:
		preload("res://assets/voice/zh-CN/unit/sir.mp3"),
		Events.UNIT_ACK_1:
		preload("res://assets/voice/zh-CN/unit/yes_sir.mp3"),
		Events.UNIT_ACK_2:
		preload("res://assets/voice/zh-CN/unit/acknowledged.mp3"),
		Events.NOT_ENOUGH_RESOURCES:
		preload("res://assets/voice/zh-CN/narrator/not_enough_resources.mp3"),
	}
