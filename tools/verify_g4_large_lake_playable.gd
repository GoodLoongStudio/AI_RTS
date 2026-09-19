extends SceneTree

## G4 256 大湖进局可玩冒烟。
## 用法：godot --headless --path . --script res://tools/verify_g4_large_lake_playable.gd

const MAP_ID := "16-0-1ca6e21aa1"
const MAP_PATH := "res://source/match/maps/generated/16-0-1ca6e21aa1/map_16-0-1ca6e21aa1.tscn"
const HEIGHT_PATH := "res://source/match/maps/generated/16-0-1ca6e21aa1/height_data.bin"
const MASK_PATH := "res://source/match/maps/generated/16-0-1ca6e21aa1/terrain_masks.png"
const PREVIEW_PATH := "res://assets/map_previews/map_16-0-1ca6e21aa1.png"
const SPAWN := Vector3(58.22, 0.0, 179.48)
const OLD_512_DIR := "res://source/match/maps/generated/16-0-7d337ce8be"

var _failures := 0


func _initialize() -> void:
	await _run()
	if _failures > 0:
		push_error("FAIL: g4 large lake playable, %d failure(s)" % _failures)
		quit(1)
	else:
		print("PASS: g4 large lake playable")
		quit(0)


func _check(cond: bool, message: String) -> void:
	if cond:
		print("  OK  ", message)
	else:
		_failures += 1
		push_error("  FAIL  " + message)


func _run() -> void:
	_check_source_files()
	_check_height_bin()
	await _check_runtime_map()
	_check_scripts()


func _check_source_files() -> void:
	_check(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OLD_512_DIR)),
		"512 旧包目录已删除")
	_check(FileAccess.file_exists(HEIGHT_PATH), "height_data.bin 在工程里")
	_check(FileAccess.file_exists(MASK_PATH), "terrain_masks.png 在工程里")
	if ResourceLoader.exists(PREVIEW_PATH) or FileAccess.file_exists(PREVIEW_PATH):
		_check(true, "大厅预览图存在")
	else:
		print("  SKIP 大厅预览图（不影响进局）")
	var abs_height := ProjectSettings.globalize_path(HEIGHT_PATH)
	_check(FileAccess.file_exists(abs_height), "height_data.bin 可 globalize")
	var mask_img := Image.load_from_file(ProjectSettings.globalize_path(MASK_PATH))
	_check(mask_img != null and not mask_img.is_empty(), "掩码可用绝对路径读取")


func _check_height_bin() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(HEIGHT_PATH), FileAccess.READ)
	_check(f != null, "高度场文件可打开")
	if f == null:
		return
	var w := f.get_32()
	var h := f.get_32()
	_check(w == h and w >= 129 and w <= 513, "高度场是 256 图尺度（%dx%d）" % [w, h])
	_check(w != 1025, "高度场不是旧 512 图的 1025²")
	var payload := f.get_buffer((w * h) * 4)
	f.close()
	_check(payload.size() == w * h * 4, "高度场字节数匹配")


