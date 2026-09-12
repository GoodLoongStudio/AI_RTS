# -*- coding: utf-8 -*-
"""结构化模型节点：PydanticAI Agent 装配 + 确定性 FakeStructuredModel。

定位（方案 §1、§2、§5、§10-Phase5）：
- PydanticAI 只是 LangGraph 内的“结构化模型节点”，不是第二个总调度器；
- 首期只配置一套 OpenAI 兼容 Provider 与一枚 Key，战略/战术/Hermes 可同模型；
- 凭证只从环境变量读取，不进入日志/配置对象/上下文；
- 本地测试一律走 FakeStructuredModel：无 API Key、无网络、确定性；
- 若环境未安装 pydantic-ai，装配会明确抛 ModelUnavailable 并给出安装命令，
  绝不伪装“已接入真实模型”。
"""

from __future__ import annotations

import json
import os
import threading
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

from ..redaction import redact_mapping
from .contracts import (
    DirectiveBatch, IntentBatch, StrategicPlan, directives_to_intents,
)
from .task_patch import (
    MODE_FAST, MODES, MODE_LIMITS, TaskPatchBatch, effective_max_rows,
    parse_task_patch,
)
from .task_patch_bridge import expand_patch
from .task_patch_prompt import NEW_SYSTEM_PROMPT, build_user_prompt, normalize_json_text

# ---------------- 环境变量（方案 §2） ----------------

ENV_BASE_URL = "LLM_BASE_URL"
ENV_API_KEY = "LLM_API_KEY"
ENV_HERMES_MODEL = "HERMES_MODEL"
ENV_STRATEGY_MODEL = "STRATEGY_MODEL"
ENV_TACTICS_MODEL = "TACTICS_MODEL"
# 分层端点（可选）：战术走本地/低延迟端点时单独配置，留空则回落全局。
ENV_STRATEGY_BASE_URL = "STRATEGY_BASE_URL"
ENV_TACTICS_BASE_URL = "TACTICS_BASE_URL"
ENV_STRATEGY_API_KEY_ENV = "STRATEGY_API_KEY_ENV"
ENV_TACTICS_API_KEY_ENV = "TACTICS_API_KEY_ENV"
ENV_TACTICS_API_KEY = "TACTICS_API_KEY"

ROLE_STRATEGY = "strategy"
ROLE_TACTICS = "tactics"
ROLE_HERMES = "hermes"

INSTALL_HINT = ("请在独立虚拟环境安装：pip install -r "
                "source/adjutant_coordinator/requirements-graph.txt")


class ModelUnavailable(RuntimeError):
    """模型不可用（依赖缺失、凭证缺失、Provider 断线）→ 图降级，不阻塞。"""


class ModelTimeout(RuntimeError):
    """模型超时 → 保留既有计划/意图，降级继续。"""


class ModelInvalidOutput(RuntimeError):
    """模型输出非法（结构/引用不合法）→ 拒绝该输出并记录，不执行。"""


# ---------------- 模型调用调度（方案 §4「异步调度」） ----------------
# 取消客户端等待**不代表**服务端停止推理：超时后 Ollama 往往仍在计算。
# 因此不能用"每次调用新建线程池"来兜底，否则超时轮次会持续堆积推理工作。
# 这里用进程内共享线程池（战略/战术各自最多一个在途，见各 Agent 实例的 `_inflight`）。
# 【2026-09-12】在途标记从"模块级全局"改为"每 Agent 一份"：全局版会让战略调用
# 阻塞战术调用（实测 6 次"上一轮推理仍在进行中"跳过，发生在另一角色推理期间）。
_CALL_POOL: Optional[ThreadPoolExecutor] = None
_CALL_POOL_LOCK = threading.Lock()


def _call_pool() -> ThreadPoolExecutor:
    """惰性创建并复用共享线程池（不再每次调用 new）。"""
    global _CALL_POOL
    with _CALL_POOL_LOCK:
        if _CALL_POOL is None:
            _CALL_POOL = ThreadPoolExecutor(max_workers=2,
                                            thread_name_prefix="adjutant-llm")
        return _CALL_POOL


# ---------------- 配置 ----------------


