extends "res://source/match/units/non-player/ResourceUnit.gd"

## 矿点 A（金矿块，2026-09-28 用户选型）。
##
## 为什么不再做"薄荷绿 → 资源色"的材质替换：换金矿块之后，矿点外观由 4041 素材包
## 图集给出（`SyntyMaterialBinder` 在 Geometry 下绑定），本身就是金黄色，与沙色地形
## 对比度足够，用户明确说"不需要蓝色"。旧的
## `traverse_node_tree_and_replace_materials_matching_albedo` 链路（按 albedo≈薄荷绿
## 精确匹配 crystal 面）只对 Kenney 晶体模型有意义，而 Kenney 晶体已从本场景移除。

@export var resource_a = 30000:
	set(value):
		resource_a = max(0, value)
		# 采空不再删除实体：转入"耗尽等待"，身份/位置/容量/再生计时全部保留。
		# 是否真的再生（还是按旧语义消失）由 Match/ResourceRegeneration 按配置裁决。
		if resource_a == 0:
			mark_depleted()
		elif depleted and total_ore() > 0:
			mark_ready()
		_refresh_depletion_presentation()

var color = Constants.Match.Resources.A.COLOR:
	set(_value):
		pass
