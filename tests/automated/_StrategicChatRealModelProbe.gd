extends Node

## 阶段1 真模型对话探针（2026-10-02）：AdjutantChatService × 本地战略模型（11436）。
## 连续 5 轮：验证真实回复、history_tail 递增（上下文保留）、耗时与 jsonl 日志。
## 上下文保留的硬证据：第 3 轮追问"你刚才说……"时，模型回复应引用第 2 轮内容。

const ChatService := preload("res://source/ui/AdjutantChatService.gd")

var _svc: Node


func _ready() -> void:
	_svc = ChatService.new()
	add_child(_svc)
	_svc.setup("probe-match", "probe-player")
	var rounds := [
		"这局的战略重点应该是什么？",
		"为什么你认为经济优先比先出击更重要？",
		"如果我的资源很快不够了，你刚才说的优先级要怎么调整？",
		"北侧完全没侦察过，现在派谁去合适？",
		"总结一下你到目前为止的三条建议。",
	]
	var turn := 0
	for question in rounds:
		turn += 1
		var sent: Dictionary = _svc.send(question)
		if not bool(sent.get("queued")):
			print("[REAL] 第%d轮 发送失败：%s" % [turn, str(sent.get("error_code"))])
			break
		var waited := 0.0
		while _svc.is_busy() and waited < 90.0:
			await get_tree().create_timer(0.25).timeout
			waited += 0.25
		var history_size: int = _svc.history.size()
		var last_assistant := ""
		for i in range(history_size - 1, -1, -1):
			if str(_svc.history[i].get("role")) == "assistant":
				last_assistant = str(_svc.history[i].get("content"))
				break
		print("[REAL] 第%d轮 tail轮数=%d 历史条数=%d 回复=%s" % [
			turn, _svc.history_tail().size(), history_size,
			last_assistant.left(80).replace("\n", " ")])
	get_tree().quit(0)
