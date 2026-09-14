# -*- coding: utf-8 -*-
"""10Hz 缓存型快速扫描层（计划《高频扫描、多线并行与安全行军》§3.1 / §4）。

## 为什么单独一层

改造前的实测节拍：runner 主循环 **0.5 秒/轮**，每轮还要串行发 3 次**全量**观测
（`op=rules` / `op=strategic` / `op=tactical`），而 `op=tactical` 自身在游戏侧要全扫
`units` 两遍、并对每个敌人再全扫一次（O(敌×我)）。所以"提高频率"不是改个 sleep 就行 ——
必须先有一条**不重扫场景**的读路径。

## 分工（硬边界）

- 本模块只在**自己的线程**里：每 100ms 拉一次 `op=adjutant_fast_state`（读的是游戏侧缓存），
  把快照塞进**有界可丢弃**的队列，把增量事件按 `seq` 去重后攒起来。
- 本模块**不写 LangGraph 状态、不调模型、不读完整战略视图**（计划 §3.1 明令）。
  协调线程通过 `latest()` / `drain_events()` 取数据，写状态永远只有协调线程一个写者。
"""

from __future__ import annotations

import threading
import time
from collections import deque
from typing import Any, Callable, Dict, List, Optional

#: 快照队列长度：**有界且可丢旧值**（协调线程慢的时候丢旧快照，绝不阻塞扫描）。
DEFAULT_QUEUE_SIZE = 8
#: 事件缓冲上限：消费方按 seq 去重，所以丢最旧的不会丢"新事件"。
DEFAULT_EVENT_BUFFER = 1024
#: 年龄/间隔统计保留的样本数（用于算 p50/p95/max）。
STATS_WINDOW = 256

#: 跨进程时间戳的**合理性上限（秒）**：超过它说明两端时钟口径不一致。
#: 实测踩过：游戏侧曾用 `Time.get_ticks_msec()`（引擎运行时长）当 epoch 秒上报，
#: Python 侧用 `time.time()` 相减 → 报出 `snapshot_age_p50 = 1789227830s` 的假指标。
#: 纪律：**宁可标"未知"，也不上报一个假数字**（假指标比没有指标更危险）。
MAX_PLAUSIBLE_AGE_S = 60.0


def _percentile(values: List[float], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * ratio))))
    return float(ordered[index])


def plausible_age(received_at: float, sampled_at: Any) -> Optional[float]:
    """两端时钟口径一致时才返回年龄；否则返回 None（=未知）。"""
    try:
        value = float(sampled_at)
    except (TypeError, ValueError):
        return None
    if value <= 0.0:
        return None
    age = float(received_at) - value
    if age < -1.0 or age > MAX_PLAUSIBLE_AGE_S:
        return None
    return max(0.0, age)


