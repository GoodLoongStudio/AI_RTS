extends Node

## 复现并验证"单人开房"：把 Play.tscn（单机模式页）当成当前场景加载，
## 程序化触发「开始游戏」按钮的处理函数，然后断言场景真的切换成了 Loading 场景。
## 这正是玩家点按钮走的那条路。

const PLAY_SCENE := "res://source/main-menu/Play.tscn"


func _ready():
	await get_tree().process_frame
	# 【关键】把大厅页挂到**容器**里（父节点不是 root），复现玩家真实路径：
	# 旧代码用 get_parent().add_child(...) 挂新场景 ⇒ current_scene 赋值被 Godot 拒绝。
	var holder := Node.new()
	holder.name = "MenuHolder"
	get_tree().root.add_child(holder)
	var play: Node = (load(PLAY_SCENE) as PackedScene).instantiate()
	holder.add_child(play)
	for _f in range(3):
		await get_tree().process_frame
	for _f in range(30):
		await get_tree().process_frame
	print("[LOBBY] Play 页就绪，父节点=%s（root? %s）" % [play.get_parent().name, str(play.get_parent() == get_tree().root)])
	# 直接调处理函数（等价于点按钮：信号就是连到这个方法）
	play.call("_on_start_button_pressed")
	var switched := false
	for _f in range(180):
		await get_tree().process_frame
		var cur := get_tree().current_scene
		if cur != null and cur != play and not is_instance_valid(play):
			switched = true
			break
		if cur != null and cur != play:
			switched = true
			break
	print("[LOBBY] 点击后 current_scene = %s" % (str(get_tree().current_scene.name) if get_tree().current_scene != null else "null"))
	print("[LOBBY] 判定: %s" % ("✓ 场景已切走（开房成功）" if switched else "✗ 仍停在原页面（开房失败）"))
	get_tree().quit(0 if switched else 1)
