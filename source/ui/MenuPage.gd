extends Control

## 主菜单侧页面通用 ESC 回退基类（2026-09-14 用户要求：所有页面支持 ESC 回退）。
## 用法：页面脚本写 `extends "res://source/ui/MenuPage.gd"`，覆写 `_on_escape()`。
##
## 为什么主菜单不直接用对局的 C# InputBindingRuntime：
## 它会在 `_input` 阶段吞掉字母/数字键（Camera/Selection/UnitCommand 上下文），
## 破坏联机大厅 LineEdit 的输入；主菜单只需要"取消/返回"这一个动作，
## 因此走 Godot 内建 `ui_cancel`（默认 ESC）。
##
## 约定：子类**覆写 `_on_escape()`** 实现"返回上一级 / 关闭内嵌面板"，
## 不要覆写 `_unhandled_input`（会绕过统一回退）。
## `_on_escape()` 返回 true 表示已消费本次 ESC（阻止父页面/其它监听者重复处理）。


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _on_escape():
			get_viewport().set_input_as_handled()


## 返回是否消费本次 ESC；默认不消费（无上一级的页面保持无动作）。
func _on_escape() -> bool:
	return false
