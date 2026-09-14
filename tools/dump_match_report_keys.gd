extends Node

## 一次性审计工具：把 MatchReportSchema 的字段树 / 枚举 / 时间线事件类型全量打印出来，
## 用于**逐条对照需求清单**（21 类时间线事件、伤害 11 项、战斗质量 13 项……）。
## 不进回归清单（在 tools/ 下，Assert-Manifest 不扫），用完即删。

func _ready() -> void:
	var template: Dictionary = MatchReportSchema.TEMPLATE
	print("=== TOPLEVEL (%d) ===" % template.keys().size())
	for key in template.keys():
		print("  %s" % str(key))

	print("=== LEAF PATHS ===")
	var leaves: Array = []
	_collect(template, "", leaves)
	leaves.sort()
	for path in leaves:
		print("  %s" % str(path))

	print("=== SECTION LEAF COUNTS ===")
	for section in ["overview", "economy", "production", "construction", "combat",
			"performance_score", "hermes_analysis", "map", "adjutant", "growth_after"]:
		var sub: Variant = template.get(section, null)
		var sub_leaves: Array = []
		if sub is Dictionary:
			_collect(sub, "", sub_leaves)
		print("  %s = %d" % [section, sub_leaves.size()])

	print("=== ENUMS ===")
	print("  OUTCOMES(%d)=%s" % [MatchReportSchema.OUTCOMES.size(), str(MatchReportSchema.OUTCOMES)])
	print("  MODES(%d)=%s" % [MatchReportSchema.MODES.size(), str(MatchReportSchema.MODES)])
	print("  DIFFICULTIES(%d)=%s" % [MatchReportSchema.DIFFICULTIES.size(), str(MatchReportSchema.DIFFICULTIES)])
	print("  HERMES_STATUSES(%d)=%s" % [MatchReportSchema.HERMES_STATUSES.size(), str(MatchReportSchema.HERMES_STATUSES)])
	print("  SCORE_DIMENSIONS(%d)=%s" % [MatchReportSchema.SCORE_DIMENSION_LABEL.keys().size(),
		str(MatchReportSchema.SCORE_DIMENSION_LABEL.keys())])
	print("  TIMELINE_TYPES(%d)=%s" % [MatchReportSchema.TIMELINE_TYPES.keys().size(),
		str(MatchReportSchema.TIMELINE_TYPES.keys())])

	print("=== SECTION KEYS ===")
	for section in ["overview", "economy", "production", "construction", "combat", "hermes_analysis"]:
		var sub: Variant = template.get(section, null)
		if sub is Dictionary:
			print("  %s -> %s" % [section, str((sub as Dictionary).keys())])
			for key in (sub as Dictionary).keys():
				var child: Variant = (sub as Dictionary)[key]
				if child is Dictionary and not (child as Dictionary).is_empty():
					print("      %s.%s -> %s" % [section, str(key), str((child as Dictionary).keys())])

	get_tree().quit(0)


func _collect(value: Variant, prefix: String, out: Array) -> void:
	if not (value is Dictionary):
		return
	for key in (value as Dictionary).keys():
		var path := "%s.%s" % [prefix, str(key)] if not prefix.is_empty() else str(key)
		var child: Variant = (value as Dictionary)[key]
		if child is Dictionary and not (child as Dictionary).is_empty():
			_collect(child, path, out)
		else:
			out.append(path)
