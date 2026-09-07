# -*- coding: utf-8 -*-
"""真实 Provider HTTP 适配层（第三阶段）。

把 ModelCallContext 归一化为 API 请求，把 API 响应归一化为 ModelOutcome：
超时/取消/HTTP 错误/空响应/非法 JSON/未知响应形态全部结构化，不炸协调器。

安全纪律：
- API 凭证只经 ProviderSettings.resolve_api_key()（环境变量）在调用期读取；
- 请求头/配置/响应摘要落日志前必须经 redaction 模块脱敏；
- http_client 为注入点（测试=脚本假客户端；真实装配=UrllibHttpClient 或服务端网关）。
  本模块自身不发任何真实网络请求。
"""

from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Protocol

from .provider import (
    ModelCallContext, ModelOutcome, OUTCOME_CANCELLED, OUTCOME_COMPLETED,
    OUTCOME_ERROR, OUTCOME_REJECTED, OUTCOME_TIMEOUT, ROLE_STRATEGY,
)
from .redaction import collect_nonempty_secrets, redact_headers, redact_text

# 响应体落日志的最大长度（截断防事件风暴）。
MAX_BODY_LOG = 200


@dataclass
class HttpResponse:
    """注入客户端的统一返回；status_code 为 HTTP 状态码，body_text 为原始文本。"""

    status_code: int
    body_text: str


class HttpClient(Protocol):
    """HTTP 客户端协议：post_json(url, headers, payload, timeout_seconds)。

    实现约定：
    - 成功返回 HttpResponse(status_code, body_text)；
    - 超时抛 TimeoutError（或其子类）；
    - 连接失败抛 OSError/ConnectionError 等异常（由本层归一化为 error）。
    """

    def post_json(self, url: str, headers: Dict[str, str], payload: Dict[str, Any],
                  timeout_seconds: float) -> HttpResponse:
        ...


class UrllibHttpClient:
    """基于标准库 urllib 的默认客户端；仅由宿主显式装配，沙盒/测试不使用。

    存在于本模块只是完成"API 请求"这一交付项的实现；本阶段没有任何
    配置会让沙盒或测试走到真实网络。
    """

    def post_json(self, url: str, headers: Dict[str, str], payload: Dict[str, Any],
                  timeout_seconds: float) -> HttpResponse:
        import json as _json
        import urllib.error
        import urllib.request
        data = _json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                return HttpResponse(status_code=response.status,
                                    body_text=response.read().decode("utf-8", errors="replace"))
        except urllib.error.HTTPError as exc:
            body = ""
            try:
                body = exc.read().decode("utf-8", errors="replace")
            except Exception:  # noqa: BLE001 —— 读失败保持空体。
                body = ""
            return HttpResponse(status_code=exc.code, body_text=body)
        # TimeoutError / URLError 等原样上抛，由 HttpModelProvider 归一化。


