extends Node3D

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Player = preload("res://source/match/players/Player.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const AICommandHUD = preload("res://source/match/hud/AICommandHUD.gd")
const TraditionalUnitCommandHUD = preload(
	"res://source/match/hud/TraditionalUnitCommandHUD.tscn"
)
const Ra3Sidebar = preload("res://source/match/hud/ra3/Ra3Sidebar.gd")
const SelectionPortraitPanel = preload("res://source/match/hud/ra3/SelectionPortraitPanel.gd")
const CommandCursor = preload("res://source/match/hud/CommandCursor.gd")
const MusicDirector = preload("res://source/match/MusicDirector.gd")
const MatchPauseGateScript = preload("res://source/match/augments/MatchPauseGate.gd")
const AugmentRuntimeScript = preload("res://source/match/augments/AugmentRuntime.gd")
const AiPerfStats = preload("res://source/match/players/simple-clairvoyant-ai/AiPerfStats.gd")

const CommandCenter = preload("res://source/match/units/CommandCenter.tscn")
# 矿车（原"工人"）不再由开局链路生成（车厂生产/矿场赠送），无需在此预载。
const VehicleFactory = preload("res://source/match/units/VehicleFactory.tscn")
const Barracks = preload("res://source/match/units/Barracks.tscn")
const Drone = preload("res://source/match/units/Drone.tscn")

@export var settings: Resource = null

var _ra3_sidebar = null  # 红警3 风格右侧指挥侧栏（非 headless 对局内挂载）
## 传统命令面板实例（RA3 布局下被侧栏 absorb_command_panel 收编，不再是 HUD 直接子节点）。
var _traditional_unit_command_hud: Control = null
var _unit_spawn_counter := 0  # P0-1 init unit deterministic naming
var _mov_diag_script = null
## 整张地形碰撞同一高度时，贴地不再每单位每步打射线。只在和一次真射线一致后启用。
var _flat_ground_state := -1
var _flat_ground_y := 0.0
var map:
	set = _set_map,
	get = _get_map
var visible_player = null:
	set = _set_visible_player
var visible_players = null:
	set = _ignore,
	get = _get_visible_players

@onready var navigation = $Navigation
@onready var fog_of_war = $FogOfWar

@onready var _camera = $IsometricCamera3D
@onready var _players = $Players
@onready var _terrain = $Terrain
@onready var _input_runtime = $InputBindingRuntime
@onready var _query_runtime = $WorldQueryRuntime
@onready var _control_group_runtime = $Handlers/UnitGroupSelectionHandler
@onready var _match_outcome_runtime = $MatchOutcomeRuntime
@onready var _battlefield_event_runtime = $BattlefieldEventRuntime
@onready var _simulation_clock = $SimulationClock

## 大地图进局前的物理追帧上限。默认 8 步：一步 60ms 时会追满 8 步 ≈ 500ms → 2 FPS。
var _prev_max_physics_steps := 8
var _prev_physics_ticks := 60
var _prev_physics_interpolation := true
## 最近一次物理帧里，从本节点到 SceneTree.physics_frame 之间的脚本耗时（毫秒）。
## 用来拆开 TIME_PHYSICS_PROCESS：引擎物理服务器 vs 节点 _physics_process。
var last_physics_script_ms := 0.0
var _physics_script_t0_us := 0
var _physics_script_armed := false
## 空间网格索敌索引（2026-09-26 优化）：`WaitingForTargets` 的候选筛选源。
var _target_grid = null


## 返回当前战局模拟毫秒；树暂停时不会继续增加。
func get_simulation_msec() -> int:
	return _simulation_clock.get_msec()


## 战局执行（单位、战斗、AI、任务时间）是否因暂停而冻结。
func is_simulation_paused() -> bool:
	return get_tree().paused


func _enter_tree():
	assert(settings != null, "match cannot start without settings, see examples in tests/manual/")
	assert(map != null, "match cannot start without map, see examples in tests/manual/")
	# 父节点 _enter_tree 早于子节点 _ready。大地图必须在第一帧绘制前关掉
	# 全屏高度雾片，否则卡住时玩家看到的就是那张肉色雾片。
	# 256 图战争迷雾走 512² 视口，这里不能拆 CombinedViewport。
	_lock_large_map_before_first_frame()
	if _is_large_generated_map():
		process_physics_priority = -100000
		set_physics_process(true)
		var tree := get_tree()
		if tree != null and not tree.physics_frame.is_connected(_on_large_map_physics_frame):
			tree.physics_frame.connect(_on_large_map_physics_frame)


func _lock_large_map_before_first_frame() -> void:
	if not _is_large_generated_map():
		return
	# 物理一步若超过 16ms，默认最多追 8 步。大地图作者碰撞还在时会锁死在 2 FPS。
	# 逻辑地形不再需要 60Hz 物理：一步脚本+空世界就够，追帧只会把 8FPS 再打穿。
	_prev_max_physics_steps = Engine.max_physics_steps_per_frame
	_prev_physics_ticks = Engine.physics_ticks_per_second
	Engine.max_physics_steps_per_frame = 1
	Engine.physics_ticks_per_second = 20
	var tree := get_tree()
	if tree != null:
		_prev_physics_interpolation = tree.physics_interpolation
		tree.physics_interpolation = false
		print("G4PERF physics_interpolation=", tree.physics_interpolation)
	_strip_height_fog_mesh()


func _ready():
	# 配置是 Match 的硬前置条件。配置加载失败时必须停在加载页，绝不能让
	# 空成本/空单位字典继续创建一个看似可玩的僵尸房。
	var balance_runtime := get_node_or_null("BalanceConfigRuntime")
	if balance_runtime == null:
		_fail_match_initialization("缺少 BalanceConfigRuntime，无法验证平衡配置")
		return
	if not balance_runtime.has_method("IsHealthy") or not balance_runtime.IsHealthy():
		var config_error := str(balance_runtime.get_meta(
			"initialization_error", "平衡配置初始化失败"))
		if balance_runtime.has_method("GetInitializationError"):
			config_error = str(balance_runtime.GetInitializationError())
		_fail_match_initialization(config_error)
		return
	add_to_group("match_root")
	_ensure_match_augments()
	_ensure_target_acquisition_grid()
	if NetSession.is_networked():
		# 防御：联机模式下加载 NetSync。在 C# 项目编译后环境下
		# preload(...).new() 会触发 “Nonexistent function 'new' in base 'GDScript'”，
		# 让 _ready 在第 63 行就崩断后续迷雾/相机/HUD 初始化，表现为联机黑屏。
		# 用 load() 取脚本再用 Callable 安全构造，且不抛错中断 _ready。
		var net_sync_script: Script = load("res://source/net/NetSync.gd") as Script
		if net_sync_script != null:
			var net_sync: Node = net_sync_script.new()
			net_sync.name = "NetSync"
			add_child(net_sync)
		else:
			push_warning("联机对局 NetSync 脚本加载失败，联机同步链路不可用")
	MatchSignals.setup_and_spawn_unit.connect(_setup_and_spawn_unit)
	# 同类建筑加速出兵（2026-09-29 用户规则）：事件驱动重算各玩家各类型的
	# production_work_per_tick 合成值；比例取自 balance，0 = 规则关闭。
	SameTypeProductionRate.install(self)
	await _setup_subsystems_dependent_on_map()
	_setup_players()
	_setup_player_units()
	_control_group_runtime.Configure(get_local_player())
	# 胜负判定**只在权威端**跑（单机 / 本机房主 / 专用服）。
	# 客户端不许做判定：迷雾下客户端看不到敌方单位，`LastSurvivingSideRule` 会把
	# "看不到"误当成"敌方全灭" → 开局没多久就判自己胜利、还经 `_rpc_match_over`
	# 上报给服务器，服务器照单广播并 5 秒后回收专用服
	#（2026-09-15 实测：副官 vs 电脑整局在 ~19 秒被判"胜利"收场，根本打不起来）。
	if FeatureFlags.handle_match_end and (not NetSession.is_networked() or NetSession.is_server()):
		_match_outcome_runtime.Initialize(_players, get_local_player())
	var players_in_group = get_tree().get_nodes_in_group("players")
	var visible_index = settings.visible_player
	if settings.local_player_index >= 0:
		visible_index = settings.local_player_index
	visible_player = players_in_group[visible_index]
	_query_runtime.Initialize(_players, get_local_player())
	_register_spawn_points_with_query_runtime()
	_battlefield_event_runtime.Initialize(get_local_player())
	_camera.force_opening_isometric()
	var visual_cull := preload("res://source/match/OffscreenVisualCull.gd").new()
	visual_cull.name = "OffscreenVisualCull"
	add_child(visual_cull)
	if fog_of_war != null and fog_of_war.has_method("refresh_now"):
		fog_of_war.refresh_now()
	_move_camera_to_initial_position()
	if _is_large_generated_map():
		_apply_large_map_playable_presentation()
	if settings.visibility == settings.Visibility.FULL:
		_disable_war_fog()
	call_deferred("_move_camera_to_initial_position")
	if not _is_dedicated_or_headless():
		_setup_ra3_sidebar()
		_setup_selection_portrait_panel()
		_setup_command_cursor()
		# 对局背景音乐恢复启用（2026-09-26 用户交付对局双曲《正常》《激情》并要求
		# "把游戏里的音乐换成这 3 个"）：导演在 Music 总线轮播，进对局起播、
		# 收局随 Match 释放。此前按产品要求关闭（_setup_music_director 无人调用）。
		# headless / 专用服不挂：Dummy 音频驱动 + 播放中的流在退出时有泄漏风险
		# （同 MenuMusic 的 headless 跳过理由），也没有听感需求。
		_setup_music_director()
		# 2026-09-14 用户要求"两种模式的副官 UI 必须一致"：这里去掉了历史上的
		# `if not NetSession.is_networked()` —— 那行是 2026-08-29 "联机 Demo 架构落地"
		# 时加的，副作用是**单机（本机开房，is_networked()==true）也不挂"岚"面板**，
		# 于是玩家在单机里只看得到旧的四行面板、在联机里才看得到"岚"，两套 UI 打架。
		# 面板挂载后默认隐藏（`set_interface_visible(false)`），玩家用 Tab /
		# 侧栏"显示 AI 副官"按钮开合，不会抢占原有 HUD 的位置。
		_setup_ai_command_hud()
		_setup_traditional_unit_command_hud()
		if get_meta("hold_hud_until_loading", false):
			$HUD.visible = false
			if has_node("UI"):
				$UI.visible = false
	else:
		$HUD.visible = false
	MatchSignals.match_started.emit()


func _fail_match_initialization(message: String) -> void:
	set_meta("match_initialization_failed", true)
	set_meta("match_initialization_error", message)
	process_mode = Node.PROCESS_MODE_DISABLED
	push_error("Match 初始化失败，拒绝进入对局：%s" % message)


## 对局背景音乐导演：和平曲 ↔ 战斗曲（受击刷新战斗状态，2s 交叉淡化）。
func _setup_music_director():
	var director = MusicDirector.new()
	director.name = "MusicDirector"
	add_child(director)


func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if _input_runtime.IsModifierPressed("Shift"):
			return
		MatchSignals.deselect_all_units.emit()


func _setup_ai_command_hud():
	if get_local_player() == null:
		return
	var ai_command_hud = AICommandHUD.new()
	ai_command_hud.name = "AICommandHUD"
	$HUD.add_child(ai_command_hud)
	var apply_visibility: Callable = _setup_ai_command_hud_toggle(ai_command_hud)
	# 【2026-09-14 用户要求：副官 UI 常驻】面板创建即显示。切换按钮/Tab 只控制副官 UI
	# 自身的显示/隐藏，**不再**与 RA3 侧栏、传统命令栏互斥（互斥会让玩家"打开副官就
	# 看不到侧栏"，实际效果是两套 HUD 打架）。
	apply_visibility.call(true)


func _setup_ai_command_hud_toggle(ai_command_hud: Control) -> Callable:
	var toggle_button := Button.new()
	toggle_button.name = "AICommandHUDToggle"
	toggle_button.text = "隐藏 AI 副官"
	toggle_button.tooltip_text = "Tab：显示 / 隐藏 AI 副官面板（副官 UI 常驻，不再与传统 HUD 互斥）"
	toggle_button.custom_minimum_size = Vector2(168, 40)
	toggle_button.mouse_filter = Control.MOUSE_FILTER_STOP
	var apply_visibility := func(should_show: bool):
		ai_command_hud.set_interface_visible(should_show)
		toggle_button.text = "隐藏 AI 副官" if should_show else "显示 AI 副官"
		# 【2026-09-14 常驻改造】原来这里把传统命令栏与 RA3 侧栏按 `not should_show`
		# 隐藏（两套 HUD 互斥）。用户要求副官 UI 常驻 ⇒ 不再隐藏它们，只做一件事：
		# 显示副官面板时取消进行中的指挥指定模式，避免维修/出售光标挂在副官面板上。
		# （必须用挂载时保存的引用：RA3 布局下命令面板被侧栏收编，
		#  `$HUD.get_node_or_null("TraditionalUnitCommandHUD")` 恒为 null。）
		var command_hud: Control = _traditional_unit_command_hud
		if command_hud == null:
			command_hud = $HUD.get_node_or_null("TraditionalUnitCommandHUD")
		if should_show and command_hud != null and command_hud.actions_controller != null:
			command_hud.actions_controller.cancel_command_targeting()
	toggle_button.pressed.connect(
		func(): apply_visibility.call(not ai_command_hud.is_interface_visible())
	)
	_input_runtime.connect(
		"ActionPressed",
		func(action_id: String):
			if action_id != "global.toggle_ai_hud":
				return
			apply_visibility.call(not ai_command_hud.is_interface_visible())
	)
	# 挂载位：优先 RA3 侧栏功能行；侧栏缺席时退回左上列（兼容旧布局）。
	if _ra3_sidebar != null:
		_ra3_sidebar.add_function_button(toggle_button)
	else:
		$HUD/TopLeftColumn.add_child(toggle_button)
	return apply_visibility


## 红警3 风格右侧指挥侧栏：收编小地图与资金显示；原左上资源列、右下生产格退场。
func _setup_ra3_sidebar():
	var sidebar = Ra3Sidebar.new()
	sidebar.name = "Ra3Sidebar"
	$HUD.add_child(sidebar)
	_ra3_sidebar = sidebar
	var minimap_wrapper = $HUD.get_node_or_null("MarginContainer")
	if minimap_wrapper != null:
		var minimap = minimap_wrapper.get_node_or_null("Minimap")
		if minimap != null:
			minimap_wrapper.remove_child(minimap)
			sidebar.absorb_minimap(minimap)
		minimap_wrapper.visible = false
	var legacy_corner = $HUD.get_node_or_null("MarginContainer3")
	if legacy_corner != null:
		legacy_corner.visible = false
	var top_left_column = $HUD.get_node_or_null("TopLeftColumn")
	if top_left_column != null:
		top_left_column.visible = false
	var minimap_node = find_child("Minimap", true, false)
	if minimap_node != null and minimap_node.has_method("_sync_minimap_fog_mask"):
		minimap_node.call_deferred("_sync_minimap_fog_mask")


## 红警3 式左侧选中单位头像栏：框选后逐个显示头像，点击头像单独选中该单位。
func _setup_selection_portrait_panel():
	var panel = SelectionPortraitPanel.new()
	panel.name = "SelectionPortraitPanel"
	$HUD.add_child(panel)


## 红警式命令光标（2026-09-14）：维修/出售等指定模式下把系统光标换成对应图标。
func _setup_command_cursor():
	var cursor = CommandCursor.new()
	cursor.name = "CommandCursor"
	$HUD.add_child(cursor)


func _setup_traditional_unit_command_hud():
	var human_player = get_local_player()
	if human_player == null:
		return
	var command_hud = TraditionalUnitCommandHUD.instantiate()
	# 联机（客户端-服务器）下本地玩家身上**可能没有** UnitActionsController
	# （只有权威端的 Human 才有，客户端是画面端）——此前这里硬 get_node，
	# 取不到就刷 `ERROR: Node not found` 并把 null 塞给面板，面板 _ready 里的
	# assert 随即中断整个初始化（皮肤/框、按钮信号、可用性刷新全不执行）。
	# 2026-09-12 实测：客户端面板"没框"、按钮看着能点却全无反应，就是这个原因。
	command_hud.actions_controller = human_player.get_node_or_null("UnitActionsController")
	# RA3 布局：命令面板收编进右侧指挥侧栏的下部命令区（无侧栏时退回自由挂载）。
	if _ra3_sidebar != null:
		_ra3_sidebar.absorb_command_panel(command_hud)
	else:
		$HUD.add_child(command_hud)
	_traditional_unit_command_hud = command_hud


func _set_map(a_map):
	assert(get_node_or_null("Map") == null, "map already set")
	a_map.name = "Map"
	add_child(a_map)
	a_map.owner = self


func _ignore(_value):
	pass


func _get_map():
	return get_node_or_null("Map")


func _set_visible_player(player):
	_conceal_player_units(visible_player)
	_reveal_player_units(player)
	visible_player = player


func _get_visible_players():
	if settings.visibility == settings.Visibility.PER_PLAYER:
		return [visible_player]
	return get_tree().get_nodes_in_group("players")


func _setup_subsystems_dependent_on_map():
	var map_terrain := map.find_child("Terrain") as MeshInstance3D
	assert(map_terrain != null and map_terrain.mesh != null, "map must provide a Terrain MeshInstance3D")
	# G4 large maps intentionally skip runtime navigation baking. Their visual
	# height mesh is 1025x1025; building a Bullet trimesh from it costs tens of
	# milliseconds per physics frame. Units use collision_mask=0 and Terrain's
	# input handler has a ray-plane fallback, so omit this collider on large maps.
	if _uses_logic_terrain() or map.size.x >= 256.0 or map.size.y >= 256.0:
		# 【2026-09-15 用户反复报"单位浮空" + 副官"控制频率极低"】这里原为
		# `_terrain.disable_runtime_collision()`，它把 Terrain 从 `terrain_navigation_input`
		# 组里摘掉、也不给地形建碰撞。后果两条：
		#   ① 导航烘焙输入为空 → navmesh 查不到任何多边形（实测 air/terrain 两域
		#      都返回 navmesh_unavailable）⇒ 副官的安全移动闸门把所有计划判成 wait；
		#   ② 地形没有物理面 ⇒ `ground_height_at()` 的射线永远打空，只能靠高度场采样兜底，
		#      旧版 `Collision/Solid*/Walk*` 台阶盒板（4×4m 方盒）会重新参与导航收集，
		#      两套面"取较高面" ⇒ 单位站盒顶、玩家看到盒下真地形 = 悬空
		#      （实测盒顶比真地形高 p50 +0.62m，与线上实测的 +0.6m 一致）。
		# 改为与普通地图同款：`update_shape` 内部对 side>256 自动 stride=16 降采样
		# （1025² → 约 4K 顶点，代价小）；真正的性能真凶是那几百个作者碰撞块，
		# 由紧随其后的 `_purge_large_map_authoring_nodes()` 清掉（保留）。
		_terrain.update_shape(map_terrain.mesh)
		_terrain.scale = map.scale
		_terrain.collision_layer = 2
		_terrain.add_to_group("terrain_navigation_input")
		_purge_large_map_authoring_nodes()
	else:
		_terrain.update_shape(map_terrain.mesh)
		# 地图网格顶点写在**语义域**里，由 Map 基座的 scale=world_scale 放大成世界米；
		# 而本 Terrain 碰撞体挂在 Match 根下（无缩放），所以必须补回同一缩放，
		# 否则碰撞/导航比可视地形小 world_scale 倍（地图 4 倍时碰撞只有 1/4 范围，
		# 表现为地形与导航脱节）。2026-09-14 与 GeneratedTerrain 的 2 倍顶点间距
		# bug 一并修正。
		_terrain.scale = map.scale
		# Runtime navmesh baking should consume the terrain collider rather than reading
		# the visual MeshInstance3D back from the GPU. Layer 2 matches the terrain navmesh mask.
		_terrain.collision_layer = 2
		_terrain.add_to_group("terrain_navigation_input")
	_recalculate_camera_bounding_planes(map.size)
	_configure_view_for_generated_map()
	fog_of_war.resize(map.size)
	await navigation.setup(map)


func _recalculate_camera_bounding_planes(map_size: Vector2):
	var world_size := map_size
	if map is Node3D:
		world_size = Vector2(
			map_size.x * absf((map as Node3D).scale.x),
			map_size.y * absf((map as Node3D).scale.z)
		)
	_camera.set_map_bounds(world_size)


func _is_large_generated_map() -> bool:
	return map != null and (map.size.x >= 256.0 or map.size.y >= 256.0)


func _uses_logic_terrain() -> bool:
	# 唯一实现见 MatchUtils.is_logic_terrain_map（旧内联判据把普通地图误判成逻辑地形，
	# 进而跳过导航烘焙、使建造全被拒）。
	return Utils.Match.is_logic_terrain_map(map)


func _purge_large_map_authoring_nodes() -> void:
	# G4 导出留着几百个 Solid*/Walk* 作者碰撞和 269 块水面。只改 layer /
	# visible 节点仍在 PhysicsServer / RenderingServer 里：真机 706 个静态体
	# → 物理一步 56–61ms，再按 60Hz 追帧就锁死在 2 FPS。必须立刻 free。
	if map == null:
		return
	var collision_removed := _free_all_children(map.get_node_or_null("Collision"))
	var water_removed := _free_all_children(map.get_node_or_null("WaterBody"))
	print(
		"G4PERF map_collision_removed=",
		collision_removed,
		" water_removed=",
		water_removed
	)


func _free_all_children(parent: Node) -> int:
	if parent == null:
		return 0
	var removed := parent.get_child_count()
	while parent.get_child_count() > 0:
		var child: Node = parent.get_child(parent.get_child_count() - 1)
		parent.remove_child(child)
		child.free()
	return removed


func _configure_view_for_generated_map() -> void:
	if not _is_large_generated_map():
		return
	_camera.configure_for_large_terrain(map.size)
	# 必须在导航烘焙之前锁表现：烘焙期间 Match 已进场景树，否则先黑/先卡。
	_apply_large_map_playable_presentation()
	print(
		"LARGE_MAP view size=",
		map.size,
		" cam_bound=",
		_camera.bounding_planes[1].d if _camera.bounding_planes.size() > 1 else 0.0,
		" cam_far=",
		_camera.far,
		" cam_size=",
		_camera.size,
		" cam_rot=",
		_camera.rotation_degrees
	)


## 只锁“能玩”需要的渲染开关，不改地形网格或寻路。
func _apply_large_map_playable_presentation() -> void:
	var sun := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		# 整图 cascade 仍贵，但完全关阴影会让模型和地形变成平涂。
		# 只把阴影距离收到镜头附近；bias/pancake 过大时建筑脚下没有接触影。
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = 80.0
		# 0.04 is too small for the large terrain depth range and produces
		# regular self-shadow acne bands across the sand in the orthographic view.
		# Keep the scene's 0.3 bias so terrain still receives unit/building shadows
		# without comparing the ground against its own shadow map quantization.
		sun.shadow_normal_bias = 1.0
		sun.directional_shadow_pancake_size = 8.0
		# 【2026-10-12 用户口径 A："不升高才好看"】光强/饱和度/曝光回到场景 tscn 口径：
		# 旧值 1.35/0.96/1.0 是 512 表现锁刻意抬高的"浓艳档"，实测进局与三选一浮层
		# 关闭瞬间反差过强（真机 A/B：adjustment_saturation 0.96→0.75 画面明显变柔）。
		sun.light_energy = 1.0
	_strip_height_fog_mesh()
	var env_node := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node != null and env_node.environment != null:
		var environment := env_node.environment
		environment.volumetric_fog_enabled = false
		environment.fog_enabled = true
		environment.fog_density = 0.0012
		environment.ssr_enabled = false
		environment.sdfgi_enabled = false
		environment.ambient_light_energy = 0.38
		environment.background_energy_multiplier = 0.9
		# 【2026-10-12 用户口径 A】饱和度/曝光回 tscn 口径（0.75/0.9）：旧 0.96/1.0 是
		# "浓艳档"，用户实测三选一浮层关闭瞬间的弹回感过强，"不升高才好看"。
		environment.adjustment_saturation = 0.75
		# 正交俯视 + 沙地颗粒上开 SSAO，会打出斜向条纹（活局截图已证实）。
		environment.ssao_enabled = false
		environment.glow_enabled = false  # 【2026-10-07 用户口径】glow 关闭：oversight 之前被这里重新打开 ⇒ 太亮（白亮光圈）
		environment.tonemap_exposure = 0.9
	var diagnostic := find_child("DiagnosticHUD", true, false)
	if diagnostic == null:
		diagnostic = find_child("DiagnosticHud", true, false)
	if diagnostic != null:
		diagnostic.visible = false
		diagnostic.set_physics_process(false)
		diagnostic.set_process(false)
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null and governor.has_method("lock_large_map_presentation"):
		governor.lock_large_map_presentation()


func _strip_height_fog_mesh() -> void:
	var height_fog := get_node_or_null("Fog") as MeshInstance3D
	if height_fog == null:
		return
	height_fog.visible = false
	height_fog.process_mode = Node.PROCESS_MODE_DISABLED
	height_fog.extra_cull_margin = 0.0
	height_fog.queue_free()


func _disable_war_fog() -> void:
	if fog_of_war != null and fog_of_war.has_method("set_runtime_enabled"):
		fog_of_war.set_runtime_enabled(false)
	elif fog_of_war != null:
		fog_of_war.visible = false
	var unit_visibility_handler = find_child("UnitVisibilityHandler", true, false)
	if unit_visibility_handler != null:
		unit_visibility_handler.visible = false
	var minimap_fog_mask = find_child("FogOfWarMask", true, false)
	if minimap_fog_mask != null:
		minimap_fog_mask.visible = false


func _physics_process(_delta) -> void:
	_physics_script_t0_us = Time.get_ticks_usec()
	_physics_script_armed = true
	if OS.get_environment("AIRTS_MOV_DIAG") != "":
		if _mov_diag_script == null:
			_mov_diag_script = load("res://source/match/units/traits/Movement.gd")
		_mov_diag_script.diag_mark("match")
		_mov_diag_script.diag_bookend("phys_first")


func _on_large_map_physics_frame() -> void:
	if not _physics_script_armed or _physics_script_t0_us <= 0:
		return
	_physics_script_armed = false
	last_physics_script_ms = float(Time.get_ticks_usec() - _physics_script_t0_us) / 1000.0
	if Engine.get_physics_frames() % 40 == 0:
		print(
			"G4PERF physics_script_ms=",
			snappedf(last_physics_script_ms, 0.01),
			" engine_physics_ms=",
			snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01)
		)


