extends Node

## 流程图截图取证：把总进度流程图的**每种状态**渲染成真实可见像素并保存 PNG。
## 用注入的可控 job 数据（不依赖生成服务），窗口以 `--hidden` 启动，不抢前台。
## 输出目录：agent/runs/20261011-adjutant-map-progress/

const MapGenerationScene = preload("res://source/main-menu/MapGeneration.tscn")
const OUT_DIR := "G:/AIRTS/AI_RTS/agent/runs/20261011-adjutant-map-progress"

var _page: Node = null


func _ready():
	_dir_exists()
	_page = MapGenerationScene.instantiate()
	add_child(_page)
	for _i in 8:
		await get_tree().process_frame
	for size in [[1920, 1080], [1280, 720], [1000, 720]]:
		get_tree().root.size = Vector2(size[0], size[1])
		await get_tree().process_frame
		await get_tree().process_frame
		await _shot_all(str(size[0]) + "x" + str(size[1]))
	print("Map progress flow shots completed")
	SmokeTestExit.request(get_tree(), 0, _page)


func _dir_exists() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)


func _render(job: Dictionary) -> void:
	_page.call("_render_job", job)


func _shot(name: String, suffix: String) -> void:
	for _i in 4:
		await get_tree().process_frame
	var image := get_tree().root.get_texture().get_image()
	var path := "%s/flow-%s-%s.png" % [OUT_DIR, name, suffix]
	var err := image.save_png(path)
	print("shot %s -> %s (err=%s)" % [name, path, err])


func _shot_all(suffix: String) -> void:
	_render({
		"id": "S1", "status": "running", "target": "full", "duration": 12.0,
		"stages": {
			"g1_input": {"status": "done", "pass": true, "duration_s": 1.2},
			"g2_terrain": {"status": "running"},
			"g3_content": {"status": "error", "error": "资源点配比不足，已停止重试"},
		},
		"progress": {"stage": "G2", "phase": "地形候选", "attempt": 3, "limit": 5},
	})
	await _shot("running-mixed", suffix)
	_render({
		"id": "S2", "status": "running", "target": "full", "duration": 20.0,
		"stages": {
			"g1_input": {"status": "done", "pass": true, "duration_s": 1.0},
			"g2_terrain": {"status": "done", "pass": false, "error": "最小路宽 3.1m 不足"},
		},
		"progress": {"stage": "G2", "phase": "地形复核"},
	})
	await _shot("done-pass-false", suffix)
	_render({
		"id": "S3", "status": "done", "target": "g2", "duration": 5.0,
		"stages": {
			"g1_input": {"status": "done", "pass": true, "duration_s": 1.0},
			"g2_terrain": {"status": "done", "pass": true, "duration_s": 2.0},
		},
		"progress": {},
	})
	await _shot("quick-preview", suffix)
	_render({
		"id": "S4", "status": "done", "target": "full", "duration": 30.0,
		"skip_engine_check": true,
		"stages": {
			"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "done", "pass": true},
			"g3_content": {"status": "done", "pass": true},
			"g4_scene": {"status": "done", "pass": true},
			"engine": {"status": "skipped", "reason": "游戏内生成：跳过引擎验收（截图/导航检查由玩家实局代替）"},
		},
		"progress": {"stage": "ENGINE", "phase": "地图已装进工程，跳过引擎验收"},
	})
	await _shot("skip-engine-in-game", suffix)
	_render({
		"id": "S5", "status": "error", "target": "full", "duration": 9.0,
		"stages": {
			"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "error", "error": "候选地形全部被硬拒：可通行率不足"},
		},
		"progress": {"stage": "G2", "phase": "布局失败"},
	})
	await _shot("stage-failed", suffix)
	_render({
		"id": "S6", "status": "done", "target": "full", "duration": 40.0,
		"stages": {
			"g1_input": {"status": "done", "pass": true},
			"g2_terrain": {"status": "done", "pass": true},
			"g3_content": {"status": "done", "pass": true},
			"g4_scene": {"status": "done", "pass": true},
			"engine": {"status": "done", "pass": true, "duration_s": 62.0},
		},
		"progress": {"stage": "ENGINE", "phase": "导航验收通过"},
	})
	await _shot("all-done", suffix)


