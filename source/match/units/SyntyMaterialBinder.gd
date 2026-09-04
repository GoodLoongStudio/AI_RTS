extends Node

## Synty 素材白模统一材质绑定。
## FBX 导入后是白模（Unity .mat 无法迁移），此脚本给父节点下所有
## MeshInstance3D 覆盖共享图集材质（预览渲染工程 map_fbx_textures.py
## 已算好 模型→图集 对应关系，接入时按 texture_map.json 选图集）。
## 用法：挂在需要绑定的节点（如单位 Geometry）下，@export 指向图集贴图。


@export var albedo_texture: Texture2D
@export var albedo_color: Color = Color.WHITE

static var _shared_materials := {}


func _ready() -> void:
	if albedo_texture == null:
		push_warning("SyntyMaterialBinder 未配置图集，保持白模")
		return
	var cache_key := "%s|%s" % [albedo_texture.resource_path, albedo_color.to_html()]
	var material: StandardMaterial3D = _shared_materials.get(cache_key)
	if material == null:
		material = StandardMaterial3D.new()
		material.albedo_texture = albedo_texture
		material.albedo_color = albedo_color
		_shared_materials[cache_key] = material
	var target := get_parent()
	if target == null:
		return
	for mesh_instance in target.find_children("*", "MeshInstance3D", true, false):
		mesh_instance.material_override = material
