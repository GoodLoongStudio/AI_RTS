class_name MatchReportScoring
extends RefCounted

## 对局表现评分：**先算依据，再算分**。
##
## 设计原则（用户要求"不要只显示一个总分，要显示评分依据"）：
## - 每个维度只吃报告里真实存在的数字；缺哪个就用不着哪个，并把维度分记为 null。
## - 每个维度的 `basis` 是一串"用到了哪些数字、怎么算的"的可核对说明，
##   玩家能在同一页里把这些数字逐个对上。
## - 总分 = 可用维度按权重归一化后的加权平均；只要有维度缺失就标 `partial = true`，
##   UI 必须把"部分依据缺失"显示出来，不允许假装是一个完整评分。
##
## 参考区间刻意写在这里而不是散落各处，方便后续按真实对局分布调参。

const METHOD := "hermes-baseline-v1"

## 每分钟采集量的"满分参考线"（资源 A+B 合计）。低于它按比例给分。
const GATHER_PER_MIN_REFERENCE := 42.0
## 每分钟伤害的满分参考线。
const DAMAGE_PER_MIN_REFERENCE := 240.0
## 期望采集/生产单位数参考。
const GATHERER_REFERENCE := 18.0


## 计算并写回 `performance_score`。返回新的报告副本。
static func apply(report: Dictionary) -> Dictionary:
	var result := report.duplicate(true)
	result["performance_score"] = evaluate(report)
	return result


## 纯函数：从 report 推导评分，不修改入参。
static func evaluate(report: Dictionary) -> Dictionary:
	var breakdown := {
		"combat": _combat(report),
		"economy": _economy(report),
		"construction": _construction(report),
		"operations": _operations(report),
		"risk": _risk(report),
		"objectives": _objectives(report),
	}
	var weight_sum := 0.0
	var total := 0.0
	var missing_dims := PackedStringArray()
	for dimension in MatchReportSchema.SCORE_DIMENSIONS:
		var entry: Dictionary = breakdown[dimension]
		if entry.get("score", null) == null:
			missing_dims.append(dimension)
			continue
		var weight := float(MatchReportSchema.SCORE_WEIGHTS.get(dimension, 0.0))
		weight_sum += weight
		total += float(entry["score"]) * weight
	var partial := not missing_dims.is_empty()
	var final_total = null
	if weight_sum > 0.0:
		final_total = int(round(total / weight_sum))
	return {
		"total": final_total,
		"method": METHOD,
		"partial": partial,
		"missing_dimensions": Array(missing_dims),
		"breakdown": breakdown,
	}


# ---------------- 各维度 ----------------

static func _combat(report: Dictionary) -> Dictionary:
	var damage: Variant = _path(report, "combat.damage", {})
	var dealt = damage.get("dealt", null)
	var taken = damage.get("taken", null)
	var killed = _path(report, "overview.enemies_killed", null)
	var lost = _path(report, "overview.units_lost", null)
	var duration = report.get("duration_seconds", null)
	var parts := PackedStringArray()
	var scores: Array = []
	var labels: Array = []

	if dealt != null and taken != null:
		var exchange := float(dealt) / maxf(float(taken), 1.0)
		var exchange_score := clampf(exchange / 1.6, 0.0, 1.0)
		scores.append(exchange_score)
		labels.append("交换比 %.2f" % exchange)
		parts.append("伤害交换 %.2f = 造成 %s / 承受 %s" % [
			exchange, MatchReportSchema.number_text(dealt), MatchReportSchema.number_text(taken)])
	if dealt != null and duration != null and float(duration) > 0.0:
		var per_min := float(dealt) / (float(duration) / 60.0)
		scores.append(clampf(per_min / DAMAGE_PER_MIN_REFERENCE, 0.0, 1.0))
		labels.append("DPM %.0f" % per_min)
		parts.append("每分钟伤害 %.0f（参考线 %.0f）" % [per_min, DAMAGE_PER_MIN_REFERENCE])
	if killed != null and lost != null:
		var kd := float(killed) / maxf(float(lost), 1.0)
		scores.append(clampf(kd / 2.5, 0.0, 1.0))
		labels.append("交换损失 %.2f" % kd)
		parts.append("击杀 %s / 损失 %s = %.2f" % [
			MatchReportSchema.number_text(killed), MatchReportSchema.number_text(lost), kd])
	if scores.is_empty():
		return {"score": null, "basis": "缺少伤害/损失数据，无法评分", "metrics": []}

	var droughts_in_combat: Variant = _path(report, "combat.quality.resource_drought_in_combat", null)
	if droughts_in_combat != null:
		parts.append("战斗中资源断档 %d 次" % int(droughts_in_combat))
	return {
		"score": _average(scores),
		"basis": "；".join(parts),
		"metrics": labels,
	}


