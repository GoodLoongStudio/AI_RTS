# -*- coding: utf-8 -*-
"""服务器 .env 加载：密钥只进环境变量，不打印、不写日志。

- 默认读取 /opt/airts-agent/.env（可用 AIRTS_AGENT_ENV 覆盖，或显式传参）；
- 已存在的环境变量优先（便于用 shell 临时覆盖模型/超时）；
- 只返回“已加载的键名列表”，绝不返回取值，避免密钥进日志。
"""

from __future__ import annotations

import os
from typing import List, Optional

DEFAULT_ENV_PATH = "/opt/airts-agent/.env"


def load_env_file(path: Optional[str] = None) -> List[str]:
    target = path or os.environ.get("AIRTS_AGENT_ENV") or DEFAULT_ENV_PATH
    loaded: List[str] = []
    try:
        with open(target, "r", encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return loaded
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if not key:
            continue
        if key in os.environ and os.environ[key]:
            continue  # 已有环境变量优先（不覆盖）
        os.environ[key] = value
        loaded.append(key)
    return loaded
