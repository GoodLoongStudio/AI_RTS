extends Control

var match_settings = null
var map_path = null
var campaign_data = null

@onready var _label = find_child("Label")
@onready var _progress_bar = find_child("ProgressBar")


func _ready():
	AudioDirector.set_music_context("menu")
	_progress_bar.value = 0.0

	_label.text = tr("LOADING_STEP_PRELOADING")
	await get_tree().physics_frame
	_progress_bar.value = 0.2

	_label.text = tr("LOADING_STEP_LOADING_MAP")
	await get_tree().physics_frame
	var map_scene := _load_packed_scene(map_path, "地图")
	if map_scene == null:
		return
	var map_instance := map_scene.instantiate()
	_progress_bar.value = 0.4

	_label.text = tr("LOADING_STEP_LOADING_MATCH")
	await get_tree().physics_frame
	var match_prototype := _load_packed_scene("res://source/match/Match.tscn", "战斗场景")
	if match_prototype == null:
		return
	_progress_bar.value = 0.7

	_label.text = tr("LOADING_STEP_INSTANTIATING_MATCH")
	await get_tree().physics_frame
	var a_match = match_prototype.instantiate()
	a_match.settings = match_settings
	a_match.map = map_instance
	a_match.campaign_data = campaign_data
	_progress_bar.value = 0.9

	_label.text = tr("LOADING_STEP_STARTING_MATCH")
	await get_tree().physics_frame
	get_parent().add_child(a_match)
	get_tree().current_scene = a_match
	queue_free()


func _load_packed_scene(path_value, display_name: String) -> PackedScene:
	var scene_path := str(path_value)
	if scene_path.is_empty() or scene_path == "<null>":
		_show_load_error("%s路径为空" % display_name)
		return null

	var resource := ResourceLoader.load(scene_path)
	if resource == null:
		_show_load_error("%s加载失败：%s" % [display_name, scene_path])
		return null

	var packed_scene := resource as PackedScene
	if packed_scene == null:
		_show_load_error("%s不是可实例化的 PackedScene：%s" % [display_name, scene_path])
		return null
	return packed_scene


func _show_load_error(message: String):
	push_error(message)
	_label.text = "加载失败\n%s" % message
	_progress_bar.value = 0.0
