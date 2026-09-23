# -*- coding: utf-8 -*-
"""System 1 决策引擎（Laya）的进程内 provider —— 新增的一层，不改动现有链路。

定位（`docs/程序文档/AI副官_Laya混合架构_执行提示词_2026-09-20.md` §P1）：

- Laya 是**判别式**决策引擎（非自回归、无幻觉），必须在 Python 进程内直接
  `import laya`（**不能**走 Ollama 的 chat 接口——它不是生成模型）；
- 本模块是它与副官指挥链之间的**唯一接触面**：懒加载单例 + `predict` / `available`；
- **全部异常自吞并返回 None**：Laya 依赖缺失、模型下载失败、显存不足、输出异常……
  任何失败都只意味着"这一拍不走 Laya"，由调用方按既有 Fallback 顺序回退
  （Laya → 现有 2B 链路 → 规则中台），**绝不允许拖垮整条指挥链**；
- 依赖/网络缺失时有明确结构化日志（`event=laya_*`，沿用 `logger.log(event, **fields)`
  约定；logger 缺席时静默——与 `nodes.GraphServices.log` 的失败方向一致）。

开关（环境变量，默认 `model` = 现状不变，必须显式开启）：

    AIRTS_S1_BACKEND = laya | model | off      # 默认 model
    AIRTS_LAYA_MODEL = convaiinnovations/laya  # 模型仓库
    AIRTS_LAYA_SUBFOLDER = multilingual        # 中文必须用多语言版（英文 base 会"自信地错"）
    AIRTS_LAYA_DEVICE =                        # 留空=自动（cuda→mps→cpu）

线程纪律：`predict` 不是为并发设计的（一次前向批处理全部问题）。调用方
（`PydanticAITaskPatchAgent`）已有"同一 Agent 至多一个在途"的标记，provider 内不再
重复加锁——但 `available()` 的懒加载用锁保证只 load 一次。
"""

from __future__ import annotations

import os
import threading
import time
from collections import deque
from typing import Any, Deque, Dict, Optional

# ---------------- 开关与配置 ----------------

ENV_S1_BACKEND = "AIRTS_S1_BACKEND"
ENV_LAYA_MODEL = "AIRTS_LAYA_MODEL"
ENV_LAYA_SUBFOLDER = "AIRTS_LAYA_SUBFOLDER"
ENV_LAYA_DEVICE = "AIRTS_LAYA_DEVICE"
ENV_LAYA_TIMEOUT = "AIRTS_LAYA_TIMEOUT_SECONDS"
ENV_LAYA_DEMOS = "AIRTS_LAYA_DEMOS"
#: 健康熔断（2026-09-21 用户要求"laya 不 healthy 就用 2B 兜底"的工程化）：
#: 单次超时只是"这一拍回退"；若 Laya **持续**不健康（弱 GPU/重争用下每拍都超 2s），
#: 每拍白等 2s 再走 2B 是纯浪费。熔断器按最近窗口的失败率直接断开，
#: 冷却后半开重探，探成功即恢复。
ENV_LAYA_CIRCUIT = "AIRTS_LAYA_CIRCUIT"
ENV_LAYA_CIRCUIT_WINDOW = "AIRTS_LAYA_CIRCUIT_WINDOW"
ENV_LAYA_CIRCUIT_MAX_FAIL_RATE = "AIRTS_LAYA_CIRCUIT_MAX_FAIL_RATE"
ENV_LAYA_CIRCUIT_COOLDOWN_S = "AIRTS_LAYA_CIRCUIT_COOLDOWN_S"

BACKEND_LAYA = "laya"
BACKEND_MODEL = "model"
BACKEND_OFF = "off"
VALID_BACKENDS = (BACKEND_LAYA, BACKEND_MODEL, BACKEND_OFF)
#: 默认 `model`：保证现状不变，Laya 必须显式开启（硬约束 §2）。
DEFAULT_BACKEND = BACKEND_MODEL

DEFAULT_LAYA_MODEL = "convaiinnovations/laya"
#: 中文字段必须用多语言版（提示词 §1.4 已知限制 4）。
DEFAULT_LAYA_SUBFOLDER = "multilingual"

