class_name DemoMatchReports
extends RefCounted

## 历史对局 Demo 数据生成器。
##
## 纪律：**Demo 数据必须自洽且可复现**。
## - 全部数值由 `RandomNumberGenerator`（种子 = BASE_SEED 派生）确定性生成，
##   同一 `demo_seed` 每次生成完全一致，便于截图比对与回归断言。
## - 交叉校验必须在生成阶段就满足：`overview.damage_dealt` 与
##   `combat.damage.dealt`、`overview.total_gathered` 与 `economy.totals.gathered`
##   是同一批数字的两处投影，不是各写一遍（否则 `MatchReportSchema.validate()`
##   会在 UI 之前就报错）。
## - 所有报告固定 `demo = true` + `demo_seed`，UI 必须打出 DEMO 徽标。
##
## 单位/建筑 id 取自 `config/balance/demo.balance.v1.json` 的真实 id，
## 因此后续把真实对局事件喂进来时，统计表结构无需改动。

const BASE_SEED := 20260914

## 单位目录：id 与平衡表一致；category 决定分组，weight/role 决定占比统计口径。
const UNITS := {
	"worker": {"label": "工程车", "category": "economy", "weight_class": "light", "role_class": "support", "cost": 200},
	"soldier": {"label": "步兵", "category": "infantry", "weight_class": "light", "role_class": "ranged", "cost": 150},
	"sniper": {"label": "狙击手", "category": "infantry", "weight_class": "light", "role_class": "ranged", "cost": 350},
	"rocketeer": {"label": "火箭兵", "category": "infantry", "weight_class": "light", "role_class": "ranged", "cost": 300},
	"apc": {"label": "装甲运兵车", "category": "vehicle", "weight_class": "medium", "role_class": "ranged", "cost": 450},
	"tank": {"label": "主战坦克", "category": "vehicle", "weight_class": "medium", "role_class": "ranged", "cost": 600},
	"heavy_tank": {"label": "重型坦克", "category": "vehicle", "weight_class": "heavy", "role_class": "ranged", "cost": 950},
	"transport_truck": {"label": "运输车", "category": "vehicle", "weight_class": "medium", "role_class": "support", "cost": 400},
	"drone": {"label": "无人机", "category": "air", "weight_class": "light", "role_class": "air", "cost": 200},
	"helicopter": {"label": "武装直升机", "category": "air", "weight_class": "medium", "role_class": "air", "cost": 800},
}

const BUILDINGS := {
	"command_center": {"label": "指挥中心", "role": "核心", "cost": 0},
	"barracks": {"label": "兵营", "role": "生产", "cost": 400},
	"vehicle_factory": {"label": "车辆工厂", "role": "生产", "cost": 700},
	"aircraft_factory": {"label": "空军工厂", "role": "生产", "cost": 900},
	"anti_ground_turret": {"label": "对地炮塔", "role": "防御", "cost": 450},
	"anti_air_turret": {"label": "对空炮塔", "role": "防御", "cost": 450},
	"machine_gun_turret": {"label": "机枪塔", "role": "防御", "cost": 300},
}

const ADJUTANTS := ["前线指挥官", "后勤统筹官", "工事工程师", "侦察参谋"]

## 每场对局的定性配置。数值细节由种子推导，这里只固定"这场是什么局"。
const PLAN := [
	{
		"outcome": "victory", "map": 0, "mode": "custom", "difficulty": "normal",
		"adjutant": 0, "duration": 812, "aggression": 0.78, "economy_focus": 0.52,
		"composition": {"worker": 12, "soldier": 18, "tank": 9, "apc": 4, "drone": 3},
		"buildings": ["command_center", "barracks", "vehicle_factory", "anti_ground_turret"],
		"defensive": false, "expansions": 2, "hermes": "completed",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "",
	},
	{
		"outcome": "victory", "map": 0, "mode": "custom", "difficulty": "hard",
		"adjutant": 1, "duration": 1146, "aggression": 0.44, "economy_focus": 0.81,
		"composition": {"worker": 20, "soldier": 10, "rocketeer": 8, "heavy_tank": 6, "helicopter": 2},
		"buildings": ["command_center", "barracks", "vehicle_factory", "aircraft_factory", "anti_air_turret"],
		"defensive": true, "expansions": 3, "hermes": "completed",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "",
	},
	{
		"outcome": "defeat", "map": 1, "mode": "online", "difficulty": "hard",
		"adjutant": 3, "duration": 903, "aggression": 0.86, "economy_focus": 0.31,
		"composition": {"worker": 8, "soldier": 14, "sniper": 6, "drone": 5, "apc": 3},
		"buildings": ["command_center", "barracks", "aircraft_factory", "anti_ground_turret"],
		"defensive": false, "expansions": 1, "hermes": "completed",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "指挥中心被摧毁：中期资源断档导致防线无法补位",
	},
	{
		"outcome": "victory", "map": 2, "mode": "custom", "difficulty": "normal",
		"adjutant": 2, "duration": 1342, "aggression": 0.36, "economy_focus": 0.88,
		"composition": {"worker": 24, "tank": 12, "heavy_tank": 4},
		"buildings": ["command_center", "barracks", "vehicle_factory", "anti_ground_turret", "anti_air_turret"],
		"defensive": true, "expansions": 4, "hermes": "completed",
		"victory_condition": "控制全部资源点", "defeat_reason": "",
	},
	{
		"outcome": "victory", "map": 0, "mode": "custom", "difficulty": "easy",
		"adjutant": 0, "duration": 604, "aggression": 0.91, "economy_focus": 0.40,
		"composition": {"worker": 9, "soldier": 22, "rocketeer": 7, "helicopter": 3},
		"buildings": ["command_center", "barracks", "anti_ground_turret"],
		"defensive": false, "expansions": 1, "hermes": "completed",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "",
	},
	{
		"outcome": "defeat", "map": 2, "mode": "online", "difficulty": "brutal",
		"adjutant": 0, "duration": 1521, "aggression": 0.52, "economy_focus": 0.61,
		"composition": {"worker": 16, "soldier": 12, "tank": 8, "sniper": 4, "transport_truck": 2},
		"buildings": ["command_center", "barracks", "vehicle_factory", "machine_gun_turret", "anti_air_turret"],
		"defensive": true, "expansions": 2, "hermes": "cached",
		"victory_condition": "坚守至时间结束", "defeat_reason": "超时未达成目标：对手控制区优势过大",
	},
	{
		"outcome": "victory", "map": 1, "mode": "skirmish", "difficulty": "normal",
		"adjutant": 3, "duration": 738, "aggression": 0.69, "economy_focus": 0.58,
		"composition": {"worker": 14, "soldier": 16, "apc": 6, "helicopter": 4, "drone": 4},
		"buildings": ["command_center", "barracks", "vehicle_factory", "aircraft_factory", "anti_ground_turret"],
		"defensive": false, "expansions": 2, "hermes": "completed",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "",
	},
	{
		"outcome": "aborted", "map": 0, "mode": "custom", "difficulty": "normal",
		"adjutant": 1, "duration": 214, "aggression": 0.50, "economy_focus": 0.70,
		"composition": {"worker": 6, "soldier": 4},
		"buildings": ["command_center", "barracks"],
		"defensive": false, "expansions": 0, "hermes": "none",
		"victory_condition": "摧毁敌方指挥中心", "defeat_reason": "",
		"aborted_reason": "玩家中途退出对局（第 3 分 34 秒）",
	},
	{
		"outcome": "defeat", "map": 1, "mode": "online", "difficulty": "hard",
		"adjutant": 2, "duration": 1765, "aggression": 0.33, "economy_focus": 0.74,
		"composition": {"worker": 22, "tank": 10, "heavy_tank": 3, "sniper": 5},
		"buildings": ["command_center", "barracks", "vehicle_factory", "anti_ground_turret", "anti_air_turret", "machine_gun_turret"],
		"defensive": true, "expansions": 5, "hermes": "running",
		"victory_condition": "控制全部资源点", "defeat_reason": "经济被压制：扩张点逐一失守",
	},
	{
		"outcome": "victory", "map": 2, "mode": "campaign", "difficulty": "brutal",
		"adjutant": 0, "duration": 1984, "aggression": 0.62, "economy_focus": 0.66,
		"composition": {"worker": 19, "soldier": 15, "rocketeer": 9, "heavy_tank": 7, "helicopter": 5},
		"buildings": ["command_center", "barracks", "vehicle_factory", "aircraft_factory", "anti_ground_turret", "anti_air_turret"],
		"defensive": true, "expansions": 4, "hermes": "failed",
		"victory_condition": "摧毁敌方全部生产建筑", "defeat_reason": "",
	},
]

