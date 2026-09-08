extends Node

## UI 音效常驻播放器（2026-09-08 试听五件套）：
## click（所有按钮按下）/ hover（悬停）/ select（选中单位）/
## place（放置建筑）/ error（命令被拒）。
## 按音效包规则：变体轮换且不连续重复同一变体；AudioStreamPlayer 非 3D；
## 走 SFX 总线 0dB；音高散布 ≤0.05（变体自带散布）。
## 自动挂接：任何 BaseButton 进树即绑定 hover/click，无需逐场景接线。

const SFX_DIR := "res://assets/sfx/ui/"
const BANKS := {
	"click": 5,
	"hover": 3,
	"select": 4,
	"place": 4,
	"error": 3,
}
const PITCH_SPREAD := 0.04

## 测试观察用：最近播放的音效键。
static var played_log: Array[String] = []

var _banks := {}
var _last_index := {}
var _player: AudioStreamPlayer


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for key in BANKS:
		var streams: Array[AudioStream] = []
		for index in range(1, int(BANKS[key]) + 1):
			var path := "%s%s_%02d.wav" % [SFX_DIR, key, index]
			if ResourceLoader.exists(path):
				streams.append(load(path))
		_banks[key] = streams
	_player = AudioStreamPlayer.new()
	_player.name = "Player"
	_player.bus = "SFX"
	add_child(_player)
	get_tree().node_added.connect(_on_node_added)
	MatchSignals.unit_selected.connect(func(_unit): play("select"))


## 播放指定角色：随机变体且不连续重复。
func play(key: String) -> void:
	if not _banks.has(key) or _banks[key].is_empty():
		return
	var streams: Array[AudioStream] = _banks[key]
	var index := randi() % streams.size()
	if index == int(_last_index.get(key, -1)):
		index = (index + 1) % streams.size()
	_last_index[key] = index
	_player.stream = streams[index]
	_player.pitch_scale = randf_range(1.0 - PITCH_SPREAD, 1.0 + PITCH_SPREAD)
	_player.play()
	played_log.append(key)


## 任何按钮进树自动绑定悬停/点击音。
func _on_node_added(node: Node):
	if node is BaseButton:
		node.mouse_entered.connect(play.bind("hover"))
		node.pressed.connect(play.bind("click"))
