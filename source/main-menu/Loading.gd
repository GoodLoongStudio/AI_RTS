extends CanvasLayer

## 【2026-09-15 用户要求】"可以把对局的加载界面的时间放长点来等冷启动嘛" ——
## 加载页承担两件事：
## ① **预热**：加载一开始就把本机副官 runner 拉起来（它的解释器启动、重依赖导入、
##    模型装配与地图加载**并行**跑，不再等到玩家点"接管"才开始）；
## ② **等挂上**：离开加载页之前等它真正挂上本局（有上限 `PREWARM_MAX_WAIT_S`）。
##
## 为什么**只在单人局**等（多人局不拖时间）：联机开局的服务器端要等所有客户端都进入
## 对局（`NetSync._try_go_live` 依赖 `NetSession.all_human_matches_ready()`），
## 在加载页多停就等于让**所有人一起等**；单人局没有这个代价。
## 多人局仍然会预热（不拖人），进对局后面板显示"启动中/运行中"。
const AdjutantRunnerLauncher := preload("res://source/ui/AdjutantRunnerLauncher.gd")
const AdjutantModelService := preload("res://source/ui/AdjutantModelService.gd")
const RandomMapRuntimeScript := preload("res://source/main-menu/RandomMapRuntime.gd")
##: 加载页最多为副官多停留的秒数（超过就先进对局，面板会继续显示状态）。
##: 12s 的依据：预热后 runner 只剩"等对局就绪 + 1~2 秒装配"（实测冷启动 22.7s 里
##: ~20s 都花在等游戏加载，那段本来就在加载页里），不需要留太久。
## 【2026-09-15 用户反馈"单机副官挂上太慢"】等待上限 12 → **30 秒**：
## 实测 runner **挂载本身只要 186ms**（`attached` 事件的 `setup_ms.ready_wait`），
## 时间全花在**进程冷启动**（python + 依赖导入，实测 11~22.7s）。原 12s 上限经常先超时
## 进对局，面板只能在局内继续显示"启动中" —— 观感就是"挂上太慢"。
## 加长**不牺牲热启动**：只要 `is_attached()` 为真就立刻返回（循环第一个分支）。
const PREWARM_MAX_WAIT_S := 30.0

##: 预热的"放弃"阈值：连握手文件都没写出来（进程压根没起来）就别白等满 30 秒。
##: 依据实测：runner 启动后 ~3 秒就会写 `agent_runner.pid`（21:31:31 lock → 21:31:34 pid）。
##: 只影响"启动失败"的罕见场景，正常路径不受影响。
const PREWARM_GIVEUP_NO_PID_S := 10.0

var match_settings = null
var map_path = null
## 单机「随机地图」：先进加载页，现生成一张图再进对局（会比选现成图更久）。
var generate_random_map := false

##: 本次加载是否真的起了预热进程（没起就完全不等，行为与旧版一致）。
var _prewarm_started := false
var _load_failed := false

@onready var _label = find_child("Label")
@onready var _progress_bar = find_child("ProgressBar")


