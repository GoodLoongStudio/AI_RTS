extends Node

## 几十轮战略对话马拉松（2026-10-02 用户要求：模拟玩家迭代，验证能否真正战术讨论）。
##
## Phase A（15 轮，无战局摘要）：基线，暴露"没有战局事实时模型只能空谈/答状态缺失"。
## Phase B（30+ 轮，带真实紧凑战局摘要 + 真实对局实体）：正式评估战术讨论质量。
##
## 评估指标（写入 [METRIC] 行）：
##   每轮耗时/回复字符数；边界违规（已执行/已下令/单位ID批次/坐标命令）；
##   重复度（与上一轮回复的相同前缀占比）；上下文回指命中（追问能否引用先前答案）；
##   战局事实正确性（引用的数字必须与真实摘要一致）；失败/超时计数。

const MAP_SCENE := "res://source/match/maps/PlainAndSimple.tscn"
const ChatService := preload("res://source/ui/AdjutantChatService.gd")

## 玩家模拟剧本（Phase B 用，30 轮；带真实战局数据引用与回指追问）。
const SCRIPT_B := [
	"现在局面怎么看？我们的战略重点是什么？",
	"我的资源够支撑多少部队？先造什么最划算？",
	"对面如果 Rush 我，我现在的兵力守得住吗？",
	"侦察应该什么时候做？先侦察哪一路？",
	"经济和出兵的比例怎么平衡？",
	"上一条你说的比例，如果资源收入下降一半还成立吗？",
	"你刚才提到的防守要点，具体指哪几个位置？",
	"重坦和坦克混编好还是单一兵种好？",
	"如果敌人出直升机，我该怎么应对？",
	"我的步兵在正面能扛多久？",
	"现在应该分兵扩张还是集中防守？",
	"上一轮你让我集中防守，那什么时候该转进攻？",
	"如果我想打游击骚扰，用哪几种单位组合？",
	"我的对空力量够吗？不够的话先补什么？",
	"敌人一直不出门龟基地，我怎么破局？",
	"你刚才的破局思路有什么风险？",
	"补给线被打断了，先修还是先抢回来？",
	"现在卖掉一些建筑换资源划算吗？",
	"我的矿车被骚扰了，护矿怎么布置？",
	"如果把防空塔往前压，会不会被绕后？",
	"总体来说，我这局犯的最大错误是什么？",
	"接下来两分钟最优先做的一件事是什么？",
	"你觉得我现在的部队构成偏进攻还是偏防守？",
	"如果现在暂停重整，你会怎么重新分配我的单位？",
	"敌人如果双线进攻，我的防守顺序应该怎么排？",
	"你说的防守顺序，和前面说的集中防守矛盾吗？",
	"我最后应该攒决战兵力还是持续消耗？",
	"决战时机怎么判断？给我两个可观察的信号。",
	"如果决战失败，保底策略是什么？",
	"用一句话总结这局我该记住的战略原则。",
]

var _match: Node
var _human: Node
var _svc: Node


