extends SceneTree

## AdjutantButton 日志摘要纯函数样例测试（headless --script 运行）。
## 覆盖任务要求的 12 类输入：status/move/gather/build/produce/attack/
## PendingAuthority/Accepted/QueueFull/ProductNotAllowed/普通中文复盘/未知行。
## 断言：不抛异常、输出为玩家可读中文（不含路径/JSON 原文/内部参数）。

var _failures := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[PASS] " + msg)
	else:
		_failures += 1
		print("[FAIL] " + msg)


func _assert_player_facing(digest: Dictionary, tag: String) -> void:
	for key in ["state", "action", "why", "result"]:
		var text := str(digest.get(key, ""))
		_check(not text.is_empty(), "%s.%s 非空" % [tag, key])
		_check(not text.contains("res://"), "%s.%s 不含内部路径" % [tag, key])
		_check(not text.contains("as_player="), "%s.%s 不含命令参数" % [tag, key])


func _init() -> void:
	var script: GDScript = load("res://source/ui/AdjutantButton.gd")
	var node: Node = script.new()

	# --- 单类样例：动作识别 ---
	var cases := {
		"status": ['{"type":"cmd","text":"status lite=true"}'],
		"move": ['{"type":"cmd","text":"move units=[\\"Unit_2\\"] dest=[30,20]"}'],
		"gather": ['{"type":"cmd","text":"gather units=[\\"Unit_2\\"] kind=a"}'],
		"build": ['{"type":"cmd","text":"build units=[\\"Unit_2\\"] pos=[10,10]"}'],
		"produce": ['{"type":"cmd","text":"produce producer=Unit_0 scene=Worker.tscn"}'],
		"attack": ['{"type":"cmd","text":"attack units=[\\"Tank_1\\"] target=Unit_9"}'],
	}
	for op in cases:
		var digest: Dictionary = node._digest_lines(cases[op])
		_assert_player_facing(digest, "op=" + str(op))
		_check(str(digest["state"]) != node.PANEL_UNKNOWN,
			"op=%s 应识别动作而非未知（state=%s）" % [op, digest["state"]])

	# --- 回执类样例：结果识别 ---
	var receipt_cases := {
		"PendingAuthority": ['{"type":"receipt","text":"produce -> status=PendingAuthority"}'],
		"Accepted": ['{"type":"receipt","text":"produce -> ok=true status=Accepted"}'],
		"QueueFull": ['{"type":"receipt","text":"produce rejected: QueueFull"}'],
		"ProductNotAllowed": ['{"type":"receipt","text":"produce rejected: ProductNotAllowed"}'],
		"InsufficientResources": ['{"type":"receipt","text":"produce rejected: InsufficientResources"}'],
		"TargetNotFound": ['{"type":"receipt","text":"attack rejected: TargetNotFound"}'],
		"ResourceNotFound": ['{"type":"receipt","text":"gather rejected: ResourceNotFound"}'],
		"Occupied": ['{"type":"receipt","text":"build rejected: Occupied"}'],
		"WeaponCannotTargetDomain": ['{"type":"receipt","text":"attack rejected: WeaponCannotTargetDomain"}'],
		"NoGateway": ['{"type":"receipt","text":"move failed: NoGateway"}'],
	}
	for name in receipt_cases:
		var digest: Dictionary = node._digest_lines(receipt_cases[name])
		_assert_player_facing(digest, "receipt=" + str(name))
		_check(str(digest["result"]) != "暂无新结果",
			"receipt=%s 应识别执行结果（result=%s）" % [name, digest["result"]])
	_check(str(node._digest_lines(
		['{"type":"receipt","text":"produce -> status=PendingAuthority"}'])["state"])
		== "等待服务器确认", "PendingAuthority 应显示等待服务器确认")
	_check(str(node._digest_lines(
		['{"type":"receipt","text":"build rejected: Occupied"}'])["result"])
		== "放置位置被占用，换个位置试试", "Occupied 应显示位置被占用文案")
	_check(str(node._digest_lines(
		['{"type":"receipt","text":"attack rejected: WeaponCannotTargetDomain"}'])["result"])
		== "武器打不了这种目标（对空/对地不匹配）", "WeaponCannotTargetDomain 应显示对空对地文案")

	# --- 普通中文复盘与未知行 ---
	var normal: Dictionary = node._digest_lines(["副官复盘：当前经济发展良好，继续补充工人。"])
	_check(str(normal["why"]) != "—", "普通中文复盘应提取到为什么")
	_check(not str(normal["why"]).contains("{"), "普通中文复盘不含 JSON 原文")
	var unknown: Dictionary = node._digest_lines(["###gibberish###", "@@@@"])
	_check(str(unknown["state"]) == node.PANEL_UNKNOWN, "未知行应回落到副官正在整理战况")

	# --- 混合输入：新失败不与旧动作错误拼接（result 取最新、action 可更旧）---
	var mixed: Dictionary = node._digest_lines([
		'{"type":"cmd","text":"produce producer=Unit_0"}',
		'{"type":"receipt","text":"produce rejected: QueueFull"}',
	])
	_check(str(mixed["action"]) == "正在生产", "混合输入动作=最新命令（正在生产）")
	_check(str(mixed["result"]) == "生产队列已满", "混合输入结果=最新失败（队列已满）")

	# --- 健壮性：空数组、畸形 JSON、非字符串 ---
	var robust: Dictionary = node._digest_lines(['{"broken', "{", "   ", ""])
	_check(robust is Dictionary and not str(robust["state"]).is_empty(),
		"畸形输入不抛异常且有兜底显示")
	_check(str(node._digest_lines([])["state"]) == node.PANEL_UNKNOWN, "空日志回落未知兜底")

	node.free()
	print("AdjutantDigestSamples: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
