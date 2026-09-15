class_name MatchReportAdapter
extends RefCounted

## 将已有对局档案归一化为 Hermes 可消费的只读摘要；缺失字段保持为空。
static func summarize(report: Dictionary) -> Dictionary:
	return {
		"match_id": report.get("match_id", ""),
		"outcome": report.get("outcome", "unknown"),
		"resources": report.get("resources", {}),
		"production": report.get("production", {}),
		"construction": report.get("construction", {}),
		"combat": report.get("combat", {}),
		"key_events": report.get("key_events", []),
		"growth_levels": report.get("growth_levels", {})
	}

static func build_profile_snapshot(player_id: String, summaries: Array, growth_levels: Dictionary) -> Dictionary:
	var combat := 0.0
	var economy := 0.0
	var construction := 0.0
	var aggression := 0.0
	var risk := 0.0
	var wins := 0
	var routes: Dictionary = {}
	for report in summaries:
		var combat_data: Dictionary = report.get("combat", {})
		var resources: Dictionary = report.get("resources", {})
		var production: Dictionary = report.get("production", {})
		var build: Dictionary = report.get("construction", {})
		combat += clampf(float(combat_data.get("damage_dealt", 0)) / 12000.0, 0.0, 1.0)
		economy += clampf(float(resources.get("gathered", 0)) / 1800.0, 0.0, 1.0)
		construction += clampf(float(build.get("value", 0.0)), 0.0, 1.0)
		aggression += clampf(float(combat_data.get("damage_dealt", 0)) / maxf(float(combat_data.get("damage_taken", 1)), 1.0) / 2.0, 0.0, 1.0)
		risk += clampf(float(combat_data.get("units_lost", 0)) / 24.0, 0.0, 1.0)
		if str(report.get("outcome", "")) == "victory": wins += 1
		for route in production.get("routes", []): routes[str(route)] = int(routes.get(str(route), 0)) + 1
	var count := maxf(float(summaries.size()), 1.0)
	var top_route := "综合编组"
	var top_count := 0
	for route in routes:
		if int(routes[route]) > top_count: top_route = route; top_count = int(routes[route])
	return {
		"player_id": player_id,
		"generated_at": Time.get_datetime_string_from_system(),
		"sample_count": summaries.size(),
		"dimensions": {"combat": round(combat / count * 100.0), "economy": round(economy / count * 100.0), "construction": round(construction / count * 100.0), "aggression": round(aggression / count * 100.0), "risk_tolerance": round(risk / count * 100.0)},
		"preferred_strategies": ["%s路线" % top_route, "主动进攻" if aggression / count > 0.55 else "稳健运营"],
		"growth_alignment": growth_levels,
		"recommended_adjutants": [{"type":"前线指挥官", "reason":"战斗贡献与进攻倾向较高，适合强化侧翼与反攻节奏。"}],
		"evidence": summaries,
		"source_reports": summaries.map(func(r): return r.get("match_id", "")),
		"model_version": "local-baseline-1"
	}
