# -*- coding: utf-8 -*-
"""凭证与敏感信息脱敏工具（第三阶段 Provider 适配层）。

纪律（architecture.md §5）：
- API 凭证只从服务端环境变量或服务端配置读取；
- 不进入客户端、Godot 资源、提交文件或普通日志；
- 所有需要落日志的结构（headers、配置、响应摘要）必须先经本模块脱敏。
"""

import re
from typing import Any, Dict, Iterable, List

REDACTED = "***redacted***"

# 键名命中即整值脱敏（不区分大小写）。
SENSITIVE_KEY_PATTERN = re.compile(
    r"(api[-_]?key|secret|token|authorization|password|credential|bearer)",
    re.IGNORECASE,
)


def is_sensitive_key(key: str) -> bool:
    return bool(SENSITIVE_KEY_PATTERN.search(str(key)))


def redact_mapping(mapping: Dict[str, Any]) -> Dict[str, Any]:
    """浅层脱敏：敏感键的值替换为固定标记，其余原样。"""
    result: Dict[str, Any] = {}
    for key, value in (mapping or {}).items():
        if is_sensitive_key(key):
            result[key] = REDACTED
        else:
            result[key] = value
    return result


def redact_headers(headers: Dict[str, str]) -> Dict[str, str]:
    """HTTP 头脱敏：Authorization / X-API-Key 等整值替换。"""
    return redact_mapping(headers)


def redact_text(text: str, secrets: Iterable[str]) -> str:
    """文本脱敏：把已知凭证字符串替换为标记（用于响应体摘要兜底）。"""
    result = text or ""
    for secret in secrets:
        if secret and secret in result:
            result = result.replace(secret, REDACTED)
    return result


def collect_nonempty_secrets(values: Iterable[str]) -> List[str]:
    return [v for v in values if v]
