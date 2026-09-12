class_name CombatSfx
extends RefCounted

## 战斗音效播放器（2026-09-07）：开火/命中音效统一从这里生成 3D 位置音源，
## WAV 素材位于 assets/sfx/combat/（弹道命中音色按受击面分类：金属/软体/爆炸）。
## 测试可通过 played_log 观察播放记录（clear_played_log/reset）。

const SFX_DIR := "res://assets/sfx/combat/"

const FIRE_SOUND_BY_SCENE := {
	"res://source/match/units/Infantry.tscn": "rifle_fire",
	"res://source/match/units/Tank.tscn": "cannon_fire",
	# 新增单位必须同步登记，否则 fire_key_for() 返回空串 → **开火完全没声音**
	# （2026-09-12 用户报"重型坦克开火没有动画和声音"；装甲车同批漏登记）。
	"res://source/match/units/HeavyTank.tscn": "cannon_fire",
	"res://source/match/units/APC.tscn": "rifle_fire",
	"res://source/match/units/AntiGroundTurret.tscn": "cannon_fire",
	"res://source/match/units/AntiAirTurret.tscn": "rocket_fire",
	"res://source/match/units/Helicopter.tscn": "rocket_fire",
	"res://source/match/units/Drone.tscn": "rocket_fire",
}

## 漏登记报错去重（每个场景只报一次），见 fire_key_for()。
static var _missing_fire_sound_reported := {}

const VOLUME_BY_KEY := {
	"rifle_fire": -4.0,
	"cannon_fire": 2.0,
	"rocket_fire": -1.0,
	"impact_metal": 0.0,
	"impact_flesh": -2.0,
	"impact_explosion": 1.0,
}

## 测试观察用：最近播放的音效键（仅测试断言使用）。
static var played_log: Array[String] = []

## ---------------------------------------------------------------------------
## 开火遥测（只读观测，2026-09-11 新增）
##
## 为什么需要它：单位会**自动攻击**靠近的敌人，所以"敌我血量变化"既不能证明
## "副官在指挥交火"，也不能证明"真的开了火"；而交火目前也没有特效/音效可供
## 肉眼确认。这里给验收/自动化一个**不依赖血条、不依赖视听**的开火证据：
## 每次真实开火记录 {单位, 位置, 时刻}，只追加、不参与任何玩法结算。
## 只统计**开火**音效（`FIRE_KEYS`）；命中音挂在受击方身上，不计入开火数。
## ---------------------------------------------------------------------------
const FIRE_KEYS := ["rifle_fire", "cannon_fire", "rocket_fire"]
## 开火总数（单调递增；跨客户端/服务器各自计数）。
static var fire_total := 0
## 最近的开火记录（容量有上限，超出丢最早）。
static var shot_log: Array[Dictionary] = []
const SHOT_LOG_LIMIT := 256

static var _stream_cache := {}


## 在 host 位置播放一次音效；host 通常为单位节点，音源挂到 Match 场景避免随单位销毁。
## 注意：等距相机距战场很远（正交 size 1-20 + 俯视角距离），3D 衰减必须放大
## unit_size，否则玩家什么都听不到——衰减曲线只在近距离 gently 衰减。
static func play_at(host: Node3D, key: String) -> void:
	if key.is_empty() or not is_inside_tree_host(host):
		return
	var stream := _get_stream(key)
	if stream == null:
		return
	var player := AudioStreamPlayer3D.new()
	player.stream = stream
	player.volume_db = VOLUME_BY_KEY.get(key, -4.0)
	player.max_distance = 160.0
	player.unit_size = 60.0
	player.pitch_scale = randf_range(0.94, 1.06)  # 微随机音高避免重复发机器感
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
	_record_shot(host, key)


## 记录一次开火（见 `shot_log` 说明）。宿主就是**开火方**单位本体，
## 因此可据此判断"哪个单位在什么位置、什么时刻真的打出了子弹"。
static func _record_shot(host: Node3D, key: String) -> void:
	if not (key in FIRE_KEYS):
		return          # 命中音挂在受击方身上，不计入开火数
	fire_total += 1
	var position := host.global_position
	shot_log.append({
		"key": key,
		"unit": str(host.name),
		"pos": [position.x, position.y, position.z],
		"msec": Time.get_ticks_msec(),
		"frame": Engine.get_physics_frames(),
	})
	if shot_log.size() > SHOT_LOG_LIMIT:
		shot_log = shot_log.slice(shot_log.size() - SHOT_LOG_LIMIT)


static func clear_shot_log() -> void:
	shot_log.clear()
	fire_total = 0


## 单位开火音效键；未映射的单位（如工人）返回空串不播放。
static func fire_key_for(unit: Node3D) -> String:
	var scene := str(unit.scene_file_path)
	var key := str(FIRE_SOUND_BY_SCENE.get(scene, ""))
	# 静默改响亮（2026-09-12）：漏登记已经咬过两次（装甲车/重型坦克都是"能打但没声音"）。
	# 每个场景只报一次，避免退化成刷屏。
	if key.is_empty() and not _missing_fire_sound_reported.has(scene):
		_missing_fire_sound_reported[scene] = true
		push_error("[SFX] 单位未登记开火音效（CombatSfx.FIRE_SOUND_BY_SCENE）: %s" % scene)
	return key


## 命中音效键：武器反应类别 × 受击面（步兵=软体；金属受击不出声——钢板音已按用户要求移除）。
static func impact_key_for(reaction: String, unit: Node3D) -> String:
	if reaction != "bullet":
		return "impact_explosion"
	var is_soft_target := str(unit.scene_file_path).contains("Infantry")
	return "impact_flesh" if is_soft_target else ""


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