@dataclass
class GraphModelSettings:
    """一套 Provider 配置；战略/战术/赫尔墨斯可共用同一个模型。

    战术层与战略层**允许使用不同端点**（`*_base_url` / `*_api_key_env`）：
    - 战术要的是"秒级反应"，适合放本地小模型（Ollama 的 OpenAI 兼容端点）；
    - 战略要的是"想得远"，可以继续用云端强模型（分钟级也能接受）。
    两个角色的 base_url 都为空时回落到全局 `base_url`，行为与改造前完全一致。
    实测依据：延迟几乎全部来自模型 reasoning（云端 step-3.7-flash 单轮 18~28s，
    本地 qwen3.5:9b 单轮 6.9s 且 800 字思考全用于 reasoning），
    所以"低延迟"的关键是换**非 reasoning**模型，而不是换机器。
    """

    base_url: str = ""
    api_key_env: str = ENV_API_KEY
    hermes_model: str = ""
    strategy_model: str = ""
    tactics_model: str = ""
    strategy_base_url: str = ""
    tactics_base_url: str = ""
    strategy_api_key_env: str = ""
    tactics_api_key_env: str = ""
    timeout_seconds: float = 8.0
    # 战略层单独超时（<=0 表示沿用 timeout_seconds）。
    # 分层依据：战术要"秒级反应"（本地小模型，10s 硬线），
    # 战略要"想得远"（云端强模型 step-3.7-flash 单轮 14~25s，远超 10s）。
    # 战略是低频调用（30~60s 一次），慢不影响部队——战术层有 rules_fallback 兜底持续指挥。
    strategy_timeout_seconds: float = 0.0
    max_output_tokens: int = 1200

    @classmethod
    def from_env(cls) -> "GraphModelSettings":
        def env(name: str, default: str = "") -> str:
            return os.environ.get(name, default)

        try:
            timeout = float(env("LLM_TIMEOUT_SECONDS", "8.0"))
        except ValueError:
            timeout = 8.0
        try:
            strategy_timeout = float(env("STRATEGY_TIMEOUT_SECONDS", "0") or 0)
        except ValueError:
            strategy_timeout = 0.0
        models = [env(ENV_HERMES_MODEL), env(ENV_STRATEGY_MODEL), env(ENV_TACTICS_MODEL)]
        fallback = next((name for name in models if name), "")
        tactics_model = env(ENV_TACTICS_MODEL) or fallback
        tactics_base_url = env(ENV_TACTICS_BASE_URL)
        tactics_key_env = env(ENV_TACTICS_API_KEY_ENV)
        if tactics_base_url and not tactics_key_env:
            # 本地 Ollama 不校验密钥，但 OpenAI 兼容客户端要求非空，用占位符兜底。
            tactics_key_env = ENV_TACTICS_API_KEY
        return cls(
            base_url=env(ENV_BASE_URL),
            hermes_model=env(ENV_HERMES_MODEL) or fallback,
            strategy_model=env(ENV_STRATEGY_MODEL) or fallback,
            tactics_model=tactics_model,
            strategy_base_url=env(ENV_STRATEGY_BASE_URL),
            tactics_base_url=tactics_base_url,
            strategy_api_key_env=env(ENV_STRATEGY_API_KEY_ENV),
            tactics_api_key_env=tactics_key_env,
            timeout_seconds=timeout,
            strategy_timeout_seconds=strategy_timeout,
        )

    def timeout_for(self, role: str) -> float:
        """按角色返回超时秒数。

        战术层必须卡在 10 秒硬线内（本地小模型，实测 0.3~2.4s）；
        战略层用云端强模型规划，单轮 14~25s，低频调用，允许更久。
        """
        if role == ROLE_STRATEGY and self.strategy_timeout_seconds > 0:
            return self.strategy_timeout_seconds
        return self.timeout_seconds

    def base_url_for(self, role: str) -> str:
        """该角色应使用的端点（未单独配置时回落到全局）。"""
        if role == ROLE_STRATEGY:
            return self.strategy_base_url or self.base_url
        if role == ROLE_TACTICS:
            return self.tactics_base_url or self.base_url
        return self.base_url

    def api_key_env_for(self, role: str) -> str:
        if role == ROLE_STRATEGY:
            return self.strategy_api_key_env or self.api_key_env
        if role == ROLE_TACTICS:
            return self.tactics_api_key_env or self.api_key_env
        return self.api_key_env

    def resolve_api_key_for(self, role: str) -> str:
        name = self.api_key_env_for(role)
        if not name:
            return ""
        value = os.environ.get(name, "")
        if not value and name == ENV_TACTICS_API_KEY:
            # 本地端点不接受鉴权，给一个非空占位符即可（不落日志）。
            return "local-no-auth"
        return value

    def resolve_api_key(self) -> str:
        """调用期从环境变量解析凭证；返回值不得写入日志或文件。"""
        if not self.api_key_env:
            return ""
        return os.environ.get(self.api_key_env, "")

    def model_for(self, role: str) -> str:
        if role == ROLE_STRATEGY:
            return self.strategy_model or self.hermes_model
        if role == ROLE_TACTICS:
            return self.tactics_model or self.hermes_model
        return self.hermes_model or self.strategy_model or self.tactics_model

    def safe_dict(self) -> Dict[str, Any]:
        return redact_mapping({
            "base_url": self.base_url,
            "api_key": self.resolve_api_key(),
            "api_key_env": self.api_key_env,
            "hermes_model": self.hermes_model,
            "strategy_model": self.strategy_model,
            "tactics_model": self.tactics_model,
            "timeout_seconds": self.timeout_seconds,
        })


def pydantic_ai_available() -> Dict[str, Any]:
    """依赖可用性探测（诚实报告版本与失败原因）。"""
    try:
        import pydantic_ai  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        return {"available": False, "version": "", "reason": str(exc), "hint": INSTALL_HINT}
    return {"available": True, "version": str(getattr(pydantic_ai, "__version__", "")),
            "reason": "", "hint": ""}


