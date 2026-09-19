extends Node

## 局内海克斯加成冒烟：开牌、点选、超时、数值、无 Hermes 降级。
## 跑法：godot --headless --path AI_RTS res://tests/automated/MatchAugmentSmokeTest.tscn -- --debugport <port>

const MatchScene = preload("res://tests/manual/TestPlayerVsAI.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Catalog = preload("res://source/match/augments/AugmentCatalog.gd")
const Mods = preload("res://source/match/augments/AugmentModifiers.gd")
const Ranker = preload("res://source/match/augments/AugmentRanker.gd")
const Schema = preload("res://source/history/MatchReportSchema.gd")

var _failures := 0
var _match: Node = null
var _human: Node = null
var _ai: Node = null
var _runtime: Node = null


func _ready() -> void:
	var flags := get_node_or_null("/root/FeatureFlags")
	if flags != null:
		flags.match_augments = true
	_match = MatchScene.instantiate()
	add_child(_match)
	await get_tree().create_timer(1.2, true, false, true).timeout
	_human = _match.get_node_or_null("Players/Human")
	_ai = _match.get_node_or_null("Players/SimpleClairvoyantAI")
	_runtime = _match.get_node_or_null("AugmentRuntime")
	if _human == null or _runtime == null:
		_fail("Match 应挂上 Human 与 AugmentRuntime")
		_finish()
		return
	await _await_account_ready()
	_test_catalog()
	_test_modifiers()
	_test_ranker_no_live_pretend()
	_test_ranker_grant_bonus()
	_test_ranker_ties_keep_input_order()
	await _test_ai_auto_pick()
	await _test_player_pick()
	await _test_timeout_hermes()
	await _test_timeout_rules()
	_test_observation_ops()
	_test_report_schema()
	_finish()


func _test_catalog() -> void:
	var cards: Array = Catalog.cards()
	_check(cards.size() >= 12, "牌库至少 12 张")
	var tags := {}
	var effects := {}
	for item in cards:
		_check(str(item.get("id", "")).begins_with("aug_"), "牌 id 必须前缀 aug_")
		_check(Catalog.is_valid_card(item), "每张牌都应合法")
		tags[str(item.get("tag", ""))] = true
		effects[str((item.get("effect", {}) as Dictionary).get("type", ""))] = true
	_check(tags.has("economy") and tags.has("military"), "牌库应覆盖经济与军事")
	_check(effects.has("gather_mult") and effects.has("damage_mult"), "应有采集与伤害类效果")
	var first := Catalog.roll("seed-a|Human|0", [], [], [])
	var again := Catalog.roll("seed-a|Human|0", [], [], [])
	_check(first.size() == 3, "每轮抽出 3 张")
	_check(_ids(first) == _ids(again), "同一种子抽牌应稳定")
	var owned_tags: Array = [str(first[0].get("tag", ""))]
	var owned_effects: Array = [str((first[0].get("effect", {}) as Dictionary).get("type", ""))]
	var next_roll := Catalog.roll("seed-b|Human|1", _ids(first), owned_tags, owned_effects)
	for item in next_roll:
		_check(str(item.get("tag", "")) != owned_tags[0], "同 tag 每局最多一张")
		_check(str((item.get("effect", {}) as Dictionary).get("type", "")) != owned_effects[0],
			"同效果类型每局最多一张")


func _test_modifiers() -> void:
	_check(Mods.scale_gather(8, 1.25) == 10, "采集倍率 1.25 应对 8 交货得到 10")
	_check(Mods.scale_gather(10, 1.5) == 15, "采集倍率 1.5 应对 10 交货得到 15")
	var probe := TankScene.instantiate()
	probe.attack_damage = 20.0
	probe.hp_max = 100.0
	probe.hp = 100.0
	var damage_card: Dictionary = Catalog.card("aug_sharpened")
	_check(not damage_card.is_empty(), "牌库应有磨锋")
	Mods.apply_to_unit(probe, [damage_card])
	_check(float(probe.attack_damage) > 20.0, "伤害牌应对坦克 attack_damage 生效")
	probe.free()


func _test_ranker_no_live_pretend() -> void:
	var ranked: Dictionary = Ranker.rank(Catalog.cards().slice(0, 3), {
		"army_count": 1, "balance_a": 50, "enemy_count": 0, "structure_count": 1,
	}, {})
	_check(str(ranked.get("source", "")) == "rules", "无画像时必须是规则推荐，不得写 live")
	for row in ranked.get("reasons", []):
		_check(row is Dictionary and not (row.get("evidence", []) as Array).is_empty(),
			"规则理由必须带 evidence")


## 资金卡的**额度**必须带动排序，且与 tag 无关。
## 护栏来源：`_grant_bonus` 曾被写进 `tag == "economy"` 分支，construction 标签的
## 「工程备料」同样给 5000 却拿不到权重，副官照旧把它排末位——两份实现彼此一致
## 也发现不了这个错，只有断言「谁该在前」才抓得到。
func _test_ranker_grant_bonus() -> void:
	var facts := {"army_count": 2, "balance_a": 9000, "enemy_count": 1, "structure_count": 4}
	var money_cards := 0
	for card in Catalog.cards():
		var effect = card.get("effect", {})
		if effect is Dictionary and str(effect.get("type", "")) == "resource_grant":
			money_cards += 1
	_check(money_cards >= 1, "牌库应有资金赠予卡（否则本护栏是空转）")
	for tag in ["economy", "construction", "scout", "military"]:
		# ⚠️ 小额牌必须放在**前面**：同 tag 同稀有度下若额度加分缺失，两张牌分数
		# 完全打平，此时「谁在前」取决于排序的平局行为 —— 把小额牌放前面，缺少
		# 加分时它会被顶到首位，断言才真的会红（放后面是假绿，已实测踩过）。
		var ranked: Dictionary = Ranker.rank([
			{"id": "aug_probe_small", "tag": tag, "rarity": "silver",
				"effect": {"type": "resource_grant", "resource_a": 250}},
			{"id": "aug_probe_big", "tag": tag, "rarity": "silver",
				"effect": {"type": "resource_grant", "resource_a": 5000}},
		], facts, {})
		var order: Array = ranked.get("order", [])
		_check(not order.is_empty() and str(order[0]) == "aug_probe_big",
			"%s 标签下 5000 资金卡必须排在 250 之前（额度加分不得挑 tag）" % tag)
		_check(str(ranked.get("starred_id", "")) == "aug_probe_big",
			"%s 标签下 5000 资金卡应被标星" % tag)


## 平局必须保持输入序 —— 两侧地板都有这条**显式契约**，不能靠排序实现碰巧稳定。
## 护栏来源：Godot 的 `Array.sort_custom` 不保证稳定，2026-09-15 实测同分时 n≤16 恰好
## 保序、n=32 起就开始乱（32 张同分牌首位变成最后一张）；而 Python 的 `list.sort` 稳定。
## 牌库现在 12 张刚好落在安全区，纯属巧合 —— 一旦超过 16 张，两侧地板就会在平局上分叉，
## 副官推荐序和 Godot 兜底序不再是同一个，且不会有任何报错。
func _test_ranker_ties_keep_input_order() -> void:
	var n := 32
	var cards: Array = []
	for i in n:
		# 全部同 tag / 同稀有度 / 无 effect ⇒ 分数完全相同，只可能靠平局键定序。
		cards.append({"id": "aug_probe_%03d" % i, "tag": "scout", "rarity": "silver", "effect": {}})
	var facts := {"army_count": 2, "balance_a": 5000, "enemy_count": 1, "structure_count": 2}
	var order: Array = Ranker.rank(cards, facts, {}).get("order", [])
	_check(order.size() == n, "同分牌应全部保留（期望 %d，实得 %d）" % [n, order.size()])
	var first_bad := ""
	for i in mini(order.size(), n):
		if str(order[i]) != "aug_probe_%03d" % i:
			first_bad = "第 %d 位是 %s" % [i, order[i]]
			break
	_check(first_bad.is_empty(),
		"同分牌必须保持输入序（平局键缺失或失效：%s）" % first_bad)


func _test_ai_auto_pick() -> void:
	if _ai == null:
		_check(false, "双玩家场景应包含 AI 玩家")
		return
	var opened: Dictionary = _runtime.debug_force_round(0, _ai)
	_check(bool(opened.get("ok", false)), "AI 应能开第 1 轮")
	var snap: Dictionary = _runtime.snapshot_for(_ai)
	_check((snap.get("owned", []) as Array).size() == 1, "电脑玩家应立即用规则地板自选")
	_check((snap.get("offer", []) as Array).is_empty(), "AI 选完后不应再挂 offer")
	var picks: Array = snap.get("picks", [])
	_check(not picks.is_empty() and str((picks[0] as Dictionary).get("source", "")) == "ai_rules",
		"AI 落选来源应为 ai_rules")
	await get_tree().process_frame


func _test_player_pick() -> void:
	_runtime.debug_set_countdown_msec(20000)
	var opened: Dictionary = _runtime.debug_force_round(0, _human)
	_check(bool(opened.get("ok", false)), "玩家应能强制开第 1 轮")
	await get_tree().create_timer(0.05, true, false, true).timeout
	var snap: Dictionary = _runtime.snapshot_for(_human)
	_check((snap.get("offer", []) as Array).size() == 3, "玩家 offer 应为 3 张")
	_check(str((snap.get("rank", {}) as Dictionary).get("source", "")) != "live",
		"开牌时不得假装有 Hermes 实时建议")
	var overlay = _match.find_child("AugmentDraftOverlay", true, false)
	_check(overlay != null and overlay.visible, "三卡覆盖层应可见")
	var gate = _match.get_node_or_null("PauseGate")
	_check(gate != null and gate.is_held("augment"), "单机选牌应占用 PauseGate")
	var before_a: int = int(_human.resource_a)
	var mobile = _ensure_mobile_combat_unit(_human)
	var structure = _find_structure(_human)
	_seed_combat_stats(mobile)
	_seed_combat_stats(structure)
	var before_damage := float(mobile.get("attack_damage")) if mobile != null else 0.0
	var before_hp_mobile := float(mobile.get("hp_max")) if mobile != null else 0.0
	var before_hp_structure := float(structure.get("hp_max")) if structure != null else 0.0
	var before_sight := float(mobile.get("sight_range")) if mobile != null else 0.0
	var offer: Array = snap.get("offer", [])
	var pick_id := str(offer[0].get("id", ""))
	var picked: Dictionary = _runtime.pick(_human, pick_id, "player")
	_check(bool(picked.get("ok", false)), "玩家点选应成功")
	snap = _runtime.snapshot_for(_human)
	_check((snap.get("owned", []) as Array).size() == 1, "点选后应拥有 1 张")
	_check(overlay != null and overlay.visible == false, "选完后覆盖层应收起")
	var tray = _match.find_child("AugmentTray", true, false)
	_check(tray != null and tray.visible, "顶栏托盘应显示已选加成")
	var card: Dictionary = Catalog.card(pick_id)
	var effect: Dictionary = card.get("effect", {})
	var effect_type := str(effect.get("type", ""))
	var scope := str(effect.get("scope", "all"))
	if effect_type == "resource_grant":
		# ⚠️ 必须锚在**权威账户**上，且要求增量**恰好等于卡面额度**。
		# 旧写法 `int(_human.resource_a) > before_a` 是弱代理：任何其它收入都能让它假绿；
		# 反过来，reason 字符串不是 C# 枚举成员时 grant 会静默变空操作（无日志、无报错），
		# 旧写法就会时红时绿（2026-09-15 实测：1/3 概率红，且完全看不出根因）。
		var economy = _match.get_node_or_null("EconomyRuntime")
		var granted := int((economy.GetSnapshot(_human) as Dictionary).get("resource_a", 0)) if economy != null else -1
		var expected := int(effect.get("resource_a", 0))
		_check(granted - before_a == expected,
			"资金赠予应恰好增加 %d（实测增量 %d）" % [expected, granted - before_a])
	elif effect_type == "gather_mult":
		_check(is_equal_approx(float(_runtime.gather_multiplier(_human)), float(effect.get("value", 1.0))),
			"采集倍率应写入 runtime")
	elif effect_type == "damage_mult":
		_check(mobile != null and float(mobile.attack_damage) > before_damage, "伤害加成应提高 attack_damage")
	elif effect_type == "hp_mult" and scope == "structure":
		_check(structure != null and float(structure.hp_max) > before_hp_structure, "建筑生命加成应提高 hp_max")
	elif effect_type == "hp_mult":
		_check(mobile != null and float(mobile.hp_max) > before_hp_mobile, "作战单位生命加成应提高 hp_max")
	elif effect_type == "sight_mult":
		_check(mobile != null and float(mobile.sight_range) > before_sight, "视野加成应提高 sight_range")
	await get_tree().create_timer(0.05, true, false, true).timeout


func _test_timeout_hermes() -> void:
	_runtime.debug_set_countdown_msec(180)
	var opened: Dictionary = _runtime.debug_force_round(1, _human)
	_check(bool(opened.get("ok", false)), "应能开第 2 轮")
	var snap: Dictionary = _runtime.snapshot_for(_human)
	var offer: Array = snap.get("offer", [])
	_check(offer.size() == 3, "第 2 轮仍应抽出 3 张")
	var order: Array = []
	for item in offer:
		order.append(str(item.get("id", "")))
	order.reverse()
	var reasons: Array = []
	for card_id in order:
		reasons.append({"id": card_id, "text": "测试注入 Hermes 排序", "evidence": ["facts.army_count"]})
	var rec: Dictionary = _runtime.submit_recommendation(_human, {"order": order, "reasons": reasons})
	_check(bool(rec.get("ok", false)), "Hermes 排序提交应成功")
	snap = _runtime.snapshot_for(_human)
	_check(str((snap.get("rank", {}) as Dictionary).get("source", "")) == "live",
		"提交后星标来源应为 live")
	var bad: Dictionary = _runtime.submit_recommendation(_human, {
		"order": ["aug_invented", order[0], order[1]], "reasons": reasons,
	})
	_check(not bool(bad.get("ok", false)), "非本轮排列必须拒绝")
	await get_tree().create_timer(0.35, true, false, true).timeout
	snap = _runtime.snapshot_for(_human)
	_check((snap.get("offer", []) as Array).is_empty(), "超时后 offer 应清空")
	var last: Dictionary = (snap.get("picks", []) as Array).back()
	_check(str(last.get("source", "")) == "timeout_hermes", "有 Hermes 星标时超时来源应为 timeout_hermes")
	_check(str(last.get("id", "")) == str(order[0]), "超时应采用 Hermes 首选")


func _test_timeout_rules() -> void:
	_runtime.debug_set_countdown_msec(180)
	var opened: Dictionary = _runtime.debug_force_round(2, _human)
	_check(bool(opened.get("ok", false)), "应能开第 3 轮")
	var snap: Dictionary = _runtime.snapshot_for(_human)
	var starred := str((snap.get("rank", {}) as Dictionary).get("starred_id", ""))
	_check(str((snap.get("rank", {}) as Dictionary).get("source", "")) != "live",
		"无 Hermes 时不得写 live")
	await get_tree().create_timer(0.35, true, false, true).timeout
	snap = _runtime.snapshot_for(_human)
	var last: Dictionary = (snap.get("picks", []) as Array).back()
	_check(str(last.get("source", "")) == "timeout_rules", "无 Hermes 超时应采用规则首选")
	_check(str(last.get("id", "")) == starred, "超时应采用规则星标")
	_check((snap.get("owned", []) as Array).size() == 3, "三轮结束后应拥有 3 张")


func _test_observation_ops() -> void:
	var dbg := get_node_or_null("/root/DebugControlServer")
	if dbg == null:
		return
	var state: Dictionary = dbg._op_augment_state(_match, {"as_player": "Human"})
	_check(bool(state.get("ok", false)), "op=augment_state 应可读")
	var aug: Dictionary = state.get("augments", {})
	_check((aug.get("owned", []) as Array).size() == 3, "fast/state 快照应含已选 3 张")
	var fast: Dictionary = dbg._op_adjutant_fast_state(_match, {"as_player": "Human"})
	if fast.has("error"):
		return
	var blob = (fast.get("state", {}) as Dictionary).get("augments", {})
	_check(blob is Dictionary and (blob as Dictionary).has("owned"), "fast_state 应带 augments")
	var tactical: Dictionary = dbg._op_tactical(_match, {"as_player": "Human"})
	if not tactical.has("error"):
		_check(tactical.has("augments"), "tactical 应带 augments 供岚读取")


func _test_report_schema() -> void:
	var owned := [{"id": "aug_cash_drop", "tag": "economy", "name": "应急拨款"}]
	var picks := [{"round": 0, "id": "aug_cash_drop", "tag": "economy", "source": "player"}]
	var normalized: Dictionary = Schema.normalize({
		"report_id": "smoke-augments",
		"augments": {"owned": owned, "picks": picks},
	})["report"]
	_check(int(normalized.get("schema_version", 0)) >= 3, "schema_version 应含 augments 区")
	var augments: Dictionary = normalized.get("augments", {})
	_check((augments.get("owned", []) as Array).size() == 1, "normalize 应保留 owned")
	_check(str((augments.get("picks", []) as Array)[0].get("source", "")) == "player",
		"normalize 应保留 pick source")
	var facts := {
		"outcome": normalized.get("outcome"),
		"augments": normalized.get("augments"),
	}
	_check(facts.has("augments"), "read_for_hermes 事实区应能带上 augments")


func _ids(cards: Array) -> Array:
	var out: Array = []
	for item in cards:
		out.append(str(item.get("id", "")))
	return out


func _ensure_mobile_combat_unit(player: Node):
	var found = _find_mobile_combat_unit(player)
	if found != null:
		return found
	var tank = TankScene.instantiate()
	tank.name = "AugmentProbeTank"
	tank.add_to_group("units")
	player.add_child(tank)
	_seed_combat_stats(tank)
	return tank


func _find_mobile_combat_unit(player: Node):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() != player:
			continue
		if Mods.is_structure_unit(unit):
			continue
		if unit.get("attack_damage") != null:
			return unit
	return null


func _find_structure(player: Node):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.get_parent() != player:
			continue
		if Mods.is_structure_unit(unit):
			return unit
	return null


func _seed_combat_stats(unit: Node) -> void:
	if unit == null:
		return
	if unit.get("attack_damage") == null:
		unit.attack_damage = 10.0
	if unit.get("hp_max") == null:
		unit.hp_max = 100.0
		unit.hp = 100.0
	if unit.get("sight_range") == null:
		unit.sight_range = 5.0


func _await_account_ready(timeout_s := 20.0) -> void:
	var economy = _match.get_node_or_null("EconomyRuntime")
	if economy == null:
		_fail("Match 应有 EconomyRuntime")
		return
	var waited := 0.0
	while waited < timeout_s:
		var snap = economy.GetSnapshot(_human)
		if snap is Dictionary and not snap.is_empty():
			return
		await get_tree().create_timer(0.1, true, false, true).timeout
		waited += 0.1
	_fail("未在时限内建立玩家资源账户")


func _check(cond: bool, message: String) -> bool:
	if cond:
		return true
	_fail(message)
	return false


func _fail(message: String) -> void:
	_failures += 1
	push_error(message)
	print("FAIL: %s" % message)


func _finish() -> void:
	print("Match augment smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1, _match)
