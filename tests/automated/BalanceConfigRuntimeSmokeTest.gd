extends Node

const BalanceConfigRuntimeScript = preload(
	"res://source/csharp/GodotAdapter/Configuration/BalanceConfigRuntime.cs"
)
const TankScene = preload("res://source/match/units/Tank.tscn")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")

var _failures := 0


## 验证 Match 在生成单位前加载平衡 Catalog，并能按稳定映射查询 Godot 资源。
func _ready():
	var runtime := Node.new()
	runtime.name = "BalanceConfigRuntime"
	runtime.set_script(BalanceConfigRuntimeScript)
	add_child(runtime)
	await get_tree().process_frame

	_check(runtime.GetUnitTypeId(TankScene) == "tank", "Tank 场景应映射到稳定 UnitTypeId")
	_check(
		runtime.GetBlueprintScenePath(CommandCenterScene)
		== "res://source/match/units/structure-geometries/CommandCenter.tscn",
		"CommandCenter 应从 manifest 查询蓝图场景"
	)
	_check(
		is_equal_approx(runtime.GetCollectionDurationSeconds("resource_a"), 1.0),
		"Resource A 采集周期应由 Catalog 映射为 1 秒"
	)
	_check(
		is_equal_approx(runtime.GetCollectionDurationSeconds("resource_b"), 2.0),
		"Resource B 采集周期应由 Catalog 映射为 2 秒"
	)

	print("Balance config runtime smoke test completed: %d failure(s)" % _failures)
	runtime.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String):
	if condition:
		return
	_failures += 1
	push_error("Balance config runtime assertion failed: %s" % message)
