extends Node

## Synty 素材白模统一材质绑定。
## FBX 导入后是白模（Unity .mat 无法迁移），此脚本给父节点下所有
## MeshInstance3D 覆盖共享图集材质（预览渲染工程 map_fbx_textures.py
## 已算好 模型→图集 对应关系，接入时按 texture_map.json 选图集）。
## 用法：挂在需要绑定的节点（如单位 Geometry）下，@export 指向图集贴图。
##
## 阵营色（2026-09-05）：材质缓存按 (图集, 底色, 阵营色) 三元组区分，
## 同阵营单位共享材质实例，不同阵营各有一份。
## 着色用小型 shader：先把图集纹理去饱和，再乘阵营色并保留 30% 原纹理细节——
## 纯相乘会被 Synty 高饱和金黄纹理吞掉阵营色（实测），去饱和后各阵营一目了然。


@export var albedo_texture: Texture2D
@export var albedo_color: Color = Color.WHITE
## 阵营色混合强度：0 = 原图集，1 = 纯阵营色
@export_range(0.0, 1.0, 0.05) var team_tint_strength := 0.75

static var _shared_materials := {}

const TEAM_TINT_SHADER: Shader = preload("res://source/shaders/3d/team_tint.gdshader")

var _team_tint := Color.WHITE


func _ready() -> void:
	apply()


## 绑定/重绑图集材质。建筑完工时 Structure 会清空 material_override，
## 需要再次调用本方法恢复 Synty 外观（若此前收到过阵营色则保持 tint）。
func apply() -> void:
	_apply_material()


## Unit._setup_color 在玩家归属就绪后调用，把阵营色写入材质。
func apply_team_tint(color: Color) -> void:
	print("[TINT] apply_team_tint ", color, " on ", get_parent().name)
	_team_tint = color
	_apply_material()
	var target := get_parent()
	var count := 0
	for mesh_instance in target.find_children("*", "MeshInstance3D", true, false):
		var override = mesh_instance.material_override
		count += 1
	print("[TINT] override meshes=", count, " tint=", _team_tint)


func _resolve_tint() -> Color:
	if _team_tint != Color.WHITE:
		return _team_tint
	# Structure 完工重绑等场景：从所属单位反查玩家阵营色。
	var geometry := get_parent()
	var unit = geometry.get_parent() if geometry != null else null
	if unit != null and "player" in unit and unit.get("player") != null:
		var player = unit.get("player")
		if player != null and "color" in player:
			return player.get("color")
	return Color.WHITE


func _apply_material() -> void:
	if albedo_texture == null:
		push_warning("SyntyMaterialBinder 未配置图集，保持白模")
		return
	var tint := _resolve_tint()
	var team_mix := 0.0 if tint == Color.WHITE else team_tint_strength
	var cache_key := "%s|%s|%s" % [
		albedo_texture.resource_path, albedo_color.to_html(), tint.to_html()
	]
	var material: ShaderMaterial = _shared_materials.get(cache_key)
	if material == null:
		var shader := Shader.new()
		shader.code = TEAM_TINT_SHADER
		material = ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter("albedo_texture", albedo_texture)
		material.set_shader_parameter("albedo_color", albedo_color)
		material.set_shader_parameter("team_color", tint)
		material.set_shader_parameter("team_mix", team_mix)
		_shared_materials[cache_key] = material
	var target := get_parent()
	if target == null:
		return
	for mesh_instance in target.find_children("*", "MeshInstance3D", true, false):
		mesh_instance.material_override = material
