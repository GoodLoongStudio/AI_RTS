extends Node

const BalanceConfigRuntimeScript = preload(
	"res://source/csharp/GodotAdapter/Configuration/BalanceConfigRuntime.cs"
)
const TankScene = preload("res://source/match/units/Tank.tscn")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const AntiGroundTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
## 本冒烟对着的实际配置。武器/射程类期望值一律从这里派生。
## 教训：`f30562a` 把坦克炮改成 3.5 伤 / 1500ms / 7.5 米时只同步了"核心断言"，本文件写死的
## 2.0 / 0.75 / 5.0 就长期为红 —— 而断言语义本是"运行时读的是 Catalog"，不是"把数值钉死"，
## 所以改成与配置比对：调平衡不再误红，而运行时不再读配置时**照样**红。
const DEMO_BALANCE := "res://config/balance/demo.balance.v1.json"

var _failures := 0


## 验证 Match 在生成单位前加载平衡 Catalog，并能按稳定映射查询 Godot 资源。
func _ready():
	var runtime := Node.new()
	runtime.name = "BalanceConfigRuntime"
	runtime.set_script(BalanceConfigRuntimeScript)
	add_child(runtime)
	await get_tree().process_frame

	_check(runtime.GetUnitTypeId(TankScene) == "tank", "Tank 场景应映射到稳定 UnitTypeId")
	_check(
		runtime.GetBlueprintScenePath(CommandCenterScene)
		== "res://source/match/units/structure-geometries/CommandCenter.tscn",
		"CommandCenter 应从 manifest 查询蓝图场景"
	)
	_check(
		is_equal_approx(runtime.GetCollectionDurationSeconds("resource_a"), 0.2),
		"Resource A 采集周期应由 Catalog 映射为 0.2 秒（2026-09-03 采集节奏 20 秒/趟）"
	)
	var balance := _load_balance()
	var tank_def := _find_by_id(balance.get("unitTypes", []), "tank")
	var tank_weapon := _primary_weapon(balance, "tank")
	var expected_tank_range := float(tank_weapon.get("rangeMeters", -1.0))
	_check(expected_tank_range > 0.0, "应能从 demo 平衡配置读到 Tank 主武器射程")
	var tank_display = runtime.GetUnitDisplaySnapshot(TankScene)
	_check(
		tank_display["hp_max"] == float(tank_def.get("maxHp", 0.0))
		and tank_display["attack_range"] == expected_tank_range,
		"HUD 显示快照应读取 Tank Catalog 数值（HP %s / 射程 %s 米）"
			% [float(tank_def.get("maxHp", 0.0)), expected_tank_range]
	)
	var tank_cost = runtime.GetProductionCost(TankScene)
	_check(
		tank_cost == {"resource_a": 500, "resource_b": 0},
		"规则 AI 与 HUD 应读取完整 Tank 生产成本副本（单币种 A×500）"
	)
	var command_center_cost = runtime.GetConstructionCost(CommandCenterScene)
	_check(
		command_center_cost == {"resource_a": 2400, "resource_b": 0},
		"规则 AI 与 HUD 应读取完整 CommandCenter 施工成本副本（单币种 A×2400）"
	)
	_verify_unit_configuration(runtime)

	print("Balance config runtime smoke test completed: %d failure(s)" % _failures)
	runtime.queue_free()
	await get_tree().process_frame
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


## 验证单位基础属性、移动能力、Worker 载荷和当前主武器均由同一 Catalog 注入。
func _verify_unit_configuration(runtime):
	var tank = TankScene.instantiate()
	runtime.ConfigureUnit(tank)
	_check(tank.unit_type_id == "tank", "Tank 应获得稳定 UnitTypeId")
	_check(tank.hp == 10.0 and tank.hp_max == 10.0, "Tank HP 应来自 Catalog")
	_check(tank.sight_range == 8.0, "Tank 视野应来自 Catalog")
	_check(tank.find_child("Movement").speed == 2.75, "Tank 速度应来自 Catalog")
	_check(tank.can_reverse and tank.can_fire_while_moving, "Tank 移动能力应来自 Catalog")
	var weapon := _primary_weapon(_load_balance(), "tank")
	var expected_damage := float(weapon.get("baseDamage", -1.0))
	var expected_interval := float(weapon.get("cooldownMilliseconds", 0)) / 1000.0
	var expected_range := float(weapon.get("rangeMeters", -1.0))
	_check(expected_damage > 0.0 and expected_interval > 0.0 and expected_range > 0.0,
		"应能从 demo 平衡配置读到 Tank 主武器参数（伤害/间隔/射程）")
	_check(
		tank.attack_damage == expected_damage and tank.attack_interval == expected_interval,
		"Tank 主武器应来自 Catalog（配置 %s 伤害 / %s 秒）" % [expected_damage, expected_interval]
	)
	_check(
		tank.attack_range == expected_range and tank.attack_domains == [1],
		"Tank 射程和目标域应来自 Catalog（配置射程 %s 米）" % [expected_range]
	)

	var worker = WorkerScene.instantiate()
	runtime.ConfigureUnit(worker)
	_check(worker.resources_max == 100, "Worker 载荷应来自 Catalog（2026-09-03 调整为 100）")
	_check(worker.construction_work_per_tick == 1, "Worker 施工贡献应来自 Catalog")

	var turret = AntiGroundTurretScene.instantiate()
	runtime.ConfigureUnit(turret)
	_check(turret.attack_range == 8.0 and turret.attack_damage == 2.0, "炮塔主武器应来自 Catalog")

	tank.free()
	worker.free()
	turret.free()


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Balance config runtime assertion failed: %s" % message)


## 读 demo 平衡配置（期望值的唯一来源；读不到返回空字典，让后续断言明确失败而非静默通过）。
func _load_balance() -> Dictionary:
	var file := FileAccess.open(DEMO_BALANCE, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _find_by_id(items: Array, id: String) -> Dictionary:
	for item in items:
		if item is Dictionary and str((item as Dictionary).get("id", "")) == id:
			return item
	return {}


## 取某单位的主武器定义（`weaponIds[0]`）；配置缺失时返回空字典。
func _primary_weapon(balance: Dictionary, unit_type_id: String) -> Dictionary:
	var unit := _find_by_id(balance.get("unitTypes", []), unit_type_id)
	var weapon_ids: Array = unit.get("weaponIds", [])
	if weapon_ids.is_empty():
		return {}
	return _find_by_id(balance.get("weapons", []), str(weapon_ids[0]))
