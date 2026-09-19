class_name AugmentCatalog
extends RefCounted

## 局内海克斯牌库。id 前缀 aug_，与局外成长树隔离。

const CONFIG_PATH := "res://config/match_augments.json"
const VALID_TAGS := ["economy", "construction", "scout", "military"]
const VALID_RARITIES := ["silver", "gold"]
const VALID_EFFECTS := ["resource_grant", "gather_mult", "damage_mult", "hp_mult", "sight_mult"]

static var _cache: Dictionary = {}


static func reload() -> Dictionary:
	_cache.clear()
	return data()


static func data() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	var file := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if file == null:
		push_error("找不到加成牌库 %s" % CONFIG_PATH)
		_cache = {"rounds": [], "offer_size": 3, "countdown_seconds": 20, "cards": []}
		return _cache
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		_cache = parsed
	else:
		_cache = {"rounds": [], "offer_size": 3, "countdown_seconds": 20, "cards": []}
	return _cache


static func cards() -> Array:
	var raw = data().get("cards", [])
	return raw if raw is Array else []


static func card(card_id: String) -> Dictionary:
	for item in cards():
		if item is Dictionary and str(item.get("id", "")) == card_id:
			return (item as Dictionary).duplicate(true)
	return {}


static func offer_size() -> int:
	return maxi(1, int(data().get("offer_size", 3)))


static func countdown_msec() -> int:
	return maxi(1000, int(round(float(data().get("countdown_seconds", 20)) * 1000.0)))


static func round_at_msec(round_index: int) -> int:
	var rounds = data().get("rounds", [])
	if rounds is Array and round_index >= 0 and round_index < rounds.size():
		var row = rounds[round_index]
		if row is Dictionary:
			return int(row.get("at_msec", 0))
	return -1


static func round_count() -> int:
	var rounds = data().get("rounds", [])
	return rounds.size() if rounds is Array else 0


static func is_valid_card(item: Dictionary) -> bool:
	if str(item.get("id", "")).begins_with("aug_") == false:
		return false
	if str(item.get("tag", "")) not in VALID_TAGS:
		return false
	if str(item.get("rarity", "")) not in VALID_RARITIES:
		return false
	var effect = item.get("effect", {})
	if not effect is Dictionary:
		return false
	return str(effect.get("type", "")) in VALID_EFFECTS


## 按种子抽 `offer_size` 张，跳过已拥有 id / tag / effect type。
static func roll(seed_text: String, owned_ids: Array, owned_tags: Array, owned_effects: Array) -> Array:
	var pool: Array = []
	for item in cards():
		if not item is Dictionary or not is_valid_card(item):
			continue
		var card_id := str(item.get("id", ""))
		var tag := str(item.get("tag", ""))
		var effect_type := str((item.get("effect", {}) as Dictionary).get("type", ""))
		if owned_ids.has(card_id) or owned_tags.has(tag) or owned_effects.has(effect_type):
			continue
		pool.append(item)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(seed_text)
	var picked: Array = []
	var need := mini(offer_size(), pool.size())
	for _i in need:
		if pool.is_empty():
			break
		var total := 0
		for item in pool:
			total += _weight(item)
		var dart := rng.randi_range(1, maxi(1, total))
		var acc := 0
		var chosen_index := 0
		for index in pool.size():
			acc += _weight(pool[index])
			if dart <= acc:
				chosen_index = index
				break
		picked.append((pool[chosen_index] as Dictionary).duplicate(true))
		pool.remove_at(chosen_index)
	return picked


static func _weight(item: Dictionary) -> int:
	return 3 if str(item.get("rarity", "")) == "gold" else 10
