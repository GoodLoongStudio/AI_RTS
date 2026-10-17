extends Node

## 阶段5 特效运行时审计（2026-10-01 世界尺度）。
## headless dummy 渲染器不模拟 GPU 粒子（get_transformed_aabb 恒空）⇒
## 从**运行时加载的资源**解析评估：process_material（发射半径/初速/寿命/重力）
## + draw_pass 网格尺寸 + Sprite3D pixel_size×贴图。输出世界包络与"挂缩放父是否二次缩放"。
## 可见视觉确认留给可见实例截图阶段（报告注明）。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"

const EFFECTS := [
	["Sparkling", "res://source/match/utils/SparklingAnimation.tscn"],
	["ShellExplosion", "res://source/match/units/projectiles/ShellExplosion.tscn"],
	["MouseClick", "res://source/match/utils/MouseClickAnimation.tscn"],
	["CannonShell", "res://source/match/units/projectiles/CannonShell.tscn"],
	["Rocket", "res://source/match/units/projectiles/Rocket.tscn"],
	["RifleRound", "res://source/match/units/projectiles/RifleRound.tscn"],
]


func _ready():
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Constants.Player.COLORS[0]
	settings.players.append(hs)
	settings.visible_player = 0
	var m: Node = load("res://source/match/Match.tscn").instantiate()
	m.settings = settings
	m.map = load(MAP_SCENE).instantiate()
	add_child(m)
	get_tree().current_scene = m
	for _f in range(200):
		await get_tree().physics_frame
	print("[FX] 名称|发射半径|初速max|寿命s|one_shot|网格/贴图尺寸|包络外缘m|挂scale2父后倍率")
	for entry in EFFECTS:
		var packed: PackedScene = load(entry[1])
		if packed == null:
			print("[FX] %s|LOAD_FAIL" % entry[0])
			continue
		var state := _evaluate_scene(packed, Vector3(1, 1, 1))
		var state_scaled := _evaluate_scene(packed, Vector3(2, 2, 2))
		var ratio := (state_scaled.envelope / state.envelope) if state.envelope > 0.001 else -1.0
		print("[FX] %s|%.2f|%.2f|%s|%s|%s|%.2f|%.2fx" % [
			entry[0], state.emission_r, state.v_max,
			("%.2f" % state.lifetime) if state.lifetime > 0 else "n/a",
			str(state.one_shot), state.mesh_desc, state.envelope, ratio])
	get_tree().quit(0)


class FxState:
	var emission_r := 0.0
	var v_max := 0.0
	var lifetime := -1.0
	var one_shot := false
	var mesh_desc := ""
	var envelope := 0.0


func _evaluate_scene(packed: PackedScene, parent_scale: Vector3) -> FxState:
	var state := FxState.new()
	var inst := packed.instantiate()
	var holder := Node3D.new()
	holder.scale = parent_scale
	holder.add_child(inst)
	get_tree().root.add_child(holder)
	var origin := Vector3(30.0, 0.0, 60.0)
	if inst is Node3D:
		(inst as Node3D).global_position = origin
	for part in inst.find_children("*", "GPUParticles3D", true, false):
		var gp := part as GPUParticles3D
		state.one_shot = state.one_shot or gp.one_shot
		if gp.lifetime > state.lifetime:
			state.lifetime = gp.lifetime
		var proc := gp.process_material as ParticleProcessMaterial
		if proc != null:
			if proc.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_SPHERE:
				state.emission_r = maxf(state.emission_r, proc.emission_sphere_radius)
			# initial_velocity_min/max 是标量（m/s）；曲线模式读 curve 不可行，取标量口径。
			if proc.initial_velocity_max > state.v_max:
				state.v_max = proc.initial_velocity_max
		for pi in range(gp.draw_passes):
			var mesh: Mesh = gp.get_draw_pass_mesh(pi)
			if mesh != null:
				state.mesh_desc += "mesh%.2fm " % _mesh_extent(mesh)
	for sprite in inst.find_children("*", "Sprite3D", true, false):
		var sp := sprite as Sprite3D
		if sp.texture != null:
			var world_w: float = sp.texture.get_width() * sp.pixel_size * parent_scale.x
			state.mesh_desc += "sprite%.2fm " % world_w
			state.emission_r = maxf(state.emission_r, world_w * 0.5)
	var flight: float = (state.lifetime * 0.5) if state.lifetime > 0 else 0.25
	state.envelope = state.emission_r + state.v_max * flight
	if state.mesh_desc.contains("mesh"):
		state.envelope += 0.15
	holder.queue_free()
	return state


func _mesh_extent(mesh: Mesh) -> float:
	var aabb := mesh.get_aabb()
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
