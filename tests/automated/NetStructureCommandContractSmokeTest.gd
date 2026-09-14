extends Node

## 维修/出售「客户端 → 权威端」命令协议契约测试（源码级）。
##
## 为什么需要它：`repair_structure` / `sell_structure` 这两个 op 名是**手抄在两处**的
## 字符串字面量——客户端 `UnitActionsController._forward_structure_command()` 发，
## 权威端 `NetSync` 用 `if op == "<op>"` 接。任何一边改名/拼错都不会报错，只会静默失效：
## 客户端"点了没反应"。运行时验证需要起专用服，本测试用源码级契约把这类漂移变成红灯。
##
## 局限（明确写清，避免误读为端到端验证）：它只证明两边**字面量一致且分支存在**，
## 不证明网络链路真的通。端到端仍需 `NetInfantrySmokeTest` 那套（专用服 + 客户端）。

const CLIENT_PATH := "res://source/match/players/human/UnitActionsController.gd"
const SERVER_PATH := "res://source/net/NetSync.gd"
const OPS := ["repair_structure", "sell_structure"]

var _failures := 0


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Net structure command contract failed: %s" % message)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


func _ready():
	var client_src := _read(CLIENT_PATH)
	var server_src := _read(SERVER_PATH)
	_check(not client_src.is_empty(), "应能读到客户端脚本 %s" % CLIENT_PATH)
	_check(not server_src.is_empty(), "应能读到权威端脚本 %s" % SERVER_PATH)

	for op in OPS:
		_check(
			client_src.contains('"%s"' % op),
			"客户端应发出 op 『%s』（改了名字就要同步权威端）" % op
		)
		_check(
			server_src.contains('if op == "%s"' % op),
			"权威端 NetSync 应有 `if op == \"%s\"` 分支" % op
		)

	# 客户端必须走"联机才转发、否则本地直执行"这条闸门，否则单机会把命令发给不存在的权威端。
	_check(
		client_src.contains("NetSession.should_forward_commands()"),
		"客户端应经 NetSession.should_forward_commands() 判定是否转发"
	)
	_check(
		client_src.contains("func _forward_structure_command"),
		"客户端应保留 _forward_structure_command 转发入口"
	)
	_check(
		client_src.contains("func _apply_structure_target_mode"),
		"客户端应保留 _apply_structure_target_mode 结算入口"
	)

	# 权威端两个分支必须真的落到玩法上（维修=切换 repairing；出售=拆毁+退款）。
	_check(
		server_src.contains("set_repairing(not unit.is_repairing())"),
		"权威端 repair_structure 分支应切换维护状态"
	)
	_check(
		server_src.contains("unit.sell()"),
		"权威端 sell_structure 分支应调用 sell()（拆毁 + 返还）"
	)

	# 客户端这两个模式必须能被查询到（右键/ESC 退出依赖它；漏掉会退不出模式）。
	_check(
		client_src.contains('return "Repair"') and client_src.contains('return "Sell"'),
		"get_active_command_targeting() 应覆盖 Repair / Sell"
	)

	print("Net structure command contract smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
