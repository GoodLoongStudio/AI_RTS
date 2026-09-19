extends Node

## 小地图战争迷雾"实时跟随"验收（2026-09-15 用户实测 bug 固化）。
##
## 背景：小地图 FogOfWarMask 曾经每次同步把 `FogOfWar/CombinedViewport` 拷成一张
## `ImageTexture` 快照，而同步只发生在开局那几次（Minimap._ready / 0.35s / 1.2s /
## 进局 refresh_now / 侧栏收编）⇒ 开局约一秒后小地图迷雾就定格在那一团，之后单位
## 再怎么探图都不更新（用户报"大湖的小地图战争迷雾不更新"）。
## 现在改成：探测到迷雾画出内容后绑 `CombinedViewport` 的**实时** ViewportTexture。
##
## 本工具用最小合成场景（假 FogOfWar + 真 Minimap 节点）做像素级证明：
##   1) 遮罩绑定的是实时 ViewportTexture，不是快照 ImageTexture；
##   2) 改迷雾纹理内容 → 小地图上被遮罩盖住的像素跟着变；
##   3) 反向对照：把同一张纹理换成快照后像素必须**不再跟随**（证明本测试测得出定格）。
##
## 跑法（**必须 GUI 模式**，headless 不渲染、量不到像素；不能用 --script，
## --script 主循环下取不到 autoload，Minimap.gd 编译不过）：
##   godot --path . res://tools/verify_minimap_fog_live.tscn --position -4000,-4000
## 退出码 0=PASS，1=FAIL；截图落在 user://minimap_fog_probe_{before,after}.png。

const MinimapScript = preload("res://source/match/hud/Minimap.gd")
const FogMaskShader = preload("res://source/shaders/2d/white_transparent.gdshader")

const FOG_PX := 64
const REVEAL_EDGE := 8
## 取样点躲开主菜单/副官面板那几块 overlay（左上角到 y≈160、y≈255~280 的标签），
## 否则量到的是面板像素而不是小地图。
const FIRST_REVEAL := Vector2(4, 44)
const SECOND_REVEAL := Vector2(48, 48)
const HIDDEN_SAMPLE := Vector2(36, 20)
const WINDOW_EDGE := 512

var _failures := 0


class MapStub:
	extends Node3D
	var size := Vector2(64.0, 64.0)


func _ready() -> void:
	await _run()
	get_tree().quit(1 if _failures > 0 else 0)


