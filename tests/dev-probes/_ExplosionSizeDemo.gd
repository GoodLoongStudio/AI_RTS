extends Node

## 爆炸尺寸自适应 + 零友伤的可见演示（录像验收件，2026-10-12）。
##
## 干什么：在真实 Match 里摆一小组靶子——爆点上两台敌方坦克、爆点 3m 处一台己方坦克，
## 然后依次让坦克炮（判定半径 8m）、火箭弹（5m）、重坦炮（8m）各持续开火若干秒。
## 相机跟住爆点，所以录像里应当看到：火球明显盖过 8m/5m 的判定范围、
## 两种尺寸差看得见，而站在 3m 的自己人一次都不掉血。
##
## 时间轴：每 0.2s 采样一次并打 `[DEMO] t=<毫秒>` 事件行（新出现的爆炸节点会打它的
## blast_radius_m 与 scale）。录像侧 `record_playtest.py` 的 frames.jsonl 用同一台机器的
## 墙钟，两边按毫秒对齐；不要只凭"看起来在那一段"下结论。

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HeavyTankScene = preload("res://source/match/units/HeavyTank.tscn")
const RocketeerScene = preload("res://source/match/units/Rocketeer.tscn")

const CLUSTER_OFFSET := Vector3(12.0, 0.0, 0.0)
const TANK_HP := 300.0

## 阶段：[标签, 射手场景, 相对爆点的射手落点, 观察秒数]
const PHASES := [
	["tank_cannon_radius8", TankScene, Vector3(-10.0, 0.0, 0.0), 8.0],
	["rocketeer_radius5", RocketeerScene, Vector3(0.0, 0.0, -8.0), 8.0],
	["heavy_cannon_radius8", HeavyTankScene, Vector3(-12.0, 0.0, 5.0), 10.0],
]

var _match: Node = null
var _seen_explosions := {}
## 事件时间轴文件：每次运行新建一个（不覆盖旧证据），路径在启动时打出来。
var _events_path := ""
var _events_file: FileAccess = null


func _ready():
	# 非 console 引擎实例不接管道时 stdout 无处可去，所以时间轴直接落到 agent/runs/ 下，
	# 与录像 frames.jsonl 用同一台机器的墙钟毫秒对齐。
	var stamp := _wall_ms()
	_events_path = "res://agent/runs/speedx2-combat/demo-events-%d.jsonl" % stamp
	_events_file = FileAccess.open(_events_path, FileAccess.WRITE)
	print("[DEMO] events_file=%s" % _events_path)
	# 必须先让出一帧：本节点的 _ready 是在 root 正在挂子节点的过程中跑的，
	# 此时 root.add_child(Match) 会直接被拒（"Parent node is busy setting up children"）。
	await get_tree().process_frame
	var settings = MatchSettings.new()
	var human = PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Color.BLUE
	settings.players.append(human)
	var ai = PlayerSettings.new()
	ai.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	ai.color = Color.RED
	settings.players.append(ai)
	settings.visible_player = 0

	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child(_match)

	var ready := false
	var deadline := Time.get_ticks_msec() + 90000
	while Time.get_ticks_msec() < deadline and not ready:
		await get_tree().physics_frame
		var players: Node = _match.get_node_or_null("Players")
		ready = players != null and players.get_child_count() >= 2 \
			and players.get_child(0).get_child_count() > 0
	if not ready:
		_event("abort=match_not_ready")
		_quit(1)
		return

	var human_player: Node = _match.get_node("Players").get_child(0)
	var enemy_player: Node = _match.get_node("Players").get_child(1)
	var cc: Node3D = null
	for child in human_player.get_children():
		if child is Node3D and str(child.scene_file_path).contains("CommandCenter"):
			cc = child
	if cc == null:
		_event("abort=no_command_center")
		_quit(1)
		return
	var cluster: Vector3 = cc.global_position + CLUSTER_OFFSET

	# 敌方两台靶子站在爆点上；己方一台站在 3m 外（溅射窗内），它必须全程不掉血。
	var victims: Array = []
	victims.append(_spawn(TankScene, cluster, enemy_player))
	victims.append(_spawn(TankScene, cluster + Vector3(2.0, 0.0, 1.5), enemy_player))
	var friend: Node3D = _spawn(TankScene, cluster + Vector3(0.0, 0.0, 3.0), human_player)
	for victim in victims:
		victim.hp = TANK_HP
	friend.hp = TANK_HP
	var gateway = human_player.get_node_or_null("UnitCommandGateway")
	if gateway != null:
		for victim in victims:
			gateway.SetFirePolicy([victim], "HoldFire", enemy_player)
	await get_tree().physics_frame

	var camera = _match.get_node_or_null("IsometricCamera3D")
	if camera != null and camera.has_method("set_follow_target"):
		camera.set_follow_target(victims[0])
	# 地面参考圈：内径 7.9 外径 8.0 的扁环，正好是坦克炮/重坦炮的权威判定半径。
	# 录像是拿它来判"特效是否稍微盖过判定范围"，不靠目测估米数。
	_add_radius_ring(cluster, 8.0)
	_event("READY_TO_RECORD cluster=%.1f,%.1f victims=%d friend_hp=%.1f ring_r=8.0" % [
		cluster.x, cluster.z, victims.size(), float(friend.hp)])

	for phase in PHASES:
		var shooter = _spawn(phase[1], cluster + phase[2], human_player)
		if not bool(shooter.request_legacy_ground_force_attack(cluster)):
			_event("phase=%s 强制攻击被拒（射手射程或落点问题）" % str(phase[0]))
			continue
		_event("phase=%s begin shooter_hp=%.1f friend_hp=%.1f victim_hp=%.1f" % [
			phase[0], float(shooter.hp), float(friend.hp), float(victims[0].hp)])
		await _observe(float(phase[3]), victims, friend)
		_event("phase=%s end friend_hp=%.1f victim_hp=%.1f" % [
			phase[0], float(friend.hp), float(victims[0].hp)])

	_event("DONE final_friend_hp=%.1f" % float(friend.hp))
	await get_tree().create_timer(1.5).timeout
	_quit(0)


