# -*- coding: utf-8 -*-
"""图 checkpoint 存储：按 (match_id, player_id) 隔离，重启后可恢复。

纪律（方案 §12、architecture.md §4）：
- checkpoint 按对局与玩家隔离，不与其他会话/旧 daemon 共享状态文件；
- 复用既有 MatchPlayerStore（独立临时文件 + os.replace 原子写 + 单写入者锁）；
- 禁止用更旧的状态覆盖更新的 checkpoint（server_tick 单调），旧数据只留证不生效；
- 文件损坏时不静默重建：返回 None 并保留现场供诊断。
"""

from __future__ import annotations

import json
import os
from abc import ABC, abstractmethod
from typing import Any, Dict, Optional

from ..persistence import MatchPlayerStore
from .state import AdjutantGraphState, CHECKPOINT_VERSION

DEFAULT_CHECKPOINT_NAME = "graph_checkpoint"


class CheckpointStore(ABC):
    """checkpoint 存储抽象：内存（测试）与 JSON 文件（本地/服务器）两种实现。"""

    @abstractmethod
    def save(self, state: AdjutantGraphState) -> Dict[str, Any]:
        """写入 checkpoint；返回 {saved, reason, saved_tick, path}。"""

    @abstractmethod
    def load(self) -> Optional[AdjutantGraphState]:
        """读取 checkpoint；不存在/损坏/版本不支持返回 None。"""

    def save_raw(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        """写入原始 checkpoint payload（节点层已构造好 dict，避免无谓往返）。"""
        return self.save(AdjutantGraphState.from_checkpoint(payload))

    def load_raw(self) -> Optional[Dict[str, Any]]:
        """读取原始 payload（恢复时保留全部诊断字段）。"""
        state = self.load()
        return state.to_checkpoint() if state is not None else None

    @abstractmethod
    def exists(self) -> bool:
        ...

    @abstractmethod
    def describe(self) -> str:
        ...


class MemoryCheckpointStore(CheckpointStore):
    """内存 checkpoint：确定性测试与 FakeModel 闭环用。"""

    def __init__(self) -> None:
        self.payload: Optional[Dict[str, Any]] = None
        self.saves = 0
        self.skipped = 0

    def save(self, state: AdjutantGraphState) -> Dict[str, Any]:
        return self.save_raw(state.to_checkpoint())

    def save_raw(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        if self.payload is not None and \
                int(payload.get("saved_tick", 0)) < int(self.payload.get("saved_tick", 0)):
            self.skipped += 1
            return {"saved": False, "reason": "stale_checkpoint_refused",
                    "saved_tick": int(self.payload.get("saved_tick", 0)), "path": "memory"}
        self.payload = payload
        self.saves += 1
        return {"saved": True, "reason": "", "saved_tick": payload.get("saved_tick", 0),
                "path": "memory"}

    def load_raw(self) -> Optional[Dict[str, Any]]:
        return self.payload

    def load(self) -> Optional[AdjutantGraphState]:
        if self.payload is None:
            return None
        try:
            return AdjutantGraphState.from_checkpoint(self.payload)
        except ValueError:
            return None

    def exists(self) -> bool:
        return self.payload is not None

    def describe(self) -> str:
        tick = (self.payload or {}).get("saved_tick", -1)
        return "MemoryCheckpointStore(saved=%s, saves=%d, skipped=%d, tick=%s)" % (
            self.exists(), self.saves, self.skipped, tick)


class JsonCheckpointStore(CheckpointStore):
    """JSON 文件 checkpoint：按 (match_id, player_id) 目录隔离 + 原子写 + 陈旧写保护。"""

    def __init__(self, root: str, match_id: str, player_id: str,
                 name: str = DEFAULT_CHECKPOINT_NAME) -> None:
        self._store = MatchPlayerStore(root, match_id, player_id)
        self._name = name
        self.match_id = match_id
        self.player_id = player_id

    @property
    def path(self) -> str:
        return os.path.join(self._store.directory, "%s.json" % self._name)

    def save(self, state: AdjutantGraphState) -> Dict[str, Any]:
        return self.save_raw(state.to_checkpoint())

    def save_raw(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        if int(payload.get("checkpoint_version", 0)) != CHECKPOINT_VERSION:
            return {"saved": False, "reason": "checkpoint_version_unsupported",
                    "saved_tick": 0, "path": self.path}
        current = self._read_raw()
        if current is not None:
            current_tick = int(current.get("saved_tick", 0))
            if int(payload.get("saved_tick", 0)) < current_tick:
                # 重启后拿旧状态覆盖新 checkpoint → 明确拒绝（不静默覆盖证据）。
                return {"saved": False, "reason": "stale_checkpoint_refused",
                        "saved_tick": current_tick, "path": self.path}
        self._store.write_state(self._name, payload)
        return {"saved": True, "reason": "", "saved_tick": payload.get("saved_tick", 0),
                "path": self.path}

    def load(self) -> Optional[AdjutantGraphState]:
        payload = self._read_raw()
        if payload is None:
            return None
        try:
            return AdjutantGraphState.from_checkpoint(payload)
        except ValueError:
            # 版本不支持/结构异常：保留文件现场，返回 None（上层走新开局）。
            return None

    def load_raw(self) -> Optional[Dict[str, Any]]:
        return self._read_raw()

    def _read_raw(self) -> Optional[Dict[str, Any]]:
        if not os.path.exists(self.path):
            return None
        try:
            with open(self.path, "r", encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            return None
        if not isinstance(data, dict):
            return None
        if int(data.get("checkpoint_version", 0)) != CHECKPOINT_VERSION:
            return None
        return data

    def exists(self) -> bool:
        return self._read_raw() is not None

    def describe(self) -> str:
        return "JsonCheckpointStore(path=%s, exists=%s)" % (self.path, self.exists())


class NullCheckpointStore(CheckpointStore):
    """禁用 checkpoint 的显式实现（禁止用 None 隐式跳过持久化）。"""

    def save(self, state: AdjutantGraphState) -> Dict[str, Any]:
        return self.save_raw(state.to_checkpoint())

    def save_raw(self, payload: Dict[str, Any]) -> Dict[str, Any]:
        return {"saved": False, "reason": "checkpoint_disabled", "saved_tick": 0, "path": ""}

    def load(self) -> Optional[AdjutantGraphState]:
        return None

    def load_raw(self) -> Optional[Dict[str, Any]]:
        return None

    def exists(self) -> bool:
        return False

    def describe(self) -> str:
        return "NullCheckpointStore(disabled)"
