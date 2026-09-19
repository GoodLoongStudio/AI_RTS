class_name MatchPauseGate
extends Node

## 对局暂停引用计数。选牌和 F10 菜单共用，避免一方关掉就把另一方的暂停冲掉。
## 联机不冻世界（服务器/其它端仍在推进）。

var _holders: Dictionary = {}


func acquire(holder_id: String) -> void:
	if holder_id.is_empty():
		return
	_holders[holder_id] = true
	_apply()


func release(holder_id: String) -> void:
	_holders.erase(holder_id)
	_apply()


func is_held(holder_id: String = "") -> bool:
	if holder_id.is_empty():
		return not _holders.is_empty()
	return _holders.has(holder_id)


func can_freeze_world() -> bool:
	# 【2026-09-15 修"游戏暂停失效"】旧判据 `not NetSession.is_networked()` 是"是否联机"，
	# 但**单机模式（Play）默认就是"本机房主"**（见 `Play.gd` / `MatchSetupPage.gd` 的说明）
	# ⇒ 单机也会 `host()` 建 peer ⇒ `is_networked()` 恒 true ⇒ 这里**拒绝冻结世界**；
	# 而菜单标题用的是另一个口径（`should_forward_commands()`，单机为 false）
	# ⇒ 表现为「标题写着『游戏暂停』、世界照常推进」（用户 2026-09-15 实测截图）。
	# 正确口径与标题一致：**只有客户端**（命令要转发给服务器、本地冻结没有意义）才不能冻；
	# 单机 / 本机房主 / 专用服都是权威端，冻结本地仿真是有意义的。
	return not NetSession.should_forward_commands()


func _apply() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if not can_freeze_world():
		return
	tree.paused = not _holders.is_empty()