## 收尾：先合上事件文件（保证录像对账用的最后一行落盘），再走 SmokeTestExit 回收整局。
func _quit(code: int) -> void:
	_close_events()
	SmokeTestExit.request(get_tree(), code, _match)


## 观察窗口：每 0.2s 采样血量，并对容器里新出现的落点特效打一行尺寸事件。
func _observe(seconds: float, victims: Array, friend):
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().physics_frame
		var projectiles = _match.get_node_or_null("Projectiles")
		if projectiles != null:
			for child in projectiles.get_children():
				if _seen_explosions.has(child.get_instance_id()):
					continue
				if not str(child.scene_file_path).ends_with("ShellExplosion.tscn"):
					continue
				_seen_explosions[child.get_instance_id()] = true
				_event("explosion blast_radius_m=%.2f scale=%.3f" % [
					float(child.get_meta("blast_radius_m", -1.0)), child.scale.x])
		if int(Time.get_ticks_msec()) % 1000 < 20:
			_event("sample friend_hp=%.1f victim_hp=%.1f" % [
				float(friend.hp) if is_instance_valid(friend) else -1.0,
				float(victims[0].hp) if is_instance_valid(victims[0]) else -1.0])


## 画一个精确等于判定半径的地面参考环（只为录像对照，不参与任何判据）。
func _add_radius_ring(center: Vector3, radius: float) -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.15
	torus.outer_radius = radius
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.global_position = center + Vector3(0.0, 0.25, 0.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.15, 0.9, 1.0, 0.9)
	mesh.material_override = mat
	_match.add_child(mesh)


func _spawn(scene: PackedScene, at: Vector3, owner_player: Node) -> Node3D:
	var unit = scene.instantiate()
	_match._setup_and_spawn_unit(unit, Transform3D(Basis.IDENTITY, at), owner_player, false)
	return unit


## 本机这版 Godot 的 Time 没有 get_datetime_msec()，用 unix 秒 ×1000 取 UTC 毫秒，
## 与录像 frames.jsonl 的墙钟同源。
func _wall_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func _event(msg: String) -> void:
	print("[DEMO] t=%d %s" % [Time.get_ticks_msec(), msg])
	if _events_file != null:
		# 同时记引擎毫秒与 UTC 毫秒：录像 frames.jsonl 只有墙钟，两者要靠 wall_ms 对齐。
		_events_file.store_line(JSON.stringify({
			"engine_ms": Time.get_ticks_msec(),
			"wall_ms": _wall_ms(),
			"msg": msg,
		}))
		_events_file.flush()


func _close_events() -> void:
	if _events_file != null:
		_events_file.close()
		_events_file = null
