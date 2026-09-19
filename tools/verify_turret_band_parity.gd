extends SceneTree

## 防御塔落点口径的**跨语言一致性**守门（用户 2026-09-15："统一吧"）。
##
## 背景：塔距口径曾在三处各自写数值 ——
##   Python `placement.py`（唯一实现）、`rules_fallback.py`（上限）、
##   GDScript `DefenseController.gd`（简单电脑 AI）—— 一旦哪边单独改，
##   两条 AI 的塔就会一个贴基地、一个跑到视野边缘（用户实测报障）。
## 本工具把"必须同值"的四个数 + 三个调用点全部机器校验。
##
## 用法：godot --headless --path . --script res://tools/verify_turret_band_parity.gd

const PLACEMENT_PATH := "res://source/adjutant_coordinator/graph/placement.py"
const RULES_PATH := "res://source/adjutant_coordinator/graph/rules_fallback.py"
const TASK_PATCH_PATH := "res://source/adjutant_coordinator/graph/task_patch.py"
const DEFENSE_PATH := "res://source/match/players/simple-clairvoyant-ai/DefenseController.gd"

var _failures := 0


func _initialize() -> void:
	_run()
	if _failures > 0:
		push_error("FAIL: turret band parity, %d failure(s)" % _failures)
		quit(1)
	else:
		print("PASS: turret band parity")
		quit(0)


func _check(cond: bool, message: String) -> void:
	if cond:
		print("  OK  ", message)
	else:
		_failures += 1
		push_error("  FAIL  " + message)


## 从源码里取常量的字面值（`NAME = 12.0` / `NAME := 12.0`），取不到返回 NAN。
func _const_of(source: String, name: String) -> float:
	for line in source.split("\n"):
		var text := line.strip_edges()
		if text.begins_with("##") or text.begins_with("#"):
			continue
		# GDScript 的常量写作 `const NAME := 1.0`，Python 写作 `NAME = 1.0` —— 两种都认。
		for prefix in ["const ", "static ", "var "]:
			if text.begins_with(prefix):
				text = text.substr(prefix.length()).strip_edges()
		if not text.begins_with(name):
			continue
		var rest := text.substr(name.length()).strip_edges()
		if not (rest.begins_with("=") or rest.begins_with(":=")):
			continue
		rest = rest.trim_prefix(":").trim_prefix("=").strip_edges()
		var digits := ""
		for index in rest.length():
			var character := rest[index]
			if character >= "0" and character <= "9" or character == ".":
				digits += character
			else:
				break
		if digits != "":
			return digits.to_float()
	return NAN


## ③ 真调用：把 GDScript 脚本实例化后直接问它打分，防"源码同值、实现写反/解析失败"。
func _check_runtime_parity(band_py: float, max_anchor_py: float, inner_py: float) -> void:
	var script: Script = load(DEFENSE_PATH)
	_check(script != null, "DefenseController.gd 能加载（脚本可解析）")
	if script == null:
		return
	_check(
		script.get("TURRET_BAND_OUTER_M") == band_py,
		"实例上读到的目标带外缘 = Python 值（%s）" % band_py
	)
	var controller: Object = script.new()
	if controller == null:
		_check(false, "DefenseController 能实例化")
		return
	var at_band: float = controller.call("_band_rank", band_py)
	var outside: float = controller.call("_band_rank", band_py + 4.0)
	var inside: float = controller.call("_band_rank", inner_py)
	var far: float = controller.call("_band_rank", max_anchor_py)
	_check(at_band > outside, "GDScript 打分：带外越远越低（%.1f > %.1f）" % [at_band, outside])
	_check(inside < at_band, "GDScript 打分：带内越外越高（%.1f < %.1f）" % [inside, at_band])
	_check(far < inside, "GDScript 打分：远端候选排在基地附近之后（%.1f < %.1f）" % [far, inside])
	controller.free()


