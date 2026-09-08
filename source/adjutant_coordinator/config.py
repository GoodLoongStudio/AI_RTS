# -*- coding: utf-8 -*-
"""Provider 配置与工厂（第三阶段：Fake / HTTP 双模式切换）。

凭证纪律（architecture.md §5）：
- API 凭证只从服务端环境变量读取（变量名可配置，值本身不进入配置对象、
  日志、文档或版本库）；`safe_dict()` 输出脱敏视图供诊断。
- 模型名称、endpoint、超时均属服务端配置，不写死在协调器核心。
"""

import os
from dataclasses import dataclass, field
from typing import Any, Dict, Optional

from .fakes import ScriptedStrategyProvider, ScriptedTacticsProvider
from .redaction import redact_mapping

MODE_FAKE = "fake"
MODE_HTTP = "http"
VALID_MODES = (MODE_FAKE, MODE_HTTP)

DEFAULT_API_KEY_ENV = "AI_ADJUTANT_API_KEY"


@dataclass
class ProviderSettings:
    """单角色 Provider 配置；可从服务端环境变量构造。"""

    mode: str = MODE_FAKE
    role: str = "strategy"
    endpoint: str = ""
    model: str = ""
    # 存"环境变量名"而不是凭证本身；解析时机在调用期（resolve_api_key）。
    api_key_env: str = DEFAULT_API_KEY_ENV
    timeout_seconds: float = 8.0
    # fake 模式脚本（确定性离线测试用；真实接入时忽略）。
    fake_script: list = field(default_factory=list)

    @classmethod
    def from_env(cls, role: str, prefix: str = "AI_ADJUTANT_") -> "ProviderSettings":
        """从服务端环境变量构造（如 AI_ADJUTANT_STRATEGY_MODE/ENDPOINT/...）。

        只读配置项（mode/endpoint/model/api_key_env/timeout），凭证值本身
        不在构造期读取；`resolve_api_key` 在调用期按 api_key_env 解析。
        """
        role_key = role.upper()

        def env(suffix: str, default: str = "") -> str:
            return os.environ.get("%s%s_%s" % (prefix, role_key, suffix), default)

        mode = env("MODE", MODE_FAKE).strip().lower()
        if mode not in VALID_MODES:
            mode = MODE_FAKE
        try:
            timeout = float(env("TIMEOUT", "8.0"))
        except ValueError:
            timeout = 8.0
        return cls(
            mode=mode,
            role=role,
            endpoint=env("ENDPOINT"),
            model=env("MODEL"),
            api_key_env=env("API_KEY_ENV", DEFAULT_API_KEY_ENV),
            timeout_seconds=timeout,
        )

    def resolve_api_key(self) -> str:
        """调用期从环境变量解析凭证；返回值不得写入日志或文件。"""
        if not self.api_key_env:
            return ""
        return os.environ.get(self.api_key_env, "")

    def safe_dict(self) -> Dict[str, Any]:
        """脱敏诊断视图：凭证值固定为掩码；api_key_env 是变量名（非凭证），保留。"""
        safe = redact_mapping({
            "mode": self.mode,
            "role": self.role,
            "endpoint": self.endpoint,
            "model": self.model,
            "api_key_env": self.api_key_env,
            "api_key": self.resolve_api_key(),
            "timeout_seconds": self.timeout_seconds,
        })
        safe["api_key_env"] = self.api_key_env
        return safe


def create_strategy_provider(
    settings: ProviderSettings,
    fake_provider: Optional[ScriptedStrategyProvider] = None,
    http_client: Any = None,
    logger: Any = None,
):
    """按配置构造战略 Provider；mode=fake 时必须注入 fake_provider。"""
    if settings.mode == MODE_FAKE:
        if fake_provider is None:
            fake_provider = ScriptedStrategyProvider(settings.fake_script)
        return fake_provider
    from .http_provider import HttpModelProvider  # 延迟导入：fake 模式零网络依赖。
    return HttpModelProvider(settings=settings, http_client=http_client, logger=logger)


def create_tactics_provider(
    settings: ProviderSettings,
    fake_provider: Optional[ScriptedTacticsProvider] = None,
    http_client: Any = None,
    logger: Any = None,
):
    """按配置构造战术 Provider；mode=fake 时必须注入 fake_provider。"""
    if settings.mode == MODE_FAKE:
        if fake_provider is None:
            fake_provider = ScriptedTacticsProvider(settings.fake_script)
        return fake_provider
    from .http_provider import HttpModelProvider  # 延迟导入：fake 模式零网络依赖。
    return HttpModelProvider(settings=settings, http_client=http_client, logger=logger)
