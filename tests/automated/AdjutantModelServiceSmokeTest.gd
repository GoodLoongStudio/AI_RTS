extends Node

## 本地模型服务自动保障的纯逻辑回归（`AdjutantModelService`）。
##
## 为什么值得一个冒烟（2026-09-23 用户实测定性）：副官的战略层要连本地 Ollama，
## 而"把服务拉起来"原来只写在 `build/启动AI_RTS.bat` 里 —— 不走 .bat 启动游戏
## （编辑器/DEBUG、直接双击 exe）就必然每轮 `Connection error`，面板显示
## "战略思考这一轮没成功，先用规则顶住"。用户要求"游戏启动自动满足所有条件"。
##
## 这里只测**不拉起真服务**的部分（拉起 + 预热要 ~70s、占 2.6GB 显存，不适合回归）；
## 真链路另有手工验证记录在 `docs/程序文档/AI副官_实战修复_第10轮报告_2026-09-23.md`。

const ModelService := preload("res://source/ui/AdjutantModelService.gd")

##: 全部状态的文案都必须非空（空状态除外）——玩家不能看到一句没信息的话。
const STATES := ["starting", "warming", "ready", "timeout", "missing", "failed"]

var _failures := 0


func _ready() -> void:
	# ---- 端口口径：与 build/启动AI_RTS.bat 的 MODEL_PORT 同值 ----
	_check(ModelService.PORT == 11436,
		"模型服务端口必须是专用口 11436（不打扰机器上可能装了的 Ollama 默认 11434）")
	_check(ModelService.endpoint() == "http://127.0.0.1:11436/v1",
		"端点必须由端口唯一推导：%s" % ModelService.endpoint())

	# ---- runner 引导注入：三个端点键都要、且都指向上面那个端点 ----
	var lines := ModelService.bootstrap_env_lines()
	for key in ["LLM_BASE_URL", "TACTICS_BASE_URL", "STRATEGY_BASE_URL"]:
		_check(lines.contains("os.environ[\"%s\"] = \"%s\"" % [key, ModelService.endpoint()]),
			"引导文件必须把 %s 钉成 %s（实际：%s）" % [key, ModelService.endpoint(), lines])
	_check(lines.count("os.environ[") == 3, "只该注入三个端点键，避免夹带别的环境变量")

	# ---- 模型名：读得到 .env.local 就不能为空 ----
	var model := ModelService.model_name()
	_check(not model.is_empty(), "模型名不能为空（预热请求要用）")

	# ---- 运行时定位：两种布局都要能解析（评测机只有分发布局）----
	var runtime := ModelService.resolve_runtime()
	if runtime.is_empty():
		print("[guard-model] 本机无模型运行时（ollama.exe / models 不在）——跳过存在性断言")
	else:
		_check(FileAccess.file_exists(str(runtime["ollama"])),
			"解析出的 ollama.exe 必须真实存在：%s" % str(runtime["ollama"]))
		_check(DirAccess.dir_exists_absolute(str(runtime["models"])),
			"解析出的 models 目录必须真实存在：%s" % str(runtime["models"]))

	# ---- 端口探测：关着的端口必须判 false（不能恒真，否则永远认为服务在跑）----
	_check(not ModelService.is_listening(11999),
		"一个没人监听的端口必须探测为 false")
	var listening := ModelService.is_listening(ModelService.PORT)
	print("[guard-model] 模型服务当前监听状态：%s" % ("在听" if listening else "没在听"))

	# ---- 状态机文案：每个状态都要有一句玩家能看懂的话 ----
	for state in STATES:
		_check(not ModelService.status_text_for(state).is_empty(),
			"状态 %s 必须有一句中文文案" % state)
	_check(ModelService.status_text_for("").is_empty(),
		"空状态不该打扰玩家（服务本来就好着）")

	# ---- 预热期必须屏蔽 runner 那句"战略思考这一轮没成功" ----
	# 玩家看到后者只会以为副官坏了，实际只是冷模型还没载入（首次 ~70s）。
	for state in ["starting", "warming"]:
		_check(ModelService.status_text_for(state).contains("预热")
			or ModelService.status_text_for(state).contains("启动中"),
			"预热中的文案必须让玩家知道在等什么：%s" % state)
	_check(ModelService.status_text_for("ready") == "本地模型已就绪",
		"就绪文案要明确")

	# ---- 未进场景树的调用方：必须显式失败，不许静默 ----
	var detached := Node.new()  # 故意不加进树
	ModelService.ensure_started(detached)
	_check(ModelService.state() == "failed",
		"调用方节点没进场景树时必须记 failed（不能静默不干活）")
	_check(ModelService.status_text().contains("场景树"),
		"失败原因要说清楚是场景树：%s" % ModelService.status_text())

	print("Adjutant model service smoke test completed: %d failure(s)" % _failures)
	SmokeTestExit.request(get_tree(), 0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("Adjutant model service assertion failed: %s" % message)