class HttpModelProvider:
    """单角色 HTTP 模型 Provider（Strategy/Tactics 共用，按 role 区分产出键）。"""

    def __init__(self, settings, http_client: Any,
                 logger: Optional[Any] = None) -> None:
        self.settings = settings
        self.role = settings.role
        self._client = http_client
        self._logger = logger

    # ---------- 对外入口 ----------

    def propose(self, context: ModelCallContext) -> ModelOutcome:
        def outcome(status: str, payload: Any = None, reason: str = "",
                    retryable: bool = False) -> ModelOutcome:
            return ModelOutcome(status=status, role=self.role,
                                request_id=context.request_id, payload=payload,
                                reason=reason, retryable=retryable)

        if context.cancelled():
            return outcome(OUTCOME_CANCELLED, reason="cancelled before request")
        api_key = self.settings.resolve_api_key()
        if not api_key:
            # 凭证缺失是配置错误：结构化 error（retryable=False 防止风暴）。
            self._log("provider_credential_missing", status="error",
                      request_id=context.request_id, server_tick=context.server_tick,
                      api_key_env=self.settings.api_key_env)
            return outcome(OUTCOME_ERROR, reason="api key missing (env %s)" %
                           self.settings.api_key_env)
        payload = self._build_request(context)
        headers = redact_safe_headers(api_key)
        if self._logger is not None:
            self._log("provider_request", status="issued",
                      request_id=context.request_id, server_tick=context.server_tick,
                      endpoint=self.settings.endpoint, model=self.settings.model,
                      headers=redact_headers(headers))
        try:
            response = self._client.post_json(
                self.settings.endpoint, headers, payload,
                timeout_seconds=self.settings.timeout_seconds)
        except TimeoutError as exc:
            self._log("provider_timeout", status="timeout",
                      request_id=context.request_id, server_tick=context.server_tick,
                      reason=str(exc))
            return outcome(OUTCOME_TIMEOUT, reason="request timeout: %s" % exc)
        except Exception as exc:  # noqa: BLE001 —— 网络异常归一化为 error。
            self._log("provider_transport_error", status="error",
                      request_id=context.request_id, server_tick=context.server_tick,
                      reason=str(exc))
            return outcome(OUTCOME_ERROR, reason="transport error: %s" % exc,
                           retryable=True)
        # 请求返回后再检查一次取消：迟到的完成不抢回控制。
        if context.cancelled():
            return outcome(OUTCOME_CANCELLED, reason="cancelled after response")
        return self._normalize_response(response, context, api_key)

    # ---------- 响应归一化 ----------

    def _normalize_response(self, response, context: ModelCallContext,
                            api_key: str) -> ModelOutcome:
        def outcome(status: str, payload: Any = None, reason: str = "",
                    retryable: bool = False) -> ModelOutcome:
            return ModelOutcome(status=status, role=self.role,
                                request_id=context.request_id, payload=payload,
                                reason=reason, retryable=retryable)

        if response.status_code >= 400:
            self._log("provider_http_error", status="error",
                      request_id=context.request_id, server_tick=context.server_tick,
                      http_status=response.status_code,
                      body=redact_text(response.body_text[:MAX_BODY_LOG],
                                       collect_nonempty_secrets([api_key])))
            return outcome(OUTCOME_ERROR,
                           reason="http %d" % response.status_code)
        body_text = (response.body_text or "").strip()
        if not body_text:
            self._log("provider_empty_body", status="empty",
                      request_id=context.request_id, server_tick=context.server_tick)
            return outcome(OUTCOME_ERROR, reason="empty response body")
        import json as _json
        try:
            parsed = _json.loads(body_text)
        except ValueError as exc:
            self._log("provider_invalid_json", status="error",
                      request_id=context.request_id, server_tick=context.server_tick,
                      reason=str(exc),
                      body=redact_text(body_text[:MAX_BODY_LOG],
                                       collect_nonempty_secrets([api_key])))
            return outcome(OUTCOME_ERROR, reason="invalid json: %s" % exc)
        if not isinstance(parsed, dict):
            return outcome(OUTCOME_ERROR, reason="response root is not an object")
        if isinstance(parsed.get("error"), str) and parsed["error"]:
            return outcome(OUTCOME_REJECTED, reason="api error: %s" % parsed["error"])
        status_field = parsed.get("status")
        if isinstance(status_field, str) and status_field and \
                status_field not in ("ok", "completed"):
            # 未知/异常状态：显式 rejected（未知状态归一化，不猜测语义）。
            return outcome(OUTCOME_REJECTED, reason="unknown response status %r" % status_field)
        if self.role == ROLE_STRATEGY:
            plan = parsed.get("plan")
            if not isinstance(plan, dict):
                if plan is None and _looks_like_empty(parsed):
                    return outcome(OUTCOME_COMPLETED, payload=None,
                                   reason="empty response")
                return outcome(OUTCOME_ERROR, reason="missing 'plan' object")
            return outcome(OUTCOME_COMPLETED, payload=plan)
        commands = parsed.get("commands")
        if not isinstance(commands, list):
            if commands is None and _looks_like_empty(parsed):
                return outcome(OUTCOME_COMPLETED, payload=None,
                               reason="empty response")
            return outcome(OUTCOME_ERROR, reason="missing 'commands' list")
        return outcome(OUTCOME_COMPLETED, payload=commands)

    # ---------- 请求构造与日志 ----------

    def _build_request(self, context: ModelCallContext) -> Dict[str, Any]:
        return {
            "role": self.role,
            "model": self.settings.model,
            "request_id": context.request_id,
            "match_id": context.match_id,
            "player_id": context.player_id,
            "rules_version": context.rules_version,
            "plan_version": context.plan_version,
            "snapshot_id": context.snapshot_id,
            "issued_tick": context.issued_tick,
            "deadline_tick": context.deadline_tick,
            "budget": dict(context.budget),
            "observation": context.observation,
        }

    def _log(self, event: str, **fields: Any) -> None:
        if self._logger is None:
            return
        # logger 为结构化日志器；响应体/头已在调用侧脱敏。
        self._logger.log(event, **fields)


def redact_safe_headers(api_key: str) -> Dict[str, str]:
    """构造认证头；返回值只用于请求，落日志前必须再过 redact_headers。"""
    return {"Authorization": "Bearer %s" % api_key,
            "Content-Type": "application/json"}


def _looks_like_empty(parsed: Dict[str, Any]) -> bool:
    return len([k for k in parsed.keys() if k != "status"]) == 0
