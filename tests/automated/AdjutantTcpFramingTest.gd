extends Node
## 副官 TCP 长度帧客户端解帧回归（2026-10-11，P1 corrective）。
##
## 针对**真实方法** `source/ui/AdjutantButton.gd::_tcp_json` 做分包/边界/失败回归：
## 本地 TCPServer 作可控发送端，按脚本分片（头逐字节切分、首片 65536、中文码点
## 中间切分、1MiB 上限、零/超限声明、残缺 EOF、断开、非法 JSON、超时后下一查询），
## 发送端记录每片长度/时间与总帧字节；断言实际时序与结果，不查源码文本。
##
## 协议（与 source/net/DebugControlServer.gd 输出端一致）：
##   请求：UTF-8 JSON + 换行；回应：4 字节小端 u32 正文长度 + 该长度 UTF-8 JSON。
##   长度包含服务端追加的末尾换行；换行不是接收完成判据（旧实现的误判点）。

const AdjutantButtonScript = preload("res://source/ui/AdjutantButton.gd")

var _failures := 0
var _server: TCPServer
var _port := 0
var _button: Node

# 客户端调用状态（由调用协程写入）
var _call_done := false
var _call_result: Dictionary = {}
var _call_elapsed := 0.0

# 发送端记录
var _received_requests: Array = []
var _sent_log: Array = []
var _sent_bytes_total := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _ready() -> void:
	_server = TCPServer.new()
	var err := _server.listen(0, "127.0.0.1")
	if err != OK:
		print("[FAIL] 测试发送端 TCPServer 监听随机端口失败（err=%d）" % err)
		print("Adjutant tcp framing test completed: %d failure(s)" % (_failures + 1))
		get_tree().quit(1)
		return
	_port = _server.get_local_port()
	_check(_port > 0 and _port != 24579, "测试发送端监听隔离端口 %d（与权威口 24579 不同）" % _port)

	_button = AdjutantButtonScript.new()
	_button.name = "TcpFramingProbeButton"
	add_child(_button)
	_check(_button.get_tree() == get_tree(), "探针按钮已挂树（_tcp_json 需要 get_tree 定时器）")

	await _scenario_small_with_late_body()
	await _scenario_large_first_chunk()
	await _scenario_split_header_and_cjk()
	await _scenario_size_bounds()
	await _scenario_invalid_frames()
	await _scenario_timeout_then_ok()

	print("[SENT] chunks=%d total_bytes=%d" % [_sent_log.size(), _sent_bytes_total])
	_button.free()
	_server.stop()
	print("Adjutant tcp framing test completed: %d failure(s)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


# ------------------------------------------------------------------ 构造辅助

## 构造“声明长度 = declared_len（含末尾换行）”的 JSON 正文字节：
## `{"marker":"<marker>","pad":"<A...>"}\n`，pad 精确补齐。返回 {bytes, pad_len}。
func _make_body(declared_len: int, marker: String) -> Dictionary:
	var base := JSON.stringify({"marker": marker, "pad": ""})
	var base_len := base.to_utf8_buffer().size()
	var pad_len := declared_len - 1 - base_len
	if pad_len < 0:
		push_error("declared_len 太小无法构造：%d" % declared_len)
		return {"bytes": PackedByteArray(), "pad_len": -1}
	var text := JSON.stringify({"marker": marker, "pad": "A".repeat(pad_len)})
	var bytes := text.to_utf8_buffer()
	bytes.append(10)
	return {"bytes": bytes, "pad_len": pad_len}


func _frame_header(declared_len: int) -> PackedByteArray:
	var head := PackedByteArray()
	head.resize(4)
	head.encode_u32(0, declared_len)
	return head


# ------------------------------------------------------------------ 发送/调用基建

## 服务端协程：等一个连接 → 读请求（记录，用于不重放断言）→ 按 plan 发送。
## plan 元素：{"send": PBA} / {"delay": 秒} / {"close_now": true}
func _serve(plan: Array) -> void:
	var wait_deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < wait_deadline and not _server.is_connection_available():
		await get_tree().process_frame
	if not _server.is_connection_available():
		push_warning("[framing-test] 服务端等待连接超时（plan 未执行）")
		return
	var peer := _server.take_connection()
	# 读一行请求并记录（客户端是“请求 UTF-8 JSON + 换行”）
	var buf := PackedByteArray()
	var read_deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < read_deadline and buf.find(10) < 0:
		peer.poll()
		await get_tree().process_frame
		var avail := peer.get_available_bytes()
		if avail > 0:
			var chunk = peer.get_data(avail)
			if chunk[0] == OK:
				buf.append_array(chunk[1])
	_received_requests.append(buf)
	for step in plan:
		if step.has("delay"):
			await get_tree().create_timer(float(step["delay"])).timeout
			continue
		if step.has("close_now"):
			peer.disconnect_from_host()
			return
		var data: PackedByteArray = step["send"]
		peer.poll()
		peer.put_data(data)
		_sent_log.append({"bytes": data.size(), "at_ms": Time.get_ticks_msec()})
		_sent_bytes_total += data.size()
		await get_tree().process_frame
	peer.disconnect_from_host()


## 启动一次客户端调用协程（fire-and-forget；完成后写 _call_* 状态）。
func _launch_call(payload: Dictionary) -> void:
	_call_done = false
	_call_result = {}
	_call_elapsed = 0.0
	_do_call(payload)


func _do_call(payload: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	var result: Dictionary = await _button._tcp_json(_port, payload)
	_call_elapsed = (Time.get_ticks_msec() - t0) / 1000.0
	_call_result = result
	_call_done = true


func _await_call(timeout_s: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while not _call_done and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.02).timeout
	return _call_done


# ------------------------------------------------------------------ 场景

## ① 266 字节正文：先只发 4 字节头（`0A 01 00 00`），正文延迟 0.3s。
## 旧实现“发现 0x0A 即停止收包”会在这里提前退出且不剥前缀 → 必败。
func _scenario_small_with_late_body() -> void:
	var body := _make_body(266, "late")
	var head := _frame_header(266)
	_check(head == PackedByteArray([0x0A, 0x01, 0x00, 0x00]), "266 帧头字节 = 0A 01 00 00（旧实现误判点）")
	var plan := [
		{"send": head},
		{"delay": 0.3},
		{"send": body["bytes"]},
	]
	_serve(plan)  # fire-and-forget 协程（不能赋值取返回值：协程返回 void 语义）
	_launch_call({"op": "status", "lite": true})
	await get_tree().create_timer(0.15).timeout
	_check(not _call_done, "① 266 帧：正文未到时仍等待（0.15s 检查点未返回）")
	var done := await _await_call(3.0)
	_check(done, "① 266 帧：延迟正文到达后调用完成")
	_check(_call_result.get("marker") == "late", "① 266 帧：返回原字典（marker=late）")
	_check(_call_elapsed >= 0.28, "① 266 帧：确实等待了延迟正文（%.2fs）" % _call_elapsed)


## ② 65546 字节正文（帧 65550，头 `0A 00 01 00`）：首片 65536，尾片延迟。
## 旧实现在首片到达时即退出，raw 只有 65536 < 65550 → 必败。
func _scenario_large_first_chunk() -> void:
	var res := _make_body(65546, "big")
	var body: PackedByteArray = res["bytes"]
	var expected_pad: int = res["pad_len"]
	var head := _frame_header(65546)
	_check(head == PackedByteArray([0x0A, 0x00, 0x01, 0x00]), "65546 帧头字节 = 0A 00 01 00")
	var first: PackedByteArray = head + body.slice(0, 65532)
	var rest: PackedByteArray = body.slice(65532)
	_check(first.size() == 65536 and rest.size() == 14,
		"② 切片：首片 65536 / 尾片 14（总帧 %d）" % (4 + body.size()))
	var plan := [
		{"send": first},
		{"delay": 0.25},
		{"send": rest},
	]
	_serve(plan)  # fire-and-forget 协程（不能赋值取返回值：协程返回 void 语义）
	_launch_call({"op": "status", "lite": true})
	await get_tree().create_timer(0.12).timeout
	_check(not _call_done, "② 65546 帧：首片后未提前退出（0.12s 检查点仍在等尾片）")
	var done := await _await_call(4.0)
	_check(done, "② 65546 帧：尾片到达后完成")
	_check(_call_result.get("marker") == "big", "② 65546 帧：字段一致（marker=big）")
	_check(str(_call_result.get("pad", "")).length() == expected_pad,
		"② 65546 帧：pad 长度 %d 与构造一致（逐字节一致的间接证据）" % expected_pad)
	_check(_call_elapsed >= 0.23, "② 65546 帧：等待尾片 %.2fs" % _call_elapsed)


## ③ 头逐字节（4×1）切分 + 正文在中文码点（“副”的 3 字节）中间切开。
func _scenario_split_header_and_cjk() -> void:
	var cn := "副官中文测试"
	var declared := 400
	var base := JSON.stringify({"marker": cn, "pad": ""})
	var pad_len := declared - 1 - base.to_utf8_buffer().size()
	var text := JSON.stringify({"marker": cn, "pad": "A".repeat(pad_len)})
	var bytes := text.to_utf8_buffer()
	bytes.append(10)
	var cn_offset := '{"marker":"'.length()
	var cut := cn_offset + 1  # 在“副”的第 1 字节后切开（码点跨包）
	_check(bytes.size() == declared, "③ 正文 %d 字节（含末尾换行）" % declared)
	var head := _frame_header(declared)
	var plan := [
		{"send": head.slice(0, 1)},
		{"delay": 0.03},
		{"send": head.slice(1, 2)},
		{"delay": 0.03},
		{"send": head.slice(2, 3)},
		{"delay": 0.03},
		{"send": head.slice(3, 4)},
		{"delay": 0.03},
		{"send": bytes.slice(0, cut)},
		{"delay": 0.15},
		{"send": bytes.slice(cut)},
	]
	_serve(plan)  # fire-and-forget 协程（不能赋值取返回值：协程返回 void 语义）
	_launch_call({"op": "status"})
	var done := await _await_call(3.0)
	_check(done, "③ 头 4×1 / 中文切分：调用完成")
	_check(_call_result.get("marker") == cn,
		"③ 中文码点切分：完整正确解码（marker=%s）" % str(_call_result.get("marker")))
	_check(not str(_call_result.get("marker", "")).contains(String.chr(0xFFFD)),
		"③ 无 UTF-8 替换字符")
	_check(_call_elapsed < 1.0, "③ 总延迟 %.2fs 在原 deadline 内" % _call_elapsed)


## ④ 合法小包 / 接近上限 / 当前上限（1MiB 含末尾换行）。
func _scenario_size_bounds() -> void:
	await _single_frame_call(64, "small")
	await _single_frame_call(1048570, "near")
	await _single_frame_call(1048576, "limit")


func _single_frame_call(declared: int, marker: String) -> void:
	var res := _make_body(declared, marker)
	var body: PackedByteArray = res["bytes"]
	var expected_pad: int = res["pad_len"]
	var full: PackedByteArray = _frame_header(declared) + body
	_check(full.size() == 4 + declared, "④ %s：帧总字节 = 4 + %d（含末尾换行）" % [marker, declared])
	var plan := []
	var off := 0
	# Two hard constraints (measured):
	# 1) Not faster than the client poll-read rate (~3.2MB/s @20ms), or kernel
	#    buffer backlog blocks put_data, freezes the main thread and the client
	#    timer never fires (deadlock).
	# 2) Not slower than what the client can receive within its 1.0s deadline:
	#    tiny chunks make the 1MiB frame arrive too late (test-side slowness,
	#    not a product defect). 48KB/20ms ~ 2.4MB/s: a single 48KB chunk never
	#    exceeds kernel socket buffers (no blocking), a 1MiB frame is sent in
	#    ~0.6s and fully received in ~0.7s < 1.0s. Close to the real server
	#    pacing (TCP_WRITE_BUDGET 64KiB/frame ~ 3.8MB/s).
	while off < full.size():
		var n := mini(49152, full.size() - off)
		plan.append({"send": full.slice(off, off + n)})
		plan.append({"delay": 0.02})
		off += n
	_serve(plan)  # fire-and-forget 协程（不能赋值取返回值：协程返回 void 语义）
	_launch_call({"op": "status", "lite": true})
	var done := await _await_call(8.0)
	_check(done, "④ %s：调用在 deadline 内完成" % marker)
	_check(_call_result.get("marker") == marker, "④ %s：字段一致" % marker)
	_check(str(_call_result.get("pad", "")).length() == expected_pad,
		"④ %s：pad 长度 %d 一致" % [marker, expected_pad])
	_check(_call_elapsed < 1.0, "④ %s：耗时 %.2fs < 1.0s（时限/内存有界）" % [marker, _call_elapsed])


## ⑤ 零长度 / 超上限声明 / 残缺头 / 残缺正文 / 连接即断 / 完整帧但非法 JSON。
func _scenario_invalid_frames() -> void:
	await _expect_failure([{"send": _frame_header(0)}], "⑤ 零长度声明")
	await _expect_failure([{"send": _frame_header(1048577)}], "⑤ 超上限声明(1048577)")
	await _expect_failure([{"send": _frame_header(266).slice(0, 2)}, {"close_now": true}],
		"⑤ 残缺头 2 字节 + 断开")
	var res := _make_body(400, "cut")
	var part: PackedByteArray = res["bytes"]
	await _expect_failure([{"send": _frame_header(400)}, {"send": part.slice(0, 200)},
		{"close_now": true}], "⑤ 残缺正文（200/400）+ 断开")
	await _expect_failure([{"close_now": true}], "⑤ 连接后立即断开")
	var bad := "not a json at all\n".to_utf8_buffer()
	await _expect_failure([{"send": _frame_header(bad.size())}, {"send": bad}],
		"⑤ 完整帧 + 非法 JSON")


func _expect_failure(plan: Array, label: String) -> void:
	_serve(plan)  # fire-and-forget 协程（不能赋值取返回值：协程返回 void 语义）
	_launch_call({"op": "status"})
	var done := await _await_call(3.5)
	_check(done, "%s：客户端有界返回（未无限等待）" % label)
	_check(_call_result.is_empty(), "%s：未返回成功（结果为空字典）" % label)


## ⑥ 超时（服务端只发 2 字节，不完整头）后的下一次合法查询；不自动重放。
func _scenario_timeout_then_ok() -> void:
	var before_requests := _received_requests.size()
	_serve([{"send": PackedByteArray([0x01, 0x02])}, {"delay": 2.5}])
	_launch_call({"op": "first_timeout"})
	var done1 := await _await_call(3.0)
	_check(done1, "⑥ 超时场景：客户端有界返回")
	_check(_call_result.is_empty(), "⑥ 超时场景：返回空（非成功）")
	_check(_call_elapsed >= 0.9 and _call_elapsed <= 1.8,
		"⑥ 超时合同：实测 %.2fs（≈1.0s 原合同，未扩大）" % _call_elapsed)

	var res := _make_body(300, "second")
	_serve([{"send": _frame_header(300)}, {"send": res["bytes"]}])
	_launch_call({"op": "second_ok"})
	var done2 := await _await_call(3.0)
	_check(done2 and _call_result.get("marker") == "second",
		"⑥ 超时后的下一次合法查询成功（面板可继续更新）")

	var got := _received_requests.size() - before_requests
	_check(got == 2, "⑥ 不自动重放：服务端收到请求 %d 条（期望 2：超时请求 + 新请求）" % got)
