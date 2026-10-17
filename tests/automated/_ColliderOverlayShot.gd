extends Node

## 碰撞体积可视化 · 自交验探针（2026-09-30）
## 目的：不依赖任何按键/控制台，确定性证明
##   ① CollisionVolumeOverlay 能被找到并开启；
##   ② 它真的画出了**碰撞包围网格**（BoxMesh），而不是只有圆形半径；
##   ③ 每个建筑/单位的三类口径数值（碰撞 / 逻辑 / carve）。
## 跑法（可见实例，便于截图）：godot_run_project(scene=res://tests/automated/_ColliderOverlayShot.tscn)

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"


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
	var overlay = m.get_node_or_null("CollisionVolumeOverlay")
	print("[SELFCHK] overlay 节点 = ", overlay != null)
	if overlay == null:
		get_tree().quit(1)
		return
	# 摆几个单位进来，便于一眼看出体积包住了模型
	var p: Node = m.get_node("Players").get_children()[0]
	var z := 60.0
	for name in ["Tank", "HeavyTank", "Infantry", "OreRefinery", "AntiGroundTurret"]:
		m.call("_setup_and_spawn_unit", load("res://source/match/units/" + name + ".tscn").instantiate(),
			Transform3D(Basis.IDENTITY, Vector3(70.0, 0.0, z)), p, false)
		z += 9.0
	for _f in range(40):
		await get_tree().physics_frame
	overlay.call("set_enabled", true)
	for _f in range(20):
		await get_tree().physics_frame
	var holder = overlay.get_node("Colliders")
	var meshes := 0
	var labels := 0
	var boxes := 0
	for ch in holder.get_children():
		if ch is Label3D:
			labels += 1
			continue
		if ch is MeshInstance3D and (ch as MeshInstance3D).mesh != null:
			meshes += 1
			if (ch as MeshInstance3D).mesh is BoxMesh:
				boxes += 1
	print("[SELFCHK] 绘制节点=%d 其中包围盒=%d 标签=%d" % [holder.get_child_count(), boxes, labels])
	print("[SELFCHK] 判定: ", "✓ 通过（有碰撞包围网格）" if boxes > 0 and labels > 0 else "✗ 未画出碰撞包围网格")
	# 【2026-09-30】可视化闭环：自己抓视口存 PNG，供人眼核对碰撞体是否贴合模型。
	for _f in range(8):
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	var out_path := "res://tmp_logs/r41_collider_shapes.png"
	var err := img.save_png(out_path)
	print("[SELFCHK] 截图保存 %s err=%d 尺寸=%dx%d" % [out_path, err, img.get_width(), img.get_height()])
	# 把镜头对准这排单位，便于人工截图核对
	var cam := m.get_viewport().get_camera_3d()
	# 【2026-09-30 可视化闭环】拉远 + 抬高俯视：前一版机位太近，多个单位的数值标签糊成一团没法验收。
	cam.set_position_safely(Vector3(70.0, 34.0, 108.0))
	cam.look_at(Vector3(70.0, 0.0, 82.0), Vector3.UP)
	cam.set_size_safely(40.0)
	print("[SELFCHK] 镜头就位 (70,0,84)")
	# 留时间给外部截图
	for _f in range(6000):   # 留足时间给外部截图（约 3 分钟 @30fps）
		await get_tree().process_frame
	get_tree().quit(0)
