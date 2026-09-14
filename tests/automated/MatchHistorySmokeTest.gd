extends "res://tools/probe_match_history.gd"

## 回归套件入口：复用 `tools/probe_match_history.gd` 的全部断言（数据层 + 版面层），
## 但只跑一个分辨率，让单条用例留在回归清单的超时预算内。
##
## 完整的多分辨率验证请直接跑探针场景本身：
##   godot --headless --path . res://tools/probe_match_history.tscn
##
## 场景放在 `tests/automated/` 是为了纳入 `Assert-Manifest` 的不变式：
## `tools/run_full_regression.ps1` 只扫描 `tests/automated/*.tscn`，落在 `tools/`
## 的场景既不会被登记也不会被校验（也就不会在别人改动后自动报警）。

const SMOKE_RESOLUTION := "1280x720"


func _requested_resolutions() -> Array:
	return [SMOKE_RESOLUTION]
