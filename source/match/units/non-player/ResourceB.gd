extends "res://source/match/units/non-player/ResourceUnit.gd"

## 矿点 B：与 A 同一套金矿块外观（2026-09-28 与 ResourceA.tscn 一起换型）。
##
## 材质说明同 ResourceA.gd：外观来自 4041 图集（SyntyMaterialBinder 绑定），
## 不再走"薄荷绿 → 资源色"替换。B 目前不在任何地图/导出入口里出现
## （g4_export 只导 A），保留场景只为与 A 保持一致，避免"改了一边忘了另一边"。

@export var resource_b = 30000:
	set(value):
		resource_b = max(0, value)
		# 采空不再删除实体：转入"耗尽等待"，身份/位置/容量/再生计时全部保留。
		# 是否真的再生（还是按旧语义消失）由 Match/ResourceRegeneration 按配置裁决。
		if resource_b == 0:
			mark_depleted()
		elif depleted and total_ore() > 0:
			mark_ready()
		_refresh_depletion_presentation()

var color = Constants.Match.Resources.B.COLOR:
	set(_value):
		pass