func _exit_tree() -> void:
	Engine.max_physics_steps_per_frame = _prev_max_physics_steps
	Engine.physics_ticks_per_second = _prev_physics_ticks
	var tree := get_tree()
	if tree != null:
		tree.physics_interpolation = _prev_physics_interpolation
		if tree.physics_frame.is_connected(_on_large_map_physics_frame):
			tree.physics_frame.disconnect(_on_large_map_physics_frame)
	var governor := get_node_or_null("/root/PerformanceGovernor")
	if governor != null and governor.has_method("unlock_large_map_presentation"):
		governor.unlock_large_map_presentation()


func _setup_players():
	assert(
		_players.get_children().is_empty() or settings.players.is_empty(),
		"players can be defined either in settings or in scene tree, not in both"
	)
	if _players.get_children().is_empty():
		_create_players_from_settings()
	for node in _players.get_children():
		if node is Player:
			node.add_to_group("players")
			node.setup_resource_account($EconomyRuntime)
			_grant_growth_starting_bonus(node)
	_ensure_local_player_has_actions_controller()


## 成长「资源储备」的开局赠款：必须在 `setup_resource_account()` 之后发放，
## 否则这笔钱进不了权威资源账户（直接改 `resource_a` 会被 C# 账户镜像拒绝）。
## 联机不发：`GrowthModifiers.is_enabled()` 为 false 时返回 0。
func _grant_growth_starting_bonus(player: Node) -> void:
	var bonus := GrowthModifiers.starting_resource_bonus(player)
	if bonus <= 0:
		return
	player.add_resources({"resource_a": bonus}, "ScriptedAdjustment", player)
	print("[GROWTH] 开局成长赠款 +%d → player=%s" % [bonus, player.name])