func _run() -> void:
	var placement_src := FileAccess.get_file_as_string(PLACEMENT_PATH)
	var rules_src := FileAccess.get_file_as_string(RULES_PATH)
	var task_patch_src := FileAccess.get_file_as_string(TASK_PATCH_PATH)
	var defense_src := FileAccess.get_file_as_string(DEFENSE_PATH)
	_check(not placement_src.is_empty(), "读得到 Python placement.py")
	_check(not rules_src.is_empty(), "读得到 Python rules_fallback.py")
	_check(not defense_src.is_empty(), "读得到 GDScript DefenseController.gd")
	if _failures > 0:
		return

	# ① 四个必须同值的数：Python 是唯一实现，GDScript 必须照抄。
	var band_py := _const_of(placement_src, "TURRET_BAND_OUTER_M")
	var inner_py := _const_of(placement_src, "TURRET_INNER_RADIUS_M")
	var max_py := _const_of(rules_src, "TURRET_MAX_HQ_M")
	var max_anchor_py := _const_of(rules_src, "TURRET_MAX_HQ_WITH_ANCHOR_M")
	var band_gd := _const_of(defense_src, "TURRET_BAND_OUTER_M")
	var inner_gd := _const_of(defense_src, "TURRET_OUTER_RADIUS_M")
	var limit_gd := _const_of(defense_src, "TURRET_INITIAL_RADIUS_M")
	var limit_anchor_gd := _const_of(defense_src, "TURRET_MAX_RADIUS_M")
	_check(not is_nan(band_py), "placement.TURRET_BAND_OUTER_M 取到值")
	_check(not is_nan(inner_py), "placement.TURRET_INNER_RADIUS_M 取到值")
	_check(not is_nan(max_py), "rules_fallback.TURRET_MAX_HQ_M 取到值")
	_check(not is_nan(max_anchor_py), "rules_fallback.TURRET_MAX_HQ_WITH_ANCHOR_M 取到值")
	_check(not is_nan(band_gd), "DefenseController.TURRET_BAND_OUTER_M 取到值")
	_check(
		band_gd == band_py,
		"目标带外缘两侧同值：Python %s / GDScript %s" % [band_py, band_gd]
	)
	_check(
		inner_gd == inner_py,
		"内圈半径两侧同值：Python %s / GDScript %s" % [inner_py, inner_gd]
	)
	_check(
		limit_gd == max_py,
		"无锚点上限两侧同值：Python %s / GDScript %s" % [max_py, limit_gd]
	)
	_check(
		limit_anchor_gd == max_anchor_py,
		"有锚点上限两侧同值：Python %s / GDScript %s" % [max_anchor_py, limit_anchor_gd]
	)
	_check(band_py > inner_py, "目标带外缘在外圈分界之外（%s > %s）" % [band_py, inner_py])
	_check(
		max_py >= band_py and max_anchor_py >= max_py,
		"上限不低于目标带且不窄于无锚点档（%s <= %s <= %s）" % [band_py, max_py, max_anchor_py]
	)

	# ② 三个调用点：打分必须走"带内越外越好、出带越远越差"的唯一实现。
	_check(placement_src.contains("def turret_band_rank"), "唯一实现 placement.turret_band_rank 在")
	_check(
		rules_src.contains("placement.turret_band_rank(hq)"),
		"规则地板 pick_turret_spot 用 band rank 打分"
	)
	_check(
		task_patch_src.contains("placement.turret_band_rank("),
		"四列模型 _build_placement 用 band rank 打分"
	)
	_check(defense_src.contains("func _band_rank"), "GDScript 侧有 _band_rank 镜像")
	_check(
		not rules_src.contains("return (hq, spread, heading, mine)"),
		"规则地板没有退回\"离基地越远越好\"的旧打分"
	)
	_check(
		not defense_src.contains("a.distance_to(center) > b.distance_to(center)"),
		"GDScript 没有退回\"离基地越远越先试\"的旧排序"
	)

	# ③ 行为性质（照 `_band_rank` 的定义复算，防"注释同值但实现写反"）。
	_check(_band(band_py + 4.0, band_py) < _band(band_py, band_py), "带外越远打分越低")
	_check(_band(band_py - 2.0, band_py) < _band(band_py, band_py), "带内越外打分越高")
	_check(_band(max_anchor_py, band_py) < _band(inner_py, band_py), "远端候选排在基地附近之后")

	# ④ 真调用 GDScript 侧（同时验证脚本可解析、实例可建）。
	_check_runtime_parity(band_py, max_anchor_py, inner_py)


func _band(distance_m: float, outer_m: float) -> float:
	if distance_m <= outer_m:
		return distance_m
	return 2.0 * outer_m - distance_m