func _ready():
	_progress_bar.value = 0.0

	print("Loading[%.1fs] 预加载" % (Time.get_ticks_msec() / 1000.0))
	_label.text = tr("LOADING_STEP_PRELOADING")
	await get_tree().physics_frame
	_progress_bar.value = 0.05

	_prewarm_adjutant()

	if generate_random_map:
		if not await _generate_random_map():
			return
	else:
		_progress_bar.value = 0.2

	print("Loading[%.1fs] 载入地图 %s" % [Time.get_ticks_msec() / 1000.0, str(map_path)])
	_label.text = tr("LOADING_STEP_LOADING_MAP")
	await get_tree().physics_frame
	var map_scene := _load_packed_scene(map_path, "地图")
	if map_scene == null:
		# 【2026-09-21 多级保底】地图加载失败不再直接进报错页：依次退到
		# 兜底 G4 成品图 → 内置 PlainAndSimple，全部失败才报错。
		# （用户口径："有错误就用保底方案"。）
		for fallback in [
			RANDOM_MAP_FALLBACK_PATH,
			"res://source/match/maps/PlainAndSimple.tscn",
		]:
			if str(map_path) == fallback:
				continue
			push_warning("地图 %s 加载失败，退保底重试：%s" % [str(map_path), fallback])
			_load_failed = false
			map_scene = _load_packed_scene(fallback, "地图(保底)")
			if map_scene != null:
				map_path = fallback
				NetSession.selected_map_path = fallback
				_label.text = tr("LOADING_STEP_LOADING_MAP")
				break
		if map_scene == null:
			return
	var map_instance := map_scene.instantiate()
	print("Loading[%.1fs] 地图实例完成" % (Time.get_ticks_msec() / 1000.0))
	_progress_bar.value = 0.4

	_label.text = tr("LOADING_STEP_LOADING_MATCH")
	await get_tree().physics_frame
	var match_prototype := _load_packed_scene("res://source/match/Match.tscn", "战斗场景")
	if match_prototype == null:
		return
	# 科幻载具/飞机 FBX 很大，必须在加载页读完，不能等进局后再被侧栏 preload 卡住。
	for unit_path in [
		"res://source/match/units/Worker.tscn",
		"res://source/match/units/Drone.tscn",
		"res://source/match/units/Tank.tscn",
		"res://source/match/units/Helicopter.tscn",
	]:
		_load_packed_scene(unit_path, "单位模型")
		await get_tree().physics_frame
	_progress_bar.value = 0.7

	print("Loading[%.1fs] 实例化 Match（导航烘焙阻塞点）" % (Time.get_ticks_msec() / 1000.0))
	_label.text = tr("LOADING_STEP_INSTANTIATING_MATCH")
	await get_tree().physics_frame
	var a_match = match_prototype.instantiate()
	if a_match.get_script() == null:
		_show_load_error("Match.gd 编译失败，战斗场景没有脚本")
		return
	a_match.settings = match_settings
	a_match.map = map_instance
	_progress_bar.value = 0.9

	_label.text = tr("LOADING_STEP_STARTING_MATCH")
	await get_tree().physics_frame
	print("Loading[%.1fs] 添加 Match 到场景树" % (Time.get_ticks_msec() / 1000.0))
	a_match.set_meta("hold_hud_until_loading", true)
	get_parent().add_child(a_match)
	_cover_match(a_match)
	get_tree().current_scene = a_match
	print("Loading[%.1fs] Match 就绪" % (Time.get_ticks_msec() / 1000.0))

	# 【用户要求】离开加载页之前等副官挂上（单人局；见文件头注释）。
	# ⚠必须在 `add_child` **之后**：runner 只能挂到"真正就绪的对局"上——本机 listen
	# 局的对局在 `add_child` 那一刻才存在（首版放在 add_child 之前，实测必然等满上限
	# 白等，日志："等副官超时（上限 20s），先进对局"）。放在这里，`Match._ready` 已经把
	# 初始单位装配完并上报了 match_ready（`NetSync._on_any_match_started`），所以联机
	# 也不会因为这段停留拖住别人的开局。
	# 等的时候加载层盖住对局：Match HUD 是 CanvasLayer，原先加载页只是 Control，
	# 副官面板/侧栏会提前露出来。
	await _wait_adjutant()
	if FeatureFlags.match_augments and NetSession.is_networked():
		print("Loading 局内加成：联机不暂停战局，倒计时用墙钟，超时采用推荐项")
	_uncover_match(a_match)
	queue_free()


func _cover_match(a_match: Node) -> void:
	if a_match == null or not is_instance_valid(a_match):
		return
	for name in ["HUD", "UI"]:
		var layer: Node = a_match.get_node_or_null(name)
		if layer != null:
			layer.visible = false


func _uncover_match(a_match: Node) -> void:
	if a_match == null or not is_instance_valid(a_match):
		return
	a_match.remove_meta("hold_hud_until_loading")
	for name in ["HUD", "UI"]:
		var layer: Node = a_match.get_node_or_null(name)
		if layer != null:
			layer.visible = true


## 随机地图失败时的**兜底 G4 成品图**（用户要求："随机地图要有兜底的 G4 成品地图"）。
## 选 49-1376088014（布局 49）：工作台历史里被反复生成验证过的布局。
## 使用前还会做存在性双检，防止兜底图本身缺失时雪上加霜。
const RANDOM_MAP_FALLBACK_PATH := (
	"res://source/match/maps/generated/49-1376088014/map_49-1376088014.tscn"
)


