extends Node

## 开发热重载：编辑器内运行时每秒扫描 source/ 下的 .gd，文件一变即替换资源缓存——
## 存量节点保留状态、新代码生效。限制：改场景结构/信号/preload 引用需重开；
## 专用服与导出包自动跳过（用 -- --hotreload 也没用，这是刻意的）。

const WATCH_DIRS := ["res://source"]
const SCAN_INTERVAL := 1.0
const WATCH_EXT := ".gd"

var _mtimes: Dictionary = {}
var _accum := 0.0


func _ready() -> void:
	if not OS.has_feature("editor"):
		queue_free()
		return
	_scan(true)
	print("[热更] 监听中（%d 个脚本，改完 ~1 秒生效）" % _mtimes.size())


func _process(delta: float) -> void:
	_accum += delta
	if _accum < SCAN_INTERVAL:
		return
	_accum = 0.0
	for dir_path in WATCH_DIRS:
		_scan_dir(dir_path, false)


func _scan(initial: bool) -> void:
	for dir_path in WATCH_DIRS:
		_scan_dir(dir_path, initial)


func _scan_dir(dir_path: String, initial: bool) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var path := dir_path.path_join(file_name)
			if dir.current_is_dir():
				_scan_dir(path, initial)
			elif file_name.ends_with(WATCH_EXT):
				var mtime := FileAccess.get_modified_time(path)
				if initial:
					_mtimes[path] = mtime
				elif int(_mtimes.get(path, 0)) != mtime:
					_mtimes[path] = mtime
					var res = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
					if res != null:
						print("[热更] %s 已生效" % path)
					else:
						printerr("[热更] %s 编译失败，保留旧代码" % path)
		file_name = dir.get_next()
	dir.list_dir_end()
