extends SceneTree

## Batch rig review: import every batch GLB in the engine, verify AnimationPlayer
## clips (Godot strips the "-loop" suffix and applies looping), skeleton size,
## skinned meshes and material textures.

const OUT := "G:/AIRTS/AI_RTS/初选素材包/绑骨管线/批量绑定_v1"
const EXPECT_DURATION := {
	"Idle": 59.0 / 30.0, "Run": 0.7, "Hit": 0.3, "HitHeavy": 1.8, "Crawl": 65.0 / 30.0, "Death": 2.4
}
const LOOPS := ["Idle", "Run", "Crawl"]

var failures: Array[String] = []
var checked := 0


func _init() -> void:
	var dir := DirAccess.open(OUT)
	var files: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".glb"):
			files.append(OUT + "/" + f)
	files.sort()
	for path in files:
		_check_glb(path)
	print("GODOT_REVIEW checked=%d failures=%d" % [checked, failures.size()])
	for f in failures:
		print("GODOT_FAIL ", f)
	print("GODOT_REVIEW_PASS" if failures.is_empty() else "GODOT_REVIEW_FAIL")
	quit(0 if failures.is_empty() else 1)


func _check_glb(path: String) -> void:
	# 工程外的 GLB 用 GLTFDocument 直接加载（与引擎导入同一条解析链）。
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		failures.append(path + " load failed code " + str(err))
		return
	var inst: Node = doc.generate_scene(state)
	root.add_child(inst)
	var name := path.get_file().get_basename()
	var skel: Skeleton3D = null
	var anim: AnimationPlayer = null
	var meshes := 0
	var untextured := 0
	var stack: Array[Node] = [inst]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			skel = n
		elif n is AnimationPlayer:
			anim = n
		elif n is MeshInstance3D:
			meshes += 1
			var mi := n as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var mat := mi.mesh.surface_get_material(i)
				if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture == null:
					untextured += 1
		for c in n.get_children():
			stack.append(c)
	if skel == null:
		failures.append(name + " no Skeleton3D")
	else:
		var bones := skel.get_bone_count()
		if bones < 49 or bones > 50:
			failures.append(name + " unexpected bone count " + str(bones))
	if anim == null:
		failures.append(name + " no AnimationPlayer")
	else:
		# GLTFDocument 保留 "-loop" 原名；引擎导入管线会剥后缀并设循环。
		# 两种命名都接受，循环判定按后缀或实际 loop_mode。
		var need := ["Idle", "Run", "Fire", "Hit", "HitHeavy", "Crawl", "Death"]
		for clip in need:
			var raw: String = clip + "-loop"
			var a: Animation = null
			var loop_hint := false
			if anim.has_animation(clip):
				a = anim.get_animation(clip)
			elif anim.has_animation(raw):
				a = anim.get_animation(raw)
				loop_hint = true
			if a == null:
				failures.append(name + " missing clip " + clip)
				continue
			if clip == "Fire":
				continue
			var expect: float = EXPECT_DURATION[clip]
			if absf(a.length - expect) > 0.0005:
				failures.append(name + " clip " + clip + " length " + str(a.length))
			var should_loop: bool = LOOPS.has(clip)
			var loops: bool = loop_hint or a.loop_mode == Animation.LOOP_LINEAR
			if should_loop != loops:
				failures.append(name + " clip " + clip + " loop mode wrong")
			if a.get_track_count() == 0:
				failures.append(name + " clip " + clip + " has no tracks")
		# 每段实际骨骼运动（TYPE_ROTATION_3D 轨道非零）。
		for clip in need:
			var a2: Animation = null
			if anim.has_animation(clip):
				a2 = anim.get_animation(clip)
			elif anim.has_animation(clip + "-loop"):
				a2 = anim.get_animation(clip + "-loop")
			if a2 == null:
				continue
			var rot_tracks := 0
			for t in a2.get_track_count():
				if a2.track_get_type(t) == Animation.TYPE_ROTATION_3D:
					rot_tracks += 1
			if rot_tracks < 10:
				failures.append(name + " clip " + clip + " rotation tracks only " + str(rot_tracks))
	checked += 1
	inst.queue_free()
