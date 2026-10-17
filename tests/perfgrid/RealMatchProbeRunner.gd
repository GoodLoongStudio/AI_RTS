extends Node

## 实机对局报告探针（2026-09-27，临时验证用，跑完即删）。
## 真实打一局（完整结算链路），把 MatchReportStore 落盘的报告原样导出，
## 核对"报告记了什么、是不是真实数据"。报告存档隔离到临时目录；
## 成长/画像存档先快照、跑完还原，不污染玩家数据。
##
## 结构：launcher（本节点）只负责把 Observer 延迟挂到 tree.root，然后换场景打对局；
## Observer 不是场景的一部分，换场景不会被释放，轮询线程活着。
## 轮询走 _process + PROCESS_MODE_ALWAYS：对局结束会 get_tree().paused = true。

const ObserverPath := "res://tests/perfgrid/RealMatchObserver.gd"
const MatchScenePath := "res://tests/perfgrid/RealMatchProbe.tscn"


func _ready() -> void:
	var observer: Node = (load(ObserverPath) as GDScript).new()
	# deferred：_ready 期间直接 add_child 到 root 会被"busy setting up children"拒绝。
	get_tree().root.add_child.call_deferred(observer)
	# 后注册的 change_scene 也在 deferred 队列里 → Observer._ready（隔离存档）先跑，
	# 再换对局场景，钩子按 current_scene 找到对局根。
	get_tree().change_scene_to_file.call_deferred(MatchScenePath)