func _check_runtime_map() -> void:
	var packed: PackedScene = load(MAP_PATH)
	_check(packed != null, "地图场景可加载")
	if packed == null:
		return
	var map_node: Node = packed.instantiate()
	root.add_child(map_node)
	for _i in range(3):
		await process_frame
	_check(map_node.get("size") == Vector2(256, 256), "map.size 是 256×256")
	var terrain := map_node.find_child("Terrain", true, false) as MeshInstance3D
	_check(terrain != null, "Terrain 节点存在")
	if terrain != null:
		_check(is_equal_approx(float(terrain.get("semantic_span")), 256.0), "semantic_span=256")
		_check(terrain.mesh is ArrayMesh, "Terrain 已建成 ArrayMesh（不是 54m 默认平面）")
		if terrain.mesh is ArrayMesh and terrain.mesh.get_surface_count() > 0:
			var arrays: Array = terrain.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			_check(verts.size() >= 200000, "513 高度场不再抽成 257（%d 顶点）" % verts.size())
			var ymin := 1.0e9
			var ymax := -1.0e9
			for v in verts:
				ymin = minf(ymin, v.y)
				ymax = maxf(ymax, v.y)
			_check(ymax - ymin > 2.0, "高度场有起伏（%.2f .. %.2f）" % [ymin, ymax])
		var mat := terrain.material_override as ShaderMaterial
		_check(mat != null, "地形已换共享 shader")
		if mat != null:
			_check(is_equal_approx(float(mat.get_shader_parameter("mask_from_tex")), 1.0), "mask_from_tex=1")
	var water_body := map_node.get_node_or_null("WaterBody")
	var water_left := water_body.get_child_count() if water_body != null else 0
	_check(water_left == 0, "半透明水面片已从树上删掉（剩余 %d）" % water_left)
	var collision := map_node.get_node_or_null("Collision")
	var collision_left := collision.get_child_count() if collision != null else 0
	_check(collision_left == 0, "作者静态碰撞已从树上删掉（剩余 %d）" % collision_left)
	if terrain != null and terrain.has_method("is_water_blocked"):
		_check(not bool(terrain.call("is_water_blocked", SPAWN)), "出生点不是水域")
		var spawn_h := float(terrain.call("sample_height", SPAWN.x, SPAWN.z))
		_check(spawn_h > 0.2, "出生点高度来自高度场（%.2f）" % spawn_h)
		var water_hit := Vector3.INF
		var x := 8.0
		while x < 256.0 and water_hit == Vector3.INF:
			var z := 8.0
			while z < 256.0:
				var sample := Vector3(x, 0.0, z)
				if bool(terrain.call("is_water_blocked", sample)):
					water_hit = sample
					break
				z += 16.0
			x += 16.0
		_check(water_hit != Vector3.INF, "图上仍有禁行水域")
		if water_hit != Vector3.INF:
			var clamped: Vector3 = terrain.call("clamp_ground_move", SPAWN, water_hit)
			_check(
				not bool(terrain.call("is_water_blocked", clamped)),
				"穿湖落点被钳到岸上（%s）" % str(clamped)
			)
		var enemy := Vector3(84.22, 0.0, 54.60)
		_check(terrain.has_method("find_ground_path"), "地形提供占用格寻路")
		_check(terrain.has_method("unstick_ground"), "地形提供脱位")
		_check(terrain.has_method("clamp_ground_destination"), "目标钳制不再沿直线截岸")
		if terrain.has_method("find_ground_path"):
			var dest: Vector3 = terrain.call("clamp_ground_destination", enemy)
			_check(not bool(terrain.call("is_ground_blocked", dest)), "P1 落点在陆上")
			var path: PackedVector3Array = terrain.call("find_ground_path", SPAWN, dest)
			_check(path.size() >= 2, "台地到对岸有绕行航点（%d）" % path.size())
			var water_crossings := 0
			var last := SPAWN
			var path_len := 0.0
			var max_dev := 0.0
			var straight_xz := Vector2(dest.x - SPAWN.x, dest.z - SPAWN.z)
			var straight := straight_xz.length()
			for point in path:
				path_len += Vector2(last.x, last.z).distance_to(Vector2(point.x, point.z))
				if bool(terrain.call("is_ground_blocked", point)):
					water_crossings += 1
				var t := 0.0
				if straight > 0.001:
					t = clampf(
						((point.x - SPAWN.x) * straight_xz.x + (point.z - SPAWN.z) * straight_xz.y)
						/ (straight * straight),
						0.0,
						1.0
					)
				var proj := Vector2(SPAWN.x, SPAWN.z) + straight_xz * t
				max_dev = maxf(max_dev, proj.distance_to(Vector2(point.x, point.z)))
				last = point
			_check(water_crossings == 0, "航点不落在水/崖里")
			_check(max_dev > 6.0, "绕开直线穿湖（偏航 %.1fm）" % max_dev)
			print(
				"  PATH  waypoints=", path.size(),
				" length=", snappedf(path_len, 0.1),
				" straight=", snappedf(straight, 0.1),
				" deviate=", snappedf(max_dev, 0.1)
			)
		var valley := Vector3(70.76, -1.75, 106.92)
		if terrain.has_method("unstick_ground"):
			var land: Vector3 = terrain.call("unstick_ground", valley, 0)
			_check(not bool(terrain.call("is_ground_blocked", land)), "河谷脱位到陆地（%s）" % str(land))
			_check(
				Vector2(land.x, land.z).distance_to(Vector2(valley.x, valley.z)) > 1.0,
				"河谷脱位离开原格（%.1fm）" % Vector2(land.x, land.z).distance_to(Vector2(valley.x, valley.z))
			)
		var deck_at := Vector3(93.997, 0.0, 78.736)
		var river_h := float(terrain.call("sample_height", deck_at.x, deck_at.z))
		var stand: Vector3 = terrain.call("project_ground", deck_at)
		_check(
			stand.y > 1.15 and stand.y < 1.55,
			"桥心站立是桥面（y=%.2f，河床=%.2f）" % [stand.y, river_h]
		)
		_check(stand.y > river_h + 0.4, "桥面明显高于河床")
		var walkb := map_node.find_child("WalkB1_3", true, false) as StaticBody3D
		_check(walkb != null, "Bridge1 主跨 WalkB 存在")
		if walkb != null:
			_check(walkb.collision_layer != 0, "桥面碰撞层保留（%d）" % walkb.collision_layer)
			var cs := walkb.get_node_or_null("CollisionShape3D") as CollisionShape3D
			_check(
				cs != null and cs.shape != null and not cs.disabled,
				"桥面碰撞盒未拆"
			)
		var rail := map_node.find_child("RailC1_0", true, false) as StaticBody3D
		_check(rail != null, "护栏碰撞体存在")
		if rail != null:
			_check(rail.collision_layer != 0, "护栏碰撞层保留（%d）" % rail.collision_layer)
			var rcs := rail.get_node_or_null("CollisionShape3D") as CollisionShape3D
			_check(rcs != null and rcs.shape != null and not rcs.disabled, "护栏碰撞盒未拆")
	else:
		_check(false, "地形提供 is_water_blocked")
	map_node.queue_free()
	await process_frame