const MAPS := [
	{"name": "Plain & Simple", "path": "res://source/match/maps/PlainAndSimple.tscn", "players": 4, "size": "50×50"},
	{"name": "Big Arena", "path": "res://source/match/maps/BigArena.tscn", "players": 8, "size": "100×100"},
	{
		"name": "G4 大湖 seed16",
		"path": "res://source/match/maps/generated/16-0-7d337ce8be/map_16-0-7d337ce8be.tscn",
		"players": 4, "size": "2048×2048",
	},
]

## 报告生成基准时刻（本地时间）。真实对局由 `Time.get_datetime_string_from_system()` 填。
const BASE_LOCAL := "2026-09-14T22:00:00"


## 生成 Demo 报告数组（已 normalize + 已评分 + 已算完整度）。
static func build(count: int = -1) -> Array:
	var total := PLAN.size() if count < 0 else mini(count, PLAN.size())
	var base_unix := Time.get_unix_time_from_datetime_string(BASE_LOCAL)
	var reports: Array = []
	for index in range(total):
		var cfg: Dictionary = PLAN[index].duplicate(true)
		# 每场间隔 6 小时 20 分向前回溯，保证列表按日期排序有稳定顺序。
		var created := Time.get_datetime_string_from_unix_time(
			int(base_unix) - index * (6 * 3600 + 20 * 60), true).replace("T", " ")
		reports.append(_build_one(index, cfg, created))
	return reports