# ---------------- 确定性假模型（无 API Key） ----------------

FAKE_BEHAVIORS = ("completed", "empty", "malformed", "timeout", "error", "raise", "late")


class FakeStructuredModel:
    """确定性结构化模型：按脚本产出计划/意图或结构化失败。

    脚本条目（按序消费；耗尽后返回 None=空响应）：
    - completed : 返回 plan / intents 载荷（原始 dict，由节点层做契约校验）
    - empty     : 返回 None（空响应，非致命）
    - malformed : 返回非法结构（触发契约校验拒绝路径）
    - timeout   : 抛 ModelTimeout（节点降级，保留既有计划/意图）
    - error     : 抛 ModelUnavailable（Provider 断线/凭证缺失）
    - raise     : 抛 RuntimeError（未知异常路径）
    - late      : 返回载荷但把 expires_tick 压到当前 tick 之前（迟到的过期输出）
    """

    def __init__(self, role: str, script: Optional[List[Dict[str, Any]]] = None) -> None:
        self.role = role
        self._script = list(script or [])
        self.calls: List[Dict[str, Any]] = []

    @property
    def call_count(self) -> int:
        return len(self.calls)

    def propose_plan(self, context: Dict[str, Any]) -> Any:
        return self._invoke(context)

    def propose_intents(self, context: Dict[str, Any]) -> Any:
        # 注意：FakeStructuredModel 是**直接**作为 tactics_model 交给图节点的
        # （不经 PydanticAI 校验），节点用 parse_intent_batch 解析，
        # 所以这里必须保持 IntentBatch 形状，做转换反而会让节点拿不到意图。
        return self._invoke(context)

    def _invoke(self, context: Dict[str, Any]) -> Any:
        self.calls.append(dict(context))
        if not self._script:
            return None
        step = self._script.pop(0)
        behavior = str(step.get("behavior", "completed"))
        if behavior == "completed":
            return step.get("plan") if self.role == ROLE_STRATEGY else step.get("intents")
        if behavior == "empty":
            return None
        if behavior == "malformed":
            return step.get("payload", {"not": "a valid structured payload"})
        if behavior == "timeout":
            raise ModelTimeout(str(step.get("reason", "scripted model timeout")))
        if behavior == "error":
            raise ModelUnavailable(str(step.get("reason", "scripted provider unavailable")))
        if behavior == "raise":
            raise RuntimeError(str(step.get("reason", "scripted model exception")))
        if behavior == "late":
            payload = step.get("plan") if self.role == ROLE_STRATEGY else step.get("intents")
            return _force_expired(payload, int(context.get("server_tick", 0)))
        raise ModelUnavailable("unknown fake behavior %r" % behavior)


def _force_expired(payload: Any, tick: int) -> Any:
    """把载荷里的过期时间压到当前 tick 之前（模拟迟到输出；不伪造新语义）。"""
    import copy

    if not isinstance(payload, dict):
        return payload
    data = copy.deepcopy(payload)
    for key in ("valid_until_tick",):
        if key in data:
            data[key] = max(0, tick - 1)
    for intent in data.get("intents", []) or []:
        if isinstance(intent, dict):
            intent["expires_tick"] = max(1, tick - 1)
    return data


# ---------------- PydanticAI 真实节点 ----------------

STRATEGY_SYSTEM_PROMPT = (
    "你是 RTS 游戏中的 AI 副官战略规划节点。只输出结构化 StrategicPlan："
    "阶段目标、任务集合（稳定 task_id、优先级、完成条件、涉及单位）、资源预留。"
    "禁止输出单位命令，禁止引用上下文以外的实体或场景，禁止编造规则或数值。"
    "字段取值纪律：match_id/player_id/rules_version 必须与上下文一致；"
    "plan_version 必须是比上下文 plan_version 更大的正整数（首次给 1）；"
    "based_on_snapshot 不得超过上下文 snapshot_id；valid_until_tick 必须大于 server_tick；"
    "tasks[].units 只能取自上下文 ai_controlled_units；tasks[].allowed_actions 只能取 "
    "move/attack/attack_move/defend/retreat/scout/hold/regroup/gather/stop/produce/build 的子集；"
    "每个 task 必填 task_id/priority/completion/units/allowed_actions。"
    "tasks 不得为空。"
    "任务集合必须同时覆盖四类目标，不要只做侦察："
    "① 经济发展（worker 采集资源、指挥中心造工人）；"
    "② 军事生产（造战斗单位）；"
    "③ 侦察（少量机动单位）；"
    "④ 防守（保护基地与工人）。"
    "经济发展类任务优先级最高：经济不增长的一方必然输掉对局。"
)