func _check_scripts() -> void:
	var match_src := FileAccess.get_file_as_string("res://source/match/Match.gd")
	_check(match_src.contains("_lock_large_map_before_first_frame"), "Match 进树锁雾")
	_check(not match_src.contains("_is_oversized_generated_map"), "不再保留 512 专用迷雾分支")
	var constants_src := FileAccess.get_file_as_string("res://source/match/MatchConstants.gd")
	_check(constants_src.contains("16-0-1ca6e21aa1"), "菜单挂 256 大湖")
	_check(not constants_src.contains("7d337ce8be"), "菜单不再挂 512 旧包")
	var terrain_src := FileAccess.get_file_as_string(
		"res://source/match/maps/generated/GeneratedTerrain.gd"
	)
	_check(terrain_src.contains("_purge_large_map_authoring_nodes"), "GeneratedTerrain 删除作者碰撞/水面")
	_check(terrain_src.contains("is_water_blocked"), "GeneratedTerrain 水域逻辑禁行")
	_check(terrain_src.contains("sample_height"), "GeneratedTerrain 高度采样不走物理")
	_check(match_src.contains("disable_runtime_collision"), "Match 生成图不建地形 trimesh")
	_check(match_src.contains("physics_ticks_per_second = 20"), "Match 大地图物理降到 20Hz")
	_check(terrain_src.contains("_absolute_data_path"), "GeneratedTerrain 绝对路径读盘")
	var minimap_src := FileAccess.get_file_as_string("res://source/match/hud/Minimap.gd")
	_check(minimap_src.contains("_show_static_preview_now"), "小地图静态预览")
	_check(minimap_src.contains("_ensure_hud_fog_mask"), "小地图迷雾遮罩挂在 HUD 而不是子视口")
	# 2026-09-15 用户实测"大湖的小地图战争迷雾不更新"：旧实现每次同步都把
	# CombinedViewport 拷成 ImageTexture 快照，而同步只在开局那几次发生 ⇒ 迷雾定格。
	# 现在必须绑实时视口纹理；像素级正反两面验收见 tools/verify_minimap_fog_live.tscn。
	_check(minimap_src.contains("_fog_live_bound"), "小地图迷雾遮罩绑实时纹理（防再次定格成快照）")
	_check(minimap_src.contains("_follow_minimap_fog_mask"), "开局按节拍重试绑定迷雾纹理")
	var minimap_fog_src := FileAccess.get_file_as_string(
		"res://source/shaders/2d/white_transparent.gdshader"
	)
	_check(minimap_fog_src.contains("unexplored_alpha"), "小地图未开雾半透明，底图仍可见")
	_check(terrain_src.contains(">= 1025"), "513 高度场不再二次抽稀")
	var main_src := FileAccess.get_file_as_string("res://source/Main.gd")
	_check(main_src.contains("--no-fog"), "评图默认开战争迷雾")
	var shader_src := FileAccess.get_file_as_string(
		"res://source/match/maps/generated/showcase_land.gdshader"
	)
	_check(shader_src.contains("masks_live"), "地形 shader 高度兜底")
	var nav_src := FileAccess.get_file_as_string("res://source/match/Navigation.gd")
	_check(nav_src.contains("should_skip_runtime_navigation"), "大图跳过运行时导航")
	_check(nav_src.contains("skip static obstacles"), "大图不再挂整图避障")
	var move_src := FileAccess.get_file_as_string("res://source/match/units/traits/Movement.gd")
	_check(move_src.contains("_skip_navigation_server"), "移动可脱离 NavigationServer")
	_check(move_src.contains("set_physics_process_internal(false)"), "空网格上关掉代理内部物理")
	_check(move_src.contains("_committed_target != null"), "是否在走只看逻辑目标")
	_check(move_src.contains("_request_logic_path"), "大图走占用格航点而不是直线")
	_check(move_src.contains("_logic_unstick_if_blocked"), "大图卡住会脱位")
	_check(terrain_src.contains("find_ground_path"), "占用格 A* 绕水/崖")
	_check(terrain_src.contains("unstick_ground"), "占用格提供脱位")
	_check(terrain_src.contains("walk_physics=on"), "进局保留桥面碰撞")
	_check(terrain_src.contains("_sample_bridge_deck"), "过桥站立用板顶而不是河床")
	_check(terrain_src.contains("_is_bridge_physics_body"), "清物理时跳过桥和护栏")
	var place_src := FileAccess.get_file_as_string(
		"res://source/match/utils/UnitPlacementUtils.gd"
	)
	_check(place_src.contains("is_ground_blocked"), "大图出兵落点走禁行格而不是空导航")
	var sidebar_src := FileAccess.get_file_as_string(
		"res://source/match/hud/ra3/Ra3Sidebar.gd"
	)
	_check(sidebar_src.contains("item.get(\"place\", false)"), "侧栏建筑页不再误读 producer")
	var fog_src := FileAccess.get_file_as_string("res://source/match/FogOfWar.gd")
	_check(fog_src.contains("_paint_fog_viewports"), "迷雾视口按开雾节拍重绘")
	_check(fog_src.contains("func refresh_now"), "进局立即刷视野圈")
	_check(match_src.contains("directional_shadow_max_distance = 80"), "大图保留近距阴影")
	_check(match_src.contains("shadow_bias = 0.04"), "大图阴影 bias 能打出接触影")
	_check(match_src.contains("ssao_enabled = false"), "大图关掉 SSAO 以免沙地条纹")
	_check(terrain_src.contains("performance_mode\", false"), "256 地形不用平涂性能档")
	_check(not terrain_src.contains("world_scale / 3.90625"), "地形 shader 尺度按世界米")
	_check(terrain_src.contains("dense_sand_diff.jpg"), "近景沙地用有颗粒的贴图")
	var land_src := FileAccess.get_file_as_string(
		"res://source/match/maps/generated/showcase_land.gdshader"
	)
	_check(land_src.contains("water_col"), "细致地形把湖色画回去")
	_check(land_src.contains("sample_tiled"), "地面贴图按世界米双 UV 采样")
	var atlas_src := FileAccess.get_file_as_string(
		"res://source/match/maps/generated/ApplyAtlas.gd"
	)
	_check(atlas_src.contains("TEXTURE_FILTER_LINEAR_WITH_MIPMAPS"), "地图装饰图集开 mipmap 过滤")
	var sand_import := FileAccess.get_file_as_string(
		"res://assets/terrain_pbr/dense_sand_diff.jpg.import"
	)
	_check(sand_import.contains("mipmaps/generate=true"), "沙地贴图按 3D 生成 mipmap")
	var tint_src := FileAccess.get_file_as_string("res://source/shaders/3d/team_tint.gdshader")
	_check(tint_src.contains("SPECULAR = 0.55"), "阵营着色保留高光而不是纯色塑料")
	var defense_src := FileAccess.get_file_as_string(
		"res://source/match/players/simple-clairvoyant-ai/DefenseController.gd"
	)
	_check(defense_src.contains("MAX_PLACEMENT_PROBES"), "规则 AI 放置探测有上限")
	var project_src := FileAccess.get_file_as_string("res://project.godot")
	_check(
		not project_src.contains("run_on_separate_thread=true"),
		"没有打开物理分线程"
	)
