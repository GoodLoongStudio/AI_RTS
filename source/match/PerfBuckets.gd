extends RefCounted

## 诊断分段计时。AIRTS_MOV_DIAG 未开时 enabled 为 false，调用方只做一次布尔判断。
## 物理步界用 SceneTree.physics_frame（在脚本之前发出）。
## 空闲帧界用 SceneTree.process_frame（固定步插值之后、_process 之前）。

static var enabled := false
static var buckets := {}
static var bucket_n := {}

static var _step_origin_us := 0
static var _match_out_us := 0
static var _cb_us := 0
static var _cb_end_us := 0
static var _saw_process_frame := false
static var _process_origin_us := 0
static var _process_end_us := 0

static var step_n := 0
static var sum_script_us := 0
static var sum_cb_us := 0
static var sum_step_tail_us := 0
static var step_tail_n := 0
static var sum_boundary_us := 0
static var boundary_n := 0
static var sum_boundary_script_us := 0
static var sum_boundary_draw_us := 0
static var sum_proc_script_us := 0
static var proc_n := 0
static var max_script_us := 0
static var max_cb_us := 0
static var max_tail_us := 0
static var max_pre_idle_us := 0
static var max_proc_us := 0
static var max_sync_us := 0
static var max_draw_us := 0
static var max_post_draw_us := 0
static var sum_sync_us := 0
static var sum_draw_us := 0
static var sum_post_draw_us := 0
static var draw_n := 0
static var _pre_draw_us := 0
static var _post_draw_us := 0
static var _after_timers_us := 0
static var _after_messages_us := 0
static var sum_mid_us := 0
static var sum_late_us := 0
static var max_mid_us := 0
static var max_late_us := 0


static func reset() -> void:
	enabled = OS.get_environment("AIRTS_MOV_DIAG") != ""
	buckets.clear()
	bucket_n.clear()
	_step_origin_us = 0
	_match_out_us = 0
	_cb_us = 0
	_cb_end_us = 0
	_saw_process_frame = false
	_process_origin_us = 0
	_process_end_us = 0
	step_n = 0
	sum_script_us = 0
	sum_cb_us = 0
	sum_step_tail_us = 0
	step_tail_n = 0
	sum_boundary_us = 0
	boundary_n = 0
	sum_boundary_script_us = 0
	sum_boundary_draw_us = 0
	sum_proc_script_us = 0
	proc_n = 0
	max_script_us = 0
	max_cb_us = 0
	max_tail_us = 0
	max_pre_idle_us = 0
	max_proc_us = 0
	max_sync_us = 0
	max_draw_us = 0
	max_post_draw_us = 0
	sum_sync_us = 0
	sum_draw_us = 0
	sum_post_draw_us = 0
	draw_n = 0
	_pre_draw_us = 0
	_post_draw_us = 0
	_after_timers_us = 0
	sum_mid_us = 0
	sum_late_us = 0
	max_mid_us = 0
	max_late_us = 0
	_after_messages_us = 0


static func add(key: String, dt: int) -> void:
	if not enabled or dt < 0:
		return
	buckets[key] = int(buckets.get(key, 0)) + dt
	bucket_n[key] = int(bucket_n.get(key, 0)) + 1


static func on_match_out() -> void:
	if not enabled:
		return
	_match_out_us = Time.get_ticks_usec()


static func on_callback(dt: int) -> void:
	if not enabled:
		return
	_cb_us += dt
	_cb_end_us = Time.get_ticks_usec()


static func on_process_frame() -> void:
	if not enabled:
		return
	_saw_process_frame = true
	_process_origin_us = Time.get_ticks_usec()


static func on_process_end() -> void:
	if not enabled or _process_origin_us <= 0:
		return
	_process_end_us = Time.get_ticks_usec()


static func on_after_messages() -> void:
	if not enabled:
		return
	_after_messages_us = Time.get_ticks_usec()


static func on_after_timers() -> void:
	if not enabled:
		return
	_after_timers_us = Time.get_ticks_usec()


static func on_pre_draw() -> void:
	if not enabled:
		return
	_pre_draw_us = Time.get_ticks_usec()


static func on_post_draw() -> void:
	if not enabled or _pre_draw_us <= 0:
		return
	_post_draw_us = Time.get_ticks_usec()
	var draw_us := int(_post_draw_us - _pre_draw_us)
	sum_draw_us += draw_us
	draw_n += 1
	if draw_us > max_draw_us:
		max_draw_us = draw_us


