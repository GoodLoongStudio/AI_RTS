# -*- coding: utf-8 -*-
"""副官持久化：按对局与玩家隔离的目录 + 原子写 + 单写入者锁。

纪律（architecture.md 第 4 节）：
- 现有 last_status.json/last_receipt.json 及固定 .tmp 不可被两个会话并发写入；
- 本模块以 (match_id, player_id) 目录隔离 + 独立临时文件（含 pid+uuid）+
  单写入者锁解决；仅原子 rename 不解决逻辑覆盖问题，因此加写入者锁。
"""

import json
import os
import tempfile
import time
import uuid
from typing import Any, Dict, Optional


class WriterLock:
    """单写入者锁：lock 文件 O_CREAT|O_EXCL + pid 活性检测的陈旧锁回收。"""

    def __init__(self, path: str) -> None:
        self.path = path
        self._held = False

    def acquire(self) -> bool:
        if self._held:
            return True
        while True:
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode("utf-8"))
                os.close(fd)
                self._held = True
                return True
            except FileExistsError:
                if not _lock_owner_alive(self.path):
                    # 陈旧锁：持有进程已死，安全回收后重试。
                    try:
                        os.remove(self.path)
                    except OSError:
                        pass
                    continue
                return False

    def release(self) -> None:
        if not self._held:
            return
        try:
            os.remove(self.path)
        except OSError:
            pass
        self._held = False

    def __enter__(self) -> "WriterLock":
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()


def _lock_owner_alive(path: str) -> bool:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            pid = int(handle.read().strip() or "0")
    except (OSError, ValueError):
        return False
    if pid <= 0:
        return False
    if pid == os.getpid():
        return True
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except OSError:
        return False


class MatchPlayerStore:
    """按 (match_id, player_id) 隔离的持久化存储。"""

    def __init__(self, root: str, match_id: str, player_id: str) -> None:
        if not match_id or not player_id:
            raise ValueError("match_id/player_id 不能为空（禁止跨对局共享账本）")
        self._directory = os.path.join(root, _safe_name(match_id), _safe_name(player_id))
        os.makedirs(self._directory, exist_ok=True)
        self._lock = WriterLock(os.path.join(self._directory, "writer.lock"))

    @property
    def directory(self) -> str:
        return self._directory

    def write_state(self, name: str, payload: Any) -> None:
        """原子写入：独立临时文件（pid+uuid）+ os.replace；并发会话不互相覆盖。

        Windows 下两个 os.replace 同时命中同一目标可能短暂 PermissionError，
        标准做法是短暂退避重试（单机本地盘通常一次即成功）。
        """
        target = os.path.join(self._directory, _safe_name(name) + ".json")
        unique = "%s.%s.tmp" % (os.getpid(), uuid.uuid4().hex[:8])
        tmp_path = os.path.join(self._directory, unique)
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        for attempt in range(5):
            try:
                os.replace(tmp_path, target)
                return
            except PermissionError:
                if attempt == 4:
                    try:
                        os.remove(tmp_path)
                    except OSError:
                        pass
                    raise
                time.sleep(0.01 * (attempt + 1))

    def read_state(self, name: str, default: Any = None) -> Any:
        target = os.path.join(self._directory, _safe_name(name) + ".json")
        if not os.path.exists(target):
            return default
        try:
            with open(target, "r", encoding="utf-8") as handle:
                return json.load(handle)
        except (OSError, ValueError):
            # 损坏文件返回默认值并保留现场供诊断，不静默重建覆盖证据。
            return default

    def append_event_log(self, name: str, entry: Dict) -> None:
        """JSONL 追加日志：决策/回执留痕，跨会话按目录隔离。"""
        target = os.path.join(self._directory, _safe_name(name) + ".jsonl")
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n")

    @property
    def lock(self) -> WriterLock:
        return self._lock


def _safe_name(raw: str) -> str:
    cleaned = "".join(ch if ch.isalnum() or ch in "-_." else "_" for ch in raw)
    return cleaned[:80] if cleaned else "_"
