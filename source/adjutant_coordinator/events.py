# -*- coding: utf-8 -*-
"""副官事件总线：有界队列 + 事件合并 + 断线恢复语义。

纪律（architecture.md 第 4 节）：
- 事件带 match_id/player_id/event_id/server_tick；
- 去重、合并和队列均有界；
- 丢事件或消费者断线后，通过新快照恢复，不假设事件永不丢失。
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional


@dataclass
class Event:
    event_id: str
    kind: str
    match_id: str
    player_id: str
    server_tick: int
    payload: Dict = field(default_factory=dict)

    @property
    def merge_key(self) -> Optional[str]:
        """同 (kind, subject) 的事件在窗口内合并为最新一条；无主体的事件不合并。"""
        subject = self.payload.get("subject")
        if not subject:
            return None
        return "%s|%s" % (self.kind, subject)


class EventBus:
    """有界事件队列；merge_window 内同键事件只保留最新。"""

    def __init__(self, capacity: int = 512, merge_window_ticks: int = 10) -> None:
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        self._capacity = capacity
        self._merge_window = merge_window_ticks
        self._queue: List[Event] = []
        self._dropped = 0
        self._merged = 0
        self._consumer_epoch = 0
        self._consumed_epoch = 0

    @property
    def dropped(self) -> int:
        return self._dropped

    @property
    def merged(self) -> int:
        return self._merged

    def push(self, event: Event) -> None:
        # 同键且在同一合并窗口内 → 覆盖旧事件（例如同单位连续移动合并）。
        key = event.merge_key
        if key is not None:
            for index in range(len(self._queue) - 1, -1, -1):
                existing = self._queue[index]
                if existing.merge_key == key:
                    if event.server_tick - existing.server_tick <= self._merge_window:
                        self._queue[index] = event
                        self._merged += 1
                        return
                    break
        self._queue.append(event)
        # 有界背压：满时丢弃最旧事件并计数（不静默膨胀）。
        while len(self._queue) > self._capacity:
            self._queue.pop(0)
            self._dropped += 1

    def drain(self) -> List[Event]:
        """消费全部事件；消费者代际更新（供断线检测）。"""
        events = self._queue
        self._queue = []
        self._consumed_epoch = self._consumer_epoch
        return events

    def mark_consumer_disconnected(self) -> None:
        """消费者断线：清空积压（恢复必须走新快照，不假设事件不丢）。"""
        self._queue.clear()
        self._consumer_epoch += 1

    def consumer_stale(self) -> bool:
        return self._consumer_epoch != self._consumed_epoch

    def pending(self) -> int:
        return len(self._queue)