## 保证"本地玩家"一定有指令控制器（2026-09-12）。
##
## 背景：客户端本地玩家节点不一定来自 `Human.tscn`（联机空槽/场景占位/A-B 基线把槽位
## 交给规则 AI 等），于是没有 `UnitActionsController` —— 命令面板会在 `_ready` 断言中断
## （皮肤/边框都上不去、按钮看着能点却没反应），维修与出售也进不了指定模式。
## 这里兜底补挂一个：控制器 `_is_local_controller()` 只在"父节点 == 本地玩家"时启用自己，
## 所以不会出现双控制器；专用服/无本地玩家（`get_local_player()` 为 null）不受影响。
func _ensure_local_player_has_actions_controller():
	var local_player = get_local_player()
	if local_player == null or not is_instance_valid(local_player):
		return
	# ⚠️ 必须用**递归**查找：控制器不一定挂在本地玩家的直接子节点下
	# （`Match.gd` 里命令面板那句 `get_node("UnitActionsController")` 会因此报
	#  `Node not found`，而侧栏用 `find_child(...)` 却能找到 —— 两者不一致正是
	#  2026-09-12 面板拿不到控制器的根因）。若这里也用 get_node_or_null，
	#  就会在"控制器存在但不在直接子节点"时**误判为缺失并再补挂一个 → 双控制器抢输入**。
	if local_player.find_child("UnitActionsController", true, false) != null:
		return
	var controller_script: Script = load("res://source/match/players/human/UnitActionsController.gd")
	if controller_script == null:
		return
	var controller: Node = controller_script.new()
	controller.name = "UnitActionsController"
	local_player.add_child(controller)
	print("[INPUT] 本地玩家无指令控制器，已补挂 player=", local_player.name)