## 加载页现生成随机四人图；失败时退到兜底 G4 成品图进局，不把玩家卡死在报错页。
func _generate_random_map() -> bool:
	_label.text = "正在生成随机地图…"
	_progress_bar.value = 0.08
	await get_tree().physics_frame
	var runtime := RandomMapRuntimeScript.new()
	add_child(runtime)
	runtime.progress.connect(_on_random_map_progress)
	var result: Dictionary = await runtime.generate_random_full()
	runtime.queue_free()
	if not bool(result.get("ok", false)):
		# 【2026-09-21 兜底】生成失败（超时/服务起不来/G2 反复不过且保底也失败）时，
		# 退到一张**已生成的 G4 成品图**进局，而不是停在报错页。
		# 生成失败的详细原因仍打印到日志，供排查。
		push_warning("随机地图生成失败，改用兜底成品图：%s"
				% str(result.get("error", "")))
		var fallback: String = RANDOM_MAP_FALLBACK_PATH
		if FileAccess.file_exists(fallback) or ResourceLoader.exists(fallback):
			map_path = fallback
			NetSession.selected_map_path = fallback
			_label.text = "随机地图生成失败，已改用备用地图进入对局"
			_progress_bar.value = 0.28
			await get_tree().physics_frame
			print("Loading[%.1fs] 随机地图失败，兜底进局 %s" % [
				Time.get_ticks_msec() / 1000.0, fallback
			])
			return true
		_show_load_error(str(result.get("error", "随机地图生成失败")))
		return false
	map_path = str(result.get("path", ""))
	NetSession.selected_map_path = str(map_path)
	# 生成成功也不能盲信：装进工程的场景必须真的存在，否则同样退兜底成品图。
	if not (FileAccess.file_exists(str(map_path)) or ResourceLoader.exists(str(map_path))):
		push_warning("随机地图场景缺失：%s，改用兜底成品图" % str(map_path))
		var fallback2: String = RANDOM_MAP_FALLBACK_PATH
		if FileAccess.file_exists(fallback2) or ResourceLoader.exists(fallback2):
			map_path = fallback2
			NetSession.selected_map_path = fallback2
			_progress_bar.value = 0.28
			return true
		_show_load_error("随机地图场景缺失：%s" % str(map_path))
		return false
	print("Loading[%.1fs] 随机地图已生成 %s" % [Time.get_ticks_msec() / 1000.0, str(map_path)])
	_progress_bar.value = 0.28
	return true


func _on_random_map_progress(text: String) -> void:
	_label.text = text


## 加载期预热副官：只做"起进程"，不阻塞（真正的加载在后面，正好并行）。
## 玩家上次点过"接管"（`auto_takeover`）才预热——那是玩家的显式选择，不替他决定。
func _prewarm_adjutant() -> void:
	# 专用服实例不预热：副官是**玩家自己**的（面板/自动化各自显式起 runner）；
	# 专用服自动起一个会与验收工装/云服的 runner 撞同一局（实测 2026-09-15 复现过）。
	if OS.get_cmdline_user_args().has("--server"):
		return
	if not AdjutantRunnerLauncher.auto_takeover():
		return
	if AdjutantRunnerLauncher.is_attached():
		return
	# 【2026-09-23】先把本地模型服务拉起来并开始预热，**再**起 runner：
	# 战略层要连它，而"把它起起来"原来只在 `启动AI_RTS.bat` 里。放在这里是为了
	# 让预热与地图加载并行——等玩家真的开始指挥时模型大概率已经热了。
	# 非阻塞：冷模型首次载入 ~70s，阻塞加载页不可接受。
	AdjutantModelService.ensure_started(self)
	var pid := AdjutantRunnerLauncher.start(0, self)
	if pid <= 0:
		push_warning("[ADJ] 加载页预热副官失败（不影响对局）")
		return
	_prewarm_started = true
	print("Loading[%.1fs] 已预热 AI 副官（pid=%d，与地图加载并行）"
	% [Time.get_ticks_msec() / 1000.0, pid])