func _ready() -> void:
	var settings = load("res://source/data-model/MatchSettings.gd").new()
	var hs = load("res://source/data-model/PlayerSettings.gd").new()
	hs.controller = Constants.PlayerType.HUMAN
	hs.color = Color.BLUE
	settings.players.append(hs)
	settings.visible_player = 0
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(MAP_SCENE).instantiate()
	add_child(_match)
	get_tree().current_scene = _match
	for _f in range(200):
		await get_tree().physics_frame
	_human = _match.get_node("Players").get_children()[0]
	_svc = ChatService.new()
	add_child(_svc)
	_svc.setup("marathon", "probe-player")

	# 摆一个真实对局态势：我方基地+部队，敌方基地+部队（在同一地图两侧）
	_make_scenario()

	print("[MARATHON] === Phase A：无战局摘要基线（15 轮） ===")
	await _run_rounds(SCRIPT_B.slice(0, 15), false)
	print("[MARATHON] === Phase B2：敌情可见 + 真实战局摘要（10 轮数据依赖型） ===")
	# 敌人此刻才生成：Phase A 是无敌人纯聊天基线；若提前放敌人，
	# 自动交战会在 Phase A 的 30 秒里把他们打死（实测）。
	var enemy := Node3D.new()
	enemy.name = "EnemyHolder"
	enemy.set_script(load("res://source/match/players/Player.gd"))
	enemy.color = Color.RED
	enemy.add_to_group("players")
	_match.get_node("Players").add_child(enemy)
	for case in [["Tank", Vector3(40, 0, 26)], ["AntiGroundTurret", Vector3(38, 0, 33)],
			["Infantry", Vector3(39, 0, 28)]]:
		var u = load("res://source/match/units/%s.tscn" % case[0]).instantiate()
		MatchSignals.setup_and_spawn_unit.emit(u, Transform3D(Basis.IDENTITY, case[1]), enemy)
	# 全员停火：这是"战术讨论"场景，不是战斗场景（讨论期间敌我都不开火）。
	var my_gateway = _human.get_node_or_null("UnitCommandGateway")
	if my_gateway != null:
		var mine: Array = []
		var theirs: Array = []
		for u in get_tree().get_nodes_in_group("units"):
			if not is_instance_valid(u):
				continue
			if u.get_parent() == _human:
				mine.append(u)
			elif u.get_parent() == enemy:
				theirs.append(u)
		if not mine.is_empty():
			my_gateway.SetFirePolicy(mine, "HoldFire", _human)
		if not theirs.is_empty():
			my_gateway.SetFirePolicy(theirs, "HoldFire", enemy)
	await get_tree().create_timer(0.5).timeout
	var script_data := [
		"你看到了什么敌情？我的部队打得过他们吗？",
		"那个对地塔对我的坦克威胁多大？",
		"敌方步兵会不会先动手？我该怎么先手？",
		"如果我先集火打掉对地塔，胜算如何？",
		"打完这一仗我的部队大概会剩多少？",
		"有没有不打就能赢的方案？",
		"综合刚才的分析，给我一个三步交战方案。",
		"这个方案最大的风险点在哪？",
		"如果敌人增援从北侧来，方案怎么改？",
		"现在给我一个最终的交战/撤退判断标准。",
	]
	_svc.context_provider = Callable(self, "_game_summary")
	_svc.setup("marathon-b2", "probe-player")
	print("[SUMMARY] " + _game_summary())
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u):
			continue
		var groups: Array = []
		for g in ["controlled_units", "adversary_units", "revealed_units"]:
			if u.is_in_group(g):
				groups.append(g)
		print("[SUMMARY-DBG] 单位=%s 父=%s 组=%s" % [
			str(u.get("unit_type_id")), u.get_parent().name, str(groups)])
	await _run_rounds(script_data, true)
	print("[MARATHON] === Phase B：带真实战局摘要（30 轮） ===")
	_svc.context_provider = Callable(self, "_game_summary")
	_svc.setup("marathon-b", "probe-player")  # 换新会话，Phase A 历史不串
	await _run_rounds(SCRIPT_B, true)
	print("[MARATHON] DONE")
	get_tree().quit(0)


func _make_scenario() -> void:
	var enemy := Node3D.new()
	enemy.name = "EnemyHolder"
	enemy.set_script(load("res://source/match/players/Player.gd"))
	enemy.color = Color.RED
	enemy.add_to_group("players")
	_match.get_node("Players").add_child(enemy)
	# 我方
	for case in [["Tank", Vector3(30, 0, 26)], ["Tank", Vector3(33, 0, 28)],
			["Infantry", Vector3(29, 0, 32)], ["Infantry", Vector3(30, 0, 33)],
			["Worker", Vector3(26, 0, 30)], ["HeavyTank", Vector3(36, 0, 30)]]:
		var u = load("res://source/match/units/%s.tscn" % case[0]).instantiate()
		MatchSignals.setup_and_spawn_unit.emit(u, Transform3D(Basis.IDENTITY, case[1]), _human)
	# 等一拍让摘要 provider 能读到
	for _f in range(10):
		await get_tree().physics_frame


## 只读战局摘要（与面板 _compact_game_summary 同口径，含敌情构成）。
func _game_summary() -> String:
	var units := {}
	for u in get_tree().get_nodes_in_group("units"):
		if not is_instance_valid(u):
			continue
		var t := str(u.get("unit_type_id"))
		if t == "<null>":
			continue
		if u.get_parent() == _human:
			units[t] = int(units.get(t, 0)) + 1
	var res: Variant = _human.get("resource_a")
	var mine: Array = []
	for k in units:
		mine.append("%s×%d" % [k, units[k]])
	var parts: Array = ["资源A=%s，部队 %s" % [
		res_a_to_str(res), "、".join(mine) if mine.size() > 0 else "无"]]
	# 敌情带距离（与面板方位口径互补）
	var by_type := {}
	for u in get_tree().get_nodes_in_group("adversary_units"):
		if not is_instance_valid(u) or not u.is_inside_tree() or not u.visible:
			continue
		var t2 := str(u.get("unit_type_id"))
		var pos: Vector3 = (u as Node3D).global_position
		var nearest := INF
		for m in get_tree().get_nodes_in_group("units"):
			if is_instance_valid(m) and m.get_parent() == _human and m.is_inside_tree():
				nearest = minf(nearest, Vector2(
					pos.x - (m as Node3D).global_position.x,
					pos.z - (m as Node3D).global_position.z).length())
		if not by_type.has(t2):
			by_type[t2] = {"n": 0, "d": nearest}
		by_type[t2]["n"] = int(by_type[t2]["n"]) + 1
		by_type[t2]["d"] = minf(float(by_type[t2]["d"]), nearest)
	var enemy_bits: Array = []
	for t2 in by_type:
		enemy_bits.append("%s×%d（距我 %.0fm）" % [t2, by_type[t2]["n"], by_type[t2]["d"]])
	parts.append("已知敌情：" + ("、".join(enemy_bits) if enemy_bits.size() > 0 else "视野内未发现"))
	var ranges := _static_range_text()
	if not ranges.is_empty():
		parts.append("射程：" + ranges)
	return ("；".join(parts)).substr(0, 400)