## 单份 Demo 报告。
static func _build_one(index: int, cfg: Dictionary, created_at: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = BASE_SEED + index * 7919
	var duration := float(cfg["duration"])
	var map_info: Dictionary = MAPS[int(cfg["map"])]
	var outcome := str(cfg["outcome"])
	var aborted := outcome == "aborted"
	var scale := duration / 900.0  # 相对基准局时长

	# ---------- 资源 ----------
	var initial_a := 1000.0
	var initial_b := 400.0
	var gather_rate := (16.0 + float(cfg["economy_focus"]) * 22.0) * (1.0 + rng.randf_range(-0.08, 0.08))
	var gathered_a := roundf(gather_rate * (duration / 60.0))
	var gathered_b := roundf(gathered_a * rng.randf_range(0.22, 0.34))
	var spent_a := roundf(gathered_a * (0.72 + float(cfg["aggression"]) * 0.16))
	var spent_b := roundf(gathered_b * 0.80)
	var wasted_a := roundf(gathered_a * rng.randf_range(0.01, 0.05))
	var wasted_b := roundf(gathered_b * rng.randf_range(0.0, 0.03))
	var remaining_a := initial_a + gathered_a - spent_a - wasted_a
	var remaining_b := initial_b + gathered_b - spent_b - wasted_b
	var total_gathered := gathered_a + gathered_b
	var total_spent := spent_a + spent_b
	var total_wasted := wasted_a + wasted_b

	# ---------- 单位 ----------
	var unit_rows: Array = []
	var combat_rows: Array = []
	var produced_total := 0
	var lost_total := 0
	var killed_total := 0
	var unit_damage_dealt := 0.0
	var unit_damage_taken := 0.0
	var composition: Dictionary = cfg["composition"]
	var unit_ids: Array = composition.keys()
	unit_ids.sort()
	var aggression := float(cfg["aggression"])
	var damage_dealt_total := roundf(float(cfg["economy_focus"]) * 6200.0 + aggression * 9800.0
		+ duration * 1.4 + rng.randf_range(-400.0, 400.0))
	var damage_taken_total := roundf(damage_dealt_total * (0.42 + (1.0 - float(cfg["economy_focus"])) * 0.55))
	for unit_id in unit_ids:
		var info: Dictionary = UNITS[unit_id]
		var produced := int(composition[unit_id])
		# 防御型局 + 重甲单位损失低；高攻局 + 轻型单位损失高。
		var weight_penalty := 1.0 if str(info["weight_class"]) == "heavy" else 1.22
		var loss_rate := clampf((0.26 + (1.0 - float(cfg["economy_focus"])) * 0.30) / weight_penalty,
			0.05, 0.85)
		if aborted:
			loss_rate *= 0.3
		var lost := int(roundf(float(produced) * loss_rate))
		if str(info["category"]) == "economy":
			lost = int(roundf(float(lost) * 0.5))
		var killed := int(roundf(float(produced) * (0.55 + aggression * 1.5)
			* (1.0 if str(info["weight_class"]) != "light" else 0.7)))
		var cost := int(info["cost"])
		var row := {
			"id": unit_id,
			"label": str(info["label"]),
			"category": str(info["category"]),
			"weight_class": str(info["weight_class"]),
			"role_class": str(info["role_class"]),
			"produced": produced,
			"alive": maxi(0, produced - lost),
			"batches": maxi(1, int(roundf(float(produced) / rng.randf_range(2.0, 4.0)))),
			"avg_interval_s": roundf(rng.randf_range(28.0, 74.0) / maxf(scale, 0.4)),
			"resource_cost": produced * cost,
			"killed": killed,
			"lost": lost,
			"damage_dealt": 0.0,
			"damage_taken": 0.0,
			"avg_lifetime_s": roundf(rng.randf_range(90.0, 320.0) * (1.0 + (1.0 - loss_rate))),
			"first_seen_s": roundf(maxf(20.0, rng.randf_range(20.0, 150.0))),
			"last_alive_s": roundf(duration * rng.randf_range(0.55, 0.98)),
		}
		unit_rows.append(row)
		combat_rows.append(row.duplicate(true))
		produced_total += produced
		lost_total += lost
		killed_total += killed

	# 伤害按产量权重分摊，末项吸收余量以保证与总览完全一致。
	var weight_sum := 0.0
	for row in unit_rows:
		weight_sum += float((row as Dictionary)["produced"]) * (1.0 + float((row as Dictionary)["produced"]) * 0.02)
	for i in range(unit_rows.size()):
		var row: Dictionary = unit_rows[i]
		var weight := float(row["produced"]) * (1.0 + float(row["produced"]) * 0.02)
		var dealt := damage_dealt_total * weight / maxf(weight_sum, 1.0)
		var taken := damage_taken_total * weight / maxf(weight_sum, 1.0)
		if i == unit_rows.size() - 1:
			dealt = damage_dealt_total - unit_damage_dealt
			taken = damage_taken_total - unit_damage_taken
		row["damage_dealt"] = roundf(dealt)
		row["damage_taken"] = roundf(taken)
		unit_damage_dealt += roundf(dealt)
		unit_damage_taken += roundf(taken)
		combat_rows[i] = row

	# ---------- 建筑 ----------
	var building_rows: Array = []
	var order_rows: Array = []
	var built_total := 0
	var destroyed_total := 0
	var building_cost_total := 0
	var building_t := 12.0
	for building_id in cfg["buildings"]:
		var info: Dictionary = BUILDINGS[building_id]
		var count := 1
		if building_id in ["anti_ground_turret", "anti_air_turret", "machine_gun_turret"]:
			count = int(roundf(2.0 + float(cfg["economy_focus"]) * 3.0))
		elif building_id in ["barracks", "vehicle_factory"]:
			count = 1 + int(roundf(float(cfg["economy_focus"])))
		var destroyed_count := 0
		if not aborted:
			var exposure := 0.10 + aggression * 0.28
			if str(info["role"]) == "防御":
				exposure *= 1.8
			destroyed_count = int(roundf(float(count) * exposure))
		var cost := int(info["cost"]) * count
		building_cost_total += cost
		built_total += count
		destroyed_total += destroyed_count
		building_rows.append({
			"id": building_id,
			"label": str(info["label"]),
			"role": str(info["role"]),
			"count": count,
			"cost": cost,
			"first_built_s": roundf(building_t),
			"destroyed": destroyed_count,
			"survival_rate": 1.0 - float(destroyed_count) / float(maxi(count, 1)),
			"avg_lifetime_s": roundf(duration * (0.35 + rng.randf_range(0.0, 0.5))),
		})
		if building_id != "command_center":
			order_rows.append({
				"t": roundf(building_t),
				"building": str(info["label"]),
				"position": "基地 %s" % ["东侧" if count % 2 == 0 else "北侧"],
				"cost": {"resource_a": int(info["cost"])},
				"note": "首批建造" if order_rows.size() < 2 else "",
			})
			building_t += rng.randf_range(28.0, 96.0)

	# ---------- 经济曲线 ----------
	var series: Array = []
	var gatherers: Array = []
	var producers: Array = []
	var peak_rate := 0.0
	var samples := 24
	var peak_t := 0.0
	for step in range(samples):
		var t := duration * float(step) / float(samples - 1)
		var progress := t / maxf(duration, 1.0)
		# 采集速度：开局爬坡 → 中期高峰 → 后期回落（不会编造"完美线性"）
		var ramp := clampf(progress / 0.28, 0.12, 1.0)
		var decay := 1.0 - clampf((progress - 0.62) / 0.45, 0.0, 0.42)
		var rate := gather_rate * ramp * decay
		var gather_rate_sample := rate * rng.randf_range(0.94, 1.06)
		var gathered_cum := roundf(total_gathered * clampf(progress * rng.randf_range(0.95, 1.05), 0.0, 1.0))
		var spent_cum := roundf(total_spent * clampf(progress * rng.randf_range(0.94, 1.06), 0.0, 1.0))
		var stock := maxf(0.0, initial_a + initial_b + gathered_cum - spent_cum - total_wasted * progress)
		series.append({
			"t": roundf(t),
			"stock": roundf(stock),
			"gathered_cum": gathered_cum,
			"spent_cum": spent_cum,
			"gather_rate": roundf(gather_rate_sample * 10.0) / 10.0,
			"spend_rate": roundf(gather_rate_sample * (0.72 + aggression * 0.16) * 10.0) / 10.0,
			"event": "",
		})
		if gather_rate_sample > peak_rate:
			peak_rate = gather_rate_sample
			peak_t = t
		var gatherer_count := int(roundf(float(composition.get("worker", 4))
			* clampf(progress / 0.35, 0.25, 1.0)))
		gatherers.append({"t": roundf(t), "count": gatherer_count})
		producers.append({"t": roundf(t), "count": maxi(1, int(roundf(float(produced_total) * progress)))})

	# 断档窗口：低效率局给 2 段，高效率局给 1 段；位置由种子决定但保证落在时域内。
	var drought_windows: Array = []
	var drought_count := 2 if float(cfg["economy_focus"]) < 0.6 else 1
	for i in range(drought_count):
		var start := duration * rng.randf_range(0.24, 0.68)
		var length := duration * rng.randf_range(0.04, 0.09)
		drought_windows.append({
			"start_s": roundf(start),
			"end_s": roundf(minf(start + length, duration)),
			"cause": ["采集单位被歼灭", "扩张点失守", "军费挤占采集投入"][i % 3],
		})

	# ---------- 战斗 ----------
	var engagements := maxi(1, int(roundf(duration / 120.0 * (0.6 + aggression))))
	var first_contact := maxf(45.0, duration * rng.randf_range(0.08, 0.19))
	var last_contact := duration * rng.randf_range(0.78, 0.98) if not aborted else duration
	var combat_win_rate := clampf(0.34 + aggression * 0.42 + (0.12 if outcome == "victory" else -0.12),
		0.15, 0.9)
	var largest_engagement := int(roundf(float(produced_total) * rng.randf_range(0.28, 0.46)))
	var damage := {
		"dealt": damage_dealt_total,
		"taken": damage_taken_total,
		"to_structures": roundf(damage_dealt_total * rng.randf_range(0.18, 0.34)),
		"to_units": 0.0,
		"to_heroes": roundf(damage_dealt_total * rng.randf_range(0.02, 0.07)),
		"physical": roundf(damage_dealt_total * rng.randf_range(0.52, 0.66)),
		"energy": roundf(damage_dealt_total * rng.randf_range(0.16, 0.26)),
		"explosive": 0.0,
		"friendly_fire": roundf(damage_dealt_total * rng.randf_range(0.004, 0.022)),
		"per_minute": 0.0,
		"exchange_ratio": 0.0,
	}
	damage["to_units"] = damage_dealt_total - damage["to_structures"] - damage["to_heroes"]
	damage["explosive"] = damage_dealt_total - damage["physical"] - damage["energy"]
	damage["per_minute"] = roundf(damage_dealt_total / maxf(duration / 60.0, 0.01) * 10.0) / 10.0
	damage["exchange_ratio"] = roundf(damage_dealt_total / maxf(damage_taken_total, 1.0) * 100.0) / 100.0

	# ---------- 目标 ----------
	var objective_titles := [
		"建立第二资源点", "守住第 %d 波进攻" % (1 + index % 3), "控制中央高地",
		"摧毁敌方前方兵营", "完成三级科技升级",
	]
	var objectives_completed: Array = []
	var objectives_failed: Array = []
	var objective_events: Array = []
	var success_count := 3 if outcome == "victory" else (2 if outcome == "defeat" else 0)
	for i in range(5):
		var title: String = objective_titles[i]
		var at := duration * (0.18 + 0.16 * float(i))
		if i < success_count:
			objectives_completed.append({
				"id": "OBJ-%02d" % (i + 1), "title": title, "completed_at_s": roundf(at), "note": "",
			})
			objective_events.append({
				"t": roundf(at), "type": "objective_completed", "title": "完成目标：%s" % title,
				"detail": "", "subject": "", "resources_delta": null, "combat_impact": null,
				"hermes_tagged": true,
			})
		elif not aborted:
			objectives_failed.append({
				"id": "OBJ-%02d" % (i + 1), "title": title, "failed_at_s": roundf(at),
				"reason": "资源投入不足或时机错过",
			})
			objective_events.append({
				"t": roundf(at), "type": "objective_failed", "title": "目标失败：%s" % title,
				"detail": "资源投入不足或时机错过", "subject": "", "resources_delta": null,
				"combat_impact": null, "hermes_tagged": true,
			})

	# ---------- 时间线 ----------
	var timeline: Array = [
		_event(0, "match_start", "游戏开始", "地图 %s · 种子 %d" % [str(map_info["name"]), _seed_of(index)],
			"", null, null, false),
		_event(roundf(24.0 + rng.randf_range(0.0, 16.0)), "first_resource_node", "建立第一个资源点",
			"工程车开始采集", "worker", {"resource_a": 0}, null, false),
		_event(roundf(78.0 + rng.randf_range(0.0, 40.0)), "first_structure_built", "首个建筑建成",
			"兵营落成", "barracks", null, null, false),
		_event(roundf(96.0 + rng.randf_range(0.0, 52.0)), "first_unit_produced", "第一个单位下线",
			"首辆步兵出厂", "soldier", null, null, false),
		_event(roundf(first_contact * rng.randf_range(0.5, 0.72)), "first_scout", "首次侦察",
			"侦察单位接触敌方外围", "drone", null, null, false),
		_event(roundf(first_contact), "first_contact", "首次接敌", "与敌方巡逻单位遭遇",
			"", null, "小规模交火，双方无损撤出", false),
		_event(roundf(first_contact * 1.4), "first_attack", "首次主动进攻", "主力向敌方前哨推进",
			"", null, "击毁敌方一座前哨建筑", false),
		_event(roundf(duration * 0.42), "hermes_advice", "Hermes 建议：优先补防线",
			"检测到敌方主力向本基地集结", "", null, null, true),
		_event(roundf(duration * 0.46), "hermes_advice_adopted", "建议被采纳",
			"玩家在 4 分钟内补齐两座防御塔", "", {"resource_a": -900}, null, true),
		_event(roundf(duration * 0.30), "tech_unlocked", "科技解锁：二级装甲",
			"车辆工厂解锁重型装甲", "", {"resource_a": -600}, null, false),
		_event(roundf(peak_t), "key_structure", "经济高峰", "采集速度达到本局峰值 %.1f/min" % peak_rate,
			"", null, null, false),
	]
	if bool(cfg["defensive"]):
		timeline.append(_event(roundf(duration * 0.55), "first_defense", "首次防守成功",
			"挡下敌方第一波正面进攻", "", null, "敌方损失 6 个单位", false))
	if int(cfg["expansions"]) > 0:
		timeline.append(_event(roundf(duration * 0.33), "first_expansion", "首次扩张",
			"在副矿区建立前哨", "", {"resource_a": -450}, null, false))
	timeline.append(_event(roundf(last_contact), "major_battle", "大规模交战",
		"双方投入约 %d 个单位" % maxi(largest_engagement, 4), "",
		null, "本局规模最大的一次交战", true))
	timeline.append(_event(roundf(first_contact * 1.9), "key_unit", "关键单位成型",
		"第一支装甲编队完成", "tank", null, null, false))
	for window in drought_windows:
		timeline.append(_event(int((window as Dictionary)["start_s"]), "resource_drought",
			"资源断档：%s" % str((window as Dictionary)["cause"]),
			"采集速度跌至谷底，持续约 %s" % MatchReportSchema.duration_text(
				int((window as Dictionary)["end_s"]) - int((window as Dictionary)["start_s"])),
			"", null, "该时段内无法补充前线损失", true))
	timeline.append_array(objective_events)
	timeline.append(_event(roundf(duration), "victory" if outcome == "victory"
		else ("defeat" if outcome == "defeat" else "match_aborted"),
		MatchReportSchema.outcome_label(outcome),
		str(cfg.get("aborted_reason", "")) if aborted else str(cfg["victory_condition"]),
		"", null, null, true))
	timeline.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	for i in range(timeline.size()):
		var entry: Dictionary = timeline[i]
		if float(entry["t"]) <= 0.0 and i == 0:
			entry["t"] = 0
	timeline[0]["t"] = 0

	# ---------- 组装 ----------
	# 副官贡献度：用于"是否保留该副官"的结构化信号，同时出现在 combat.quality 与
	# hermes_analysis.adjutant_impact 里 —— 一处算，两处引用，避免两个数字打架。
	var adjutant_contribution := roundf(clampf(0.18 + aggression * 0.34, 0.1, 0.6) * 100.0) / 100.0
	_mark_series_events(series, timeline, duration)
	# 中途取消的建造数：**只取一次随机数**，供 `build_cancelled` 与 `build_started` 共用，
	# 保证"开工 = 落成 + 取消"自洽（两次调用会让 3 个数字互相矛盾）。
	var build_cancelled := int(roundf(rng.randf_range(0.0, 3.0)))
	var report := {
		"schema_version": MatchReportSchema.SCHEMA_VERSION,
		"report_id": "MR-DEMO-%03d" % (index + 1),
		"player_id": "local_player_demo",
		"created_at": created_at,
		"match_id": "demo-match-%03d" % (index + 1),
		"match_version": "0.1",
		"demo": true,
		"demo_seed": _seed_of(index),
		"migrated_from_legacy": false,
		"map": {
			"name": str(map_info["name"]),
			"path": str(map_info["path"]),
			"seed": _seed_of(index),
			"size": str(map_info["size"]),
			"players": int(map_info["players"]),
		},
		"mode": str(cfg["mode"]),
		"difficulty": str(cfg["difficulty"]),
		"duration_seconds": duration,
		"outcome": outcome,
		"victory_condition": str(cfg["victory_condition"]),
		"defeat_reason": str(cfg["defeat_reason"]),
		"commander": "local_player_demo",
		"adjutant": {
			"type": str(ADJUTANTS[int(cfg["adjutant"])]),
			"level": 1 + (index % 4),
		},
		"growth_before": {
			"levels": _growth_levels(index, false),
			"available_points": 12 + index,
			"earned_total": 12 + index,
			"spent_total": 4 + index * 2,
		},
		"growth_after": {
			"levels": _growth_levels(index, true),
			"available_points": 12 + index - (2 + index % 3),
			"earned_total": 12 + index,
			"spent_total": 4 + index * 2 + (2 + index % 3),
		},
		"growth_spent_this_match": 2 + index % 3,
		"overview": {
			"final_resources": {"resource_a": remaining_a, "resource_b": remaining_b},
			"total_gathered": {"resource_a": gathered_a, "resource_b": gathered_b},
			"total_spent": {"resource_a": spent_a, "resource_b": spent_b},
			"resource_efficiency": roundf(total_spent / maxf(total_gathered, 1.0) * 1000.0) / 1000.0,
			"structures_built": built_total,
			"units_produced": produced_total,
			"damage_dealt": damage_dealt_total,
			"damage_taken": damage_taken_total,
			"units_lost": lost_total,
			"enemies_killed": killed_total,
			"objectives_completed": objectives_completed,
			"objectives_failed": objectives_failed,
			"key_events": _key_events(timeline),
			"final_base_value": roundf((0.35 + float(cfg["economy_focus"]) * 0.6) * 100.0) / 100.0,
			"final_controlled_zones": 1 + int(cfg["expansions"]),
			"peak_army_value": _peak_army_value(unit_rows, aggression),
			"score": null,
		},
		"economy": {
			"resources": [
				{
					"key": "resource_a", "label": str(MatchReportSchema.RESOURCE_LABEL["resource_a"]),
					"initial": initial_a, "gathered": gathered_a, "spent": spent_a,
					"wasted": wasted_a, "remaining": remaining_a,
					"gather_avg_per_min": roundf(gathered_a / maxf(duration / 60.0, 0.01) * 10.0) / 10.0,
					"gather_peak_per_min": roundf(peak_rate * 0.78 * 10.0) / 10.0,
					"utilization": roundf(spent_a / maxf(gathered_a, 1.0) * 1000.0) / 1000.0,
				},
				{
					"key": "resource_b", "label": str(MatchReportSchema.RESOURCE_LABEL["resource_b"]),
					"initial": initial_b, "gathered": gathered_b, "spent": spent_b,
					"wasted": wasted_b, "remaining": remaining_b,
					"gather_avg_per_min": roundf(gathered_b / maxf(duration / 60.0, 0.01) * 10.0) / 10.0,
					"gather_peak_per_min": roundf(peak_rate * 0.26 * 10.0) / 10.0,
					"utilization": roundf(spent_b / maxf(gathered_b, 1.0) * 1000.0) / 1000.0,
				},
			],
			"totals": {
				"gathered": total_gathered, "spent": total_spent,
				"wasted": total_wasted, "remaining": remaining_a + remaining_b,
			},
			"rates": {
				"gather_avg_per_min": roundf(total_gathered / maxf(duration / 60.0, 0.01) * 10.0) / 10.0,
				"gather_peak_per_min": roundf(peak_rate * 10.0) / 10.0,
				"spend_avg_per_min": roundf(total_spent / maxf(duration / 60.0, 0.01) * 10.0) / 10.0,
			},
			"utilization": roundf(total_spent / maxf(total_gathered, 1.0) * 1000.0) / 1000.0,
			"conversion_efficiency": roundf(damage_dealt_total / maxf(total_spent, 1.0) * 100.0) / 100.0,
			"source_breakdown": _breakdown({
				"采集": total_gathered,
				"初始储备": initial_a + initial_b,
			}),
			"sink_breakdown": _sink_breakdown(total_spent),
			"series": series,
			"structure": {
				"gatherers": gatherers,
				"producers": producers,
				"investment_ratio": {
					"construction": 0.28, "military": 0.52,
					"technology": 0.14, "defense": snappedf(0.06 + aggression * 0.06, 0.01),
				},
				"conversion_routes": [
					{"from": "资源 A", "to": "单位生产", "amount": roundf(total_spent * 0.52),
						"share": 0.52},
					{"from": "资源 A", "to": "建筑施工", "amount": roundf(total_spent * 0.28),
						"share": 0.28},
					{"from": "资源 A", "to": "科技升级", "amount": roundf(total_spent * 0.14),
						"share": 0.14},
				],
				"dominant_resource": "resource_a",
				"peak_time_seconds": roundf(peak_t),
				"drought_windows": drought_windows,
			},
		},
		"production": {
			"units": unit_rows,
			"queue": {
				"wait_avg_s": roundf(rng.randf_range(6.0, 26.0)),
				"idle_total_s": roundf(duration * clampf(0.30 - float(cfg["economy_focus"]) * 0.16, 0.03, 0.3)),
				"cancellations": int(roundf(rng.randf_range(0.0, 4.0))),
				"utilization": roundf(clampf(0.62 + float(cfg["economy_focus"]) * 0.3, 0.4, 0.96) * 100.0) / 100.0,
				"earliest_production_s": roundf(rng.randf_range(70.0, 120.0)),
				"latest_production_s": roundf(duration * rng.randf_range(0.68, 0.95)),
				"first_main_force_s": roundf(duration * clampf(0.34 - aggression * 0.14, 0.12, 0.36)),
			},
			"composition": _composition(unit_rows, produced_total, lost_total),
			"combos": {
				"most_used": [_combo(_top_ids(unit_rows, 3), maxi(2, produced_total / 6))],
				"most_effective": [_combo(_top_kill_ids(unit_rows, 3), maxi(1, killed_total / 5))],
				"highest_loss": [_combo(_top_loss_ids(unit_rows, 2), maxi(1, lost_total / 4))],
			},
		},
		"construction": {
			"total_built": built_total,
			"buildings": building_rows,
			"order": order_rows,
			"destroyed_count": destroyed_total,
			"survival_rate": 1.0 - float(destroyed_total) / float(maxi(built_total, 1)),
			"avg_lifetime_s": roundf(duration * 0.62),
			"frontline_count": int(roundf(float(built_total) * 0.25)),
			"economy_count": 1 + int(roundf(float(cfg["economy_focus"]) * 2.0)),
			"defense_count": _count_role(building_rows, "防御"),
			"tech_count": _count_role(building_rows, "生产"),
			"expansions": int(cfg["expansions"]),
			"first_expansion_s": roundf(duration * 0.33) if int(cfg["expansions"]) > 0 else null,
			"farthest_building_distance_m": roundf(60.0 + float(cfg["expansions"]) * 74.0),
			"density_per_km2": roundf(float(built_total) / maxf(0.6 + float(cfg["expansions"]) * 0.45, 0.2) * 10.0) / 10.0,
			"defense_line_integrity": roundf(clampf(
				0.48 + float(cfg["economy_focus"]) * 0.3 + (0.12 if bool(cfg["defensive"]) else 0.0),
				0.2, 0.95) * 100.0) / 100.0,
			# 开工数 = 落成数 + 中途取消数，两个数字必须自洽（取消失败的建造不该凭空消失）。
			"build_cancelled": build_cancelled,
			"build_started": built_total + build_cancelled,
			"avg_build_time_s": roundf(rng.randf_range(12.0, 34.0)),
			"rebuild_count": mini(destroyed_total, int(roundf(float(destroyed_total) * 0.35))),
			"repair_spent": roundf(float(building_cost_total) * clampf(
				0.06 + (1.0 - aggression) * 0.12, 0.02, 0.25)),
			"peak_concurrent_builds": 1 + int(roundf(aggression * 3.0)),
		},
		"combat": {
			"overview": {
				"engagements": engagements,
				"first_contact_s": roundf(first_contact),
				"last_contact_s": roundf(last_contact),
				"total_contact_s": roundf((last_contact - first_contact) * 0.42),
				"win_rate": roundf(combat_win_rate * 100.0) / 100.0,
				"offensives": int(roundf(float(engagements) * aggression * 0.6)),
				"defenses": int(roundf(float(engagements) * (1.0 - aggression) * 0.7)),
				"counterattacks": int(roundf(float(engagements) * 0.18)),
				"ambushes": int(roundf(float(engagements) * 0.08)),
				"retreats": int(roundf(float(engagements) * (0.10 + (1.0 - aggression) * 0.12))),
				"turning_point": "第 %s" % MatchReportSchema.duration_text(roundf(duration * 0.58)),
				"largest_engagement": largest_engagement,
				"most_important": "第 %s 的中央高地争夺" % MatchReportSchema.duration_text(roundf(last_contact)),
			},
			"damage": damage,
			"units": combat_rows,
			"unit_stats": MatchReportSchema.derive_unit_stats(combat_rows),
			"quality": {
				"focus_fire": roundf(clampf(0.44 + aggression * 0.4, 0.2, 0.92) * 100.0) / 100.0,
				"formation_time_s": roundf(rng.randf_range(18.0, 62.0)),
				"idle_time_s": roundf(duration * clampf(0.22 - aggression * 0.1, 0.04, 0.24)),
				"moving_time_s": roundf(duration * clampf(0.30 + aggression * 0.12, 0.2, 0.6)),
				"engagement_distance_m": roundf(rng.randf_range(22.0, 58.0)),
				"recon_coverage": roundf(clampf(0.28 + float(cfg["economy_focus"]) * 0.42, 0.15, 0.9) * 100.0) / 100.0,
				"reaction_time_s": roundf(rng.randf_range(2.4, 9.6) * 10.0) / 10.0,
				"target_selection": roundf(clampf(0.40 + aggression * 0.42, 0.2, 0.94) * 100.0) / 100.0,
				"retreat_timing": roundf(clampf(0.38 + (1.0 - aggression) * 0.4, 0.2, 0.9) * 100.0) / 100.0,
				"abilities_used": int(roundf(rng.randf_range(2.0, 14.0))),
				"ability_hit_rate": roundf(clampf(0.42 + aggression * 0.36, 0.2, 0.9) * 100.0) / 100.0,
				"adjutant_contribution": adjutant_contribution,
				"resource_drought_in_combat": drought_windows.size(),
			},
			"mvp_unit": _unit_label(_top_kill_ids(unit_rows, 1)),
			"worst_loss_unit": _unit_label(_top_loss_ids(unit_rows, 1)),
			"most_efficient_kill_unit": _unit_label(_top_efficiency(unit_rows, true)),
			"least_efficient_unit": _unit_label(_top_efficiency(unit_rows, false)),
		},
		"timeline": timeline,
		"hermes_analysis": _hermes(index, cfg, {
			"outcome": outcome, "duration": duration, "aggression": aggression,
			"damage_dealt": damage_dealt_total, "damage_taken": damage_taken_total,
			"total_gathered": total_gathered, "total_spent": total_spent,
			"utilization": total_spent / maxf(total_gathered, 1.0),
			"lost_ratio": float(lost_total) / maxf(float(produced_total), 1.0),
			"droughts": drought_windows.size(), "map": str(map_info["name"]),
			"difficulty": str(cfg["difficulty"]), "adjutant": str(ADJUTANTS[int(cfg["adjutant"])]),
			"unit_rows": unit_rows, "engagements": engagements, "win_rate": combat_win_rate,
			"adjutant_contribution": adjutant_contribution,
		}),
	}
	report["source"] = {
		"generated_by": "DemoMatchReports.gd",
		"generated_at": created_at,
		"game_version": "0.1",
	}
	if aborted:
		# 半途退出的对局天然缺数据：把"退出瞬间拿不到"的区块置空，让完整度与
		# UI 如实反映缺口，而不是拿瞬时值冒充完整统计。
		report["combat"]["quality"] = {}
		report["production"]["combos"] = {}
		report["construction"]["order"] = []
		report["adjutant"] = {"type": "", "level": null}
		report["hermes_analysis"] = {"status": "none"}
	var normalized: Dictionary = MatchReportSchema.normalize(report)["report"]
	normalized["performance_score"] = MatchReportScoring.evaluate(normalized)
	normalized["overview"]["score"] = normalized["performance_score"]["total"]
	# 评分写回后重新归一化一次，让完整度反映最终结构。
	return MatchReportSchema.normalize(normalized)["report"]


# ---------------- 内部工具 ----------------

static func _seed_of(index: int) -> int:
	return 4100 + index * 137


static func _event(t: float, type_key: String, title: String, detail: String, subject: String,
		resources_delta: Variant, combat_impact: Variant, hermes_tagged: bool) -> Dictionary:
	return {
		"t": t, "type": type_key, "title": title, "detail": detail, "subject": subject,
		"resources_delta": resources_delta, "combat_impact": combat_impact,
		"hermes_tagged": hermes_tagged,
	}


static func _key_events(timeline: Array) -> Array:
	var out: Array = []
	for event in timeline:
		if not (event is Dictionary):
			continue
		if bool((event as Dictionary).get("hermes_tagged", false)):
			out.append({
				"t": (event as Dictionary).get("t", null),
				"title": str((event as Dictionary).get("title", "")),
				"detail": str((event as Dictionary).get("detail", "")),
			})
	return out


static func _breakdown(source: Dictionary) -> Array:
	var total := 0.0
	for key in source:
		total += float(source[key])
	var out: Array = []
	for key in source:
		out.append({
			"key": str(key), "label": str(key), "amount": roundf(float(source[key])),
			"share": roundf(float(source[key]) / maxf(total, 1.0) * 1000.0) / 1000.0,
		})
	return out


## 会被标到资源曲线上的事件类型（重大事件 / 扩张 / 断档 / 结算）。
const SERIES_EVENT_TYPES := [
	"victory", "defeat", "match_aborted", "first_expansion", "resource_drought",
	"major_battle", "tech_unlocked",
]


## 把时间线上的重大事件吸附到最近的曲线采样点，让"资源曲线 + 事件标记"同源。
static func _mark_series_events(series: Array, timeline: Array, duration: float) -> void:
	if series.is_empty():
		return
	for event in timeline:
		if not (event is Dictionary):
			continue
		var entry: Dictionary = event
		if not SERIES_EVENT_TYPES.has(str(entry.get("type", ""))):
			continue
		var target := float(entry.get("t", 0))
		var best := 0
		var best_delta := INF
		for i in range(series.size()):
			var delta: float = absf(float((series[i] as Dictionary)["t"]) - target)
			if delta < best_delta:
				best_delta = delta
				best = i
		var marked: Dictionary = series[best]
		var label := MatchReportSchema.timeline_label(str(entry.get("type", "")))
		if duration <= 0.0 and best == 0:
			label = "%s（时间戳缺失）" % label
		var existing := str(marked.get("event", ""))
		marked["event"] = label if existing.is_empty() else "%s / %s" % [existing, label]


## 资源消耗切片：末项吸收舍入余量，保证四片之和严格等于总消耗。
static func _sink_breakdown(total_spent: float) -> Array:
	var ratios := [["单位生产", 0.52], ["建筑施工", 0.28], ["科技升级", 0.14], ["防御工事", 0.06]]
	var out: Array = []
	var assigned := 0.0
	for i in range(ratios.size()):
		var label := str(ratios[i][0])
		var amount := roundf(total_spent * float(ratios[i][1]))
		if i == ratios.size() - 1:
			amount = maxf(0.0, total_spent - assigned)
		assigned += amount
		out.append({
			"key": label, "label": label, "amount": amount,
			"share": roundf(amount / maxf(total_spent, 1.0) * 1000.0) / 1000.0,
		})
	return out


## 峰值军力：本局"同时在场"单位价值最高值。用**累计投入的战斗单位价值 × 同时在场系数**估算，
## 系数随进攻性上升（换线快 ⇒ 同时在场的比例更接近累计投入），并封顶在累计投入之内。
## 只统计战斗单位（`category != "economy"`）—— 工程车不计入军力。
static func _peak_army_value(unit_rows: Array, aggression: float) -> float:
	var invested := 0.0
	for row in unit_rows:
		var entry: Dictionary = row
		if str(entry["category"]) == "economy":
			continue
		var cost := int(UNITS.get(str(entry["id"]), {}).get("cost", 0))
		invested += float(int(entry["produced"]) * cost)
	return roundf(invested * clampf(0.45 + aggression * 0.34, 0.3, 0.85))


## 单位统计 11 项：与「伤害统计 11 项 / 战斗质量 13 项」同级的**汇总口径**。
## 推导放在 `MatchReportSchema.derive_unit_stats()` —— Demo 与真实对局共用同一份实现，
## 避免两条链路各算一套数字。
static func _composition(unit_rows: Array, produced_total: int, lost_total: int) -> Dictionary:
	var by_type: Array = []
	var weight := {"light": 0, "medium": 0, "heavy": 0}
	var role := {"ranged": 0, "melee": 0, "air": 0, "support": 0}
	for row in unit_rows:
		var entry: Dictionary = row
		var count := int(entry["produced"])
		by_type.append({
			"key": str(entry["id"]), "label": str(entry["label"]), "count": count,
			"share": roundf(float(count) / maxf(float(produced_total), 1.0) * 1000.0) / 1000.0,
		})
		var w := str(entry["weight_class"])
		if weight.has(w):
			weight[w] += count
		var r := str(entry["role_class"])
		if role.has(r):
			role[r] += count
	var scout := 0
	for row in unit_rows:
		# 侦察单位判定与 `unit_stats.scout_units` 共用同一份白名单，否则两处口径会打架。
		if MatchReportSchema.SCOUT_UNIT_IDS.has(str((row as Dictionary)["id"])):
			scout += int((row as Dictionary)["produced"])
	var total := maxf(float(produced_total), 1.0)
	return {
		"type_ratio": by_type,
		"weight_class": {
			"light": roundf(float(weight["light"]) / total * 1000.0) / 1000.0,
			"medium": roundf(float(weight["medium"]) / total * 1000.0) / 1000.0,
			"heavy": roundf(float(weight["heavy"]) / total * 1000.0) / 1000.0,
		},
		"role_class": {
			"ranged": roundf(float(role["ranged"]) / total * 1000.0) / 1000.0,
			"melee": roundf(float(role["melee"]) / total * 1000.0) / 1000.0,
			"air": roundf(float(role["air"]) / total * 1000.0) / 1000.0,
			"support": roundf(float(role["support"]) / total * 1000.0) / 1000.0,
		},
		"scout_ratio": roundf(float(scout) / total * 1000.0) / 1000.0,
		"main_force_ratio": roundf(float(produced_total - scout) / total * 1000.0) / 1000.0,
		"sacrificed_ratio": roundf(float(lost_total) / total * 1000.0) / 1000.0,
	}


static func _combo(ids: Array, count: int) -> Dictionary:
	var labels := PackedStringArray()
	for unit_id in ids:
		labels.append(str(UNITS.get(str(unit_id), {}).get("label", unit_id)))
	return {"units": Array(labels), "count": count, "win_rate": null}


static func _top_ids(unit_rows: Array, limit: int) -> Array:
	var rows := unit_rows.duplicate(true)
	rows.sort_custom(func(a, b): return int(a["produced"]) > int(b["produced"]))
	return _ids_of(rows, limit)


static func _top_kill_ids(unit_rows: Array, limit: int) -> Array:
	var rows := unit_rows.duplicate(true)
	rows.sort_custom(func(a, b): return int(a["killed"]) > int(b["killed"]))
	return _ids_of(rows, limit)


static func _top_loss_ids(unit_rows: Array, limit: int) -> Array:
	var rows := unit_rows.duplicate(true)
	rows.sort_custom(func(a, b): return int(a["lost"]) > int(b["lost"]))
	return _ids_of(rows, limit)


static func _top_efficiency(unit_rows: Array, best: bool) -> Array:
	var rows: Array = []
	for row in unit_rows:
		var entry: Dictionary = row
		var lost := maxf(float(entry["lost"]), 1.0)
		rows.append({"id": str(entry["id"]), "score": float(entry["killed"]) / lost})
	rows.sort_custom(func(a, b): return float(a["score"]) > float(b["score"]))
	if rows.is_empty():
		return []
	return [str((rows[0] if best else rows[rows.size() - 1])["id"])]


static func _ids_of(rows: Array, limit: int) -> Array:
	var out: Array = []
	for i in range(mini(limit, rows.size())):
		out.append(str((rows[i] as Dictionary)["id"]))
	return out


static func _unit_label(ids: Array) -> String:
	if ids.is_empty():
		return ""
	return str(UNITS.get(str(ids[0]), {}).get("label", ids[0]))


static func _count_role(rows: Array, role: String) -> int:
	var total := 0
	for row in rows:
		if str((row as Dictionary)["role"]) == role:
			total += int((row as Dictionary)["count"])
	return total


static func _growth_levels(index: int, after: bool) -> Dictionary:
	var keys := ["combat_power", "combat_guard", "economy_gather", "economy_stock",
		"construction_speed", "construction_armor"]
	var levels := {}
	for i in range(keys.size()):
		var base := (index + i) % 4
		var value := base + (1 if (after and i < 2) else 0)
		if value > 0:
			levels[str(keys[i])] = value
	return levels


## Hermes 分析：自然语言只出现在 observations / suggestions，且每条都带 evidence。
## status 覆盖 completed / cached / running / failed / none 五种状态。
static func _hermes(index: int, cfg: Dictionary, facts: Dictionary) -> Dictionary:
	var status := str(cfg["hermes"])
	var generated := Time.get_datetime_string_from_unix_time(
		int(Time.get_unix_time_from_datetime_string(BASE_LOCAL)) - index * (6 * 3600 + 20 * 60) + 240, true
		).replace("T", " ")
	var observations: Array = []
	var suggestions: Array = []
	var memory: Array = []
	var updates: Array = []
	if status == "completed" or status == "cached":
		var dealt := float(facts["damage_dealt"])
		var taken := float(facts["damage_taken"])
		var gathered := float(facts["total_gathered"])
		var lost_ratio := float(facts["lost_ratio"])
		var drought_count := int(facts["droughts"])
		observations.append({
			"text": "本局伤害交换比为 %.2f，%s" % [
				dealt / maxf(taken, 1.0),
				"进攻节奏压制住了对手" if dealt > taken else "承担了过多的正面消耗"],
			"evidence": [
				"combat.damage.dealt=%s" % MatchReportSchema.number_text(dealt),
				"combat.damage.taken=%s" % MatchReportSchema.number_text(taken),
			],
		})
		observations.append({
			"text": "共采集 %s，其中 %.0f%% 被转化为战力或建筑" % [
				MatchReportSchema.number_text(gathered),
				float(facts["utilization"]) * 100.0],
			"evidence": [
				"economy.totals.gathered=%s" % MatchReportSchema.number_text(gathered),
				"economy.utilization=%s" % MatchReportSchema.percent_text(facts["utilization"]),
			],
		})
		observations.append({
			"text": "单位损失率 %.0f%%，资源断档 %d 次" % [lost_ratio * 100.0, drought_count],
			"evidence": [
				"overview.units_lost / overview.units_produced = %.2f" % lost_ratio,
				"economy.structure.drought_windows=%d 段" % drought_count,
			],
		})
		suggestions.append({
			"text": "在 %s 上把首个扩张点提前到战斗窗口之前，可减少后期断档" % str(facts["map"]),
			"evidence": [
				"economy.structure.drought_windows=%d 段" % drought_count,
				"construction.first_expansion_s",
			],
			"adopted": index % 3 != 0,
			"outcome": "采纳后下一局采集均速提升" if index % 3 != 0 else "",
		})
		suggestions.append({
			"text": "副官「%s」与当前作战风格匹配度较高，建议保留" % str(facts["adjutant"]),
			"evidence": [
				"combat.quality.adjutant_contribution",
				"combat.overview.win_rate=%s" % MatchReportSchema.percent_text(
					_path(facts, "win_rate", 0.5)),
			],
			"adopted": true,
			"outcome": "",
		})
		memory.append({
			"key": "preferred_map_%s" % str(facts["map"]).replace(" ", "_").to_lower(),
			"label": "地图偏好",
			"value": str(facts["map"]),
			"source": "MR-DEMO-%03d" % (index + 1),
		})
		memory.append({
			"key": "avg_loss_ratio",
			"label": "平均单位损失率",
			"value": roundf(lost_ratio * 1000.0) / 1000.0,
			"source": "MR-DEMO-%03d" % (index + 1),
		})
		updates.append({
			"dimension": "combat",
			"before": 60 + index,
			"after": 60 + index + (4 if dealt > taken else -3),
			"basis": "本局伤害交换比 %.2f" % (dealt / maxf(taken, 1.0)),
		})
		updates.append({
			"dimension": "economy",
			"before": 55 + index,
			"after": 55 + index + (5 if float(facts["utilization"]) > 0.8 else -2),
			"basis": "本局资源利用率 %s" % MatchReportSchema.percent_text(facts["utilization"]),
		})
	var cache := {"cached_at": null, "stale": null, "source_generated_at": null}
	if status == "cached":
		cache = {
			"cached_at": Time.get_datetime_string_from_unix_time(
				int(Time.get_unix_time_from_datetime_string(BASE_LOCAL)) - 3 * 86400, true
				).replace("T", " "),
			"stale": true,
			"source_generated_at": Time.get_datetime_string_from_unix_time(
				int(Time.get_unix_time_from_datetime_string(BASE_LOCAL)) - 4 * 86400, true
				).replace("T", " "),
		}
	var adjutant_impact := {
		"type": str(facts["adjutant"]),
		"score": roundf(clampf(0.3 + float(facts["aggression"]) * 0.5, 0.0, 1.0) * 100.0) / 100.0,
		"recommendation_signal": "keep" if float(facts["aggression"]) > 0.5 else "reconsider",
		"basis": "本局交战 %s 次，副官技能贡献 %s" % [
			MatchReportSchema.number_text(_path(facts, "engagements", 0)),
			MatchReportSchema.percent_text(_path(facts, "adjutant_contribution", 0.0)),
		],
	}
	var basis := PackedStringArray()
	for path in ["overview.damage_dealt", "economy.totals.gathered", "overview.units_lost",
			"combat.overview.engagements", "construction.total_built"]:
		basis.append(path)
	return {
		"status": status,
		"generated_at": generated if status in ["completed", "cached"] else null,
		"model_version": "hermes-local-1",
		"source_report_ids": ["MR-DEMO-%03d" % (index + 1)],
		"cache": cache,
		"observations": observations,
		"suggestions": suggestions,
		"memory_delta": memory,
		"profile_updates": updates,
		"adjutant_impact": adjutant_impact,
		"data_basis": Array(basis),
		"failure_reason": "" if status != "failed" else "本地模型端点不可用（连接被拒绝），本局分析未完成",
	}


static func _path(source: Dictionary, key: String, default: Variant) -> Variant:
	if not source.has(key):
		return default
	var value = source[key]
	return default if value == null else value
