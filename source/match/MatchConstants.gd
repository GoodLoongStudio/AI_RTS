const OWNED_PLAYER_CIRCLE_COLOR = Color.GREEN
const ADVERSARY_PLAYER_CIRCLE_COLOR = Color.RED
const RESOURCE_CIRCLE_COLOR = Color.YELLOW
const DEFAULT_CIRCLE_COLOR = Color.WHITE
# 选中单位/建筑时显示的攻击范围圈（2026-09-12 用户要求"点击炮塔和单位要显示其攻击范围"）。
# 刻意不用绿色：绿色在语义上已经是"选中圈"，两圈同心时必须一眼分得开。
const ATTACK_RANGE_CIRCLE_COLOR = Color(0.55, 0.85, 1.0)
const MAPS = {
	"res://source/match/maps/PlainAndSimple.tscn":
	{
		"name": "Plain & Simple",
		"players": 4,
		# 【2026-09-15 用户要求】50×50 → 100×100 → 200×200（2026-09-27 单位/建筑放大后地图同步 ×2；出生点四角外圈）。
		# 该 size 只用于菜单文案与小地图等 UI；**运行时以 `Map.size`（场景根节点属性）为准**，
		# 两者必须同步改，否则菜单显示与实际地图不一致。
		"size": Vector2i(512, 512),
	},
	# 【2026-09-29 用户要求】把工作台最新产出的 3 张合规图挂进大厅（"把这3个好地图加上去"）。
	# 这批图按最新 G3 规则生成（矿点不落水面/桥面/山岩，含 12 个随机散矿），已逐张验证
	# 场景可加载。名字沿用工作台标题，方便和「RTS 地图工作台」的生成记录对上。
	# 注意：大厅不自动发现生成图（DISCOVER_GENERATED_MAPS=false），新图出片后在这里手动登记。
	"res://source/match/maps/generated/47-903520021-767a002977/map_47-903520021-767a002977.tscn":
	{
		"name": "布局 47 · 地貌 903520021",
		"players": 4,
		"size": Vector2i(512, 512),
	},
	"res://source/match/maps/generated/36-1846106761-767a002977/map_36-1846106761-767a002977.tscn":
	{
		"name": "布局 36 · 地貌 1846106761",
		"players": 4,
		"size": Vector2i(512, 512),
	},
	"res://source/match/maps/generated/8-561215132-767a002977/map_8-561215132-767a002977.tscn":
	{
		"name": "布局 8 · 地貌 561215132",
		"players": 4,
		"size": Vector2i(512, 512),
	},
	# 大厅统一512世界米；生成器源栅格256不等于实际地图大小。
	# 8 人 BigArena 已从大厅拿掉（2026-09-15）；场景文件仍保留。
	# 【2026-09-20】"G4 大湖 seed16"已从大厅移除（用户要求）：它由
	# tools/mapgen/tools/regen_large_lake_256.py 生成，作为随机地图 G1-G4
	# 流程的参照样本保留在 tools 里；菜单只保留 Plain & Simple。
}