TACTICS_SYSTEM_PROMPT = (
    "你是 RTS 游戏中的 AI 副官战术节点。只输出极简 DirectiveBatch，"
    "字段名与取值必须严格照下面示例。"
    "输出纪律："
    "0) 顶层只给 directives 数组；每个元素只给 action、units，"
    "必要时给 target_id（敌人/资源点 id）、target_pos（[x,z] 数字坐标）、"
    "producer（生产建筑名）、scene（建造物 id）、task_id。"
    "**严禁输出 intent_id / plan_version / snapshot / tick / expires_tick / generation "
    "等元数据，系统会按请求上下文自动补齐。**"
    "示例（字段名必须完全一致）："
    "{\"directives\": [{\"action\": \"gather\", \"units\": [\"Unit_3\"], "
    "\"target_id\": \"ResourceA\"}]}"
    "；{\"directives\": [{\"action\": \"move\", \"units\": [\"Unit_1\"], "
    "\"target_pos\": [30.0, 30.0]}]}"
    "；{\"directives\": [{\"action\": \"produce\", \"units\": [\"Unit_0\"], "
    "\"producer\": \"Unit_0\", \"scene\": \"worker\"}]}"
    "；没有可执行动作时给 {\"directives\": []}，不要编造单位或坐标。"
    "1) action 只能取 move/attack/attack_move/defend/retreat/scout/hold/regroup/"
    "gather/stop/produce/build；"
    "2) units 只能取自 own_units[].name（玩家接管的单位一律不要出现）；"
    "3) produce 必须从 production_options 里**整条**选：producer 与 product 必须来自同一项，"
    "写成 {\"action\":\"produce\",\"units\":[producer],\"producer\":producer,\"scene\":product}；"
    "build 必须从 build_options 里整条选，写成 {\"action\":\"build\",\"units\":[builder],"
    "\"producer\":builder,\"scene\":building}。"
    "**绝对不允许你自己拼装 producer 与 scene（实测会填反）**；"
    "4) gather 的 target_id 只能取自 visible_resources[].entity_id；"
    "attack 的 target_id 只能取自 visible_enemy_ids；"
    "移动类动作给 target_pos（[x,z] 数字坐标）；"
    "5) 能力匹配：采集只能用 can_gather=true 的单位，建造只能用 can_build=true 的，"
    "生产只能用 can_produce=true 的（通常只有 command_center），移动用 can_move=true 的；"
    "6) 运作纪律：① 经济优先——只要还有空闲 worker 就必须让它 gather；"
    "② 有闲钱时从 production_options 里挑一项补工人或战斗单位；"
    "③ 侦察最多占用 1 个机动单位，其余单位不得空转闲置；"
    "④ **同一个单位在同一批里只能出现一次**，不得既 attack 又 move（实测会自相矛盾）；"
    "7) 威胁处置（实测缺这条会拿单个单位硬冲三个敌人）："
    "① 若 visible_enemy_ids 的数量**多于**我方作战单位数量，作战单位一律"
    "retreat 或 move 撤离（朝自己主基地方向给 target_pos），不要 attack；"
    "② 否则作战单位 attack 最近的可见敌人（target_id 取 visible_enemy_ids）；"
    "③ 采集中的 worker 不必回防，交战的活优先给作战单位；"
    "8) 不得空转：没有 worker 可派时，把空闲的机动单位至少派 1 个去 scout，"
    "给它 target_pos=[x,z]（朝地图上尚未探索的方向）；"
    "9) 输出极简：directives 最多 3 条，不要解释、不要复述上下文。"
)


def build_openai_model(settings: GraphModelSettings, role: str):
    """构造 OpenAI 兼容模型对象（PydanticAI 版本差异在此收敛）。

    未识别的版本 API 会明确抛 ModelUnavailable，不做静默降级伪装。
    """
    availability = pydantic_ai_available()
    if not availability["available"]:
        raise ModelUnavailable("pydantic-ai 不可用：%s。%s" % (availability["reason"],
                                                           INSTALL_HINT))
    api_key = settings.resolve_api_key_for(role)
    if not api_key:
        raise ModelUnavailable("缺少 API Key（环境变量 %s）；真实模型未接入。"
                               % settings.api_key_env_for(role))
    model_name = settings.model_for(role)
    if not model_name:
        raise ModelUnavailable("缺少模型名（%s / %s / %s 均未配置）。" % (
            ENV_HERMES_MODEL, ENV_STRATEGY_MODEL, ENV_TACTICS_MODEL))
    try:
        from pydantic_ai.models.openai import OpenAIChatModel
        from pydantic_ai.providers.openai import OpenAIProvider
    except Exception as exc:  # noqa: BLE001 —— 版本 API 不识别：明确报错。
        raise ModelUnavailable("PydanticAI OpenAI 适配不可用（%s）；%s" % (exc, INSTALL_HINT))
    # 端点按角色取：战术可指向本地低延迟端点，战略继续用云端。
    base_url = settings.base_url_for(role) or ""
    provider = OpenAIProvider(base_url=base_url or None, api_key=api_key,
                              http_client=_http_client_for(base_url))
    return OpenAIChatModel(model_name, provider=provider)


