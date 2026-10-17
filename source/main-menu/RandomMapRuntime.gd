extends Node

## 加载页用的本机随机地图客户端：拉起 tools/mapgen、提交完整流水线、等到装进工程。
## 不打开工作台 UI。几何与默认参数对齐 MapGeneration.gd 的四人随机任务。

signal progress(text)

const GENERATED_DIR := "res://source/match/maps/generated"
const REQUIRED_WORLD_SIZE := Vector2(512, 512)
const EXPORT_CONTRACT_VERSION := "world-meters-v2"
const WORKBENCH_PORTS := [8766, 8765, 8767, 8768]
const POLL_INTERVAL_S := 1.0
const BOOT_WAIT_S := 12.0
const GENERATE_TIMEOUT_S := 900.0
const CONTROL_DEFAULTS := {
	"river_layout": 2,
	"river_enabled": 1,
	"lake_count": 0,
	"lake_area": 5000,
	"neutral_plateau_scale": 1.7,
	"plateau_max": 8,
	"landform_elongation": 1.2,
	"landform_recess": 0.2,
	"landform_softness": 0.16,
	"plateau_ramp_width": 8,
	"river_width": 18,
	"river_bend_scale": 1.0,
	"river_crossings": 6,
	"obstacle_percent": 40,
	"cover_cluster_max": 10,
	"layout_attempts": 4,
}

var _http: HTTPRequest
var _url := ""
var _backend_launched := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = 2.0
	add_child(_http)


## 生成一张随机四人完整图。成功返回 {ok, path}，失败返回 {ok:false, error}。
func generate_random_full() -> Dictionary:
	progress.emit("正在连接本机地图生成服务…")
	if not await _ensure_workbench():
		return _fail("本机地图生成服务没有起来。请确认 tools/mapgen/.venv-g2 已安装。")
	progress.emit("正在提交随机地图任务…")
	var job := await _start_or_follow_job()
	if job.is_empty() or str(job.get("id", "")).is_empty():
		return _fail(str(job.get("error", "工作台没有接下生成任务。")))
	var job_id := str(job["id"])
	var started := Time.get_ticks_msec() / 1000.0
	while true:
		var elapsed := Time.get_ticks_msec() / 1000.0 - started
		if elapsed > GENERATE_TIMEOUT_S:
			return _fail("随机地图生成超时（超过 15 分钟）。")
		var status := str(job.get("status", ""))
		if status == "done":
			var path := await _wait_installed_path(job)
			if path.is_empty():
				return _fail("地图生成完成，但工程里还没有场景文件。")
			return {"ok": true, "path": path, "error": ""}
		if status == "error":
			return _fail(str(job.get("error", "随机地图生成失败。")))
		_emit_job_progress(job, elapsed)
		await get_tree().create_timer(POLL_INTERVAL_S).timeout
		job = await _http_json(HTTPClient.METHOD_GET, "%s/api/jobs/%s" % [_url, job_id], {}, 2.0)
		if job.is_empty():
			continue
	return _fail("随机地图生成中断。")


func _ensure_workbench() -> bool:
	if await _probe_workbench():
		return true
	progress.emit("正在启动本机地图生成服务…")
	if not _launch_backend():
		return false
	var waited := 0.0
	while waited < BOOT_WAIT_S:
		await get_tree().create_timer(1.0).timeout
		waited += 1.0
		if await _probe_workbench():
			return true
	return false


func _launch_backend() -> bool:
	if _backend_launched:
		return true
	_backend_launched = launch_compatible_backend()
	return _backend_launched


static func launch_compatible_backend() -> bool:
	var root := ProjectSettings.globalize_path("res://tools/mapgen").trim_suffix("/").trim_suffix("\\")
	var script := root.path_join("serve_g2.py")
	if not FileAccess.file_exists(script):
		return false
	var scripts := root.path_join(".venv-g2").path_join("Scripts")
	var pyw := scripts.path_join("pythonw.exe")
	var py := scripts.path_join("python.exe")
	var exe := pyw if FileAccess.file_exists(pyw) else py
	if not FileAccess.file_exists(exe):
		return false
	# An old service can stay running; never kill it or try to bind its port.
	var free_port := -1
	for candidate in WORKBENCH_PORTS:
		var reservation := TCPServer.new()
		if reservation.listen(candidate, "127.0.0.1") == OK:
			reservation.stop()
			free_port = candidate
			break
	if free_port < 0:
		return false
	if OS.create_process(exe, PackedStringArray([script, "--port", str(free_port)]), false) < 0:
		return false
	return true


func _probe_workbench() -> bool:
	for port in WORKBENCH_PORTS:
		var url := "http://127.0.0.1:%d" % port
		var data := await _http_json(HTTPClient.METHOD_GET, url + "/api/bootstrap", {}, 1.2)
		if data.is_empty() or not data.has("version"):
			continue
		if not compatible_bootstrap(data):
			continue
		_url = url
		return true
	_url = ""
	return false


