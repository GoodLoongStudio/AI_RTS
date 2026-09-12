# -*- coding: utf-8 -*-
"""副官结构化日志（第二阶段离线准备）。

每条事件至少携带：match_id / player_id / request_id / plan_version / task_id /
command_id / rules_version / snapshot_id / 状态 / 原因 / 时间（server_tick）。
输出为 UTF-8 JSONL；sink 可注入（测试用内存列表，宿主用文件）。
不记录任何凭证、模型名称或隐藏推理过程。
"""

import json
import os
import threading
from typing import Any, Callable, Dict, List, Optional

# 结构化日志的标准字段；缺省值统一为空串，保证每行字段齐全可解析。
BASE_FIELDS = (
    "event", "status", "reason", "server_tick",
    "match_id", "player_id", "request_id", "plan_version", "task_id",
    "command_id", "rules_version", "snapshot_id",
)
# 身份字段只允许 update_identity 修改（事件级传参不能伪造对局身份）。
IDENTITY_FIELDS = ("match_id", "player_id", "rules_version", "snapshot_id")

LogSink = Callable[[Dict[str, Any]], None]


class MemorySink:
    """测试用内存 sink：保留全部条目供断言。"""

    def __init__(self) -> None:
        self.entries: List[Dict[str, Any]] = []

    def __call__(self, entry: Dict[str, Any]) -> None:
        self.entries.append(entry)

    def find(self, event: str) -> List[Dict[str, Any]]:
        return [e for e in self.entries if e.get("event") == event]


class JsonlFileSink:
    """UTF-8 JSONL 文件 sink；逐行追加，进程异常时已写行不丢失。"""

    def __init__(self, path: str) -> None:
        self.path = path
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        self._lock = threading.Lock()

    def __call__(self, entry: Dict[str, Any]) -> None:
        # `default=str`：字段里混进 set/dataclass 时降级成字符串，**不要抛异常**。
        # `GraphServices.log` 会吞掉异常，一旦序列化失败就是**整行日志静默消失** ——
        # 而这正是"打了点却看不到"这类排查最怕的失败模式（本项目已踩过）。
        line = json.dumps(entry, ensure_ascii=False, sort_keys=True, default=str)
        with self._lock:
            with open(self.path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")


class StructuredLogger:
    """结构化日志入口：base 身份字段 + 事件级字段合成。"""

    def __init__(self, sink: LogSink,
                 base: Optional[Dict[str, Any]] = None) -> None:
        self._sink = sink
        self._base = dict(base or {})

    def update_identity(self, **fields: Any) -> None:
        """重连/换局后更新 base 身份（match_id/player_id/rules_version/snapshot_id）。"""
        for key, value in fields.items():
            if key in BASE_FIELDS:
                self._base[key] = value

    def log(self, event: str, status: str = "", reason: str = "",
            server_tick: Optional[int] = None, **fields: Any) -> Dict[str, Any]:
        entry: Dict[str, Any] = {}
        for name in BASE_FIELDS:
            if name == "event":
                entry[name] = event
            elif name == "status":
                entry[name] = status
            elif name == "reason":
                entry[name] = reason
            elif name == "server_tick":
                entry[name] = int(server_tick) if server_tick is not None else -1
            elif name in IDENTITY_FIELDS:
                entry[name] = self._base.get(name, "")
            else:
                value = fields.get(name, self._base.get(name, ""))
                entry[name] = value if value is not None else ""
        # 扩展字段（如 role / attempts / drift）原样附加，不覆盖标准字段。
        for key, value in fields.items():
            if key not in entry:
                entry[key] = value
        self._sink(entry)
        return entry


class NullLogger(StructuredLogger):
    """空日志：字段合成照常（供测试读取返回值），但不落任何 sink。"""

    def __init__(self) -> None:
        super().__init__(sink=lambda entry: None)
