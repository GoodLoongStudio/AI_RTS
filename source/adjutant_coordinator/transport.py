# -*- coding: utf-8 -*-
"""副官命令通道抽象：transport、心跳、重连与关闭（第二阶段离线准备）。

纪律：
- 核心只依赖 Transport 抽象；真实网络客户端由宿主装配时注入。
- 断线不得丢失当前计划/任务状态/待诊断信息：发送失败的原命令进入
  unsent 留证队列，由上层决定复核或重提（不静默丢弃）。
- 重连后必须重新读取状态并校验 match_id/player_id/rules_version，
  不一致保持断开并记录身份漂移。
- 不连接真实 Hermes，不改动现有 rts_ctl 链路。
"""

import json
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional


class TransportError(Exception):
    """通道层错误（断线、心跳失败、对端协议异常）。"""


class ConnectionState(Enum):
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"
    CLOSED = "closed"


class Transport(ABC):
    """命令通道抽象：真实 TCP / Loopback / Fake 都实现本接口。"""

    @abstractmethod
    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        """提交单条命令包并返回回执 dict；通道故障抛 TransportError。"""
        raise NotImplementedError

    @abstractmethod
    def heartbeat(self) -> bool:
        """健康探测；失败返回 False（不抛异常，便于调度器计数）。"""
        raise NotImplementedError

    @abstractmethod
    def close(self) -> None:
        raise NotImplementedError

    @abstractmethod
    def describe(self) -> str:
        raise NotImplementedError


class LoopbackTransport(Transport):
    """环回通道：handler 由装配方注入（E2E 真实接入时为 TCP 客户端函数）。"""

    def __init__(self, handler: Callable[[Dict[str, Any]], Dict[str, Any]]) -> None:
        self._handler = handler
        self.sent: List[Dict[str, Any]] = []
        self.closed = False

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        if self.closed:
            raise TransportError("transport closed")
        self.sent.append(envelope)
        receipt = self._handler(envelope)
        if not isinstance(receipt, dict):
            raise TransportError("handler returned non-dict receipt: %r" % (receipt,))
        return receipt

    def heartbeat(self) -> bool:
        return not self.closed

    def close(self) -> None:
        self.closed = True

    def describe(self) -> str:
        return "LoopbackTransport(closed=%s, sent=%d)" % (self.closed, len(self.sent))


class FakeTransport(Transport):
    """脚本化离线通道：模拟正常回执/断线/空响应/非法 JSON/未知状态/心跳失败。

    脚本条目（按序消费；耗尽后使用 default_behavior）：
    - ok            : 返回注入的 receipt（默认 Accepted）
    - disconnect    : 抛 TransportError（模拟断线）
    - empty         : 返回空 dict（对端空响应）
    - invalid_json  : 返回 {"raw": "<not json>"} 模拟非法 JSON 经解析后意外结构
    - unknown_state : 返回带未知 status 的回执
    heartbeat_failures: 前 N 次 heartbeat() 返回 False。
    """

    def __init__(self, script: Optional[List[str]] = None,
                 default_receipt: Optional[Dict[str, Any]] = None,
                 heartbeat_failures: int = 0) -> None:
        self._script = list(script or [])
        self._default = default_receipt or {
            "ok": True, "accepted": True, "status": "Accepted", "result": {}}
        self._heartbeat_failures = heartbeat_failures
        self.sent: List[Dict[str, Any]] = []
        self.closed = False
        self.state = ConnectionState.CONNECTED

    def send_command(self, envelope: Dict[str, Any]) -> Dict[str, Any]:
        if self.closed or self.state == ConnectionState.CLOSED:
            raise TransportError("transport closed")
        self.sent.append(envelope)
        behavior = self._script.pop(0) if self._script else "ok"
        if behavior == "disconnect":
            self.state = ConnectionState.DISCONNECTED
            raise TransportError("simulated disconnect")
        if behavior == "empty":
            return {}
        if behavior == "invalid_json":
            # 模拟对端返回无法解析为 JSON 对象的文本：包装后交上层按异常结构处理。
            return {"raw": "<<<not valid json>>>", "status": None}
        if behavior == "unknown_state":
            receipt = dict(self._default)
            receipt["status"] = "MysteryStatus"
            receipt["accepted"] = False
            return receipt
        return dict(self._default)

    def heartbeat(self) -> bool:
        if self.closed:
            return False
        if self._heartbeat_failures > 0:
            self._heartbeat_failures -= 1
            return False
        return self.state == ConnectionState.CONNECTED

    def set_connected(self, connected: bool) -> None:
        self.state = ConnectionState.CONNECTED if connected else ConnectionState.DISCONNECTED

    def close(self) -> None:
        self.closed = True
        self.state = ConnectionState.CLOSED

    def describe(self) -> str:
        return "FakeTransport(state=%s, script=%d)" % (self.state.value, len(self._script))


