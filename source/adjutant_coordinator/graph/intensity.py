# -*- coding: utf-8 -*-
"""副官强度等级（保守 / 标准 / 激进）：等级 → 规则地板参数的**唯一实现**。

由来（2026-09-15 用户要求）：面板上要有"AI 副官的 3 个强度等级"，而按钮必须真的改变
玩法，不能是假按钮。强度只能落在**规则地板**上才可验证（模型只负责选意图，不保证数值
口径），所以"等级 → 参数"的映射单点定义在这里：

- ``army_threshold``：出击/推进所需的作战单位数。``graph/campaign.py`` 建主线时写进
  ``campaign_state["army_threshold"]``，被 ``decision_map.PRECONDITIONS`` 的
  ``combat_ready`` / ``below_army``、``campaign`` 的 M03 证据与 ``squad_min`` 共用。

不变式（别破坏）：
1. **默认 standard 必须等于历史行为**（阈值 2）。不带 ``--intensity`` 启动的 runner
   与改造前逐字节同行为 —— 这是"不把副官链路搞坏"的底线，守门见
   ``tests/test_intensity.py``。
2. 等级名 / 标签 / 参数只在本文件出现：面板按钮（GDScript）、runner 参数、规则参数
   都从这里取，**不许在别处再写一份映射**（历史事故全是"同一个常量两处各自定义"）。
3. 非法 / 空值一律回落 standard，永不抛错 —— 强度是玩家侧开关，不能因为一个命令行
   拼写把 runner 起不来。
"""
from __future__ import annotations

from typing import Any, Dict, Tuple

LEVEL_CONSERVATIVE = "conservative"
LEVEL_STANDARD = "standard"
LEVEL_AGGRESSIVE = "aggressive"

#: UI 顺序（面板三个按钮从左到右）；也是 `--intensity` 的合法取值。
LEVELS: Tuple[str, ...] = (LEVEL_CONSERVATIVE, LEVEL_STANDARD, LEVEL_AGGRESSIVE)

#: 等级 → 参数。`army_threshold` 是**唯一**当前生效的规则地板参数。
PROFILES: Dict[str, Dict[str, Any]] = {
    LEVEL_CONSERVATIVE: {
        "label": "保守",
        "army_threshold": 4,
        "hint": "攒够 4 个作战单位才出击，先站稳再扩张。",
    },
    LEVEL_STANDARD: {
        "label": "标准",
        "army_threshold": 2,
        "hint": "默认节奏：2 个作战单位即可压制/推进。",
    },
    LEVEL_AGGRESSIVE: {
        "label": "激进",
        "army_threshold": 1,
        "hint": "1 个作战单位就出击骚扰，扩张更积极。",
    },
}

#: 本进程当前生效的等级。runner 一进程一局，启动时 `set_active()` 一次即可；
#: checkpoint 里持久生效的等级记在 `campaign_state["intensity"]`（留档可查）。
_active: str = LEVEL_STANDARD


def normalize(level: Any) -> str:
    """把任意输入规整成合法等级；非法/空值回落 standard（不抛错）。"""
    text = str(level or "").strip().lower()
    return text if text in PROFILES else LEVEL_STANDARD


def set_active(level: Any) -> str:
    """设定本进程生效的强度等级，返回实际生效值。"""
    global _active
    _active = normalize(level)
    return _active


def active() -> str:
    return _active


def label(level: Any = None) -> str:
    return str(PROFILES[normalize(_active if level is None else level)]["label"])


def hint(level: Any = None) -> str:
    return str(PROFILES[normalize(_active if level is None else level)]["hint"])


def army_threshold(level: Any = None) -> int:
    """出击阈值。默认读当前生效等级，也可显式问某个等级（面板/测试用）。"""
    return int(PROFILES[normalize(_active if level is None else level)]["army_threshold"])


def describe(level: Any = None) -> Dict[str, Any]:
    """给日志/留档用的完整描述（runner start 事件、campaign 快照）。"""
    key = normalize(_active if level is None else level)
    profile = PROFILES[key]
    return {
        "level": key,
        "label": str(profile["label"]),
        "army_threshold": int(profile["army_threshold"]),
        "hint": str(profile["hint"]),
    }


def reset_for_tests() -> str:
    """把进程内生效等级还原成默认值（测试用，避免用例之间互相污染）。"""
    return set_active(LEVEL_STANDARD)
