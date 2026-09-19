extends Node

## 副官连通测试文案守门：权威口已挂上时不得报“没有运行中的副官”。

const AdjutantButtonScript = preload("res://source/ui/AdjutantButton.gd")

var _failures := 0


func _check(cond, label) -> void:
	if cond:
		print("  [PASS] " + str(label))
	else:
		_failures += 1
		print("  [FAIL] " + str(label))


func _ready() -> void:
	var source := FileAccess.open("res://source/ui/AdjutantButton.gd", FileAccess.READ)
	_check(source != null, "AdjutantButton.gd exists")
	if source != null:
		var text := source.get_as_text()
		_check(text.contains("format_connectivity_result"), "连通测试有可测文案函数")
		_check(text.contains("_authority_reports_attachment"), "连通测试必须问权威口")
		_check(text.contains("_should_prefer_local_dcs"), "联机客户端不得优先本机空 DCS")
		_check(text.contains("func _on_test_pressed"), "连通测试按钮仍在")

	var attached := AdjutantButtonScript.format_connectivity_result({
		"attached": true,
		"external": true,
		"networked_client": true,
		"port": 24579,
		"basis": "权威口 24579 租约单位已对齐",
	})
	_check(bool(attached.get("ok")), "外部/联机挂上应为成功")
	_check(str(attached.get("text")).begins_with("✓"), "成功文案以勾开头")
	_check(not str(attached.get("text")).contains("没有运行中的副官"), "成功时不得报没副官")

	var idle := AdjutantButtonScript.format_connectivity_result({
		"attached": false,
		"active": false,
	})
	_check(not bool(idle.get("ok")), "未挂上应为失败")
	_check(str(idle.get("text")).contains("未挂上本局"), "失败文案说明未挂上")

	var basis := AdjutantButtonScript.format_authority_basis("units", 24579)
	_check(basis.contains("24579"), "判据带端口")
	_check(not basis.contains("不一致"), "判据不写身份不一致")

	var hud_text := FileAccess.get_file_as_string("res://source/match/hud/AICommandHUD.gd")
	_check(hud_text.contains("func set_adjutant_state_text"), "岚面板必须接收真实状态")
	_check(hud_text.contains("STATE_OFFLINE"), "岚面板默认尚未启动")

	print("Adjutant connectivity smoke test completed: %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