def _http_client_for(base_url: str):
    """本机端点必须**绕开系统代理**（实测踩坑，2026-09-12）。

    症状：runner 的模型调用 ~11s 后返回 `status_code: 502` 且响应体为空，
    Ollama 服务端日志里**完全没有**这两次请求（从未到过 Ollama）。

    机制：Windows 注册表里配了系统代理（`ProxyEnable=1 / ProxyServer=127.0.0.1:7897`，
    Clash 之类）。`urllib`（A/B 工具用）会按注册表的 bypass 列表放过 localhost，
    但 `httpx`（PydanticAI 的 OpenAI 客户端用）**不处理** Windows 的 bypass 列表，
    于是 `http://127.0.0.1:11434` 的请求被送去代理 → 502 空响应。
    复现：`HTTP_PROXY=http://127.0.0.1:7897` 访问本机 Ollama → 502 空体。

    只对**本机端点**关闭 `trust_env`：云端端点仍需遵循代理设置（企业网络/加速）。
    """
    if not _is_local_endpoint(base_url):
        return None
    try:
        import httpx
    except Exception:  # noqa: BLE001 —— 没有 httpx 时退回默认（由 PydanticAI 自行处理）
        return None
    return httpx.AsyncClient(trust_env=False)


def _is_local_endpoint(url: Any) -> bool:
    """端点是否指向本机（Ollama 等本地推理服务）。

    用途：决定要不要下发 `openai_reasoning_effort=none`。该参数只对本地/自托管端点
    安全（Ollama 把 `reasoning_effort` 映射到 `think`），云端 reasoning 模型
    （step-3.7-flash）收到它会异常（实测 strategy 报 `ModelInvalidOutput`）。
    """
    try:
        host = (urlparse(str(url or "")).hostname or "").lower()
    except Exception:  # noqa: BLE001 —— 端点串异常时按"非本地"处理更保守
        return False
    return host in ("127.0.0.1", "localhost", "::1", "0.0.0.0", "[::1]")