func _create_players_from_settings():
	var player_index := 0
	for player_settings in settings.players:
		var player
		if player_settings.controller == Constants.PlayerType.NONE:
			# 联机空槽：占位玩家，保留槽位索引但不生成任何单位
			#（修复「大厅设 1 个 AI，开局却出现 3 个 AI」——空槽此前被无脑填成 AI）。
			player = Player.new()
			player.set_meta("slot_kind", Constants.PlayerType.NONE)
		else:
			var player_scene = Constants.Match.Player.CONTROLLER_SCENES[player_settings.controller]
			player = player_scene.instantiate()
			if Constants.is_rule_ai(player_settings.controller) and "difficulty" in player:
				var difficulty := int(player_settings.difficulty)
				if difficulty < 0 or difficulty > 2:
					difficulty = Constants.rule_ai_difficulty(player_settings.controller)
				player.difficulty = difficulty
		player.color = player_settings.color
		# 初始经济：所有玩家统一 10000（用户设定 2026-09-15，此前 50000）。
		# 与单位定价的方向性调整配套（小兵降、载具升，见 config/balance/demo.balance.v1.json）：
		# 开局够铺经济 + 少量部队，不再一开局就能堆满重型单位。
		player.resource_a = 10000
		player.resource_b = 10000
		# 仅自动化测试启动参数生效的低余额局：用于真实触发 InsufficientResources
		# （工人 200 而余额 150）。正常玩家进程不带 --e2e-low-balance 不受影响，
		# 不构成任何运行时可调作弊接口。
		if "--e2e-low-balance" in OS.get_cmdline_user_args():
			player.resource_a = 150
		if player_settings.spawn_index_offset > 0:
			for _i in range(player_settings.spawn_index_offset):
				_players.add_child(Node.new())
		_players.add_child(player)
		# 联机 P0-1：跨进程确定性节点路径。Godot 自动命名（@Node3D@N）的计数器
		# 随进程启动路径漂移，两端初始清单必然对不上——玩家与单位必须显式命名。
		player.name = "Player_%d" % player_index
		player_index += 1


