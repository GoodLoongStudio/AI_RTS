extends Node

## 音频设置守门测试（2026-09-23 用户要求"设置要能关闭游戏的声音"）。
##
## 守门不变式：
## ① 总开关关闭 → Master 总线 mute（音乐/语音/音效一次全关）；
## ② 总开关开启 → Master 取消 mute；
## ③ 分类音量 0 → 对应总线 mute（Music/Voice/SFX 三条都接管）；
## ④ 保存后重新加载 → 设置原样恢复（持久化不丢类型）；
## ⑤ SFX 总线必须有音量入口（此前完全没接管，用户关不掉游戏音效）。

const AUDIO_CONFIG_PATH := "user://audio.cfg"

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _bus_muted(bus_name: String) -> bool:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return false
	return AudioServer.is_bus_mute(index)


func _ready():
	# 清掉可能存在的旧配置，保证测试从默认态开始
	if FileAccess.file_exists(AUDIO_CONFIG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(AUDIO_CONFIG_PATH))
	Globals._apply_audio_volumes()

	# --- ① 默认应有声 ---
	_check(Globals.is_sound_enabled(), "默认应有声（sound_enabled 默认 true）")
	_check(not _bus_muted("Master"), "默认 Master 总线不静音")

	# --- ② 总开关关闭 → Master 静音 ---
	Globals.set_sound_enabled(false)
	_check(not Globals.is_sound_enabled(), "关闭总开关后 is_sound_enabled=false")
	_check(_bus_muted("Master"), "关闭总开关后 Master 总线必须静音（一次全关）")

	# --- ③ 总开关开启 → 恢复 ---
	Globals.set_sound_enabled(true)
	_check(not _bus_muted("Master"), "开启总开关后 Master 必须取消静音")

	# --- ④ 分类音量 0 → 对应总线静音（三条都接管） ---
	Globals.set_audio_volume("music_volume", 0.0)
	_check(_bus_muted("Music"), "音乐音量 0% → Music 总线静音")
	Globals.set_audio_volume("voice_volume", 0.0)
	_check(_bus_muted("Voice"), "语音音量 0% → Voice 总线静音")
	Globals.set_audio_volume("sfx_volume", 0.0)
	_check(_bus_muted("SFX"), "音效音量 0% → SFX 总线静音（本次新增接管）")
	Globals.set_audio_volume("sfx_volume", 1.0)
	_check(not _bus_muted("SFX"), "音效音量恢复 100% → SFX 取消静音")
	Globals.set_audio_volume("music_volume", 0.9)
	Globals.set_audio_volume("voice_volume", 1.0)

	# --- ⑤ 持久化：保存 → 改掉 → 重载 → 恢复 ---
	Globals.set_sound_enabled(false)
	Globals.set_audio_volume("sfx_volume", 0.5)
	Globals.save_audio_options()
	# 改掉当前状态模拟"重启后读到旧值"
	Globals.set_sound_enabled(true)
	Globals.set_audio_volume("sfx_volume", 1.0)
	var reloaded: Dictionary = Globals._load_audio_options()
	_check(bool(reloaded.get("sound_enabled", true)) == false,
		"重载后总开关应保持关闭（bool 类型不能漂成数字）")
	_check(absf(float(reloaded.get("sfx_volume", 0.0)) - 0.5) < 0.001,
		"重载后音效音量应保持 0.5")
	# 恢复现场
	Globals.set_sound_enabled(true)
	Globals.set_audio_volume("sfx_volume", 1.0)
	Globals.save_audio_options()
	if FileAccess.file_exists(AUDIO_CONFIG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(AUDIO_CONFIG_PATH))

	if _failures == 0:
		print("Audio settings: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Audio settings: %d failure(s)" % _failures)
		get_tree().quit(1)