static func _economy(report: Dictionary) -> Dictionary:
	var totals: Variant = _path(report, "economy.totals", {})
	var gathered = totals.get("gathered", null)
	var wasted = totals.get("wasted", null)
	var utilization = _path(report, "economy.utilization", null)
	var duration = report.get("duration_seconds", null)
	var parts := PackedStringArray()
	var scores: Array = []

	if gathered != null and duration != null and float(duration) > 0.0:
		var per_min := float(gathered) / (float(duration) / 60.0)
		scores.append(clampf(per_min / GATHER_PER_MIN_REFERENCE, 0.0, 1.0))
		parts.append("采集 %s，均速 %.1f/min（参考线 %.0f）" % [
			MatchReportSchema.number_text(gathered), per_min, GATHER_PER_MIN_REFERENCE])
	if utilization != null:
		scores.append(clampf(float(utilization), 0.0, 1.0))
		parts.append("资源利用率 %s" % MatchReportSchema.percent_text(utilization))
	if gathered != null and wasted != null and float(gathered) > 0.0:
		var waste_ratio := float(wasted) / float(gathered)
		scores.append(clampf(1.0 - waste_ratio * 4.0, 0.0, 1.0))
		parts.append("浪费 %s（占采集 %s）" % [
			MatchReportSchema.number_text(wasted), MatchReportSchema.percent_text(waste_ratio)])
	if scores.is_empty():
		return {"score": null, "basis": "缺少采集/消耗数据，无法评分", "metrics": []}
	return {"score": _average(scores), "basis": "；".join(parts), "metrics": []}


static func _construction(report: Dictionary) -> Dictionary:
	var built = _path(report, "construction.total_built", null)
	var survival = _path(report, "construction.survival_rate", null)
	var integrity = _path(report, "construction.defense_line_integrity", null)
	var expansions = _path(report, "construction.expansions", null)
	var parts := PackedStringArray()
	var scores: Array = []

	if built != null:
		scores.append(clampf(float(built) / 20.0, 0.0, 1.0))
		parts.append("建造建筑 %s 座（参考线 20）" % MatchReportSchema.number_text(built))
	if survival != null:
		scores.append(clampf(float(survival), 0.0, 1.0))
		parts.append("建筑存活率 %s" % MatchReportSchema.percent_text(survival))
	if integrity != null:
		scores.append(clampf(float(integrity), 0.0, 1.0))
		parts.append("防线完整度 %s" % MatchReportSchema.percent_text(integrity))
	if expansions != null:
		scores.append(clampf(float(expansions) / 3.0, 0.0, 1.0))
		parts.append("扩张 %s 次（参考线 3）" % MatchReportSchema.number_text(expansions))
	if scores.is_empty():
		return {"score": null, "basis": "缺少建设数据，无法评分", "metrics": []}
	return {"score": _average(scores), "basis": "；".join(parts), "metrics": []}


