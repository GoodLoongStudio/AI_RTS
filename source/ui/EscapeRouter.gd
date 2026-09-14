extends RefCounted

## 「ESC 回退」唯一咽喉（2026-09-14 用户要求：所有页面 ESC 都能回退；
## 对局内 ESC 与 F10 都能唤出暂停菜单）。
##
## 引用方式：`const EscapeRouter = preload("res://source/ui/EscapeRouter.gd")`，
## 静态状态挂在同一份脚本资源上，全仓共享（不依赖 class_name 缓存）。
##
## 不变式（改 ESC 行为前必读）：
## 1) 对局内一次 ESC 只允许产生**一个**结果：要么某个"取消"语义生效
##    （取消建筑放置 / 取消目标选择 / 清空待发命令），要么由暂停菜单兜底唤出。
## 2) 谁消费了 ESC 谁就调用 `claim()`；菜单的兜底判定必须排在**同一帧末尾**
##    （call_deferred），这样才看得到本帧是否已被认领。
## 3) 认领按"帧"记录：`Engine.get_process_frames()` 在一帧内恒定，
##    对局暂停（get_tree().paused）不影响该计数。

static var _claimed_frame: int = -1


## 声明"本次 ESC 已被消费"（取消类操作在真正生效后调用）。
static func claim() -> void:
	_claimed_frame = Engine.get_process_frames()


## 本帧是否已有系统认领 ESC（仅菜单兜底判定使用）。
static func is_claimed_this_frame() -> bool:
	return _claimed_frame == Engine.get_process_frames()