static func compatible_bootstrap(data: Dictionary) -> bool:
	var fixed: Dictionary = data.get("fixed", {})
	return has_required_world_size(fixed.get("world_size_m", [])) and fixed.get("export_contract_version", "") == EXPORT_CONTRACT_VERSION


static func has_required_world_size(value: Variant) -> bool:
	# JSON numbers decode as floats; Array equality also compares element types.
	if not value is Array or value.size() != 2:
		return false
	for extent in value:
		if typeof(extent) not in [TYPE_INT, TYPE_FLOAT] or float(extent) != 512.0:
			return false
	return true


func _start_or_follow_job() -> Dictionary:
	var payload := {
		"target": "full",
		"schema_version": 2,
		"required_world_size_m": [512, 512],
		"player_spacing": "any",
		# 跳过工作台的 ENGINE 验收（三张截图 + 导航检查要另起 Godot 进程，
		# 实测 60s+）：加载页干等没有收益，地图在 G4 阶段已装进工程，
		# 能不能玩马上由玩家实局检验（失败还有兜底图）。浏览器工作台不带此标志。
		"skip_engine_check": true,
		"controls": CONTROL_DEFAULTS.duplicate(),
	}
	var job := await _http_json(HTTPClient.METHOD_POST, _url + "/api/generate", payload, 8.0)
	if not job.is_empty() and not str(job.get("id", "")).is_empty():
		return job
	var boot := await _http_json(HTTPClient.METHOD_GET, _url + "/api/bootstrap", {}, 1.2)
	var active := str(boot.get("active", ""))
	if active.is_empty():
		return job
	progress.emit("工作台已有任务，正在等待它完成…")
	return await _http_json(HTTPClient.METHOD_GET, "%s/api/jobs/%s" % [_url, active], {}, 2.0)


func _wait_installed_path(job: Dictionary) -> String:
	for _i in range(8):
		var path := installed_map_path(job)
		if not path.is_empty():
			return path
		await get_tree().create_timer(0.4).timeout
	return installed_map_path(job)


static func installed_map_path(job: Dictionary) -> String:
	var map_id := str(job.get("map_id", ""))
	if map_id.is_empty():
		return ""
	var path := "%s/%s/map_%s.tscn" % [GENERATED_DIR, map_id, map_id]
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path) or FileAccess.file_exists(abs_path):
		var index_path := path.get_base_dir().path_join("map_index.json")
		if not FileAccess.file_exists(index_path):
			return ""
		var index = JSON.parse_string(FileAccess.get_file_as_string(index_path))
		if not index is Dictionary or not has_required_world_size(index.get("size", [])) or index.get("export_contract_version", "") != EXPORT_CONTRACT_VERSION:
			return ""
		var packed := load(path) as PackedScene
		if packed == null:
			return ""
		return path if scene_matches_world_contract(packed) else ""
	return ""


static func scene_matches_world_contract(packed: PackedScene) -> bool:
	var state := packed.get_state()
	var size_ok := false
	var terrain_span_ok := false
	var terrain_scale_ok := false
	for prop in state.get_node_property_count(0):
		var key := state.get_node_property_name(0, prop)
		var value = state.get_node_property_value(0, prop)
		if key == "size":
			size_ok = value == REQUIRED_WORLD_SIZE
		elif key == "scale" and value != Vector3.ONE:
			return false
	for node in state.get_node_count():
		if str(state.get_node_path(node)).trim_prefix("./") != "Geometry/Terrain":
			continue
		for prop in state.get_node_property_count(node):
			var key := state.get_node_property_name(node, prop)
			var value = state.get_node_property_value(node, prop)
			if key == "semantic_span":
				terrain_span_ok = is_equal_approx(float(value), 512.0)
			elif key == "world_scale":
				terrain_scale_ok = is_equal_approx(float(value), 1.0)
	return size_ok and terrain_span_ok and terrain_scale_ok


func _emit_job_progress(job: Dictionary, elapsed: float) -> void:
	var info: Dictionary = job.get("progress", {})
	if not info is Dictionary:
		info = {}
	var stage := str(info.get("stage", ""))
	var phase := str(info.get("phase", ""))
	var title := "正在生成随机地图"
	if not stage.is_empty() and not phase.is_empty():
		title = "%s · %s" % [stage, phase]
	elif not phase.is_empty():
		title = phase
	elif not stage.is_empty():
		title = stage
	progress.emit("%s（已等待 %.0f 秒）" % [title, elapsed])


func _http_json(method: HTTPClient.Method, url: String, body: Dictionary = {}, timeout_sec := 2.0) -> Dictionary:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	_http.timeout = timeout_sec
	var headers := PackedStringArray()
	var payload := ""
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	if _http.request(url, headers, method, payload) != OK:
		return {}
	var completed: Array = await _http.request_completed
	if int(completed[0]) != HTTPRequest.RESULT_SUCCESS:
		return {}
	var raw: PackedByteArray = completed[3]
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _fail(message: String) -> Dictionary:
	return {"ok": false, "path": "", "error": message}