func _setup_player_units():
	for player in _players.get_children():
		if not player is Player:
			continue
		if player.get_meta("slot_kind", -1) == Constants.PlayerType.NONE:
			continue
		var player_index = player.get_index()
		var predefined_units = player.get_children().filter(func(child): return child is Unit)
		if not predefined_units.is_empty():
			predefined_units.map(func(unit): _setup_unit_groups(unit, unit.player))
		else:
			_spawn_player_units(
				player, map.find_child("SpawnPoints").get_child(player_index).global_transform
			)


## 把地图出生点登记进查询运行时（公共知识：双方开局即可见彼此出生位置）。
func _register_spawn_points_with_query_runtime() -> void:
	var spawn_points: Node = map.find_child("SpawnPoints", true, false)
	if spawn_points == null:
		return
	var positions := PackedVector3Array()
	for point in spawn_points.get_children():
		positions.append(point.global_transform.origin)
	_query_runtime.RegisterSpawnPoints(positions)


## 兼容旧调用名（相机/DCS 建造落点仍走这里）。
func _sample_generated_height(at: Vector3) -> float:
	return ground_height_at(at)


## 世界坐标处的地表高度。生成图走高度场（含缩放）；手摆图走地形碰撞射线。
## 碰撞顶点全部同高、且和一次真射线一致时，直接返回该高度。斜坡/高台仍走射线。
func ground_height_at(at: Vector3) -> float:
	if _uses_logic_terrain():
		return Utils.Match.sample_world_ground_y(map, at)
	if _flat_ground_state == 1:
		return _flat_ground_y
	var y := _ray_ground_height(at)
	if _flat_ground_state < 0:
		_try_enable_flat_ground(y)
	return y


