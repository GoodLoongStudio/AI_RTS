class_name CombatSfx
extends RefCounted

## 战斗音效播放器（2026-09-07）：开火/命中音效统一从这里生成 3D 位置音源，
## WAV 素材位于 assets/sfx/combat/（弹道命中音色按受击面分类：金属/软体/爆炸）。
## 测试可通过 played_log 观察播放记录（clear_played_log/reset）。

const SFX_DIR := "res://assets/sfx/combat/"

const FIRE_SOUND_BY_SCENE := {
	"res://source/match/units/Infantry.tscn": "rifle_fire",
	"res://source/match/units/Tank.tscn": "cannon_fire",
	"res://source/match/units/AntiGroundTurret.tscn": "cannon_fire",
	"res://source/match/units/AntiAirTurret.tscn": "rocket_fire",
	"res://source/match/units/Helicopter.tscn": "rocket_fire",
	"res://source/match/units/Drone.tscn": "rocket_fire",
}

const VOLUME_BY_KEY := {
	"rifle_fire": -10.0,
	"cannon_fire": -2.0,
	"rocket_fire": -6.0,
	"impact_metal": -6.0,
	"impact_flesh": -8.0,
	"impact_explosion": -4.0,
}

## 测试观察用：最近播放的音效键（仅测试断言使用）。
static var played_log: Array[String] = []

static var _stream_cache := {}


## 在 host 位置播放一次音效；host 通常为单位节点，音源挂到 Match 场景避免随单位销毁。
static func play_at(host: Node3D, key: String) -> void:
	if key.is_empty() or not is_inside_tree_host(host):
		return
	var stream := _get_stream(key)
	if stream == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = VOLUME_BY_KEY.get(key, -6.0)
	player.max_distance = 90.0
	player.unit_size = 8.0
	player.bus = "Master"
	var match_root := host.find_parent("Match")
	var parent := match_root if match_root != null else host.get_tree().current_scene
	if parent == null:
		return
	parent.add_child(player)
	player.global_position = host.global_position
	player.play()
	player.finished.connect(player.queue_free)
	played_log.append(key)


## 单位开火音效键；未映射的单位（如工人）返回空串不播放。
static func fire_key_for(unit: Node3D) -> String:
	return str(FIRE_SOUND_BY_SCENE.get(str(unit.scene_file_path), ""))


## 命中音效键：武器反应类别 × 受击面（步兵=软体，其余=金属）。
static func impact_key_for(reaction: String, unit: Node3D) -> String:
	if reaction != "bullet":
		return "impact_explosion"
	var is_soft_target := str(unit.scene_file_path).contains("Infantry")
	return "impact_flesh" if is_soft_target else "impact_metal"


static func clear_played_log() -> void:
	played_log.clear()


static func _get_stream(key: String) -> AudioStream:
	if _stream_cache.has(key):
		return _stream_cache[key]
	var path := SFX_DIR + key + ".wav"
	if not ResourceLoader.exists(path):
		return null
	var stream := load(path) as AudioStream
	_stream_cache[key] = stream
	return stream


static func is_inside_tree_host(host: Node3D) -> bool:
	return host != null and host.is_inside_tree()
