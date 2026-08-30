extends Node

## 双进程联机冒烟监控节点。由 Online.gd 在 --smokeclient 时挂到 root 下——
## 挂在 root 而不是当前场景，因此场景切换（Online→Loading→Match）不会释放它，
## 协程全程存活，规避「lambda/方法在实例释放后静默失效」的坑。

var _log_fa: FileAccess = null
var _deadline := 0
var _port := 24599
var _host := "127.0.0.1"


func _log(msg: String) -> void:
	print(msg)
	if _log_fa == null:
		_log_fa = FileAccess.open("user://smoke_client.log", FileAccess.WRITE)
	if _log_fa != null:
		_log_fa.store_line("%d %s" % [Time.get_ticks_msec(), msg])
		_log_fa.flush()


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_port = NetSession.DEFAULT_PORT
	var pi := args.find("--smokeport")
	if pi >= 0 and pi + 1 < args.size():
		_port = int(args[pi + 1])
	var host := "127.0.0.1"
	pi = args.find("--smokehost")
	if pi >= 0 and pi + 1 < args.size():
		host = args[pi + 1]
	_host = host
	_deadline = Time.get_ticks_msec() + 420_000
	_run()


func _run() -> void:
	var tree := get_tree()
	_log("SMOKE: client start, target %s:%d" % [_host, _port])
	var err := NetSession.join(_host, _port)
	_log("SMOKE: join err=%d" % err)
	if err != OK:
		_log("SMOKE_FAIL join")
		tree.quit(1)
		return
	# 等连接+槽位（槽位分配后状态直接跳"已分配阵营槽位"，两种都要认）。
	var waited := 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(0.5).timeout
		waited += 1
		var st := NetSession.get_status()
		if st.begins_with("已连接") or st.begins_with("已分配阵营槽位"):
			break
		if waited % 10 == 0:
			_log("SMOKE: 等连接 %ds, status=%s" % [waited, st])
	if not NetSession.is_networked():
		_log("SMOKE_FAIL connect")
		tree.quit(1)
		return
	_log("SMOKE: connected, status=%s" % NetSession.get_status())
	await tree.create_timer(1.0).timeout
	NetSession.start_solo()
	_log("SMOKE: solo start requested")
	# 等客户端 Match 场景加载出 NetSync。
	var sync: Node = null
	waited = 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		sync = tree.root.find_child("NetSync", true, false)
		if sync != null:
			_log("SMOKE: NetSync 出现于等待 %ds" % waited)
			break
		if waited % 10 == 0:
			_log("SMOKE: 等 NetSync %ds, scene=%s" % [
				waited, tree.current_scene.name if tree.current_scene else "null"])
	if sync == null:
		_log("SMOKE_FAIL no NetSync (Match 未加载)")
		tree.quit(1)
		return
	# 等 go-live 后首个快照写入插值目标。
	waited = 0
	while Time.get_ticks_msec() < _deadline:
		await tree.create_timer(1.0).timeout
		waited += 1
		if not NetSession.is_networked():
			_log("SMOKE_FAIL 会话已断开（等待 %ds）" % waited)
			tree.quit(1)
			return
		var targets: Dictionary = sync.get("_interp_target") if sync.get("_interp_target") is Dictionary else {}
		var units := tree.get_nodes_in_group("units").size()
		if targets.size() > 0:
			_log("SMOKE_OK units=%d interp_targets=%d" % [units, targets.size()])
			tree.quit(0)
			return
		if waited % 10 == 0:
			_log("SMOKE: 等快照 %ds, units=%d, live=%s" % [
				waited, units, str(sync.get("_live"))])
	_log("SMOKE_FAIL timeout")
	tree.quit(1)