class FastScanner:
    """10Hz 扫描器：线程只负责"取数据 + 入队"，不做任何决策。"""

    def __init__(self, port: int, player: str, *, tcp_json: Callable[..., Dict[str, Any]],
                 interval: float = 0.1, queue_size: int = DEFAULT_QUEUE_SIZE,
                 event_buffer: int = DEFAULT_EVENT_BUFFER, timeout: float = 5.0) -> None:
        self.port = int(port)
        self.player = str(player)
        self._tcp_json = tcp_json
        self.interval = max(0.02, float(interval))
        self.timeout = float(timeout)
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        #: 快照队列：maxlen 保证"旧值自动丢"，协调线程永远拿到最新的几条。
        self._snapshots: deque = deque(maxlen=max(1, int(queue_size)))
        #: 未消费事件（按 seq 去重后追加）。
        self._events: deque = deque(maxlen=max(16, int(event_buffer)))
        #: 已消费到的 seq：扫描线程据此只请求增量。
        self._since_seq = -1
        self._consumed_seq = -1
        self._ages: deque = deque(maxlen=STATS_WINDOW)
        self._intervals: deque = deque(maxlen=STATS_WINDOW)
        self._latencies: deque = deque(maxlen=STATS_WINDOW)
        #: 游戏侧 10Hz 采样的**自身耗时**（`state.sample_ms`，由游戏上报）。
        #: 为什么要跨进程上报：玩家掉帧时第一个要回答的问题是"副官通道占了多少"，
        #: 而这个数字只有游戏侧知道（实测：`is_target_reachable` 每单位每 100ms 一次
        #: 真寻路 → 大部队时把 FPS 拖到 20~30）。缺字段时留空，**不编 0**。
        self._sample_ms: deque = deque(maxlen=STATS_WINDOW)
        self.sample_ms_unknown = 0
        #: 游戏帧率（随采样上报）：与单位数、采样耗时放进同一条时间线，
        #: 任何一局都能回答"帧率是随部队规模掉的，还是随副官通道掉的"。
        self._fps: deque = deque(maxlen=STATS_WINDOW)
        #: 帧率治理（游戏侧 `PerformanceGovernor`）：画质档与缩放。
        #: 为什么要跨进程上报（用户 2026-09-14："单位多就降画质、稳住 60 帧"）：
        #: "部队涨上来时画质到底有没有降下去"只能靠这条时间线证明；缺字段时留空，**不编 0**。
        self._quality_tier: deque = deque(maxlen=STATS_WINDOW)
        self._quality_scale: deque = deque(maxlen=STATS_WINDOW)
        self.samples = 0
        self.errors = 0
        self.last_error = ""
        self.last_payload_ms = 0
        #: 因两端时钟口径不一致而**无法计算**年龄的次数（显式计数，避免 0.0 被误读成"完美"）。
        self.age_unknown = 0

    # ---------------- 线程生命周期 ----------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._loop, name="adjutant-fast-scan",
                                        daemon=True)
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        thread = self._thread
        if thread is not None:
            thread.join(timeout=timeout)
        self._thread = None

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def _request(self, attempts: int = 2) -> Any:
        """请求一次快照（**失败重试一次**）。

        为什么必须重试：`adjutant_fast_state` 的载荷随单位数增长（实测 41 个单位时几 KB），
        而 DCS 是逐帧写出的；读取超时/半行读会返回"非 JSON"。5 分钟集成局实测
        **127 次 `non-json`（约 4%）** —— 每次丢掉一整个快照。
        重试一次是廉价且安全的：`amount` 无副作用（只读 op）。
        """
        last: Any = {}
        for _ in range(max(1, int(attempts))):
            last = self._tcp_json(self.port, {
                "op": "adjutant_fast_state", "as_player": self.player,
                "since_event_seq": self._since_seq}, timeout=self.timeout)
            if isinstance(last, dict) and last.get("ok") and last.get("state"):
                return last
        return last

    def _loop(self) -> None:
        previous_sample = 0.0
        while not self._stop.is_set():
            started = time.time()
            if previous_sample > 0.0:
                self._intervals.append(started - previous_sample)
            previous_sample = started
            try:
                self._poll_once(started)
            except Exception as exc:  # noqa: BLE001 —— 扫描线程绝不允许把 runner 拖崩
                with self._lock:
                    self.errors += 1
                    self.last_error = repr(exc)[:200]
            elapsed = time.time() - started
            self._stop.wait(max(0.0, self.interval - elapsed))

    def _poll_once(self, started: float) -> None:
        payload = self._request(attempts=2)
        if not isinstance(payload, dict) or payload.get("error") or not payload.get("ok"):
            with self._lock:
                self.errors += 1
                self.last_error = str((payload or {}).get("error", "bad fast_state response"))[:200]
            return
        state = payload.get("state") or {}
        if not isinstance(state, dict) or not state:
            return
        received_at = time.time()
        state["_received_at"] = received_at
        age = plausible_age(received_at, state.get("sampled_at"))
        events = payload.get("events") or []
        with self._lock:
            self.samples += 1
            self.last_payload_ms = int((time.time() - started) * 1000)
            raw_fps = state.get("fps")
            if isinstance(raw_fps, (int, float)) and float(raw_fps) > 0:
                self._fps.append(float(raw_fps))
            raw_tier = state.get("quality_tier")
            if isinstance(raw_tier, (int, float)):
                self._quality_tier.append(float(raw_tier))
            raw_scale = state.get("quality_scale")
            if isinstance(raw_scale, (int, float)) and float(raw_scale) > 0:
                self._quality_scale.append(float(raw_scale))
            raw_sample_ms = state.get("sample_ms")
            if isinstance(raw_sample_ms, (int, float)):
                self._sample_ms.append(float(raw_sample_ms))
            else:
                # 旧版游戏不上报 → 记"未知"（不写 0，否则会被读成"零成本"）。
                self.sample_ms_unknown += 1
            if age is not None:
                self._ages.append(age)
            else:
                self.age_unknown += 1
            self._snapshots.append(state)
            next_seq = int(payload.get("next_event_seq", self._since_seq) or self._since_seq)
            if next_seq > self._since_seq:
                self._since_seq = next_seq
            for event in events:
                if not isinstance(event, dict):
                    continue
                self._events.append(event)
                latency = plausible_age(received_at, event.get("sampled_at"))
                if latency is not None:
                    self._latencies.append(latency)

    # ---------------- 协调线程读取 ----------------

    def latest(self) -> Optional[Dict[str, Any]]:
        with self._lock:
            return dict(self._snapshots[-1]) if self._snapshots else None

    def drain_events(self) -> List[Dict[str, Any]]:
        """返回**尚未消费**的事件（按 seq 升序、去重）。

        去重口径与游戏侧一致：事件自带全局递增 `seq`，消费游标只增不减；
        因此扫描线程丢掉的"旧事件"不会造成误判，只会少看到一次历史。
        """
        with self._lock:
            out = [dict(event) for event in self._events
                   if int(event.get("seq", 0)) > self._consumed_seq]
            if out:
                self._consumed_seq = max(int(event.get("seq", 0)) for event in out)
            return out

    def stats(self) -> Dict[str, Any]:
        with self._lock:
            ages = list(self._ages)
            intervals = list(self._intervals)
            latencies = list(self._latencies)
            return {
                "scan_samples": self.samples,
                "scan_errors": self.errors,
                "scan_last_error": self.last_error,
                "scan_hz": (1.0 / (sum(intervals) / len(intervals)) if intervals else 0.0),
                "scan_ms_p50": self.last_payload_ms,
                # 游戏侧采样成本（副官通道对帧率的固定开销，玩家可见）。
                "sample_ms_last": int(self._sample_ms[-1]) if self._sample_ms else None,
                "sample_ms_p50": _percentile(list(self._sample_ms), 0.5) if self._sample_ms else None,
                "sample_ms_p95": _percentile(list(self._sample_ms), 0.95) if self._sample_ms else None,
                "sample_ms_max": max(self._sample_ms) if self._sample_ms else None,
                "sample_ms_unknown": self.sample_ms_unknown,
                # 游戏帧率（玩家最在意的那个数）：与单位数/采样耗时同一条时间线。
                "fps_last": int(self._fps[-1]) if self._fps else None,
                "fps_min": int(min(self._fps)) if self._fps else None,
                "fps_p50": int(_percentile(list(self._fps), 0.5)) if self._fps else None,
                # 画质档（游戏侧帧率治理）：**最高档号 = 画质最低**（0 最高、3 最低）。
                # 验收读它回答"单位多的时候画质到底降没降"。
                "quality_tier_last": int(self._quality_tier[-1]) if self._quality_tier else None,
                "quality_tier_max": int(max(self._quality_tier)) if self._quality_tier else None,
                "quality_scale_last": (round(self._quality_scale[-1], 2)
                                       if self._quality_scale else None),
                "snapshot_age_samples": len(ages),
                "snapshot_age_unknown": self.age_unknown,
                "snapshot_age_p50": _percentile(ages, 0.5),
                "snapshot_age_p95": _percentile(ages, 0.95),
                "snapshot_age_max": max(ages) if ages else 0.0,
                "event_latency_p50": _percentile(latencies, 0.5),
                "event_latency_p95": _percentile(latencies, 0.95),
                "event_latency_max": max(latencies) if latencies else 0.0,
                "queued_snapshots": len(self._snapshots),
                "pending_events": len(self._events),
                "event_seq": self._since_seq,
                "consumed_seq": self._consumed_seq,
            }


#: 快速事件 → 能证明"命令已生效"的映射（**故意保守**）。
#: 采集/移动不在这里：工人采集不产生事件、移动到位需要订单状态（当前观测没有），
#: 按计划纪律"到达只表示移动段完成"，宁可标未证明，也不把"发了"当"生效"。
EFFECT_EVENTS: Dict[str, tuple] = {
    "produce": ("production_started",),
    "build": ("construction_done",),
    "attack": ("damage",),
}