@dataclass
class UnsentRecord:
    """断线期间发送失败的原命令留证（不丢失待诊断信息）。"""

    envelope: Dict[str, Any]
    reason: str
    server_tick: int


class ResilientTransport(Transport):
    """带重连与身份校验的通道包装。

    - send 失败：进入 DISCONNECTED，命令写入 unsent_log（留证不丢），
      然后尝试 reconnect。
    - reconnect：调用注入的 reconnect_probe 回调，返回当前对局身份
      {match_id, player_id, rules_version}；与 bound identity 逐项比对，
      全部一致才恢复 CONNECTED；不一致保持断开并记录 identity_drift。
    - 断线期间 heartbeat() 返回 False；重连成功后恢复。
    - close() 幂等。
    """

    def __init__(
        self,
        inner: Transport,
        bound_identity: Dict[str, str],
        reconnect_probe: Optional[Callable[[], Dict[str, str]]] = None,
        max_reconnect_attempts: int = 3,
    ) -> None:
        self._inner = inner
        self._identity = dict(bound_identity)
        self._probe = reconnect_probe
        self._max_attempts = max_reconnect_attempts
        self.state = ConnectionState.CONNECTED
        self.unsent_log: List[UnsentRecord] = []
        self.heartbeat_failure_count = 0
        self.reconnect_attempts = 0
        self.identity_drift: Optional[Dict[str, Any]] = None
        self.last_reconnect_identity: Optional[Dict[str, str]] = None

    @property
    def identity(self) -> Dict[str, str]:
        return dict(self._identity)

    def send_command(self, envelope: Dict[str, Any], server_tick: int = 0) -> Dict[str, Any]:
        if self.state == ConnectionState.CLOSED:
            raise TransportError("transport closed")
        if self.state == ConnectionState.DISCONNECTED:
            self.unsent_log.append(UnsentRecord(
                envelope=envelope, reason="disconnected", server_tick=server_tick))
            raise TransportError("transport disconnected")
        try:
            return self._inner.send_command(envelope)
        except TransportError as exc:
            self.state = ConnectionState.DISCONNECTED
            self.unsent_log.append(UnsentRecord(
                envelope=envelope, reason=str(exc), server_tick=server_tick))
            self.try_reconnect(server_tick)
            raise

    def try_reconnect(self, server_tick: int = 0) -> bool:
        """尝试重连；身份校验失败保持断开并记录 drift。"""
        if self.state == ConnectionState.CONNECTED:
            return True
        if self._probe is None:
            return False
        for _ in range(self._max_attempts):
            self.reconnect_attempts += 1
            try:
                observed = self._probe()
            except Exception as exc:  # noqa: BLE001 —— 探测失败计一次尝试。
                self.last_reconnect_identity = {"error": str(exc)}
                continue
            self.last_reconnect_identity = dict(observed)
            drift = {key: {"bound": self._identity.get(key), "observed": observed.get(key)}
                     for key in ("match_id", "player_id", "rules_version")
                     if str(observed.get(key, "")) != str(self._identity.get(key, ""))}
            if drift:
                self.identity_drift = drift
                return False
            self.identity_drift = None
            self.state = ConnectionState.CONNECTED
            return True
        return False

    def heartbeat(self) -> bool:
        if self.state != ConnectionState.CONNECTED:
            self.heartbeat_failure_count += 1
            return False
        if not self._inner.heartbeat():
            self.heartbeat_failure_count += 1
            self.state = ConnectionState.DISCONNECTED
            return False
        return True

    def close(self) -> None:
        if self.state == ConnectionState.CLOSED:
            return
        self.state = ConnectionState.CLOSED
        self._inner.close()

    def describe(self) -> str:
        return "ResilientTransport(state=%s, inner=%s, unsent=%d)" % (
            self.state.value, self._inner.describe(), len(self.unsent_log))
