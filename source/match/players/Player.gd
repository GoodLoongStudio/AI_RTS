extends Node3D

signal changed

@export var resource_a = 0:
	set(value):
		if _economy_runtime != null and not _applying_authoritative_snapshot:
			push_error("resource_a is an authoritative C# account mirror; use a resource transaction")
			return
		resource_a = value
		if not _applying_authoritative_snapshot:
			emit_changed()
@export var color = Color.WHITE

var _color_material = null
var _economy_runtime = null
var _resource_account_id := ""
var _resource_account_version := 0
var _applying_authoritative_snapshot := false


## 将 Player 接入当前 Match 唯一的 C# 资源账户，并导入场景初始余额。
func setup_resource_account(economy_runtime):
	assert(_economy_runtime == null, "resource account can only be configured once")
	_economy_runtime = economy_runtime
	_resource_account_id = _economy_runtime.RegisterPlayer(self, resource_a)


## 接收 C# 权威账户快照并更新 Legacy 只读字段，供现有 HUD 与测试读取。
func apply_authoritative_resource_snapshot(a: int, version: int):
	if version < _resource_account_version:
		return
	_resource_account_version = version
	_applying_authoritative_snapshot = true
	resource_a = a
	_applying_authoritative_snapshot = false
	emit_changed()


func add_resources(resources, reason := "ScriptedAdjustment", source = null) -> bool:
	assert(_economy_runtime != null, "resource account must be configured before use")
	return _economy_runtime.AddResources(self, resources, reason, source)["accepted"]


func has_resources(resources):
	assert(_economy_runtime != null, "resource account must be configured before use")
	return _economy_runtime.HasResources(self, resources)


func subtract_resources(resources, reason := "ScriptedAdjustment", source = null) -> bool:
	assert(_economy_runtime != null, "resource account must be configured before use")
	return _economy_runtime.SubtractResources(self, resources, reason, source)["accepted"]


func get_color_material():
	if _color_material == null:
		_color_material = StandardMaterial3D.new()
		_color_material.vertex_color_use_as_albedo = true
		_color_material.albedo_color = color
		_color_material.metallic = 1
	return _color_material


func emit_changed():
	changed.emit()