class _PydanticAgentBase:
    """PydanticAI Agent 的共同装配与运行（超时保护 + 结构化错误归一化）。"""

    system_prompt = ""
    #: True = 用 `PromptedOutput` 做声明式结构校验（旧 DirectiveBatch 路径）；
    #: False = 纯文本输出，结构由程序自己解析（四列接口，见 PydanticAITaskPatchAgent）。
    structured_output = True

    def __init__(self, role: str, settings: GraphModelSettings,
                 model: Any = None) -> None:
        self.role = role
        self.settings = settings
        self.calls: List[Dict[str, Any]] = []
        try:
            from pydantic_ai import Agent, PromptedOutput
        except Exception as exc:  # noqa: BLE001
            raise ModelUnavailable("pydantic-ai 不可用：%s。%s" % (exc, INSTALL_HINT))
        resolved = model if model is not None else build_openai_model(settings, role)
        # output_type 用契约模型：非法结构直接由 PydanticAI 校验拦下。
        # retries=2：真实模型首次结构化输出常有小瑕疵，允许模型按校验反馈自纠一次以上。
        #
        # 【关键】model_settings 里必须关掉思考：
        # reasoning 模型默认把 token 全花在内部推理上（实测本地 qwen3.5:9b 基线
        # 3.78s/正文为空/思考 1015 字），关掉后同一请求 0.52s 且直接产出合法 IntentBatch。
        # 走的是 Ollama 官方 OpenAI 兼容参数，不需要任何协议转换代理。
        # model_settings 必须**按角色**区分，且不要硬设 max_tokens：
        # - 关思考只对本地小模型有意义；云端 reasoning 模型（step-3.7-flash）收到
        #   openai_reasoning_effort=none 会异常（实测 strategy 报 ModelInvalidOutput）。
        # - 统一设 max_tokens=1200 会把较长的 StrategicPlan 截断，同样表现为
        #   strategy_model_ModelInvalidOutput。因此只给战术层加关思考，其余交给 Provider 默认。
        model_settings: Dict[str, Any] = {}
        # 本地完整副官（方案 §3「本地模型接入」）的初始参数：
        # 输出上限 512 token、温度 0、单次决策总期限 4 秒（自动纠错含在同一期限内）。
        # 这些是**实施起点与验收目标**，不是已测得的性能保证，可按证据调整。
        # 【关键·已实测修正】输出预算必须**按角色**给，不能一刀切 512。
        # 实测（2026-09-11）：战术层 512 够用（DirectiveBatch 很小），
        # 但战略层的 `StrategyPlan` 是嵌套结构（tasks[] 每项含
        # task_id/priority/completion/units/unit_constraint/target_type/allowed_actions…），
        # 512 token 会把 JSON **截断** → PydanticAI 解析失败 →
        # `ModelInvalidOutput: Exceeded maximum output retries (2)`，
        # 而且每次要烧 20s（含 2 次重试）。这是"战略层永远失败"的真凶之一。
        model_settings["max_tokens"] = self._max_tokens()
        model_settings["temperature"] = 0
        model_settings["timeout"] = max(1.0, float(settings.timeout_for(role)))
        # 【关键·已实测修正】只要端点在**本机**就必须关思考，不能按模型名判断。
        # 曾经的写法是 `if "qwen" in model`（认为 MiniCPM5 是非 reasoning 模型、传该参数
        # 会被拒）。实测**恰好相反**：`maternion/minicpm5:2b` 是推理模型，
        # /v1 响应里正文落在 `message.reasoning`、`message.content` 为空、
        # `finish_reason=length`（512 token 预算全被思考吃掉）→ PydanticAI 解析不到内容
        # → 触发 retries=2 → 最终表现为 `ModelTimeout`（4.01s），看起来像"模型慢"。
        # 实测同一请求加 `reasoning_effort:"none"`（/v1 上有效）：
        #   reasoning 0 字节、content 正常、0.06s。
        # 云端端点（step-3.7-flash）必须**不下发**该参数，否则 ModelInvalidOutput。
        if _is_local_endpoint(settings.base_url_for(role)):
            model_settings["openai_reasoning_effort"] = "none"
        # 【关键】必须用 PromptedOutput，不能用默认的 tool calling：
        # 实测本地 qwen3:4b 在**带 tools** 时单次推理要 300s（不带 tools 只要 3.2s），
        # 因为小模型对 tool calling 的支持很差。PromptedOutput 改为"提示词约束 +
        # 文本 JSON 解析"，把结构化输出从 tools 通道挪到普通文本通道，
        # 这是满足 10 秒硬线的前提。
        if self.structured_output:
            self._agent = Agent(resolved, output_type=PromptedOutput(self.output_type),
                                system_prompt=self.system_prompt, retries=2,
                                model_settings=model_settings or None)
        else:
            # 纯文本输出（四列接口用）：模型只需按系统提示给出 JSON 文本，
            # 结构由程序 `parse_task_patch` + 逐行 `decode_task_patch` 约束。
            # 为什么不用 PromptedOutput：实测（2026-09-12）本机 2B 在带 schema 指令时
            # 稳定回**合法但空的批次** `{"u":[]}`（每轮 0 任务、游戏毫无变化），
            # 换成纯文本后同一提示词稳定给出真实任务。
            self._agent = Agent(resolved, system_prompt=self.system_prompt, retries=0,
                                model_settings=model_settings or None)
        self.last_validation_hint = ""
        # 最近一次失败的技术细节（供诊断；不含凭证）。
        self.last_error_detail = ""
        # 最近一次模型原始文本（供诊断"围栏/截断"这类结构问题；不含凭证）。
        self.last_raw_text = ""
        # 每个 Agent 一份在途标记（原来全局一份，会让战略阻塞战术）。
        self._inflight = threading.Event()

    def _max_tokens(self) -> int:
        """按角色的输出预算；子类可覆盖（四列接口按模式给 96/256）。"""
        return 512 if self.role != ROLE_STRATEGY else 1280

    def _run(self, context: Dict[str, Any]) -> Any:
        return self._run_text(json.dumps(context, ensure_ascii=False, sort_keys=True),
                              record=dict(context))

    def _run_text(self, prompt: str, record: Optional[Dict[str, Any]] = None) -> Any:
        """与 `_run` 相同的调度/超时/归一化路径，但直接使用给定提示文本。

        四列接口的输入是**紧凑文本表**（不是 JSON 上下文），所以不能复用
        `_run` 的 `json.dumps(context)`；其余（共享线程池、单一在途、超时后不 cancel、
        PromptedOutput 结构化校验）完全一致。
        """
        from pydantic_ai.exceptions import UnexpectedModelBehavior

        self.calls.append(dict(record or {}))
        captured: List[Any] = []

        def _call() -> Any:
            try:
                from pydantic_ai import capture_run_messages
            except Exception:  # noqa: BLE001 —— 老版本没有该 API 时退化为直接调用
                return self._agent.run_sync(prompt)
            with capture_run_messages() as messages:
                try:
                    return self._agent.run_sync(prompt)
                finally:
                    captured.extend(list(messages))

        # 注意：不能用 `with ThreadPoolExecutor(...)`。
        # 上下文退出会执行 shutdown(wait=True)，在 future.result 已超时的情况下
        # 仍会继续死等那个推理线程 —— 实测 30s 超时实际阻塞到 85s，
        # 直接把 runner 主循环（观测/回执/玩家事件）一起拖住。
        # 这里改为超时即返回，并用 shutdown(wait=False) 让迟到线程自己跑完。
        # 【方案 §4】不得依赖"不断创建线程"解决阻塞：
        # 取消客户端等待**不代表 Ollama 停止推理**（超时后它仍在算）。
        # 若每次调用都新建线程池，超时轮次会持续堆积推理工作。因此：
        #   ① 使用**类级共享**线程池（不再每次 new）；
        #   ② 用**本 Agent 的**在途标记保证"同一时刻至多一个在途请求"，
        #      只有请求**真正结束**（含超时后迟到完成）才清除，
        #      从而避免"上一轮还在算、这一轮又发一条"的堆积。
        #
        # 【2026-09-12 修正】该标记原先是**模块级全局**的，于是战略模型的调用会阻塞
        # 战术模型（反过来也一样）—— 实测 runner 里出现 6 次
        # "上一轮推理仍在进行中…本轮跳过"，而这些跳过发生在**另一个角色**正在推理时。
        # 计划 §2 要求"一个模型决策入口"，但战略/战术是两次独立调用、各自有自己的端点与
        # 预算，必须各自守住自己的在途纪律（战术侧另由 `async_scheduler` 保证单一在途）。
        if self._inflight.is_set():
            raise ModelTimeout(
                "上一轮推理仍在进行中（超时后服务端可能仍在计算），本轮跳过以避免堆积。")
        self._inflight.set()
        future = _call_pool().submit(_call)
        # 迟到线程跑完（或异常结束）时才释放在途标记。
        future.add_done_callback(lambda _f: self._inflight.clear())
        call_timeout = self.settings.timeout_for(self.role)
        try:
            result = future.result(timeout=call_timeout)
        except FuturesTimeout as exc:
            # 不 cancel：让它在后台自然结束并清标记；这里只放弃本次等待。
            raise ModelTimeout("模型调用超时（%.1fs）" % call_timeout) from exc
        except UnexpectedModelBehavior as exc:
            hint = _validation_hint(captured)
            self.last_validation_hint = hint
            raise ModelInvalidOutput("模型输出不合法：%s%s" % (exc, hint)) from exc
        except Exception as exc:  # noqa: BLE001 —— 网络/Provider 异常统一归一化。
            # 在途标记由 future 的 done_callback 统一释放，此处不再手动清，
            # 避免"线程还在跑但标记已清"导致下一轮重复提交。
            import traceback as _tb
            self.last_error_detail = ("%s: %s\n%s"
                                      % (type(exc).__name__, exc,
                                         _tb.format_exc()[-1200:]))
            raise ModelUnavailable("模型调用失败：%s" % exc) from exc
        finally:
            # 不 shutdown 共享池：迟到线程仍需完成并自行清标记。
            pass
        self.last_raw_text = _last_assistant_text(captured)
        return getattr(result, "output", result)


