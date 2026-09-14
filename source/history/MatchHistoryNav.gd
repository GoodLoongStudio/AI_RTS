class_name MatchHistoryNav
extends RefCounted

## 历史对局页面之间的导航状态中枢。
##
## 为什么用一个独立的静态中转而不是在页面里存字段：
## 页面切换走的是 `change_scene_to_file()`，旧页面整个被释放，"从哪来"这件事
## 只能存在场景之外。集中放在这里比让两个页面互相 `preload` 干净，
## 也让 headless 测试可以精确控制入口。

## 历史列表页「返回」的目标场景。入口页（成长卡片 / 玩家画像）在跳转前设置它。
static var return_scene := "res://source/main-menu/PlayerProfile.tscn"
## 待打开的报告 id。列表页点击某条记录时写入，详情页 `_ready` 时消费并清空。
static var pending_report_id := ""
## 待打开的标签页下标（0-5），默认总览。
static var pending_tab := 0


static func open_detail(report_id: String, tab: int = 0) -> void:
	pending_report_id = report_id
	pending_tab = tab


static func take_pending_report_id() -> String:
	var value := pending_report_id
	pending_report_id = ""
	return value


static func reset() -> void:
	return_scene = "res://source/main-menu/PlayerProfile.tscn"
	pending_report_id = ""
	pending_tab = 0