#: 熔断默认参数（可用环境变量覆盖）。
DEFAULT_CIRCUIT_WINDOW = 10            # 统计窗口（最近 N 次决策）
DEFAULT_CIRCUIT_MIN_SAMPLES = 5        # 窗口内至少这么多次才判定（避免 1 次失败就断）
DEFAULT_CIRCUIT_MAX_FAIL_RATE = 0.5    # 失败率超过它就断开
DEFAULT_CIRCUIT_COOLDOWN_S = 60.0      # 断开后的基础冷却；连续断开每次翻倍（上限 8 倍）

INSTALL_HINT = ("Laya 未安装或模型不可用：请在副官虚拟环境执行 "
                "pip install laya（首次加载会自动下载多语言版模型，"
                "需网络或代理）；当前链路按既有 Fallback 顺序继续。")


def _env_float(name: str, default: float) -> float:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value


def _env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return value


def circuit_enabled() -> bool:
    """熔断器总开关（默认开；`AIRTS_LAYA_CIRCUIT=0` 关闭）。"""
    return (os.environ.get(ENV_LAYA_CIRCUIT, "1").strip()
            not in ("0", "false", "off", "no"))


def s1_backend() -> str:
    """当前 System 1 后端（非法值按默认 `model` 处理，不抛异常）。"""
    value = (os.environ.get(ENV_S1_BACKEND) or "").strip().lower()
    return value if value in VALID_BACKENDS else DEFAULT_BACKEND


#: Laya 单次调用的超时预算（秒）。P0 实测（RTX 3080 Ti，120 个真实帧）：
#: 一次前向 p50 47~63ms / p95 63~83ms / max 122ms —— 2 秒已是 15 倍余量；
#: 超时即按 Fallback 顺序退回现有模型链路，绝不把指挥链拖死。
DEFAULT_LAYA_TIMEOUT_SECONDS = 2.0


def laya_timeout() -> float:
    """Laya 单次调用超时（秒；非法值回落默认，不抛异常）。"""
    raw = (os.environ.get(ENV_LAYA_TIMEOUT) or "").strip()
    if not raw:
        return DEFAULT_LAYA_TIMEOUT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_LAYA_TIMEOUT_SECONDS
    return value if value > 0 else DEFAULT_LAYA_TIMEOUT_SECONDS