def _validation_hint(messages: List[Any]) -> str:
    """从 PydanticAI 运行消息里提取最近一次校验反馈（用于诊断，不含隐藏推理）。"""
    hints: List[str] = []
    for message in messages or []:
        for part in getattr(message, "parts", []) or []:
            content = getattr(part, "content", None)
            if content is None:
                continue
            if isinstance(content, (list, tuple)):
                text = " ".join(str(item) for item in content)
            else:
                text = str(content)
            lowered = text.lower()
            if "validation" in lowered or "error" in lowered or "field required" in lowered:
                hints.append(text[:400])
    if not hints:
        return ""
    return "；最近一次校验反馈：" + " | ".join(hints[-2:])


class PydanticAIStrategyAgent(_PydanticAgentBase):
    """战略节点：输出 StrategicPlan。"""

    system_prompt = STRATEGY_SYSTEM_PROMPT
    output_type = StrategicPlan

    def __init__(self, settings: GraphModelSettings, model: Any = None) -> None:
        super().__init__(ROLE_STRATEGY, settings, model)

    def propose_plan(self, context: Dict[str, Any]) -> Optional[StrategicPlan]:
        return self._run(context)


class PydanticAITacticsAgent(_PydanticAgentBase):
    """战术节点：模型只输出极简 DirectiveBatch，元数据由程序补齐成 IntentBatch。

    这样模型每次只要回"谁做什么、目标是谁/在哪"，输出量大幅下降
    （实测 IntentBatch 需回填大量元数据字段，输出 744 token，本地解码 20 秒）。
    """

    system_prompt = TACTICS_SYSTEM_PROMPT
    output_type = DirectiveBatch

    def __init__(self, settings: GraphModelSettings, model: Any = None) -> None:
        super().__init__(ROLE_TACTICS, settings, model)

    def propose_intents(self, context: Dict[str, Any]) -> Optional[IntentBatch]:
        batch = self._run(context)
        if batch is None:
            return None
        data = context or {}
        return directives_to_intents(
            batch,
            plan_version=str(data.get("plan_version", "")),
            snapshot_id=int(data.get("snapshot_id", 0) or 0),
            server_tick=int(data.get("server_tick", 0) or 0),
            intent_ttl_ticks=int(data.get("intent_ttl_ticks", 3600) or 3600),
        )


def _last_assistant_text(messages: List[Any]) -> str:
    """从运行消息里取最近一条"像 JSON 的"文本（诊断围栏/截断用）。"""
    best = ""
    for message in messages or []:
        for part in getattr(message, "parts", []) or []:
            content = getattr(part, "content", None)
            if isinstance(content, (list, tuple)):
                text = " ".join(str(item) for item in content)
            elif content is not None:
                text = str(content)
            else:
                continue
            if "{" in text and "}" in text or text.strip().startswith("```"):
                best = text
    return best[:2000]


