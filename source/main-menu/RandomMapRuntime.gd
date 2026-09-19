extends Node

## 加载页用的本机随机地图客户端：拉起 tools/mapgen、提交完整流水线、等到装进工程。
## 不打开工作台 UI。几何与默认参数对齐 MapGeneration.gd 的四人随机任务。

signal progress(text)

const GENERATED_DIR := "res://source/match/maps/generated"
const WORKBENCH_PORTS := [8766, 8765]
const WORKBENCH_PORT := 8766
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
	if OS.create_process(exe, PackedStringArray([script, "--port", str(WORKBENCH_PORT)]), false) < 0:
		return false
	_backend_launched = true
	return true


func _probe_workbench() -> bool:
	for port in WORKBENCH_PORTS:
		var url := "http://127.0.0.1:%d" % port
		var data := await _http_json(HTTPClient.METHOD_GET, url + "/api/bootstrap", {}, 1.2)
		if data.is_empty() or not data.has("version"):
			continue
		_url = url
		return true
	_url = ""
	return false


func _start_or_follow_job() -> Dictionary:
	var payload := {
		"target": "full",
		"schema_version": 2,
		"player_spacing": "any",
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
		return path
	return ""


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