func _static_range_text() -> String:
	var handle := FileAccess.open("res://config/balance/demo.balance.v1.json", FileAccess.READ)
	if handle == null:
		return ""
	var parsed = JSON.parse_string(handle.get_as_text())
	handle.close()
	if not parsed is Dictionary:
		return ""
	var weapons := {}
	for w in (parsed as Dictionary).get("weapons", []):
		weapons[str(w.get("id"))] = float(w.get("rangeMeters", 0.0))
	var names := {"tank": "坦克", "heavy_tank": "重坦", "soldier": "步兵",
		"anti_ground_turret": "对地塔", "anti_air_turret": "对空塔"}
	var out: Array = []
	for ut in (parsed as Dictionary).get("unitTypes", []):
		var uid := str(ut.get("id", ""))
		if not names.has(uid):
			continue
		var wids = ut.get("weaponIds", [])
		if wids.is_empty():
			continue
		var r: float = float(weapons.get(str(wids[0]), 0.0))
		if r > 0.0:
			out.append("%s%.1fm" % [names[uid], r])
	return "、".join(out)
func res_a_to_str(v: Variant) -> String:
	return str(v) if v != null else "?"


func _run_rounds(script: Array, with_context: bool) -> void:
	var phase := "B" if with_context else "A"
	var total_ms := 0
	var violations := 0
	var failures := 0
	var prev_reply := ""
	var turn := 0
	for question in script:
		turn += 1
		var sent: Dictionary = _svc.send(question)
		if not bool(sent.get("queued")):
			print("[R%s.%02d] 发送被拒：%s" % [phase, turn, str(sent.get("error_code"))])
			failures += 1
			await get_tree().create_timer(0.5).timeout
			continue
		var waited := 0.0
		while _svc.is_busy() and waited < 90.0:
			await get_tree().create_timer(0.25).timeout
			waited += 0.25
		var reply := ""
		for i in range(_svc.history.size() - 1, -1, -1):
			if str(_svc.history[i].get("role")) == "assistant":
				reply = str(_svc.history[i].get("content"))
				break
		var elapsed_ms := int(waited * 1000)
		total_ms += elapsed_ms
		# 边界违规扫描
		var violation := ""
		for marker in ["已执行", "已下令", "已派遣", "单位ID", "已经派兵", "我将派兵去打"]:
			if reply.contains(marker):
				violation = marker
				break
		if not violation.is_empty():
			violations += 1
		# 重复度：与上轮回复的最长公共前缀占比
		var overlap := 0.0
		if not prev_reply.is_empty() and not reply.is_empty():
			var n := mini(prev_reply.length(), reply.length())
			var common := 0
			while common < n and prev_reply[common] == reply[common]:
				common += 1
			overlap = float(common) / maxf(1.0, float(mini(prev_reply.length(), reply.length())))
		var state_ref := reply.contains("资源A=") or reply.contains("已知敌方")
		print("[R%s.%02d] %dms 字数=%d 重复前缀=%.0f%% 战局引用=%s 违规=%s | 问：%s | 答：%s" % [
			phase, turn, elapsed_ms, reply.length(), overlap * 100,
			"是" if state_ref else "否", violation if not violation.is_empty() else "无",
			question.left(28), reply.left(100).replace("\n", " ")])
		if waited >= 90.0:
			failures += 1
			print("[R%s.%02d] FAIL 超时未回复" % [phase, turn])
		prev_reply = reply
	print("[METRIC-%s] 轮数=%d 总耗时=%.1fs 平均=%.1fs 违规=%d 失败=%d" % [
		phase, turn, total_ms / 1000.0, total_ms / 1000.0 / maxf(1.0, turn), violations, failures])