class PydanticAITaskPatchAgent(_PydanticAgentBase):
    """四列任务修改 Agent：**实时链路唯一的决策入口**（设计 §2、§3）。

    - 输出契约是 `TaskPatchBatch`（字符串二维数组、每行 4 项），结构由 PydanticAI 约束，
      语义（能力/目标/参数相容）由 `decode_task_patch` 逐行判定；
    - 输入是 `render_compact_text` 渲染的紧凑文本表 + 常量系统提示（可前缀缓存）；
    - 输出上限按模式给（fast 96 / deep 256 token），对应计划的输出预算；
    - `propose_task_patch(frame)` 返回已展开的 `IntentBatch`（元数据取自 frame），
      `last_decode` 保留逐行接受/拒绝，供逐项回执与验收留痕。
    """

    system_prompt = NEW_SYSTEM_PROMPT
    # 【2026-09-12 真机定位，别再改回声明式输出】
    # 用 `output_type=TaskPatchBatch`（PromptedOutput）时，PydanticAI 会额外插入一段
    # "按这个 schema 输出"的指令（请求里能看到 3 条消息），而这个 2B 模型对那段指令的反应是
    # **回一个合法但空的批次** `{"u":[]}`：副官于是每轮派 0 个任务，游戏里毫无变化，
    # 而日志里只看到 `rows=0 accepted=0`（配合 decode=None 的误导，卡了数小时）。
    # 同一份提示词**不发**那段指令时，模型稳定给出真实任务
    # （`{"u":[["W1","GAT","R5","P0"],["F1","PROD","U5","P0"]]}`）。
    # 计划要求的是"结构由程序约束、语义逐项判定"——而逐行校验与拒绝本就在
    # `parse_task_patch` + `decode_task_patch` 里（有 20 个单测覆盖），不依赖声明式输出。
    output_type = str
    structured_output = False

    def __init__(self, settings: GraphModelSettings, model: Any = None,
                 mode: str = MODE_FAST) -> None:
        # mode 必须在 super().__init__ 之前设置（_max_tokens 在构造期被调用）。
        self.mode = mode if mode in MODES else MODE_FAST
        super().__init__(ROLE_TACTICS, settings, model)
        self.last_decode = None

    def _max_tokens(self) -> int:
        return int(MODE_LIMITS[self.mode]["output_budget"])

    def propose_task_patch(self, frame: Any) -> Optional[IntentBatch]:
        user = build_user_prompt(frame, max_rows=effective_max_rows(frame))
        text = self._run_text(user, record={
            "interface": "task_patch", "mode": self.mode,
            "server_tick": int(getattr(frame, "server_tick", 0) or 0),
            "actors": len(getattr(frame, "actors", {}) or {}),
        })
        if text is None:
            self.last_decode = None
            return None
        # 文本 → 契约：剥围栏/取最外层 JSON，再做结构校验（逐行问题留给解码器）。
        # 注意：纯文本输出模式下 `run_sync` 的返回值不保证是 `str`（可能是 SDK 的响应对象），
        # 因此这里做一次宽松取文本，取不到就退回 `last_raw_text`（`capture_run_messages` 抓到的原文）。
        raw = text if isinstance(text, str) else ""
        if not raw.strip():
            raw = str(getattr(text, "content", "") or "") or str(self.last_raw_text or "")
        try:
            # 文本 → JSON 对象 → 契约（`parse_task_patch` 接受 dict，不接受裸字符串）
            payload = json.loads(normalize_json_text(raw))
        except ValueError as exc:
            self.last_validation_hint = "raw=%s" % raw[:160]
            raise ModelInvalidOutput("四列输出不是合法 JSON：%s" % exc) from exc
        batch = parse_task_patch(payload)
        intent_batch, decode = expand_patch(batch, frame)
        self.last_decode = decode
        return intent_batch


def build_agents(settings: Optional[GraphModelSettings] = None,
                 model: Any = None) -> Dict[str, Any]:
    """装配战略/战术 Agent；失败时返回结构化错误（不抛裸异常给宿主）。"""
    settings = settings or GraphModelSettings.from_env()
    availability = pydantic_ai_available()
    if not availability["available"]:
        return {"available": False, "reason": availability["reason"], "hint": INSTALL_HINT,
                "strategy": None, "tactics": None}
    try:
        return {
            "available": True, "reason": "", "hint": "",
            "strategy": PydanticAIStrategyAgent(settings, model=model),
            "tactics": PydanticAITacticsAgent(settings, model=model),
            # 四列接口：目标形态（阶段 A-2 起为默认决策入口）。
            "task_patch": PydanticAITaskPatchAgent(settings, model=model),
            "settings": settings.safe_dict(),
        }
    except ModelUnavailable as exc:
        return {"available": False, "reason": str(exc), "hint": INSTALL_HINT,
                "strategy": None, "tactics": None}


def fake_models(strategy_script: Optional[List[Dict[str, Any]]] = None,
                tactics_script: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
    """便捷构造一对确定性假模型（测试/回放用）。"""
    return {
        "strategy": FakeStructuredModel(ROLE_STRATEGY, strategy_script),
        "tactics": FakeStructuredModel(ROLE_TACTICS, tactics_script),
    }
