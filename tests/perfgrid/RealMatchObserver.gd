extends Node

const OUT := "G:/AIRTS/tmp_logs/report_probe"
const USER_FILES := ["user://growth_state.json", "user://player_profile.json",
	"user://match_reports.json"]

const POLL_INTERVAL_S := 5.0
const MAX_WAIT_S := 1200.0

var _store: Node
var _tmp_dir := ""
var _snapshot_dir := ""
var _poll_accum := 0.0
var _waited := 0.0
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(OUT)
	_tmp_dir = ProjectSettings.globalize_path("user://").get_base_dir().path_join(
		"report_probe_tmp")
	DirAccess.make_dir_recursive_absolute(_tmp_dir)
	_snapshot_dir = OUT.path_join("user_snapshot")
	DirAccess.make_dir_recursive_absolute(_snapshot_dir)
	for file in USER_FILES:
		var abs := ProjectSettings.globalize_path(file)
		if FileAccess.file_exists(file):
			_copy_file(abs, _snapshot_dir.path_join(abs.get_file()))
	_store = get_node_or_null("/root/MatchReportStore")
	_store.configure_paths(_tmp_dir.path_join("reports.json"), _tmp_dir.path_join("legacy.json"))
	_store.load_all()
	print("[PROBE] 报告存档隔离到 %s；成长存档已快照" % _tmp_dir)


func _process(delta: float) -> void:
	if _done or _store == null:
		return
	_poll_accum += delta
	if _poll_accum < POLL_INTERVAL_S:
		return
	_poll_accum = 0.0
	_waited += POLL_INTERVAL_S
	var reports: Array = _store.get("reports")
	var kids := PackedStringArray()
	for kid in _store.get_children():
		kids.append(str(kid.name))
	print("[PROBE] t=%.0fs store_kids=%s reports=%d last_id=%s cur=%s" % [
		_waited, str(kids), reports.size(), str(_store.get("last_report_id")),
		str(get_tree().current_scene.name) if get_tree().current_scene != null else "null"])
	var report_id := str(_store.get("last_report_id"))
	if report_id.is_empty():
		if _waited >= MAX_WAIT_S:
			_done = true
			push_warning("[PROBE] %.0fs 内未等到对局报告" % MAX_WAIT_S)
			_restore_user_files()
			get_tree().quit(0)
		return
	var found: Dictionary = _store.get_report(report_id)
	if found.is_empty():
		return
	var path := OUT.path_join("real_report.json")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(found, "  "))
	file.close()
	_done = true
	print("[PROBE] 报告已导出：%s（outcome=%s duration=%s）" % [
		path, str(found.get("outcome", null)), str(found.get("duration_seconds", null))])
	_restore_user_files()
	get_tree().quit(0)


func _restore_user_files() -> void:
	for file in USER_FILES:
		var abs := ProjectSettings.globalize_path(file)
		var backup := _snapshot_dir.path_join(abs.get_file())
		if FileAccess.file_exists(backup):
			_copy_file(backup, abs)
			print("[PROBE] 已还原 %s" % abs)


func _copy_file(from: String, to: String) -> void:
	var reader := FileAccess.open(from, FileAccess.READ)
	if reader == null:
		return
	var writer := FileAccess.open(to, FileAccess.WRITE)
	if writer == null:
		return
	writer.store_buffer(reader.get_buffer(reader.get_length()))
	writer.close()
