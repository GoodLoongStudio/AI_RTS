class_name MatchSetupShared
extends RefCounted

## 单机与联机共用的对局配置数据工具。UI 层只负责呈现，地图数据统一从目录读取。
static func map_entries() -> Array:
	# 显式类型：Utils.Dict.items() 无返回类型注解（Variant），用 `:=` 会
	# 触发 "Cannot infer the type" 解析错误，导致本脚本整体编译失败、
	# 页面地图列表为空（2026-09-14 实测）。
	var entries: Array = Utils.Dict.items(Constants.Match.ALL_MAPS)
	entries.sort_custom(func(a, b): return int(a[1].get("players", 0)) < int(b[1].get("players", 0)))
	return entries

static func map_paths() -> Array[String]:
	var result: Array[String] = []
	for entry in map_entries():
		result.append(str(entry[0]))
	return result

static func map_label(path: String) -> String:
	var info: Dictionary = Constants.Match.ALL_MAPS.get(path, {})
	return str(info.get("name", path))

static func map_summary(path: String) -> String:
	var info: Dictionary = Constants.Match.ALL_MAPS.get(path, {})
	var size = info.get("size", Vector2i.ZERO)
	return "%d 人 · %s×%s" % [int(info.get("players", 0)), str(size.x), str(size.y)]


## 地图预览图目录。图由 `tools/render_map_previews.gd` **离线**渲染真实地图生成
## （菜单里不再用"按路径 hash 派生颜色"的假格子）：
##   godot --path . --resolution 1280x720 --position -4000,-4000 res://tools/render_map_previews.tscn
## 生成后需 `--headless --import` 一次；缺图时 UI 自动退回占位棋盘，不会崩。
const PREVIEW_DIR := "res://assets/map_previews"


## 地图路径 → 预览图文件基名（用地名图文件基名，稳定可读、与地图一对一）。
static func preview_slug(path: String) -> String:
	return path.get_file().get_basename()


static func preview_path(path: String) -> String:
	return "%s/%s.png" % [PREVIEW_DIR, preview_slug(path)]


## 预览图是否可用（未生成或未导入时为 false）。
static func preview_available(path: String) -> bool:
	return ResourceLoader.exists(preview_path(path))