## 离开加载页之前等副官真正挂上（有上限）。只等自己起的那个进程。
func _wait_adjutant() -> void:
	if not _prewarm_started:
		return
	if not _solo_match():
		print("Loading[%.1fs] 多人局：不在加载页等副官（进对局后面板继续显示状态）"
			% (Time.get_ticks_msec() / 1000.0))
		return
	var started := Time.get_ticks_msec() / 1000.0
	while Time.get_ticks_msec() / 1000.0 - started < PREWARM_MAX_WAIT_S:
		if AdjutantRunnerLauncher.is_attached():
			print("Loading[%.1fs] AI 副官已挂上（在加载页多等了 %.1fs）"
				% [Time.get_ticks_msec() / 1000.0,
				   Time.get_ticks_msec() / 1000.0 - started])
			return
		_label.text = "%s（AI 副官启动中… %.0f 秒）" % [
			tr("LOADING_STEP_STARTING_MATCH"), Time.get_ticks_msec() / 1000.0 - started]
		# 护栏：10 秒内连握手文件都没出现 ⇒ 进程没起来（启动失败），别白等满上限。
		if Time.get_ticks_msec() / 1000.0 - started >= PREWARM_GIVEUP_NO_PID_S \
				and AdjutantRunnerLauncher.pidfile_pid() <= 0:
			print("Loading[%.1fs] 副官进程未见握手文件（疑似启动失败），不等待"
				% (Time.get_ticks_msec() / 1000.0))
			return
		await get_tree().create_timer(0.3).timeout
	print("Loading[%.1fs] 等副官超时（上限 %.0fs），先进对局"
		% [Time.get_ticks_msec() / 1000.0, PREWARM_MAX_WAIT_S])


## 本局是不是"没有别的真人"（单人/本机房）。多人局不能用加载页拖时间。
## 口径取**大厅快照里的人类槽位数**（客户端也拿得到；`connected_human_count()` 是服务器侧数据）。
func _solo_match() -> bool:
	var humans := 0
	for entry in NetSession.last_lobby_slots:
		if int((entry as Dictionary).get("kind", 0)) == NetSession.SLOT_HUMAN:
			humans += 1
	if humans == 0:
		return true      # 还没有大厅快照（本机直开/单人）→ 按单人处理
	return humans <= 1


func _load_packed_scene(path_value, display_name: String) -> PackedScene:
	var scene_path := str(path_value)
	if scene_path.is_empty() or scene_path == "<null>":
		_show_load_error("%s路径为空" % display_name)
		return null
	var abs_path := ProjectSettings.globalize_path(scene_path)
	# 【2026-09-21 修复假阴性】`FileAccess.file_exists` 对 res:// 在部分运行形态下
	# 会**假阴性**（文件明明在磁盘上却返回 false），曾把 PlainAndSimple 和 generated
	# 成品图都拦在 load 之前报"找不到文件"。现以 `ResourceLoader.exists`（Godot 官方的
	# "可加载"判定，按 remap/导入规则查）为**首选**；文件系统直读只作为补充。
	# 两者都说"没有"才报错。`_unimported_ext_resources` 需要直读文本，读不到就跳过扫描
	# （pck 形态），把判定交给真正的 load。
	var fs_visible := FileAccess.file_exists(scene_path) or FileAccess.file_exists(abs_path)
	if not ResourceLoader.exists(scene_path) and not fs_visible:
		_show_load_error("%s找不到文件：%s" % [display_name, scene_path])
		return null
	if fs_visible:
		var missing := _unimported_ext_resources(abs_path)
		if not missing.is_empty():
			_show_load_error("%s有未导入依赖：%s" % [display_name, ", ".join(missing)])
			return null

	var resource := ResourceLoader.load(scene_path)
	if resource == null:
		resource = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if resource == null:
		_show_load_error("%s加载失败：%s" % [display_name, scene_path])
		return null

	var packed_scene := resource as PackedScene
	if packed_scene == null:
		_show_load_error("%s不是可实例化的 PackedScene：%s" % [display_name, scene_path])
		return null
	return packed_scene


func _unimported_ext_resources(abs_scene_path: String) -> PackedStringArray:
	var missing: PackedStringArray = []
	var file := FileAccess.open(abs_scene_path, FileAccess.READ)
	if file == null:
		return missing
	var text := file.get_as_text()
	var regex := RegEx.new()
	regex.compile('ext_resource type="Texture2D"[^\\n]*path="(res://[^"]+\\.png)"')
	for m in regex.search_all(text):
		var res_path := m.get_string(1)
		if ResourceLoader.exists(res_path):
			continue
		var abs_res := ProjectSettings.globalize_path(res_path)
		if FileAccess.file_exists(abs_res) and not FileAccess.file_exists(abs_res + ".import"):
			missing.append(res_path)
	return missing


func _show_load_error(message: String):
	push_error(message)
	_load_failed = true
	_label.text = "加载失败\n%s\n按 ESC 返回对局设置" % message
	_progress_bar.value = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not _load_failed:
		return
	if event.is_action_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")
