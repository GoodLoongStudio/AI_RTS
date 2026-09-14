extends Node

## 中文播报完整性冒烟测试（2026-09-14）：
## 1) 所有可生产单位类型都有专属选中/确认语音映射；
## 2) 所有建筑类型都有选中语音映射；
## 3) 全部音频流可加载且非空；
## 4) 控制器按 unit_type_id 取流（含兜底）。

const SmokeTestWarmup = preload("res://tests/automated/SmokeTestWarmup.gd")

var _failures := 0


func _ready() -> void:
	var narrator = Constants.Match.VoiceNarrator

	# balance 中可生产的单位类型（排除建筑）
	var balance_text := FileAccess.get_file_as_string("res://config/balance/demo.balance.v1.json")
	var balance: Dictionary = JSON.parse_string(balance_text)
	var produced_units: Array[String] = []
	for p in balance["productions"]:
		var unit_id: String = p["productUnitTypeId"]
		if not produced_units.has(unit_id):
			produced_units.append(unit_id)
	for unit_id in produced_units:
		if narrator.UNIT_HELLO_MAPPING.has(unit_id):
			continue
		_failures += 1
		push_error("VoiceMapping unit %s 缺少选中语音" % unit_id)
		print("FAIL: unit %s 缺少选中语音映射" % unit_id)
		if not narrator.UNIT_ACK_1_MAPPING.has(unit_id):
			_failures += 1
			print("FAIL: unit %s 缺少 ack1 语音映射" % unit_id)
		if not narrator.UNIT_ACK_2_MAPPING.has(unit_id):
			_failures += 1
			print("FAIL: unit %s 缺少 ack2 语音映射" % unit_id)

	# 建筑选中语音
	for c in balance["constructions"]:
		var cid: String = c["id"]
		if not narrator.STRUCTURE_HELLO_MAPPING.has(cid):
			_failures += 1
			print("FAIL: structure %s 缺少选中语音映射" % cid)

	# 音频流全部可加载
	for mapping in [
		narrator.UNIT_HELLO_MAPPING,
		narrator.UNIT_ACK_1_MAPPING,
		narrator.UNIT_ACK_2_MAPPING,
		narrator.STRUCTURE_HELLO_MAPPING,
	]:
		for key in mapping:
			var stream: AudioStream = mapping[key]
			if stream == null or stream.get_length() <= 0.1:
				_failures += 1
				print("FAIL: 语音流为空或过短: %s" % key)
	for key in narrator.EVENT_TO_ASSET_MAPPING:
		var stream: AudioStream = narrator.EVENT_TO_ASSET_MAPPING[key]
		if stream == null or stream.get_length() <= 0.1:
			_failures += 1
			print("FAIL: 旁白流为空或过短: event=%s" % key)

	# 按类型取流（含兜底）
	if narrator.unit_voice("sniper", narrator.Events.UNIT_HELLO) != narrator.UNIT_HELLO_MAPPING["sniper"]:
		_failures += 1
		print("FAIL: unit_voice 未能按类型返回狙击兵语音")
	if narrator.unit_voice("unknown_type", narrator.Events.UNIT_HELLO) != narrator.FALLBACK_HELLO:
		_failures += 1
		print("FAIL: 未知类型未回落到步兵兜底语音")

	print("Chinese voice mapping smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