class LayaProvider:
    """Laya 的懒加载单例包装：`available()` / `predict()`，异常全部自吞。

    失败语义（与提示词 §P1 一致）：
    - `available()` False = 依赖缺失 / 加载失败 / 上次加载已失败（**不反复重试**，
      避免每拍都尝试下载模型把链路拖死）；
    - `predict()` 返回 None = 这一拍不采信 Laya（调用方回退，不抛异常）；
    - 每次失败都留一条结构化日志（`event=laya_*`），缺 logger 时只更新
      `last_error` / `last_event` 供测试与诊断读取。
    """

    def __init__(self, logger: Any = None, model: str = "",
                 subfolder: str = "", device: Optional[str] = None) -> None:
        self.logger = logger
        self._model = model or os.environ.get(ENV_LAYA_MODEL) or DEFAULT_LAYA_MODEL
        self._subfolder = (subfolder
                           or os.environ.get(ENV_LAYA_SUBFOLDER)
                           or DEFAULT_LAYA_SUBFOLDER)
        self._device = device if device is not None else (
            os.environ.get(ENV_LAYA_DEVICE) or None)
        self._agent: Any = None
        self._lock = threading.Lock()
        self._load_failed = False
        #: 最近一次失败原因（不含凭证；供诊断/测试断言）。
        self.last_error = ""
        #: 最近一次事件名（如 `laya_unavailable` / `laya_predict_failed`）。
        self.last_event = ""
        #: 成功加载后的设备（诊断用；未加载为 ""）。
        self.device = ""
        # ---------------- 健康熔断状态 ----------------
        #: 最近窗口内的决策结果（"ok"/"timeout"/"rejected"/"unavailable"）。
        self._outcomes: Deque[str] = deque(maxlen=max(1, _env_int(
            ENV_LAYA_CIRCUIT_WINDOW, DEFAULT_CIRCUIT_WINDOW)))
        #: 熔断状态：closed=正常 / open=断开（直接走 2B）/ half_open=冷却到期试探。
        self._circuit = "closed"
        self._circuit_opened_at = 0.0
        self._circuit_consecutive_opens = 0
        self._circuit_lock = threading.Lock()

    # ---------------- 内部 ----------------

    def _log(self, event: str, **fields: Any) -> None:
        self.last_event = event
        if self.logger is None:
            return
        try:
            self.logger.log(event, **fields)
        except Exception:  # noqa: BLE001 —— 日志失败不改变决策路径。
            pass

    # ---------------- 健康熔断 ----------------

    def _circuit_cooldown_s(self) -> float:
        base = _env_float(ENV_LAYA_CIRCUIT_COOLDOWN_S, DEFAULT_CIRCUIT_COOLDOWN_S)
        # 连续断开每次翻倍（60→120→240…，上限 8 倍）：持续不健康时尽快"别再交学费"。
        factor = min(8, 2 ** max(0, self._circuit_consecutive_opens - 1))
        return base * factor

    def _circuit_allows_call(self) -> bool:
        """此刻是否允许调 Laya（熔断断开期内直接拒绝，冷却过半开试探）。"""
        if not circuit_enabled():
            return True
        with self._circuit_lock:
            if self._circuit != "open":
                return True
            if time.monotonic() - self._circuit_opened_at >= self._circuit_cooldown_s():
                self._circuit = "half_open"     # 冷却到期：放一次试探
                self._log("laya_circuit_half_open", status="probing")
                return True
            return False

    def note_decision(self, outcome: str) -> None:
        """记录一次 Laya 决策的结果，驱动熔断状态机。

        `outcome` ∈ {"ok", "timeout", "rejected", "unavailable"}：
        - ok         ：拿到可用答案（至少一行通过既有校验）；
        - timeout    ：超过 laya_timeout() 预算（调用方在 agent 侧判定）；
        - rejected   ：有答案但全部行被既有校验拒（质量信号，等同不健康）；
        - unavailable：predict 返回 None / 模型不可用。
        只有 timeout/rejected/unavailable 计失败。
        """
        if not circuit_enabled():
            return
        kind = str(outcome)
        with self._circuit_lock:
            self._outcomes.append(kind)
            if self._circuit == "half_open":
                if kind == "ok":
                    self._circuit = "closed"
                    self._circuit_consecutive_opens = 0
                    self._outcomes.clear()
                    self._log("laya_circuit_close", status="recovered")
                else:
                    self._open_circuit_locked()
                return
            if self._circuit == "open":
                return
            samples = len(self._outcomes)
            if samples < DEFAULT_CIRCUIT_MIN_SAMPLES:
                return
            failures = sum(1 for item in self._outcomes if item != "ok")
            rate = failures / float(samples)
            if rate > _env_float(ENV_LAYA_CIRCUIT_MAX_FAIL_RATE,
                                 DEFAULT_CIRCUIT_MAX_FAIL_RATE):
                self._open_circuit_locked()

    def _open_circuit_locked(self) -> None:
        """断开熔断（调用方须已持有 _circuit_lock）。"""
        self._circuit = "open"
        self._circuit_opened_at = time.monotonic()
        self._circuit_consecutive_opens += 1
        self.last_error = ("Laya 健康熔断：最近 %d 次决策失败率超限，"
                           "断开 %.0fs（第 %d 次连续断开）"
                           % (len(self._outcomes), self._circuit_cooldown_s(),
                              self._circuit_consecutive_opens))
        self._log("laya_circuit_open", status="open",
                  consecutive_opens=self._circuit_consecutive_opens,
                  cooldown_s=round(self._circuit_cooldown_s(), 1),
                  window=len(self._outcomes))

    def circuit_state(self) -> Dict[str, Any]:
        """熔断状态诊断视图（供 describe/测试）。"""
        with self._circuit_lock:
            failures = sum(1 for item in self._outcomes if item != "ok")
            return {
                "enabled": circuit_enabled(),
                "state": self._circuit,
                "window": len(self._outcomes),
                "failures": failures,
                "consecutive_opens": self._circuit_consecutive_opens,
                "cooldown_s": round(self._circuit_cooldown_s(), 1),
            }

    def _import_agent(self) -> Any:
        """进程内导入 laya 并加载模型（唯一允许触碰 laya 的地方）。"""
        import importlib

        laya = importlib.import_module("laya")
        # subfolder 只对 HF 仓库 id 有意义；本地 checkpoint 目录（自对局微调产物）
        # 本身就是模型根，再传 subfolder 会 FileNotFoundError（2026-09-21 实测）。
        subfolder = None if os.path.isdir(self._model) else self._subfolder
        return laya.load(self._model, subfolder=subfolder,
                         device=self._device)

    # ---------------- 对外 ----------------

    def available(self) -> bool:
        """Laya 是否可用（依赖已装且模型已加载/可加载）。

        懒加载：首次调用才真正 import + load（避免拖慢启动）。加载失败记一次，
        后续直接 False——不在每拍重试下载。
        """
        if self._agent is not None:
            return True
        with self._lock:
            if self._agent is not None:
                return True
            if self._load_failed:
                return False
            try:
                agent = self._import_agent()
            except Exception as exc:  # noqa: BLE001 —— 任何依赖/网络/模型错误都自吞。
                self._load_failed = True
                self.last_error = "%s: %s" % (type(exc).__name__, exc)
                self._log("laya_unavailable", status="unavailable",
                          reason=self.last_error[:200], hint=INSTALL_HINT)
                return False
            self._agent = agent
            self.device = str(getattr(agent, "device", "") or "")
            self._log("laya_loaded", status="ready", device=self.device,
                      model=self._model, subfolder=self._subfolder)
            return True

    def predict(self, state: Any, questions: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """一次前向回答全部问题；任何失败返回 None（调用方回退，不抛异常）。

        熔断断开期内**直接返回 None**（不再调用、不再白等超时）——持续不健康时
        每拍省下最多 laya_timeout() 秒的学费，直接走 2B 兜底。
        """
        if not isinstance(questions, dict) or not questions:
            self.last_error = "questions 必须是非空 dict"
            self._log("laya_predict_failed", status="invalid",
                      reason=self.last_error)
            return None
        if not self._circuit_allows_call():
            # 熔断断开中：这一拍不调 Laya（事件在断开时已记录过一次）。
            self.last_error = self.last_error or "Laya 健康熔断断开中"
            return None
        if not self.available():
            return None
        try:
            result = self._agent.predict(state, questions)
        except Exception as exc:  # noqa: BLE001 —— OOM/输入异常/驱动错误都自吞。
            self.last_error = "%s: %s" % (type(exc).__name__, exc)
            self._log("laya_predict_failed", status="failed",
                      reason=self.last_error[:200])
            return None
        if not isinstance(result, dict):
            self.last_error = "predict 返回了非 dict：%s" % type(result).__name__
            self._log("laya_predict_failed", status="invalid",
                      reason=self.last_error)
            return None
        answers = result.get("answers")
        if not isinstance(answers, dict) or not answers:
            self.last_error = "predict 没有返回 answers"
            self._log("laya_predict_failed", status="empty",
                      reason=self.last_error)
            return None
        return answers

    def describe(self) -> Dict[str, Any]:
        """诊断视图（不含凭证；模型体积/路径属公开信息）。"""
        view = {
            "backend": s1_backend(),
            "model": self._model,
            "subfolder": self._subfolder,
            "device": self.device,
            "loaded": self._agent is not None,
            "load_failed": self._load_failed,
            "last_event": self.last_event,
            "last_error": self.last_error[:200],
        }
        view.update(self.circuit_state())
        return view


# ---------------- 进程内单例 ----------------

_PROVIDER: Optional[LayaProvider] = None
_PROVIDER_LOCK = threading.Lock()


def get_provider(logger: Any = None) -> LayaProvider:
    """进程内单例（首次调用不加载模型；`available()` 才懒加载）。"""
    global _PROVIDER
    with _PROVIDER_LOCK:
        if _PROVIDER is None:
            _PROVIDER = LayaProvider(logger=logger)
        elif logger is not None and _PROVIDER.logger is None:
            _PROVIDER.logger = logger
        return _PROVIDER


def reset_provider() -> None:
    """测试用：丢弃单例（不卸载已加载的模型，进程内引用由 GC 回收）。"""
    global _PROVIDER
    with _PROVIDER_LOCK:
        _PROVIDER = None


# ---------------- 少样本示例库 ----------------
# P0 实测（120 个真实决策点，多语言版）：**零样本一致率 0%**（恒定选同一个技能），
# 带项目自己的历史决策样例后 54%~100%（配置敏感）——模型卡也自述"零样本接近随机"。
# 因此生产路径默认从 `AIRTS_LAYA_DEMOS`（JSONL：每行 {"state":..., "rows":[[a,s,t,p]]}）
# 读一份少样本库；缺省为空（= 零样本，已知不可用，仅作对照）。

_DEMOS_CACHE: Dict[str, List[Dict[str, Any]]] = {}
_DEMOS_LOCK = threading.Lock()


def load_demos(path: Optional[str] = None) -> List[Dict[str, Any]]:
    """读少样本库（进程内缓存；坏行跳过，读取失败返回空列表——不抛异常）。"""
    target = path if path is not None else (os.environ.get(ENV_LAYA_DEMOS) or "")
    if not target:
        return []
    with _DEMOS_LOCK:
        if target in _DEMOS_CACHE:
            return _DEMOS_CACHE[target]
    out: List[Dict[str, Any]] = []
    try:
        import json

        with open(target, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict) and item.get("rows"):
                    out.append(item)
    except OSError:
        out = []
    with _DEMOS_LOCK:
        _DEMOS_CACHE[target] = out
    return out


def reset_demos_cache() -> None:
    """测试用：清空少样本库缓存。"""
    with _DEMOS_LOCK:
        _DEMOS_CACHE.clear()


# ---------------- 训练数据采集（自对局迭代用） ----------------
# 用户 2026-09-21：用"副官 vs 电脑"对局迭代训练 Laya。本采集器把每次 Laya 决策
# 落成一条 JSONL：state + questions（选项集）+ Laya 的选择 + 置信度 + 既有校验
# 结果 + **教师标签**（最终实际下发的那一行——Laya 自己被拒时来自 2B/规则回退）。
# 之后 `deploy/train_laya.py` 用它做监督微调。
ENV_LAYA_DATASET = "AIRTS_LAYA_DATASET"
_DATASET_LOCK = threading.Lock()


def dataset_path() -> str:
    return (os.environ.get(ENV_LAYA_DATASET) or "").strip()


def record_dataset(record: Dict[str, Any]) -> bool:
    """追加一条训练样本（JSONL）。未配置路径 / 写失败都静默返回 False。"""
    path = dataset_path()
    if not path:
        return False
    try:
        import json

        line = json.dumps(record, ensure_ascii=False, sort_keys=True)
        with _DATASET_LOCK:
            os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        return True
    except Exception:  # noqa: BLE001 —— 采集失败绝不影响指挥链
        return False


def question_view(questions: Dict[str, Any]) -> Dict[str, Any]:
    """问题集的可序列化视图。

    **必须存完整 criteria**（选项键 → 描述）：训练时 `build_sequence` 把选项描述
    文本编进输入序列，只存键会改变输入分布、让微调与推理不同源。
    """
    view: Dict[str, Any] = {}
    for qid, qdef in (questions or {}).items():
        if not isinstance(qdef, dict):
            continue
        entry: Dict[str, Any] = {"type": str(qdef.get("type", "")),
                                 "instructions": str(qdef.get("instructions", ""))[:200]}
        criteria = qdef.get("criteria")
        if isinstance(criteria, dict):
            entry["criteria"] = {str(k): str(v)[:64] for k, v in criteria.items()}
        elif isinstance(criteria, list):
            entry["criteria"] = [str(x) for x in criteria]
        view[str(qid)] = entry
    return view


def answer_view(answers: Any) -> Dict[str, Any]:
    """Laya 答案的可序列化视图（选择 + 置信度）。"""
    out: Dict[str, Any] = {}
    for qid, entry in (answers or {}).items():
        if not isinstance(entry, dict):
            continue
        item: Dict[str, Any] = {}
        if "choice" in entry:
            item["choice"] = str(entry.get("choice") or "")
        if "score" in entry:
            item["score"] = entry.get("score")
        if "noul" in entry:
            item["noul"] = entry.get("noul")
        if entry.get("confidence") is not None:
            item["confidence"] = entry.get("confidence")
        out[str(qid)] = item
    return out


def label_from_decode(decode: Any, *, branch: str = "") -> Dict[str, Any]:
    """从解码结果提取教师标签（最终实际下发的前几行四列 + 主线分支）。

    返回 `{"rows": [[actor, skill, target, params], ...], "branch": "D3"}`；
    行空表示本轮无下发；`branch` 为当时主线实际沿用的节点（分支问题的教师标签，
    取自帧的 campaign 上下文，不是模型自述——避免“自己教自己”）。
    """
    rows: List[List[str]] = []
    for modification in getattr(decode, "modifications", None) or []:
        rows.append([str(modification.actor_ref), str(modification.skill),
                     str(modification.target_ref), str(modification.params_ref)])
    label: Dict[str, Any] = {"rows": rows[:8]}
    if branch:
        label["branch"] = str(branch)
    return label
