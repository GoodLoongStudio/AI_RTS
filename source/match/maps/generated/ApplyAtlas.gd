extends Node3D
## 生成地图的图集挂载：遍历 Decorations 子树，按 metadata/atlas 给每个
## MeshInstance3D 设 material_override（共享材质缓存，避免实例间材质重复创建）。
## metadata/blocking 仅作标记（碰撞由 .tscn 内 StaticBody3D 承担）。

static var _mat_cache := {}


func _ready() -> void:
	for child in get_children():
		var atlas: String = child.get_meta("atlas", "")
		if atlas.is_empty():
			continue
		var tex: Texture2D = load(atlas)
		if tex == null:
			push_warning("ApplyAtlas: 图集加载失败 %s" % atlas)
			continue
		_apply(child, tex)


func _apply(node: Node, tex: Texture2D) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if not _mat_cache.has(tex.resource_path):
			var mat := StandardMaterial3D.new()
			mat.albedo_texture = tex
			mat.roughness = 1.0
			mat.metallic = 0.0
			_mat_cache[tex.resource_path] = mat
		mi.material_override = _mat_cache[tex.resource_path]
	for c in node.get_children():
		_apply(c, tex)
