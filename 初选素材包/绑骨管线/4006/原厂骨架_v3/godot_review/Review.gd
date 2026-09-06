extends Node3D

const CLIPS := ["Idle", "Run", "Fire", "Hit", "HitHeavy", "Crawl", "Death"]
const LABELS := ["待命", "跑步", "射击", "子弹命中", "爆炸击飞死亡", "匍匐", "死亡"]
const LOOPS := ["Idle", "Run", "Crawl"]
const EXPECTED_SECONDS := {"Idle": 59.0/30.0, "Run": 0.7, "Fire": 0.6, "Hit": 0.3, "HitHeavy": 1.8, "Crawl": 65.0/30.0, "Death": 2.4}
var camera: Camera3D
var player: AnimationPlayer
var skeleton: Skeleton3D
var info: Label
var selected := "Idle"
var paused := false
var failures: Array[String] = []

func _ready() -> void:
	var model: Node3D = load("res://Infantry_native_v3.glb").instantiate()
	add_child(model)
	# The original Synty asset exports facing +Z; gameplay uses -Z.
	model.rotation.y = PI
	player = model.find_child("AnimationPlayer", true, false)
	skeleton = model.find_child("Skeleton3D", true, false)
	camera = Camera3D.new()
	add_child(camera)
	camera.position = Vector3(2.6, 2.2, -4.6)
	camera.look_at(Vector3(0, 0.85, 0))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.6
	camera.current = true
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.24, 0.27, 0.31)
	ground.material_override = material
	add_child(ground)
	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-45, -30, 0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	light.directional_shadow_max_distance = 12.0
	light.shadow_bias = 0.1
	light.shadow_normal_bias = 0.8
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.12, 0.14, 0.17)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.8, 0.85, 1)
	settings.ambient_light_energy = 0.5
	environment.environment = settings
	add_child(environment)
	_setup_controls()
	if "--verify" in OS.get_cmdline_user_args():
		await _verify()
	else:
		player.animation_finished.connect(func(_name):
			if not paused: player.play(selected))
		_play("Idle")

func _setup_controls() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var box := VBoxContainer.new()
	box.position = Vector2(18, 16)
	layer.add_child(box)
	info = Label.new()
	info.text = "4006 原厂骨架 · 单角色审核"
	box.add_child(info)
	var row := HBoxContainer.new()
	box.add_child(row)
	for i in CLIPS.size():
		var button := Button.new()
		button.text = LABELS[i]
		button.pressed.connect(_play.bind(CLIPS[i]))
		row.add_child(button)
	var pause := Button.new()
	pause.text = "暂停 / 继续"
	pause.pressed.connect(func():
		paused = not paused
		if paused: player.pause()
		else: player.play())
	row.add_child(pause)

func _play(clip: String) -> void:
	selected = clip
	paused = false
	_frame_clip(clip)
	player.play(clip)
	info.text = "4006 原厂骨架 · " + LABELS[CLIPS.find(clip)]

func _frame_clip(clip: String) -> void:
	var target := Vector3(0, 1, 1.05) if clip == "HitHeavy" else Vector3(0, 0.85, 0)
	camera.position = target + Vector3(2.6, 1.35, -4.6)
	camera.look_at(target)
	camera.size = 3.5 if clip == "HitHeavy" else 2.6

func _check(condition: bool, message: String) -> void:
	print(("PASS " if condition else "FAIL ") + message)
	if not condition: failures.append(message)

func _verify() -> void:
	_check(skeleton != null and player != null, "Skeleton3D and AnimationPlayer exist")
	if skeleton == null or player == null:
		get_tree().quit(1)
		return
	_check(skeleton.get_bone_count() == 50, "50 native bones")
	for name in ["Root", "Hips", "Hand_L", "Hand_R", "Thumb_01", "Finger_01", "IndexFinger_01"]:
		_check(skeleton.find_bone(name) >= 0, "bone " + name)
	var results := {}
	for clip in CLIPS:
		_frame_clip(clip)
		_check(player.has_animation(clip), "clip " + clip)
		if not player.has_animation(clip): continue
		var animation := player.get_animation(clip)
		_check(animation.length > 0.1, clip + " duration")
		_check(absf(animation.length - EXPECTED_SECONDS[clip]) < 0.001, clip + " source/export/Godot duration agree")
		_check((animation.loop_mode == Animation.LOOP_LINEAR) == LOOPS.has(clip), clip + " imported loop mode")
		player.play(clip)
		player.seek(0, true)
		await get_tree().process_frame
		player.pause()
		var before: Array[Quaternion] = []
		for bone in skeleton.get_bone_count(): before.append(skeleton.get_bone_pose_rotation(bone))
		var maximum := 0.0
		var lowest := INF
		var fractions := [0.0, 0.25, 0.5, 0.75, 1.0]
		if clip == "Hit": fractions.insert(1, 1.0/9.0)
		for fraction in fractions:
			player.seek(animation.length * fraction, true)
			await get_tree().process_frame
			for instance in skeleton.get_parent().find_children("*", "MeshInstance3D", true, false):
				lowest = minf(lowest, _skinned_min_y(instance))
			for bone in skeleton.get_bone_count():
				var rotation := skeleton.get_bone_pose_rotation(bone)
				if not rotation.is_finite():
					_check(false, clip + " finite pose")
				maximum = maxf(maximum, rotation.angle_to(before[bone]))
			var capture: bool = fraction in [0.0, 0.5, 1.0] or (clip == "HitHeavy" and fraction == 0.25) or (clip == "Hit" and fraction == 1.0/9.0)
			if DisplayServer.get_name() != "headless" and capture:
				info.text = "4006 · " + clip + " · " + str(fraction)
				await RenderingServer.frame_post_draw
				var directory := ProjectSettings.globalize_path("res://screenshots")
				DirAccess.make_dir_recursive_absolute(directory)
				get_viewport().get_texture().get_image().save_png(directory.path_join(clip + "_" + str(fraction) + ".png"))
		_check(maximum > 0.0001, clip + " actually changes bone rotations")
		_check(lowest >= -0.001, clip + " Godot skinned ground clearance " + str(lowest))
		results[clip] = {"duration": animation.length, "max_bone_rotation_radians": maximum, "loop": animation.loop_mode, "min_mesh_y": lowest}
	var report := {"engine": Engine.get_version_info(), "passed": failures.is_empty(), "failures": failures, "clips": results}
	var file := FileAccess.open("res://godot_validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("GODOT_NATIVE_VALIDATION ", "PASS" if failures.is_empty() else "FAIL")
	get_tree().quit(0 if failures.is_empty() else 1)

func _skinned_min_y(instance: MeshInstance3D) -> float:
	if instance.skin == null: return INF
	var lowest := INF
	var transforms: Array[Transform3D] = []
	for bind_index in instance.skin.get_bind_count():
		var bone := instance.skin.get_bind_bone(bind_index)
		if bone < 0: bone = skeleton.find_bone(instance.skin.get_bind_name(bind_index))
		transforms.append(skeleton.global_transform * skeleton.get_bone_global_pose(bone) * instance.skin.get_bind_pose(bind_index))
	for surface in instance.mesh.get_surface_count():
		var arrays := instance.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var influences := bones.size() / vertices.size()
		for v in vertices.size():
			var point := Vector3.ZERO
			for j in influences:
				var offset := v * influences + j
				point += (transforms[bones[offset]] * vertices[v]) * weights[offset]
			lowest = minf(lowest, point.y)
	return lowest
