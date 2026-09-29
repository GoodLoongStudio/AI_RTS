extends Node

## 音频设置持久化端到端验证（2026-09-26 用户要求）：
##   ① "游戏启动默认是关闭声音的"——无 audio.cfg 时按静音启动；
##   ② "设置里的保存一定要能生效"——走**真实 Options UI**（勾选总开关 + 点保存按钮），
##      audio.cfg 必须落盘，重新按启动路径加载后状态保持。
## 测试结束把 audio.cfg 恢复为"不存在"（出厂状态 = 默认静音），不污染用户机器。

const OptionsScene := preload("res://source/main-menu/Options.tscn")

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _cfg_path() -> String:
	return OS.get_user_data_dir() + "/audio.cfg"


func _reload_as_boot() -> void:
	# 等价于进程重启的加载路径：Globals.audio_options 的初始化 + _ready 各做一步。
	Globals.audio_options = Globals._load_audio_options()
	Globals._apply_audio_volumes()


func _ready():
	await get_tree().process_frame
	await get_tree().process_frame

	var master := AudioServer.get_bus_index("Master")
	var had_cfg: bool = FileAccess.file_exists(_cfg_path())
	var saved_cfg: String = ""
	if had_cfg:
		saved_cfg = FileAccess.get_file_as_string(_cfg_path())
	print("[INFO] audio.cfg 存在=", had_cfg)

	# ---- ① 出厂状态（无 audio.cfg）→ 默认静音 ----
	if had_cfg:
		DirAccess.remove_absolute(_cfg_path())
	_reload_as_boot()
	_check(not Globals.is_sound_enabled(),
		"出厂状态（无配置）应默认静音（is_sound_enabled=false）")
	_check(AudioServer.is_bus_mute(master),
		"出厂状态 Master 总线应处于静音")

	# ---- ② 真实 UI 流程：取消勾选（开声）→ 点保存 → 落盘 ----
	var options_ui: Control = OptionsScene.instantiate()
	add_child(options_ui)
	await get_tree().process_frame
	var toggle: CheckBox = options_ui.find_child("SoundEnabledToggle", true, false) \
		as CheckBox
	_check(toggle != null, "设置页应有声音总开关")
	_check(toggle != null and toggle.button_pressed,
		"打开设置页时总开关应呈'已勾选（静音）'状态")
	if toggle == null:
		_finish()
		return
	toggle.button_pressed = false          # 用户取消勾选 = 开声音
	await get_tree().process_frame
	_check(Globals.is_sound_enabled(), "取消勾选后应立即有声（实时生效）")
	_check(not AudioServer.is_bus_mute(master), "取消勾选后 Master 应解除静音")

	var save_button: Button = options_ui.find_child("SaveButton", true, false) as Button
	_check(save_button != null, "设置页应有保存按钮")
	if save_button != null:
		save_button.pressed.emit()         # 玩家点"保存设置"
		await get_tree().process_frame
	_check(FileAccess.file_exists(_cfg_path()), "点保存后 audio.cfg 应落盘")

	# ---- ③ 模拟重启：按启动路径重新加载，选择必须保持 ----
	_reload_as_boot()
	_check(Globals.is_sound_enabled(), "重启加载后声音应保持开启（保存生效）")
	_check(not AudioServer.is_bus_mute(master), "重启加载后 Master 应有声")

	# ---- ④ 反向：勾选（静音）→ 立即落盘（不走防抖）→ 重启仍静音 ----
	toggle.button_pressed = true
	await get_tree().process_frame
	_check(FileAccess.file_exists(_cfg_path()), "勾选静音应立即落盘（不等防抖）")
	_check(not Globals.is_sound_enabled(), "勾选后应立即静音")
	_reload_as_boot()
	_check(not Globals.is_sound_enabled(), "重启加载后应保持静音（保存生效）")
	_check(AudioServer.is_bus_mute(master), "重启加载后 Master 应静音")

	options_ui.queue_free()

	# ---- 恢复现场：回到测试前的 audio.cfg 状态 ----
	if had_cfg:
		var f := FileAccess.open(_cfg_path(), FileAccess.WRITE)
		f.store_string(saved_cfg)
		f.close()
	else:
		if FileAccess.file_exists(_cfg_path()):
			DirAccess.remove_absolute(_cfg_path())
	_reload_as_boot()
	print("[INFO] 现场已恢复：audio.cfg 存在=", FileAccess.file_exists(_cfg_path()),
		" 当前静音=", not Globals.is_sound_enabled())
	_finish()


func _finish() -> void:
	if _failures == 0:
		print("Audio persist: 0 failure(s)")
		get_tree().quit(0)
	else:
		print("Audio persist: %d failure(s)" % _failures)
		get_tree().quit(1)
