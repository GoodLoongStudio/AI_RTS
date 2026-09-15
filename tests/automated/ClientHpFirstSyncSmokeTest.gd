extends Node

## 联机客户端 HP 首次同步守门（2026-09-15 用户实测 bug 固化）。
##
## 背景：联机客户端的所有单位在 `_ready` 后会被平衡配置（BalanceConfigRuntime）
## 设成**满血**，而施工中的建筑权威血量是 **1**。客户端若直接 `unit.hp = 权威值`，
## 等于"血量下降"，`Unit._set_hp` 会广播 `unit_damaged` → 旁白误播「基地遭到攻击」，
## 表现为**每次建造都会响**。（权威端走 `mark_as_under_construction` →
## `set_hp_without_damage(1)` 抑制了事件，所以单机不中、只在联机客户端命中。）
##
## 本测试锁死 `NetSync._apply_authoritative_hp` 的两条不变式：
##   1) 首次把权威 hp 写进单位 = 初始化 → **不得**触发受击；
##   2) 之后的 hp 下降 = 真受伤 → **必须**触发受击（受伤播报不能被修没）。
##
## 跑法：godot --headless --path . res://tests/automated/ClientHpFirstSyncSmokeTest.tscn
##      （或 run_tests.ps1 -Tests "ClientHpFirstSyncSmokeTest"）

const NetSyncScript = preload("res://source/net/NetSync.gd")
const BarracksScene = preload("res://source/match/units/Barracks.tscn")

const FULL_HP := 100.0
const SITE_HP := 1.0
const HIT_HP := 0.5

var _failures := 0
var _finished := false
var _damaged := 0


func _ready():
	get_tree().create_timer(60.0).timeout.connect(_on_failsafe)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)

	# 不进树：只借用方法，避免 NetSync._ready 里的 HUD/可视化挂载去依赖 Match。
	var net_sync: Node = NetSyncScript.new()

	# 单位 `_ready` 会向上找 "Match" 上下文（导航/玩家等）。本测试不跑对局，
	# 给一个最小桩把"缺上下文"的报错压到最低；本测试只关心 hp 同步语义。
	var match_stub := Node.new()
	match_stub.name = "Match"
	add_child(match_stub)

	var structure: Node = BarracksScene.instantiate()
	structure.hp_max = FULL_HP
	# 客户端 _ready 后"配置应用 = 满血"的等效状态（真实前提见探针与
	# BalanceConfigRuntime 的 unit.Set("hp", definition.MaxHp)）。
	structure.hp = FULL_HP
	match_stub.add_child(structure)
	await get_tree().process_frame
	await get_tree().process_frame

	_damaged = 0
	net_sync.call("_apply_authoritative_hp", structure, SITE_HP)
	_check(
		_damaged == 0,
		"首次同步权威 hp（工地 1 ↔ 单位满血 100）不得触发受击——否则每次建造误播『基地遭到攻击』"
	)
	_check(
		float(structure.hp) == SITE_HP,
		"首次同步仍必须把权威 hp 真正写进单位（期望 %s，实际 %s）" % [
			str(SITE_HP), str(structure.hp),
		]
	)

	_damaged = 0
	net_sync.call("_apply_authoritative_hp", structure, HIT_HP)
	_check(_damaged == 1, "之后的 hp 下降必须触发受击（受伤播报保留）")

	net_sync.free()
	_finish()


func _on_unit_damaged(_unit) -> void:
	_damaged += 1


func _on_failsafe() -> void:
	if _finished:
		return
	print("FAIL: 看门狗超时——测试协程中断未收尾")
	_finish()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	print("Client HP first-sync smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		print("  [PASS] %s" % message)
		return
	_failures += 1
	print("FAIL: %s" % message)