func _ray_ground_height(at: Vector3) -> float:
	var terrain_body: Node3D = (
		(_terrain if _terrain != null else find_child("Terrain", true, false)) as Node3D
	)
	if terrain_body == null:
		return at.y
	var world: World3D = terrain_body.get_world_3d()
	if world == null:
		return at.y
	var params := PhysicsRayQueryParameters3D.create(
		Vector3(at.x, at.y + 200.0, at.z), Vector3(at.x, at.y - 200.0, at.z)
	)
	params.collision_mask = 2
	params.collide_with_areas = false
	var hit: Dictionary = world.direct_space_state.intersect_ray(params)
	if hit.is_empty():
		return Utils.Match.sample_world_ground_y(map, at)
	return (hit["position"] as Vector3).y


func _try_enable_flat_ground(ray_y: float) -> void:
	if _terrain == null:
		return
	var col := _terrain.find_child("CollisionShape3D") as CollisionShape3D
	if col == null or col.shape == null:
		return
	if not (col.shape is ConcavePolygonShape3D):
		_flat_ground_state = 0
		return
	var faces: PackedVector3Array = (col.shape as ConcavePolygonShape3D).get_faces()
	if faces.is_empty():
		return
	var y0: float = faces[0].y
	for i in faces.size():
		if absf(faces[i].y - y0) > 0.0004:
			_flat_ground_state = 0
			return
	var basis: Basis = _terrain.global_transform.basis
	if absf(basis.x.y) > 0.0001 or absf(basis.z.y) > 0.0001:
		_flat_ground_state = 0
		return
	var analytic: float = (_terrain.global_transform * Vector3(faces[0].x, y0, faces[0].z)).y
	if absf(analytic - ray_y) > 0.0005:
		_flat_ground_state = 0
		print("G4PERF flat_ground rejected analytic=", analytic, " ray=", ray_y)
		return
	_flat_ground_y = analytic
	_flat_ground_state = 1
	print("G4PERF flat_ground_y=", analytic)


