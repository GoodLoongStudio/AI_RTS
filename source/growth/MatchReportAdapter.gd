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
	return {
		"player_id": player_id,
		"generated_at": Time.get_datetime_string_from_system(),
		"sample_count": summaries.size(),
		"dimensions": {"combat": 0, "economy": 0, "construction": 0, "aggression": 0, "risk_tolerance": 0},
		"preferred_strategies": [],
		"growth_alignment": growth_levels,
		"recommended_adjutants": [],
		"evidence": summaries,
		"source_reports": [],
		"model_version": "local-baseline-1"
	}
