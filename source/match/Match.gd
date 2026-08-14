extends Node3D

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Player = preload("res://source/match/players/Player.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const AICommandHUD = preload("res://source/match/hud/AICommandHUD.gd")
const TraditionalUnitCommandHUD = preload(
	"res://source/match/hud/TraditionalUnitCommandHUD.tscn"
)
const CampaignController = preload("res://source/campaign/CampaignController.gd")
const CampaignHeroIdentity = preload("res://source/campaign/CampaignHeroIdentity.gd")

const CommandCenter = preload("res://source/match/units/CommandCenter.tscn")
const Drone = preload("res://source/match/units/Drone.tscn")
const Worker = preload("res://source/match/units/Worker.tscn")

@export var settings: Resource = null

var campaign_data = null
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


func _enter_tree():
	assert(settings != null, "match cannot start without settings, see examples in tests/manual/")
	assert(map != null, "match cannot start without map, see examples in tests/manual/")


func _ready():
	MatchSignals.setup_and_spawn_unit.connect(_setup_and_spawn_unit)
	_setup_subsystems_dependent_on_map()
	_setup_players()
	_setup_player_units()
	visible_player = get_tree().get_nodes_in_group("players")[settings.visible_player]
	_move_camera_to_initial_position()
	if settings.visibility == settings.Visibility.FULL:
		fog_of_war.reveal()
	_setup_ai_command_hud()
	_setup_traditional_unit_command_hud()
	_setup_campaign()
	MatchSignals.match_started.emit()


func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.is_action_pressed("shift_selecting"):
			return
		MatchSignals.deselect_all_units.emit()


func _setup_ai_command_hud():
	if _get_human_player() == null:
		return
	var ai_command_hud = AICommandHUD.new()
	ai_command_hud.name = "AICommandHUD"
	if campaign_data != null:
		ai_command_hud.control_mode = campaign_data.get("initial_control_mode", "squad")
		ai_command_hud.hero_name = campaign_data.get("hero_name", "先锋指挥单元")
	$HUD.add_child(ai_command_hud)
	_setup_ai_command_hud_toggle(ai_command_hud)


func _setup_ai_command_hud_toggle(ai_command_hud: Control):
	var toggle_button := Button.new()
	toggle_button.name = "AICommandHUDToggle"
	toggle_button.text = "显示 AI 副官"
	toggle_button.tooltip_text = "显示或隐藏 Legacy AI 副官原型界面"
	toggle_button.position = Vector2(18, 18)
	toggle_button.custom_minimum_size = Vector2(150, 40)
	toggle_button.mouse_filter = Control.MOUSE_FILTER_STOP
	toggle_button.pressed.connect(
		func():
			var should_show = not ai_command_hud.is_interface_visible()
			ai_command_hud.set_interface_visible(should_show)
			toggle_button.text = "隐藏 AI 副官" if should_show else "显示 AI 副官"
	)
	$HUD.add_child(toggle_button)


func _setup_traditional_unit_command_hud():
	var human_player = _get_human_player()
	if human_player == null:
		return
	var command_hud = TraditionalUnitCommandHUD.instantiate()
	command_hud.actions_controller = human_player.get_node("UnitActionsController")
	$HUD.add_child(command_hud)


func _setup_campaign():
	if campaign_data == null:
		return
	var campaign_controller = CampaignController.new()
	campaign_controller.name = "CampaignController"
	campaign_controller.mission_data = campaign_data
	add_child(campaign_controller)


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
	_terrain.update_shape(map_terrain.mesh)
	# Runtime navmesh baking should consume the terrain collider rather than reading
	# the visual MeshInstance3D back from the GPU. Layer 2 matches the terrain navmesh mask.
	_terrain.collision_layer = 2
	_terrain.add_to_group("terrain_navigation_input")
	fog_of_war.resize(map.size)
	_recalculate_camera_bounding_planes(map.size)
	navigation.setup(map)


func _recalculate_camera_bounding_planes(map_size: Vector2):
	_camera.bounding_planes[1] = Plane(-1, 0, 0, -map_size.x)
	_camera.bounding_planes[3] = Plane(0, 0, -1, -map_size.y)


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


func _create_players_from_settings():
	for player_settings in settings.players:
		var player_scene = Constants.Match.Player.CONTROLLER_SCENES[player_settings.controller]
		var player = player_scene.instantiate()
		player.color = player_settings.color
		if player_settings.spawn_index_offset > 0:
			for _i in range(player_settings.spawn_index_offset):
				_players.add_child(Node.new())
		_players.add_child(player)


func _setup_player_units():
	for player in _players.get_children():
		if not player is Player:
			continue
		var player_index = player.get_index()
		var predefined_units = player.get_children().filter(func(child): return child is Unit)
		if not predefined_units.is_empty():
			predefined_units.map(func(unit): _setup_unit_groups(unit, unit.player))
		else:
			_spawn_player_units(
				player, map.find_child("SpawnPoints").get_child(player_index).global_transform
			)


func _spawn_player_units(player, spawn_transform):
	if _should_spawn_campaign_hero(player):
		var hero_scene_path: String = campaign_data.get("hero_scene", "res://source/match/units/Tank.tscn")
		var hero_scene: PackedScene = load(hero_scene_path) as PackedScene
		assert(hero_scene != null, "campaign hero scene could not be loaded: %s" % hero_scene_path)
		var hero_unit: Node3D = hero_scene.instantiate() as Node3D
		assert(hero_unit != null and hero_unit is Unit, "campaign hero must be a normal RTS Unit")
		_setup_and_spawn_unit(hero_unit, spawn_transform, player)
		_register_campaign_hero(hero_unit)
		return

	_setup_and_spawn_unit(CommandCenter.instantiate(), spawn_transform, player, false)
	_setup_and_spawn_unit(
		Drone.instantiate(), spawn_transform.translated(Vector3(-2, 0, -2)), player
	)
	_setup_and_spawn_unit(
		Worker.instantiate(), spawn_transform.translated(Vector3(-3, 0, 3)), player
	)
	_setup_and_spawn_unit(
		Worker.instantiate(), spawn_transform.translated(Vector3(3, 0, 3)), player
	)


func _register_campaign_hero(unit: Node3D):
	# Hero is an identity/role layered on top of a normal RTS Unit. The current prologue
	# uses Tank.tscn, while future missions can swap in a stronger dedicated unit scene.
	unit.add_to_group("campaign_hero")
	var identity = CampaignHeroIdentity.new()
	identity.name = "CampaignHeroIdentity"
	identity.configure(campaign_data if campaign_data != null else {})
	unit.add_child(identity)


func _should_spawn_campaign_hero(player) -> bool:
	return (
		campaign_data != null
		and campaign_data.get("initial_control_mode", "squad") == "hero"
		and player == _get_human_player()
	)


func _setup_and_spawn_unit(unit, a_transform, player, mark_structure_under_construction = true):
	unit.global_transform = a_transform
	if unit is Structure and mark_structure_under_construction:
		unit.mark_as_under_construction()
	_setup_unit_groups(unit, player)
	player.add_child(unit)
	MatchSignals.unit_spawned.emit(unit)


func _setup_unit_groups(unit, player):
	unit.add_to_group("units")
	if player == _get_human_player():
		unit.add_to_group("controlled_units")
	else:
		unit.add_to_group("adversary_units")
	if player in visible_players:
		unit.add_to_group("revealed_units")


func _get_human_player():
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	assert(human_players.size() <= 1, "more than one human player is not allowed")
	if not human_players.is_empty():
		return human_players[0]
	return null


func _move_camera_to_initial_position():
	var human_player = _get_human_player()
	if human_player != null:
		_move_camera_to_player_units_crowd_pivot(human_player)
	else:
		_move_camera_to_player_units_crowd_pivot(get_tree().get_nodes_in_group("players")[0])


func _move_camera_to_player_units_crowd_pivot(player):
	var player_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player
	)
	assert(not player_units.is_empty(), "player must have at least one initial unit")
	var crowd_pivot = Utils.Match.Unit.Movement.calculate_aabb_crowd_pivot_yless(player_units)
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