func _grounded_spawn_transform(spawn_transform: Transform3D) -> Transform3D:
	var origin := spawn_transform.origin
	# 【2026-09-29 尺寸口径统一】必须整支传下去（含 scale）：旧代码只取 basis，
	# 把场景里写的 root scale 抹成 1 —— 视觉尺寸与 Movement/MovementObstacle 的世界
	# 占地（如基地 7m）从此不一致，玩家看到"小房子占大地盘"。
	var grounded := Transform3D(spawn_transform)
	grounded.origin = Vector3(origin.x, ground_height_at(origin), origin.z)
	return grounded


func _is_air_unit(unit: Node) -> bool:
	var movement := unit.find_child("Movement", true, false)
	if movement == null or not ("domain" in movement):
		return false
	return int(movement.domain) == int(Constants.Match.Navigation.Domain.AIR)


func _spawn_player_units(player, spawn_transform):
	# 开局：主基地 + 1 无人机（2026-09-28 红警2 口径：**开局不再送工人**；
	# 经济单位改为"矿车"（内部 id 仍是 worker），由车厂生产、矿场完工赠送一辆）。
	# 出生点投到真实地形高度；无人机在 _setup_and_spawn_unit 里再加离地。
	spawn_transform = _grounded_spawn_transform(spawn_transform)
	_setup_and_spawn_unit(CommandCenter.instantiate(), spawn_transform, player, false)
	# 主基地视觉约 14m 宽。旧偏移 (-2, 0, -2) 只有 2.8m，无人机生在圆顶模型里面，
	# 场上看不到。放到基地外侧 12m，网格和选择圈都露在建筑外面。
	_setup_and_spawn_unit(
		Drone.instantiate(), spawn_transform.translated(Vector3(-12, 0, 0)), player
	)
	if NetSession.passive_ai_test_server or NetSession.passive_ai_test:
		# 测试局预置已完成车辆工厂，确保生产流程可以直接通过 UI 验证。
		_setup_and_spawn_unit(
			VehicleFactory.instantiate(), spawn_transform.translated(Vector3(0, 0, 6)), player, false
		)
		# 期 2：同步预置已完成兵营，联机冒烟可验证步兵生产转发链路。
		_setup_and_spawn_unit(
			Barracks.instantiate(), spawn_transform.translated(Vector3(0, 0, 9)), player, false
		)


func _setup_and_spawn_unit(unit, a_transform, player, mark_structure_under_construction = true):
	# 所有单位/建筑的唯一出场入口。地面始终贴地；飞机贴地后再抬离地高度。
	# 不再用 3m 护栏：高差 >3m 时跳过校正，正是"埋进地里 / 悬在盒顶"的来源。
	# 【2026-09-30 护栏（验证席建议）】出生只接受"世界位置 + 旋转"：调用方若递进带缩放的基
	# （例如蓝图 ghost 带着 Visual 缩放 3），旧实现会整支套用 ⇒ 落地 root scale=3、视觉 9 倍、
	# 车厂碰撞半径 19.95m（应 6.65）。放置链已在 C# 侧正交化；这里再兜一道，防止将来重现。
	if not a_transform.basis.get_scale().is_equal_approx(Vector3.ONE):
		print("[SPAWN] 剔除调用方带来的缩放 ", str(a_transform.basis.get_scale()), " → 1（出生只接受位置+旋转）")
		a_transform = Transform3D(a_transform.basis.orthonormalized(), a_transform.origin)
	var perf_on := AiPerfStats.enabled()
	var ground_started := Time.get_ticks_usec() if perf_on else 0
	var grounded := _grounded_spawn_transform(a_transform)
	if perf_on:
		AiPerfStats.add("spawn_ground", Time.get_ticks_usec() - ground_started)
	# 【2026-09-30 世界米制归一化】所有单位场景的 UnitRoot scale 已归一到 1，
	# 原先"把场景 root scale 合入 spawn transform"的补偿不再需要 —— 那正是
	# "根×3、子×1/3"结构的一半。调用方只给世界位置与旋转；美术缩放留在各自的
	# Visual 分支（Geometry）里，玩法节点（碰撞/移动/障碍/出生点）直接是世界米。
	if _is_air_unit(unit):
		# 【2026-09-29 尺寸口径统一】整支传下去（含 scale），只抬 origin.y：
		# 旧代码重新构造 Transform3D 又丢掉 scale，root scale 对空中单位同样失效。
		var lifted := Transform3D(grounded)
		lifted.origin = Vector3(
			grounded.origin.x,
			grounded.origin.y + Constants.Match.Air.HOVER_OFFSET,
			grounded.origin.z
		)
		a_transform = lifted
	else:
		a_transform = grounded
	if unit is Structure and mark_structure_under_construction:
		var mark_started := Time.get_ticks_usec() if perf_on else 0
		unit.mark_as_under_construction()
		if perf_on:
			AiPerfStats.add("spawn_mark", Time.get_ticks_usec() - mark_started)
	var groups_started := Time.get_ticks_usec() if perf_on else 0
	_setup_unit_groups(unit, player)
	if perf_on:
		AiPerfStats.add("spawn_groups", Time.get_ticks_usec() - groups_started)
	# 联机 P0-1：显式命名（同玩家节点，自动命名跨进程不稳定）。
	unit.name = "Unit_%d" % _unit_spawn_counter
	_unit_spawn_counter += 1
	# Players/Player 在原点：入树前写本地变换，_ready 才不会在 (0,0) 闪一帧/盖障碍。
	# 【2026-09-30 归一化后】场景 root scale 恒为 1，整支赋值与只取 basis+origin 等价；
	# 美术缩放已搬到各场景的 Visual 分支，玩法节点直接是世界米。
	unit.transform = a_transform
	var enter_started := Time.get_ticks_usec() if perf_on else 0
	player.add_child(unit)
	if perf_on:
		AiPerfStats.add("spawn_enter_tree", Time.get_ticks_usec() - enter_started)
	var xform_started := Time.get_ticks_usec() if perf_on else 0
	unit.global_transform = a_transform
	if perf_on:
		AiPerfStats.add("spawn_xform", Time.get_ticks_usec() - xform_started)
	if unit.has_method("reset_physics_interpolation"):
		unit.reset_physics_interpolation()
	var signal_started := Time.get_ticks_usec() if perf_on else 0
	MatchSignals.unit_spawned.emit(unit)
	if perf_on:
		AiPerfStats.add("spawn_signal", Time.get_ticks_usec() - signal_started)