static func _operations(report: Dictionary) -> Dictionary:
	var utilization = _path(report, "production.queue.utilization", null)
	var idle = _path(report, "production.queue.idle_total_s", null)
	var duration = report.get("duration_seconds", null)
	var gatherers = _path(report, "economy.structure.gatherers", [])
	var first_force = _path(report, "production.queue.first_main_force_s", null)
	var parts := PackedStringArray()
	var scores: Array = []

	if utilization != null:
		scores.append(clampf(float(utilization), 0.0, 1.0))
		parts.append("生产队列利用率 %s" % MatchReportSchema.percent_text(utilization))
	if idle != null and duration != null and float(duration) > 0.0:
		var idle_ratio := float(idle) / float(duration)
		scores.append(clampf(1.0 - idle_ratio * 2.0, 0.0, 1.0))
		parts.append("队列空转 %s（占对局 %s）" % [
			MatchReportSchema.duration_text(idle), MatchReportSchema.percent_text(idle_ratio)])
	if gatherers is Array and not (gatherers as Array).is_empty():
		var peak := 0
		for entry in (gatherers as Array):
			if entry is Dictionary and (entry as Dictionary).get("count", null) != null:
				peak = maxi(peak, int((entry as Dictionary)["count"]))
		if peak > 0:
			scores.append(clampf(float(peak) / GATHERER_REFERENCE, 0.0, 1.0))
			parts.append("采集单位峰值 %d（参考线 %.0f）" % [peak, GATHERER_REFERENCE])
	if first_force != null and duration != null and float(duration) > 0.0:
		var ratio := float(first_force) / float(duration)
		scores.append(clampf(1.0 - ratio, 0.0, 1.0))
		parts.append("首支主力成型于 %s（占对局 %s）" % [
			MatchReportSchema.duration_text(first_force), MatchReportSchema.percent_text(ratio)])
	if scores.is_empty():
		return {"score": null, "basis": "缺少运营数据，无法评分", "metrics": []}
	return {"score": _average(scores), "basis": "；".join(parts), "metrics": []}


static func _risk(report: Dictionary) -> Dictionary:
	var lost = _path(report, "overview.units_lost", null)
	var produced = _path(report, "overview.units_produced", null)
	# 默认值必须是 null 而不是 []：报告根本没有经济分区时，"零次断档"不是事实，
	# 而是"没有这个数据"。用 [] 会让空报告白拿一个满分风险分。
	var droughts: Variant = _path(report, "economy.structure.drought_windows", null)
	var integrity = _path(report, "construction.defense_line_integrity", null)
	var parts := PackedStringArray()
	var scores: Array = []

	if lost != null and produced != null and float(produced) > 0.0:
		var loss_ratio := float(lost) / float(produced)
		scores.append(clampf(1.0 - loss_ratio, 0.0, 1.0))
		parts.append("单位损失率 %s（损失 %s / 生产 %s）" % [
			MatchReportSchema.percent_text(loss_ratio), MatchReportSchema.number_text(lost),
			MatchReportSchema.number_text(produced)])
	if droughts is Array:
		scores.append(clampf(1.0 - float((droughts as Array).size()) / 5.0, 0.0, 1.0))
		parts.append("资源断档 %d 次（参考容忍 5）" % (droughts as Array).size())
	if integrity != null:
		scores.append(clampf(float(integrity), 0.0, 1.0))
		parts.append("防线完整度 %s" % MatchReportSchema.percent_text(integrity))
	if scores.is_empty():
		return {"score": null, "basis": "缺少损失/断档数据，无法评分", "metrics": []}
	return {"score": _average(scores), "basis": "；".join(parts), "metrics": []}


static func _objectives(report: Dictionary) -> Dictionary:
	var done = _path(report, "overview.objectives_completed", null)
	var failed = _path(report, "overview.objectives_failed", null)
	if not (done is Array) or not (failed is Array):
		return {"score": null, "basis": "缺少目标清单，无法评分", "metrics": []}
	var total := (done as Array).size() + (failed as Array).size()
	if total == 0:
		return {"score": null, "basis": "本局未登记关键目标", "metrics": []}
	var score := int(round(float((done as Array).size()) / float(total) * 100.0))
	return {
		"score": score,
		"basis": "完成 %d / 共 %d 项关键目标（失败 %d 项）"
			% [(done as Array).size(), total, (failed as Array).size()],
		"metrics": [],
	}


# ---------------- 工具 ----------------

static func _average(scores: Array) -> int:
	if scores.is_empty():
		return 0
	var total := 0.0
	for value in scores:
		total += clampf(float(value), 0.0, 1.0)
	return int(round(total / float(scores.size()) * 100.0))


static func _path(report: Dictionary, path: String, default: Variant) -> Variant:
	var current: Variant = report
	for segment in path.split("."):
		if not (current is Dictionary) or not (current as Dictionary).has(segment):
			return default
		current = (current as Dictionary)[segment]
	if current == null:
		return default
	return current
