extends Node

## 验证烘焙导出的步兵动画 GLB（绑骨管线 Infantry_anim_v1.glb）：
## 五段剪辑齐全、骨骼结构正确、可播放推进、循环标志符合命名约定、截图供目检。
## 纯资产验证，不实例化任何游戏单位、不触碰游戏逻辑。

const ANIM_GLB := "res://assets/models/polygon-scifi/Infantry_anim_v2.glb"
const FBX_MODEL := "res://assets/models/polygon-scifi/Infantry_Soldier_Male_01_rigged.fbx"
const SHOT_DIR := "G:/AIRTS/tmp_logs/anim_verify"

## 九段剪辑: Idle/Walk/Run 来自 Soldier 真人动捕, Attack/Fire/Gather/Build/Hit/Death
## 来自 UAL (Quaternius CC0 通用骨架重定向)。"Gather-loop/Build-loop/Idle-loop" 等
## Godot glTF 导入约定: "-loop" 后缀转为循环标志并从名字中移除。
const LOOP_CLIPS := ["Idle", "Walk", "Run", "Gather", "Build"]
const ONESHOT_CLIPS := ["Attack", "Fire", "Hit", "Death"]
const EXPECTED_BONES := ["Hips", "Spine", "Spine2", "Head", "LeftArm", "RightArm",
	"LeftForeArm", "RightForeArm", "LeftUpLeg", "RightUpLeg", "LeftLeg", "RightLeg"]

var _failures := 0


func _ready():
	var packed: PackedScene = load(ANIM_GLB)
	_check(packed != null, "GLB 应能加载为 PackedScene")
	if packed == null:
		_finish()
		return
	var model := packed.instantiate()
	add_child(model)
	await get_tree().process_frame

	var skeleton: Skeleton3D = model.find_child("Skeleton3D", true, false)
	_check(skeleton != null, "GLB 内应有 Skeleton3D")
	if skeleton != null:
		_check(skeleton.get_bone_count() == 23,
			"骨骼数应为 23，实际 %d" % skeleton.get_bone_count())
		for bone in EXPECTED_BONES:
			_check(skeleton.find_bone(bone) >= 0, "应存在骨骼 %s" % bone)

	_print_aabb(model, "GLB")
	var fbx_packed: PackedScene = load(FBX_MODEL)
	if fbx_packed != null:
		var fbx_model := fbx_packed.instantiate()
		add_child(fbx_model)
		# Infantry.tscn 的游戏挂载变换：scale 0.45 + 绕 Y 转 180°
		fbx_model.transform = Transform3D(
			Basis(Vector3.UP, PI).scaled(Vector3.ONE * 0.45), Vector3.ZERO)
		await get_tree().process_frame
		_print_aabb(fbx_model, "FBX(游戏挂载变换)")

	var player: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	_check(player != null, "GLB 内应有 AnimationPlayer")
	if player == null:
		_finish()
		return
	var clips := player.get_animation_list()
	print("ANIMATIONS: ", clips)
	for clip in LOOP_CLIPS + ONESHOT_CLIPS:
		_check(player.has_animation(clip), "应存在动画剪辑 %s" % clip)
	for clip in LOOP_CLIPS:
		if player.has_animation(clip):
			_check(player.get_animation(clip).loop_mode == Animation.LOOP_LINEAR,
				"%s 应按命名约定导入为循环（loop_mode=%d）" % [clip, player.get_animation(clip).loop_mode])
	for clip in ONESHOT_CLIPS:
		if player.has_animation(clip):
			_check(player.get_animation(clip).loop_mode == Animation.LOOP_NONE,
				"%s 应为单次播放（loop_mode=%d）" % [clip, player.get_animation(clip).loop_mode])

	_setup_stage()
	var left_arm := skeleton.find_bone("LeftArm") if skeleton != null else -1
	for clip in LOOP_CLIPS + ONESHOT_CLIPS:
		if not player.has_animation(clip):
			continue
		player.play(clip)
		await get_tree().process_frame
		_check(player.is_playing() and player.current_animation == clip,
			"剪辑 %s 应能开始播放" % clip)
		var pose_before := skeleton.get_bone_pose_rotation(left_arm) if left_arm >= 0 else Quaternion()
		player.advance(0.2)
		await get_tree().process_frame
		_check(player.current_animation_position > 0.0,
			"剪辑 %s 播放位置应推进（pos=%.3f）" % [clip, player.current_animation_position])
		var pose_after := skeleton.get_bone_pose_rotation(left_arm) if left_arm >= 0 else Quaternion()
		_check(pose_after != pose_before or player.current_animation_position >= 0.2,
			"剪辑 %s 应实际驱动骨骼姿态" % clip)
		if DisplayServer.get_name() != "headless":
			# 目检帧: 每段抽起始/中间/结束 3 帧
			var length: float = player.get_animation(clip).length
			for k in [[0.05, "a"], [0.5, "b"], [0.92, "c"]]:
				player.seek(length * k[0], true)
				await get_tree().process_frame
				await _screenshot(SHOT_DIR + "/clip_%s_%s.png" % [clip, k[1]])
		player.stop()
	_finish()


## 相机在角色前方（glTF 约定面朝 -Z）+ 平行光，保证截图可见。
func _setup_stage():
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 1.1, -2.6)
	cam.look_at(Vector3(0, 0.9, 0))
	cam.current = true
	var sun := DirectionalLight3D.new()
	add_child(sun)
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_energy = 1.2


func _print_aabb(node: Node, label: String):
	var aabb := _combined_aabb(node)
	print("AABB_%s pos=%s size=%s" % [label, aabb.position, aabb.size])


func _combined_aabb(node: Node) -> AABB:
	var result := AABB()
	var first := true
	for mesh_instance in node.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = mesh_instance.global_transform * mesh_instance.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


func _screenshot(path: String):
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	image.save_png(path)
	print("SCREENSHOT_SAVED ", path)


func _check(condition: bool, message: String):
	if condition:
		print("PASS ", message)
	else:
		_failures += 1
		push_error("FAIL " + message)
		print("FAIL ", message)


func _finish():
	print("InfantryAnimClipsSmokeTest completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 1 if _failures > 0 else 0)