# 自定义对局地图清单只保留 4 人图。
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
						var size_arr: Array = parsed.get("size", [0, 0])
						var players := int(parsed.get("players", 4))
						var size := Vector2i(int(size_arr[0]), int(size_arr[1]))
						# 旧尺寸和缺少尺寸合同的残包不进菜单。
						if players != 4 or size != Vector2i(512, 512):
							continue
						result[parsed["path"]] = {
							"name": str(parsed.get("name", entry)),
							"players": players,
							"size": size,
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
	# 空域导航网格的烘焙/AABB 参考高度（覆盖台地与山体）。
	# 飞机实体不得钉在这个全局 Y 上，否则平地局会飞出镜头或穿进高台。
	const Y = 40.0
	const PLANE = Plane(Vector3.UP, Y)
	## 飞机相对脚下地表的离地高度（世界米）。
	## 1.8 是单位放大前定的；现在最大地面载具半径 2.8m、空中单位半径 2.3m，
	## 贴地 1.8m 会让飞机看起来擦着地面/车顶滑行，提到 3.5m（约 1.5× 空中单位半径）。
	const HOVER_OFFSET = 3.5

	class Navmesh:
		# 2048m 大地图：cell 过小会让 Recast 栅格超限，触发引擎崩溃防护
		# （Baking interrupted -> polygons=0；on_thread 时直接 0xC0000005）。
		const CELL_SIZE = 0.3
		const CELL_HEIGHT = 0.4
		# 【2026-09-27 单位整体放大】原 0.8 是按 0.8~0.9m 半径的单位定的，
		# 现在最大空中单位（直升机）半径 2.3m：agent 半径必须 ≥ 单位半径，
		# 否则烘焙出的走廊比单位窄（单位会卡墙/穿模）。cell_size 0.8 < 2.3 仍合法。
		const MAX_AGENT_RADIUS = 0.9  # 空中域同值（空中实体不参与 carve）


class Terrain:
	const PLANE = Plane(Vector3.UP, 0)

	class Navmesh:
		# 0.3 -> 0.6：2048m 世界栅格从 6800^2 降到 3400^2（崩溃防护阈值内）
		const CELL_SIZE = 0.3
		const CELL_HEIGHT = 0.4
		# 【2026-09-27 单位整体放大】原 0.9 是按半径 ≤0.9 的单位定的；现在最大地面
		# 载具（运输卡车）半径 2.8m——agent 半径必须 ≥ 单位半径，否则单位比走廊宽，
		# 表现为"贴着墙走/绕墙到达误差巨大"。cell_size 0.6 < 2.8 仍合法。
		const MAX_AGENT_RADIUS = 0.9  # 与 navmesh.agent_radius 同步；大单位靠逻辑推出层兜底（见 skills 碰撞约定）
		# 建筑 carve 轮廓在碰撞表面外再扩的距离。体素化+轮廓简化会把 agent 腐蚀吃掉一部分，
		# 洞边离表面实际只有约 0.5~0.9m；外扩后洞边须 ≥ 矿车推出层的表面距离（≈1.21m），
		# 否则寻路会把矿车送进推出层不让站的环带里来回顶。取值依据见 docs/plan/navigation-clearance-plan.md。
		const STRUCTURE_CARVE_MARGIN_M = 0.6
		# 挖洞建筑是否同时作为 RVO 障碍。开着时两楼之间的窄口会被 RVO 障碍+人群锁死
		# （movement-recovery override 场景坦克 40s 退不出）；关掉后 RVO 会把单位往楼里挤、
		# 由推出层顶回，因此 Movement 里被动推挤不改朝向、推出前先截断步长。
		const STRUCTURE_AVOIDANCE_ENABLED = false


class Resources:
	class A:
		# 金矿块（2026-09-28 换型）：矿点模型换成 4041 的 SM_Prop_Gold_Nugget_01，
		# HUD 资源条色块跟着改金，别再让 UI 上的"矿"是蓝色、地上的矿是金色。
		const COLOR = Color(0.96, 0.78, 0.25, 1)
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
		Events.MATCH_STARTED: preload("res://assets/voice/chinese/narrator_battle_control_online.mp3"),
		Events.MATCH_ABORTED: preload("res://assets/voice/chinese/narrator_battle_control_offline.mp3"),
		Events.MATCH_FINISHED_WITH_VICTORY: preload("res://assets/voice/chinese/narrator_victory.mp3"),
		Events.MATCH_FINISHED_WITH_DEFEAT: preload("res://assets/voice/chinese/narrator_defeat.mp3"),
		Events.BASE_UNDER_ATTACK: preload("res://assets/voice/chinese/narrator_base_under_attack.mp3"),
		Events.UNIT_UNDER_ATTACK: preload("res://assets/voice/chinese/narrator_unit_under_attack.mp3"),
		Events.UNIT_LOST: preload("res://assets/voice/chinese/narrator_unit_lost.mp3"),
		Events.UNIT_PRODUCTION_STARTED: preload("res://assets/voice/chinese/narrator_training.mp3"),
		Events.UNIT_PRODUCTION_FINISHED: preload("res://assets/voice/chinese/narrator_unit_ready.mp3"),
		Events.UNIT_CONSTRUCTION_FINISHED: preload(
			"res://assets/voice/chinese/narrator_construction_complete.mp3"
		),
		Events.NOT_ENOUGH_RESOURCES: preload("res://assets/voice/chinese/narrator_not_enough_resources.mp3"),
	}

	## 单位选中语音：unit_type_id → 音频流（未收录类型兜底步兵）。
	const UNIT_HELLO_MAPPING = {
		"worker": preload("res://assets/voice/chinese/unit_worker_hello.mp3"),
		"drone": preload("res://assets/voice/chinese/unit_drone_hello.mp3"),
		"soldier": preload("res://assets/voice/chinese/unit_soldier_hello.mp3"),
		"sniper": preload("res://assets/voice/chinese/unit_sniper_hello.mp3"),
		"rocketeer": preload("res://assets/voice/chinese/unit_rocketeer_hello.mp3"),
		"transport_truck": preload("res://assets/voice/chinese/unit_transport_truck_hello.mp3"),
		"apc": preload("res://assets/voice/chinese/unit_apc_hello.mp3"),
		"tank": preload("res://assets/voice/chinese/unit_tank_hello.mp3"),
		"heavy_tank": preload("res://assets/voice/chinese/unit_heavy_tank_hello.mp3"),
		"helicopter": preload("res://assets/voice/chinese/unit_helicopter_hello.mp3"),
	}

	## 单位命令确认语音（两条轮换）：unit_type_id → 音频流。
	const UNIT_ACK_1_MAPPING = {
		"worker": preload("res://assets/voice/chinese/unit_worker_ack1.mp3"),
		"drone": preload("res://assets/voice/chinese/unit_drone_ack1.mp3"),
		"soldier": preload("res://assets/voice/chinese/unit_soldier_ack1.mp3"),
		"sniper": preload("res://assets/voice/chinese/unit_sniper_ack1.mp3"),
		"rocketeer": preload("res://assets/voice/chinese/unit_rocketeer_ack1.mp3"),
		"transport_truck": preload("res://assets/voice/chinese/unit_transport_truck_ack1.mp3"),
		"apc": preload("res://assets/voice/chinese/unit_apc_ack1.mp3"),
		"tank": preload("res://assets/voice/chinese/unit_tank_ack1.mp3"),
		"heavy_tank": preload("res://assets/voice/chinese/unit_heavy_tank_ack1.mp3"),
		"helicopter": preload("res://assets/voice/chinese/unit_helicopter_ack1.mp3"),
	}

	const UNIT_ACK_2_MAPPING = {
		"worker": preload("res://assets/voice/chinese/unit_worker_ack2.mp3"),
		"drone": preload("res://assets/voice/chinese/unit_drone_ack2.mp3"),
		"soldier": preload("res://assets/voice/chinese/unit_soldier_ack2.mp3"),
		"sniper": preload("res://assets/voice/chinese/unit_sniper_ack2.mp3"),
		"rocketeer": preload("res://assets/voice/chinese/unit_rocketeer_ack2.mp3"),
		"transport_truck": preload("res://assets/voice/chinese/unit_transport_truck_ack2.mp3"),
		"apc": preload("res://assets/voice/chinese/unit_apc_ack2.mp3"),
		"tank": preload("res://assets/voice/chinese/unit_tank_ack2.mp3"),
		"heavy_tank": preload("res://assets/voice/chinese/unit_heavy_tank_ack2.mp3"),
		"helicopter": preload("res://assets/voice/chinese/unit_helicopter_ack2.mp3"),
	}

	## 建筑选中语音：unit_type_id → 音频流。
	const STRUCTURE_HELLO_MAPPING = {
		"ore_refinery": preload("res://assets/voice/chinese/structure_ore_refinery.tres"),
		"command_center": preload("res://assets/voice/chinese/structure_command_center.mp3"),
		"barracks": preload("res://assets/voice/chinese/structure_barracks.mp3"),
		"vehicle_factory": preload("res://assets/voice/chinese/structure_vehicle_factory.mp3"),
		"aircraft_factory": preload("res://assets/voice/chinese/structure_aircraft_factory.mp3"),
		"anti_ground_turret": preload("res://assets/voice/chinese/structure_anti_ground_turret.mp3"),
		"anti_air_turret": preload("res://assets/voice/chinese/structure_anti_air_turret.mp3"),
		"machine_gun_turret": preload("res://assets/voice/chinese/structure_machine_gun_turret.mp3"),
	}

	## 未收录单位类型的兜底语音（步兵）。
	const FALLBACK_HELLO := preload("res://assets/voice/chinese/unit_soldier_hello.mp3")
	const FALLBACK_ACK_1 := preload("res://assets/voice/chinese/unit_soldier_ack1.mp3")
	const FALLBACK_ACK_2 := preload("res://assets/voice/chinese/unit_soldier_ack2.mp3")

	## 按单位类型取选中/确认语音；type_id 为空或未收录时回落步兵语音。
	static func unit_voice(unit_type_id: String, event: int) -> AudioStream:
		var mapping := {}
		var fallback: AudioStream = FALLBACK_HELLO
		match event:
			Events.UNIT_HELLO:
				mapping = UNIT_HELLO_MAPPING
				fallback = FALLBACK_HELLO
			Events.UNIT_ACK_1:
				mapping = UNIT_ACK_1_MAPPING
				fallback = FALLBACK_ACK_1
			Events.UNIT_ACK_2:
				mapping = UNIT_ACK_2_MAPPING
				fallback = FALLBACK_ACK_2
			_:
				return null
		return mapping.get(unit_type_id, fallback)