static func on_physics_frame() -> void:
	if not enabled:
		return
	var now := Time.get_ticks_usec()
	if _step_origin_us > 0:
		var script_us := 0
		if _match_out_us > _step_origin_us:
			script_us = int(_match_out_us - _step_origin_us)
		var after_script := _step_origin_us + script_us
		if _cb_end_us > after_script:
			after_script = _cb_end_us
		var tail := int(now - after_script)
		if _saw_process_frame:
			var proc_script := 0
			if _process_end_us > _process_origin_us and _process_origin_us > 0:
				proc_script = int(_process_end_us - _process_origin_us)
			var pre_idle := 0
			if _process_origin_us > after_script:
				pre_idle = int(_process_origin_us - after_script)
			var draw_us := 0
			if _process_end_us > 0 and now > _process_end_us:
				draw_us = int(now - _process_end_us)
			sum_boundary_us += script_us + tail
			sum_boundary_script_us += proc_script
			sum_proc_script_us += proc_script
			proc_n += 1
			if proc_script > max_proc_us:
				max_proc_us = proc_script
			sum_boundary_draw_us += draw_us
			if pre_idle > max_pre_idle_us:
				max_pre_idle_us = pre_idle
			add("pre_idle", pre_idle)
			var sync_us := 0
			if _pre_draw_us > _process_end_us and _process_end_us > 0:
				sync_us = int(_pre_draw_us - _process_end_us)
			var msg_us := 0
			if _after_messages_us > _process_end_us and _process_end_us > 0:
				msg_us = int(_after_messages_us - _process_end_us)
			var xform_us := 0
			if _after_timers_us > _after_messages_us and _after_messages_us > 0:
				xform_us = int(_after_timers_us - _after_messages_us)
			add("msg_flush", msg_us)
			add("xform_flush", xform_us)
			var mid_us := msg_us + xform_us
			var late_us := 0
			if _pre_draw_us > _after_timers_us and _after_timers_us > 0:
				late_us = int(_pre_draw_us - _after_timers_us)
			sum_mid_us += mid_us
			sum_late_us += late_us
			if mid_us > max_mid_us:
				max_mid_us = mid_us
			if late_us > max_late_us:
				max_late_us = late_us
			var post_us := 0
			if _post_draw_us > 0 and now > _post_draw_us:
				post_us = int(now - _post_draw_us)
			sum_sync_us += sync_us
			sum_post_draw_us += post_us
			if sync_us > max_sync_us:
				max_sync_us = sync_us
			if post_us > max_post_draw_us:
				max_post_draw_us = post_us
			boundary_n += 1
		else:
			sum_step_tail_us += tail
			step_tail_n += 1
			if tail > max_tail_us:
				max_tail_us = tail
		sum_script_us += script_us
		sum_cb_us += _cb_us
		if script_us > max_script_us:
			max_script_us = script_us
		if _cb_us > max_cb_us:
			max_cb_us = _cb_us
		step_n += 1
	_step_origin_us = now
	_match_out_us = 0
	_cb_us = 0
	_cb_end_us = 0
	_saw_process_frame = false
	_process_origin_us = 0
	_process_end_us = 0
	_pre_draw_us = 0
	_post_draw_us = 0
	_after_timers_us = 0
	_after_messages_us = 0


static func line() -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("steps=%d script_us=%d max_script=%d cb_us=%d max_cb=%d step_tail_us=%d max_tail=%d step_tail_n=%d boundary_n=%d proc_script_us=%d max_proc=%d proc_n=%d pre_idle_max=%d mid_us=%d max_mid=%d late_us=%d max_late=%d sync_us=%d max_sync=%d draw_us=%d max_draw=%d draw_n=%d post_draw_us=%d max_post=%d after_proc_us=%d" % [
		step_n, sum_script_us, max_script_us, sum_cb_us, max_cb_us,
		sum_step_tail_us, max_tail_us, step_tail_n,
		boundary_n, sum_proc_script_us, max_proc_us, proc_n, max_pre_idle_us,
		sum_mid_us, max_mid_us, sum_late_us, max_late_us,
		sum_sync_us, max_sync_us, sum_draw_us, max_draw_us, draw_n,
		sum_post_draw_us, max_post_draw_us, sum_boundary_draw_us,
	])
	var keys: Array = buckets.keys()
	keys.sort()
	for key in keys:
		parts.append("%s_us=%d n=%d" % [str(key), int(buckets[key]), int(bucket_n.get(key, 0))])
	return " ".join(parts)