func _setup_unit_groups(unit, player):
	unit.add_to_group("units")
	# 空间网格索敌索引：所有单位/建筑的注册漏斗（出场入口与预置单位都经过这里）。
	if _target_grid != null:
		_target_grid.register(unit)
	if player == get_local_player():
		unit.add_to_group("controlled_units")
	else:
		unit.add_to_group("adversary_units")
	if player in visible_players:
		unit.add_to_group("revealed_units")


func _ensure_match_augments() -> void:
	if get_node_or_null("PauseGate") == null:
		var gate: Node = MatchPauseGateScript.new()
		gate.name = "PauseGate"
		add_child(gate)
	var flags := get_node_or_null("/root/FeatureFlags")
	var enabled := true if flags == null else bool(flags.get("match_augments"))
	if enabled and get_node_or_null("AugmentRuntime") == null:
		var runtime: Node = AugmentRuntimeScript.new()
		runtime.name = "AugmentRuntime"
		add_child(runtime)


## 空间网格索敌索引：必须在 `_setup_players()`/`_setup_player_units()` 之前建好，
## 预置单位的注册漏斗 `_setup_unit_groups()` 才有地方写。
## AIRTS_TARGETING=baseline 时完全不创建（性能对照基线 = 旧代码等价形态）。
func _ensure_target_acquisition_grid() -> void:
	if get_node_or_null("TargetAcquisitionGrid") != null:
		return
	if OS.get_environment("AIRTS_TARGETING") == "baseline":
		return
	var grid_script: Script = load("res://source/match/TargetAcquisitionGrid.gd") as Script
	if grid_script == null:
		push_warning("TargetAcquisitionGrid 脚本加载失败，索敔回退全场组扫描")
		return
	var grid: Node = grid_script.new()
	grid.name = "TargetAcquisitionGrid"
	add_child(grid)
	_target_grid = grid


func get_local_player():
	if settings != null and settings.local_player_index >= 0:
		var grouped = get_tree().get_nodes_in_group("players")
		if settings.local_player_index < grouped.size():
			return grouped[settings.local_player_index]
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	if human_players.size() == 1:
		return human_players[0]
	if (
		settings != null
		and settings.visible_player >= 0
		and settings.visible_player < human_players.size()
	):
		var grouped = get_tree().get_nodes_in_group("players")
		if settings.visible_player < grouped.size() and grouped[settings.visible_player] is Human:
			return grouped[settings.visible_player]
	if not human_players.is_empty():
		return human_players[0]
	return null


func _get_human_player():
	return get_local_player()


func _is_dedicated_or_headless() -> bool:
	return NetSession.is_dedicated_server()


func _move_camera_to_initial_position():
	var human_player = get_local_player()
	if human_player != null:
		_move_camera_to_player_units_crowd_pivot(human_player)
		return
	var players = get_tree().get_nodes_in_group("players")
	if players.is_empty():
		# 防御：对局无任何玩家（数据异常）时不再让数组越界炸断 _ready，
		# 相机回退地图中心，保证迷雾/HUD 等子系统继续初始化（修复联机/观战黑屏）。
		push_warning("开局对局无任何玩家，相机回退地图中心（请排查玩家生成链路）")
		_move_camera_to_map_center()
		return
	_move_camera_to_player_units_crowd_pivot(players[0])


func _move_camera_to_map_center():
	var map_size: Vector2 = map.size
	var center := Vector3(map_size.x / 2.0, 0.0, map_size.y / 2.0)
	center.y = _sample_generated_height(center)
	_camera.set_position_safely(center)


func _move_camera_to_player_units_crowd_pivot(player):
	var player_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player
	)
	if player_units.is_empty():
		# 防御：玩家无初始单位（空槽局/单位生成失败）时不再 assert 炸断 _ready，
		# 相机回退地图中心，保证迷雾/HUD 等子系统继续初始化（修复进局黑屏）。
		push_warning("开局玩家无初始单位，相机回退地图中心（请排查单位生成链路）")
		_move_camera_to_map_center()
		return
	var crowd_pivot = Utils.Match.Unit.Movement.calculate_aabb_crowd_pivot_yless(player_units)
	crowd_pivot.y = _sample_generated_height(crowd_pivot)
	_camera.set_position_safely(crowd_pivot)


func _reveal_player_units(player):
	if player == null:
		return
	for unit in get_tree().get_nodes_in_group("units").filter(
		func(a_unit): return a_unit.player == player
	):
		unit.add_to_group("revealed_units")


func _conceal_player_units(player):
	if player == null:
		return
	for unit in get_tree().get_nodes_in_group("units").filter(
		func(a_unit): return a_unit.player == player
	):
		unit.remove_from_group("revealed_units")
