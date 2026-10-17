extends Node

## 生产卡片图标"尺寸规范"回归测试（2026-10-10）
##
## 用户口径（原话）：「这些UI的建筑的大小你也规范一下，基地这么小，兵营这么大，都不协调」。
##
## 规范（唯一权威规则）：`NewUnitsLineupSmokeTest._render_normalized_icon()`
## 按模型包围盒自动取景，再把**可见内容**（非透明像素包围盒）迭代收敛到占画面
## `ICON_TARGET_FILL = 0.82` 并居中。因此每张图标的观感大小都落在同一条带上。
##
## 本测试直接量**落盘的 PNG**（headless 可跑，不需渲染），断言：
##  1) `Ra3Sidebar.TABS` 里出现的**每一个** icon key 都存在对应 PNG；
##  2) 每张的占满度 fill = max(ink_w, ink_h) ∈ [FILL_MIN, FILL_MAX]；
##  3) 内容居中：包围盒中心相对画面中心的偏移 ≤ CENTER_TOLERANCE_PX；
##  4) **协调性硬指标**：所有图标 fill 的极差 ≤ MAX_SPREAD（"大小一致"的可量化判据）。
##
## 基线（2026-10-10 规范化之前，同样口径实测）：0.352（对地炮）… 1.000（兵营/矿场），
## 极差 0.648 —— 正是"基地这么小、兵营这么大"的来源。

const SidebarScript = preload("res://source/match/hud/ra3/Ra3Sidebar.gd")

const ICON_DIR := "res://source/match/hud/ra3/icons"
const ICON_PX := 128
const FILL_MIN := 0.72
const FILL_MAX := 0.92
const CENTER_TOLERANCE_PX := 8
const MAX_SPREAD := 0.12

var _failures := 0


func _ready():
	var keys: Array = []
	for tab in SidebarScript.TABS:
		for item in tab.get("items", []):
			var key := str(item.get("icon", ""))
			if not key.is_empty() and not keys.has(key):
				keys.append(key)
	print("  [info] TABS 里共有 %d 个 icon key: %s" % [keys.size(), str(keys)])
	_check(keys.size() >= 17, "TABS 的 icon key 数量异常（实际 %d）" % keys.size())

	var fills: Array = []
	for key in keys:
		var path := "%s/%s.png" % [ICON_DIR, key]
		if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
			_fail("TABS 用到图标 %s，但 %s 不存在" % [key, path])
			continue
		var image := Image.load_from_file(ProjectSettings.globalize_path(path))
		if image == null:
			_fail("图标 %s 读取失败" % key)
			continue
		var size := image.get_size()
		var rect := image.get_used_rect()
		if rect.size.x <= 0 or rect.size.y <= 0:
			_fail("图标 %s 是空白图（没有可见像素）" % key)
			continue
		var fill := float(maxi(rect.size.x, rect.size.y)) / float(size.x)
		fills.append(fill)
		var cx := float(rect.position.x) + float(rect.size.x) * 0.5 - float(size.x) * 0.5
		var cy := float(rect.position.y) + float(rect.size.y) * 0.5 - float(size.y) * 0.5
		print("  [info] %-20s fill=%.3f ink=%dx%d center=(%.0f,%.0f)" % [
			key, fill, rect.size.x, rect.size.y, cx, cy])
		_check(fill >= FILL_MIN and fill <= FILL_MAX,
			"图标 %s 占满度 %.3f 应在 [%.2f, %.2f]（规范：统一自动取景）" % [
				key, fill, FILL_MIN, FILL_MAX])
		_check(absf(cx) <= float(CENTER_TOLERANCE_PX) and absf(cy) <= float(CENTER_TOLERANCE_PX),
			"图标 %s 内容未居中（偏移 %.0f,%.0f，容差 %d）" % [
				key, cx, cy, CENTER_TOLERANCE_PX])

	if not fills.is_empty():
		var lo := float(fills.min())
		var hi := float(fills.max())
		print("  [info] fill 极差 = %.3f（min %.3f / max %.3f，上限 %.2f）" % [
			hi - lo, lo, hi, MAX_SPREAD])
		_check(hi - lo <= MAX_SPREAD,
			"图标大小不协调：fill 极差 %.3f 超过 %.2f（min %.3f / max %.3f）" % [
				hi - lo, MAX_SPREAD, lo, hi])

	_finish()


func _check(condition: bool, message: String):
	if condition:
		print("  ok: %s" % message)
		return
	_fail(message)


func _fail(message: String):
	_failures += 1
	print("FAIL: %s" % message)
	push_error("Icon size standard assertion failed: %s" % message)


func _finish():
	print("Icon size standard smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)
