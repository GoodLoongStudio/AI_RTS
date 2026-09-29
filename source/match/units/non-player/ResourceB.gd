extends "res://source/match/units/non-player/ResourceUnit.gd"

const MATERIAL_ALBEDO_TO_REPLACE = Color(0.4687, 0.944, 0.7938)
const MATERIAL_ALBEDO_TO_REPLACE_EPSILON = 0.05

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


func _ready():
	super()
	_setup_mesh_colors()


func _setup_mesh_colors():
	# gdlint: ignore = function-preload-variable-name
	var material = preload(Constants.Match.Resources.B.MATERIAL_PATH)
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		self, MATERIAL_ALBEDO_TO_REPLACE, MATERIAL_ALBEDO_TO_REPLACE_EPSILON, material
	)
