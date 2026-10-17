extends Node

## 迁移前世界值快照（GPT-6 归一化计划 阶段 1/2 的验证基准）。
## 对每个单位场景**按作者原样**实例化（不经过 Match._setup_and_spawn_unit），
## 打印四类世界尺寸 + 每个表现/玩法节点的世界缩放与位置，供迁移后逐项比对。
## 输出为 JSON（每行一条 [SNAP] {...}），便于后续程序化 diff。

const SCENES := [
	"CommandCenter", "VehicleFactory", "Barracks", "AircraftFactory", "OreRefinery",
	"AntiGroundTurret", "AntiAirTurret", "MachineGunTurret",
	"Tank", "HeavyTank", "APC", "TransportTruck", "Worker", "Drone", "Scout", "Infantry",
	"Helicopter", "Rocketeer", "Sniper",
	"ResourceA", "ResourceB",
]
const WATCH := [
	"Geometry", "CollisionShape3D", "MovementObstacle", "Movement", "Highlight",
	"Selection", "Targetability", "HealthBar", "RallyPoint", "DetachTransform",
]
## 旋转不变的"模型尺寸"口径：几何子树里每个网格的**本地** AABB 尺寸 × 世界缩放。
## 炮塔的待机随机会转头部，直接用世界 AABB 比较会被旋转污染（x/z 变化、y 不变）。
const GEOMETRY_PATHS := ["Geometry", "DetachTransform/Geometry"]


const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


func _ready():
	# 必须在真实 Match 里生成：单位脚本依赖 "Match"/"Players" 等父链，裸实例化会报错中断。
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var match_node: Node = load("res://source/match/Match.tscn").instantiate()
	match_node.settings = settings
	match_node.map = load(MAP_SCENE).instantiate()
	add_child(match_node)
	get_tree().current_scene = match_node
	for _f in range(240):
		await get_tree().physics_frame
	var human: Node = match_node.get_node("Players").get_children()[0]
	var holder := Node3D.new()
	add_child(holder)
	for name in SCENES:
		var path := "res://source/match/units/%s.tscn" % name
		if not ResourceLoader.exists(path):
			print("[SNAP] {\"scene\":\"%s\",\"missing\":true}" % name)
			continue
		var node: Node3D = load(path).instantiate()
		# 走标准出生路径（含 Match 的根缩放合入），把"运行时世界值"如实记下来。
		match_node.call(
			"_setup_and_spawn_unit", node,
			Transform3D(Basis.IDENTITY, Vector3(150.0, 0.0, 150.0)), human, false
		)
		for _f in range(3):
			await get_tree().physics_frame
		await get_tree().process_frame
		var entry := {
			"scene": name,
			"root_type": node.get_class(),
			"root_scale": _vec(node.scale),
			"visual_world_aabb": _visual_aabb(node),
			"collision_world_aabb": _collision_aabb(node),
			"nodes": {},
		}
		for child_name in WATCH:
			var child := node.get_node_or_null(child_name)
			if child == null:
				continue
			var item := {"type": child.get_class()}
			if not (child is Node3D):
				# 例如炮塔的 DetachTransform 是普通 Node（无 Transform），只记类型。
				entry["nodes"][child_name] = item
				continue
			item["world_scale"] = _vec((child as Node3D).global_transform.basis.get_scale())
			item["local_scale"] = _vec((child as Node3D).scale)
			item["origin_world"] = _vec((child as Node3D).global_position)
			for prop in ["radius", "size"]:
				if child.get(prop) != null:
					item[prop] = str(child.get(prop))
			if child is CollisionShape3D and (child as CollisionShape3D).shape is CylinderShape3D:
				var cyl: CylinderShape3D = (child as CollisionShape3D).shape
				item["shape_radius"] = cyl.radius
				item["shape_height"] = cyl.height
				item["shape_scale"] = _vec((child as CollisionShape3D).scale)
			var obs: Node = child
			if obs.get("vertices") != null and (obs.get("vertices") as PackedVector3Array).size() > 0:
				var verts: PackedVector3Array = obs.get("vertices")
				var world_scale := (obs as Node3D).global_transform.basis.get_scale().x
				var outer := 0.0
				for v in verts:
					outer = maxf(outer, Vector2(v.x, v.z).length() * world_scale)
				item["carve_ring_world_outer"] = snappedf(outer, 0.01)
			entry["nodes"][child_name] = item
		# 旋转不变的"模型尺寸"口径：几何子树各网格**本地** AABB 尺寸 × 该网格本地缩放，
		# 再乘几何节点的世界缩放。炮塔待机随机转头，直接用世界 AABB 会被旋转污染。
		for geo_path in GEOMETRY_PATHS:
			var geo_node: Node3D = node.get_node_or_null(geo_path)
			if geo_node == null:
				continue
			var total := Vector3.ZERO
			for sub in geo_node.find_children("*", "MeshInstance3D", true, false):
				var mi: MeshInstance3D = sub
				if mi.mesh == null:
					continue
				var aabb: AABB = mi.mesh.get_aabb()
				var ls: Vector3 = mi.transform.basis.get_scale()
				total = Vector3(
					maxf(total.x, aabb.size.x * ls.x),
					maxf(total.y, aabb.size.y * ls.y),
					maxf(total.z, aabb.size.z * ls.z))
			var ws: float = geo_node.global_transform.basis.get_scale().x
			entry["model_local_max"] = [snappedf(total.x, 0.001), snappedf(total.y, 0.001), snappedf(total.z, 0.001)]
			entry["geometry_world_scale"] = snappedf(ws, 0.0001)
			break
		print("[SNAP] ", JSON.stringify(entry))
		node.queue_free()
		await get_tree().process_frame
	get_tree().quit(0)


func _vec(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


func _visual_aabb(node: Node3D) -> Array:
	var out := AABB()
	var first := true
	for sub in node.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = sub
		if str(sub.name).begins_with("ActualBar") or sub.name == "HealthBar":
			continue
		var aabb: AABB = gi.get_aabb()
		if aabb.size.length_squared() <= 0.0 and gi is MeshInstance3D:
			var mesh: Mesh = (gi as MeshInstance3D).mesh
			if mesh != null:
				aabb = mesh.get_aabb()
		var world := gi.global_transform * aabb
		out = world if first else out.merge(world)
		first = false
	return [snappedf(out.size.x, 0.01), snappedf(out.size.y, 0.01), snappedf(out.size.z, 0.01)]


func _collision_aabb(node: Node3D) -> Array:
	var out := AABB()
	var first := true
	for sub in node.find_children("*", "CollisionShape3D", true, false):
		var cs: CollisionShape3D = sub
		if cs.shape == null:
			continue
		var ext: AABB = AABB()
		if cs.shape.has_method("get_rect"):
			ext = cs.shape.get_rect()
		if cs.shape is CylinderShape3D:
			var cyl: CylinderShape3D = cs.shape
			ext = AABB(Vector3(-cyl.radius, -cyl.height * 0.5, -cyl.radius),
				Vector3(cyl.radius * 2.0, cyl.height, cyl.radius * 2.0))
		var world: AABB = cs.global_transform * ext
		out = world if first else out.merge(world)
		first = false
	return [snappedf(out.size.x, 0.01), snappedf(out.size.y, 0.01), snappedf(out.size.z, 0.01)]
