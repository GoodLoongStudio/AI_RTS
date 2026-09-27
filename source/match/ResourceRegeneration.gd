extends Node

## 矿点周期再生的**唯一权威**驱动器（阶段 4 / 提示词 8.2）。
##
## 纪律：
## - 只在权威端跑：客户端傀儡不推进（否则两端各自刷矿必然分叉）。
## - 只按**模拟毫秒**计时：本节点继承 Match 的 PAUSABLE，暂停时 `_physics_process` 不被调用，
##   所以暂停期间不偷跑；不使用墙钟（Time.get_ticks_msec）也不使用客户端定时器。
## - 恢复只加**矿点存量**，绝不直接给玩家账户加钱；收入仍然必须经过采集与交付。
## - 同一再生周期只结算一次：到账即把矿点从 depleted 翻回 ready，计时归零，
##   再次进入本分支必须等到它重新被采空——重复调用本帧不会多刷。
## - 矿量不超过容量：`apply_regeneration` 内部按 room 夹紧。
##
## 关闭再生（配置 regeneration.enabled=false 或整块缺失）时保持旧语义：采空即消失。

## 每个权威物理帧请求一次恢复的矿点（供 HUD / 联机镜像 / 对局报告订阅）。
signal ore_replenished(node, added_amount)
signal ore_exhausted(node)

## 测试夹具用覆盖（提示词 8.4 要求"小容量、短等待的专用夹具"）：非空时取代从 balance
## 读到的规则。只影响计时与恢复量，不绕过任何权威判定；正常对局留空。
@export var rule_overrides := {}

var _balance = null
## 每种资源（resource_a / resource_b）的再生规则缓存；null 表示尚未读到配置。
var _rules_by_property = {}
## 已经广播过"耗尽"的矿点，避免每帧重复发信号。
var _exhausted_notified := {}


func _ready():
	# 与 SimulationClock 同性质：暂停时不推进。Match 根节点是 PAUSABLE，子节点默认继承，
	# 这里显式写出来是为了让"暂停不计时"这件事在读代码时一眼可见，而不是靠继承推断。
	process_mode = Node.PROCESS_MODE_INHERIT


func _physics_process(delta: float):
	if get_tree() != null and get_tree().paused:
		return
	if _balance == null:
		_balance = get_parent().get_node_or_null("BalanceConfigRuntime")
		if _balance == null:
			return
	var elapsed_ms := int(round(delta * 1000.0))
	for node in get_tree().get_nodes_in_group("resource_units"):
		if node == null or not is_instance_valid(node) or not node.has_method("ensure_capacity_recorded"):
			continue
		_step(node, elapsed_ms)


func _step(node, elapsed_ms: int):
	node.ensure_capacity_recorded()
	var property_name := _ore_property(node)
	if property_name.is_empty():
		return
	var rule := _rule_for(property_name)
	if not bool(rule.get("enabled", false)):
		# 旧语义：采空即消失。
		if node.total_ore() <= 0 and not node.is_queued_for_deletion():
			node.queue_free()
		return
	if node.total_ore() > 0:
		node.regen_remaining_ms = int(rule.get("delay_milliseconds", 0))
		_exhausted_notified.erase(node)
		return
	if not node.depleted:
		node.mark_depleted()
	if not _exhausted_notified.has(node):
		_exhausted_notified[node] = true
		ore_exhausted.emit(node)
		MatchSignals.resource_exhausted.emit(node)
	node.regen_remaining_ms -= elapsed_ms
	if node.regen_remaining_ms > 0:
		return
	# 到点：结算一次，然后重新计时。`apply_regeneration` 会把矿点翻回 ready，
	# 于是下一帧起走上面的"仍有矿"分支，本周期不会再进入这里 ⇒ 天然幂等。
	var added = node.apply_regeneration(int(rule.get("restore_amount", 0)))
	node.regen_remaining_ms = int(rule.get("delay_milliseconds", 0))
	if added > 0:
		ore_replenished.emit(node, added)
		MatchSignals.resource_replenished.emit(node, added)


## 该矿点属于哪种资源（决定套用哪条再生规则）：看它带的是哪个属性，不看场景名。
func _ore_property(node) -> String:
	if "resource_a" in node:
		return "resource_a"
	if "resource_b" in node:
		return "resource_b"
	return ""


func _rule_for(property_name: String) -> Dictionary:
	if rule_overrides.has(property_name):
		return rule_overrides[property_name]
	if not _rules_by_property.has(property_name):
		var rule: Dictionary = {}
		if _balance.has_method("GetResourceRegeneration"):
			rule = _balance.GetResourceRegeneration(property_name)
		_rules_by_property[property_name] = rule
	return _rules_by_property[property_name]