func _check(cond: bool, message: String) -> void:
	if cond:
		print("  OK  ", message)
	else:
		_failures += 1
		print("  FAIL  ", message)


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _run() -> void:
	get_window().size = Vector2i(WINDOW_EDGE, WINDOW_EDGE)
	await _wait_frames(2)

	var match_node := Node3D.new()
	match_node.name = "Match"
	var map_stub := MapStub.new()
	map_stub.name = "Map"
	match_node.add_child(map_stub)

	var fog := Node3D.new()
	fog.name = "FogOfWar"
	match_node.add_child(fog)
	var combined := SubViewport.new()
	combined.name = "CombinedViewport"
	combined.disable_3d = true
	combined.size = Vector2i(FOG_PX, FOG_PX)
	combined.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	fog.add_child(combined)
	var fog_bg := ColorRect.new()
	fog_bg.color = Color(0, 0, 0, 1)
	fog_bg.size = Vector2(FOG_PX, FOG_PX)
	combined.add_child(fog_bg)
	var revealed := ColorRect.new()
	revealed.name = "FakeRevealed"
	revealed.color = Color(1, 1, 1, 1)
	revealed.size = Vector2(REVEAL_EDGE, REVEAL_EDGE)
	revealed.position = FIRST_REVEAL
	combined.add_child(revealed)

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	match_node.add_child(hud)

	var minimap := PanelContainer.new()
	minimap.name = "Minimap"
	minimap.set_script(MinimapScript)
	var margin := MarginContainer.new()
	margin.name = "MarginContainer"
	minimap.add_child(margin)
	var minimap_viewport := SubViewport.new()
	minimap_viewport.name = "MinimapViewport"
	minimap_viewport.disable_3d = true
	minimap_viewport.size = Vector2i(128, 128)
	minimap_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var viewport_bg := ColorRect.new()
	viewport_bg.name = "Background"
	viewport_bg.color = Color(0.35, 0.35, 0.35, 1)
	viewport_bg.size = Vector2(128, 128)
	minimap_viewport.add_child(viewport_bg)
	var texture_rect := TextureRect.new()
	texture_rect.name = "MinimapTextureRect"
	texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(minimap_viewport)
	margin.add_child(texture_rect)
	var mask := ColorRect.new()
	mask.name = "FogOfWarMask"
	var mask_material := ShaderMaterial.new()
	mask_material.shader = FogMaskShader
	mask.material = mask_material
	mask.color = Color(0, 0, 0, 1)
	# 位置照抄 Match.tscn：遮罩初始挂在 MinimapViewport 下，由 Minimap 挪到 TextureRect。
	minimap_viewport.add_child(mask)
	var indicator := Line2D.new()
	indicator.name = "CameraIndicator"
	minimap_viewport.add_child(indicator)
	minimap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.add_child(minimap)

	# Minimap.gd 用 find_child（owned 默认 true）取节点，运行时建的节点必须显式认场景主。
	_own_tree(match_node, match_node)
	get_tree().root.add_child(match_node)
	await _wait_frames(6)

	# ---- 1. 遮罩绑定实时纹理 ----
	var attempts := 0
	while not bool(minimap.get("_fog_live_bound")) and attempts < 12:
		attempts += 1
		minimap.call("_sync_minimap_fog_mask")
		await _wait_frames(2)
	_check(bool(minimap.get("_fog_live_bound")), "遮罩完成绑定（尝试 %d 次）" % attempts)
	_check(mask.visible, "迷雾开着时遮罩可见")
	_check(mask.get_parent() == texture_rect, "遮罩挂在 MinimapTextureRect 上（不是子视口里）")
	var bound = mask_material.get_shader_parameter("reference_texture")
	_check(
		bound is ViewportTexture and bound == combined.get_texture(),
		"reference_texture 是 CombinedViewport 的实时纹理（实际 %s）" % str(bound)
	)
	_check(
		not (bound is ImageTexture),
		"reference_texture 不是一次性快照 ImageTexture（旧实现会定格）"
	)

	# ---- 2. 像素级：已探明处亮、未探明处暗 ----
	var transform := mask.get_screen_transform()
	print("  mask size=", mask.size, " screen_origin=", transform.origin)
	var shot_a := await _capture()
	var first_point := transform * _region_center(FIRST_REVEAL, mask.size)
	var hidden_point := transform * _region_center(HIDDEN_SAMPLE, mask.size)
	var a_revealed := _luma(shot_a, first_point)
	var a_hidden := _luma(shot_a, hidden_point)
	print("  亮度：已探明=%.3f 未探明=%.3f" % [a_revealed, a_hidden])
	_check(a_revealed > a_hidden + 0.05, "未探明区被遮罩压暗（%.3f > %.3f）" % [a_revealed, a_hidden])
	_check(a_revealed > 0.2, "已探明区不被遮罩压黑（%.3f）" % a_revealed)

	# ---- 3. 换一个探明点：遮罩必须跟着实时的迷雾纹理走 ----
	revealed.position = SECOND_REVEAL
	await _wait_frames(6)
	var shot_b := await _capture()
	var b_old := _luma(shot_b, first_point)
	var b_new := _luma(shot_b, transform * _region_center(SECOND_REVEAL, mask.size))
	print("  亮度：旧点=%.3f 新点=%.3f" % [b_old, b_new])
	_check(b_new > a_hidden + 0.05, "新探明区变亮（%.3f > 未探明 %.3f）" % [b_new, a_hidden])
	_check(
		b_old < a_revealed - 0.05,
		"旧探明区跟着变暗（%.3f < 原亮度 %.3f）—— 迷雾不是快照" % [b_old, a_revealed]
	)
	_save(shot_a, "user://minimap_fog_probe_before.png")
	_save(shot_b, "user://minimap_fog_probe_after.png")

	# ---- 4. 反向对照：换成快照后必须不再跟随（证明本测试测得出"定格"） ----
	mask_material.set_shader_parameter(
		"reference_texture", ImageTexture.create_from_image(combined.get_texture().get_image())
	)
	revealed.position = FIRST_REVEAL
	await _wait_frames(8)
	var shot_c := await _capture()
	var c_new := _luma(shot_c, first_point)
	var c_snapshot := _luma(shot_c, transform * _region_center(SECOND_REVEAL, mask.size))
	print("  亮度（快照遮罩）：新探明点=%.3f 快照里还亮着的旧点=%.3f" % [c_new, c_snapshot])
	_check(
		c_new < a_hidden + 0.05,
		"反向对照：快照遮罩认不出新探明区（%.3f）—— 旧实现就是这样定格的" % c_new
	)
	_check(
		c_snapshot > a_hidden + 0.05,
		"反向对照：快照遮罩还留着旧亮斑（%.3f）" % c_snapshot
	)

	if _failures > 0:
		print("FAIL: minimap fog live, %d failure(s)" % _failures)
	else:
		print("PASS: minimap fog live")


func _own_tree(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_tree(child, owner_node)


func _region_center(origin: Vector2, mask_size: Vector2) -> Vector2:
	# 迷雾纹理的像素 → 遮罩局部坐标（遮罩铺满 TextureRect，UV 0..1 覆盖整块）。
	var center := origin + Vector2(REVEAL_EDGE, REVEAL_EDGE) * 0.5
	return (center / float(FOG_PX)) * mask_size


func _capture() -> Image:
	await _wait_frames(3)
	var tex := get_tree().root.get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	return img


func _luma(img: Image, screen_pos: Vector2) -> float:
	if img == null:
		return -1.0
	var total := 0.0
	var samples := 0
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			var x := clampi(int(screen_pos.x) + dx, 0, img.get_width() - 1)
			var y := clampi(int(screen_pos.y) + dy, 0, img.get_height() - 1)
			var c := img.get_pixel(x, y)
			total += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			samples += 1
	return total / maxf(1.0, float(samples))


func _save(img: Image, path: String) -> void:
	if img == null:
		return
	img.save_png(path)
	print("  saved ", path)
