class_name AugmentRanker
extends RefCounted

## 规则地板排序。Hermes / PydanticAI 只允许在此结果上重排，不得发明第四张牌。
## 每条理由必须带 evidence；没有画像就写 rules.fallback，禁止编造成长数据。
##
## **平局键为什么必需**：Godot 的 `Array.sort_custom` 不保证稳定（官方文档明写），
## 实测同分时 n≤16 恰好保序、n=32 起就开始乱（2026-09-15 实测：32 张同分牌首位变成
## 最后一张）。而 Python 的 `list.sort` 是稳定的 ⇒ 只靠「两边都恰好稳定」这个巧合，
## 牌库一旦超过 16 张，Godot 地板与 Python 地板就会在平局上分叉，副官推荐序与兜底序
## 不再是同一个。这里用**原始下标**做次键，把「平局 = 保持输入序」变成两边的显式契约
## （Python 侧 `augment_rank.py` 的排序同样带 `idx`）。
static func rank(offer: Array, facts: Dictionary, profile: Dictionary) -> Dictionary:
	var ids: Array[String] = []
	var scored: Array = []
	var idx := 0
	for item in offer:
		if not item is Dictionary:
			continue
		var card_id := str(item.get("id", ""))
		if card_id.is_empty():
			continue
		ids.append(card_id)
		scored.append({
			"id": card_id,
			"score": _score(item, facts, profile),
			"idx": idx,
			"item": item,
		})
		idx += 1
	scored.sort_custom(func(a, b):
		if int(a["score"]) != int(b["score"]):
			return int(a["score"]) > int(b["score"])
		return int(a["idx"]) < int(b["idx"]))
	var order: Array = []
	var reasons: Array = []
	for row in scored:
		order.append(str(row["id"]))
		reasons.append(_reason(row["item"], facts, profile))
	return {
		"order": order,
		"reasons": reasons,
		"source": "rules" if profile.is_empty() else "cache",
		"starred_id": str(order[0]) if not order.is_empty() else "",
	}


## 规则地板的数值口径。⚠️ 与 Python 侧 `adjutant_coordinator/graph/augment_rank.py`
## 的同名常量必须一致（`tests/test_augment_rank.py` 会读本文件逐条核对，
## 只改一边会红）。`LOW_BALANCE_A` 是「近乎破产」检测，不是相对开局的比例。
const LOW_BALANCE_A := 400
const GRANT_UNIT_A := 1000
const GRANT_BONUS_CAP := 6


static func _score(item: Dictionary, facts: Dictionary, profile: Dictionary) -> int:
	var score := 10
	if str(item.get("rarity", "")) == "gold":
		score += 8
	var tag := str(item.get("tag", ""))
	var army := int(facts.get("army_count", 0))
	var balance := int(facts.get("balance_a", 0))
	var enemies := int(facts.get("enemy_count", 0))
	if tag == "economy":
		score += 6 if balance < LOW_BALANCE_A else 2
		score += _profile_level(profile, "economy_gather") * 3
	elif tag == "construction":
		score += 4 if int(facts.get("structure_count", 0)) >= 1 else 1
		score += _profile_level(profile, "construction_speed") * 3
	elif tag == "scout":
		score += 8 if enemies <= 0 else 2
	elif tag == "military":
		score += 8 if army < 4 else 3
		score += _profile_level(profile, "combat_power") * 3
		if enemies > army:
			score += 6
	# 额度加分与 tag 无关：「工程备料」是 construction 标签但同样给 5000，
	# 只在 economy 分支里加会让它拿不到本该有的权重，副官仍会把它排末位。
	score += _grant_bonus(item)
	return score


## 资金赠予卡的**额度本身**要参与排序。开局 10000（Match.gd:573），一张 5000 的
## 「加钱」牌等于半个开局，不该只在「近乎破产」时才被看见；250 那种小额牌则不该
## 白拿分。每 GRANT_UNIT_A 记 1 分，封顶 GRANT_BONUS_CAP。
## ⚠️ 与 Python 侧 `augment_rank.py:_grant_bonus` 同口径，两边必须同时改；
## 用截断而非四舍五入，避免语言间舍入口径分叉。
static func _grant_bonus(item: Dictionary) -> int:
	var effect = item.get("effect", {})
	if not effect is Dictionary:
		return 0
	if str(effect.get("type", "")) != "resource_grant":
		return 0
	var amount: int = int(effect.get("resource_a", 0))
	return clampi(int(floor(float(amount) / float(GRANT_UNIT_A))), 0, GRANT_BONUS_CAP)


static func _reason(item: Dictionary, facts: Dictionary, profile: Dictionary) -> Dictionary:
	var tag := str(item.get("tag", ""))
	var evidence: Array = []
	var text := "规则按当前兵力与库存排序。"
	if tag == "economy":
		text = "库存偏低、或这张牌能立刻补一大笔资金时优先经济。"
		evidence.append("facts.balance_a")
		if _profile_level(profile, "economy_gather") > 0:
			evidence.append("growth.levels.economy_gather")
	elif tag == "military":
		text = "作战单位少或对面可见兵力更多时优先军事。"
		evidence.append("facts.army_count")
		if _profile_level(profile, "combat_power") > 0:
			evidence.append("growth.levels.combat_power")
	elif tag == "scout":
		text = "还没有稳定敌情时优先侦察视野。"
		evidence.append("facts.enemy_count")
	elif tag == "construction":
		text = "已有基地时加固或备料更划算。"
		evidence.append("facts.structure_count")
	if evidence.is_empty():
		evidence.append("rules.fallback")
		text = "无画像数据，使用规则地板默认序。"
	return {
		"id": str(item.get("id", "")),
		"text": text,
		"evidence": evidence,
	}


static func _profile_level(profile: Dictionary, node_id: String) -> int:
	if profile.is_empty():
		return 0
	var levels = profile.get("levels", {})
	if levels is Dictionary:
		return int(levels.get(node_id, 0))
	var growth = profile.get("growth_levels", {})
	if growth is Dictionary:
		return int(growth.get(node_id, 0))
	return 0
