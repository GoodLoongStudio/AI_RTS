# -*- coding: utf-8 -*-
"""**图通道声明守门**：`AdjutantGraphState` 的每个字段都必须在 `GraphStateDict` 里声明。

## 为什么必须有（2026-09-14 血泪，一次性解释了四个"讲不通"的现象）
LangGraph 引擎在图入口用 `graph._cleaned()` 把状态**过滤成只含声明过的通道**。漏声明一个字段
→ 它每轮被静默丢掉，表现为"功能写了、单测也过、真机每轮归零"：

| 漏声明的字段 | 真机表现（都被误判过） |
|---|---|
| `production_ledger` | 归档里"生产样本 0"（被当成"生产没发生"） |
| `army_cap` | 兵力上限留档永远空（拦截其实有效，因为每轮从观测重算） |
| `combat_types` | 作战单位口径表恒空（**曾被误判成"验收局规则视图没有 capabilities"**） |
| `unattackable_targets` / `enemy_types` | "打不了的目标"记忆每轮清空 → **同一条注定被拒的命令每轮重发**（`Unit_43` 被拒 10 次、一局 124 条被拒命令的真因） |

纪律：**新增状态字段 = 同时声明通道**。这条测试就是那道防线（漏一个立刻红灯）。
"""

import io
import os
import re
import sys
import unittest
from dataclasses import fields

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

from adjutant_coordinator.graph.graph import GraphStateDict  # noqa: E402
from adjutant_coordinator.graph.state import AdjutantGraphState  # noqa: E402

GRAPH_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "graph")
#: 节点里**字面量**写入的状态键（`state["x"] = …` / `state.setdefault("x", …)`）。
_STATE_WRITE = re.compile(r'state\[[\'"]([A-Za-z_][\w]*)[\'"]\]\s*='
                          r'|state\.setdefault\([\'"]([A-Za-z_][\w]*)[\'"]')
#: 允许"写了但不需要跨轮"的键（每一条都要说清理由）。
TRANSIENT_STATE_KEYS = {
    # 本轮服务到的线路：**只在同一轮写、没人读**（历史遗留；跨轮无意义）。
    "lanes_served_this_tick",
}


class GraphStateChannelTest(unittest.TestCase):
    def test_every_state_field_is_declared_as_a_channel(self):
        declared = set(GraphStateDict.__annotations__)
        missing = [field.name for field in fields(AdjutantGraphState)
                   if field.name not in declared]
        self.assertEqual(missing, [],
                         "这些状态字段没在 `GraphStateDict` 里声明 → LangGraph 每轮会把它们"
                         "静默丢掉（真机表现：功能写了但每轮归零）：%s" % missing)

    #: **故意只做"节点间临时交接"的通道**（不是持久状态字段，所以不在 dataclass 里）。
    #: 每一条都要说清"为什么它不需要进 checkpoint"，否则下一个人分不清"临时"与"忘了声明"。
    TRANSIENT_CHANNELS = {
        # 本轮异步决策结果的同 tick 交接键（结果落地后就被消费）。
        "patch_ready",
        # 规则中台本轮是否已生成 baseline 的幂等闸（每轮重算即可，不必持久）。
        "baseline_tick",
        # 意图来源旁路账本 `{intent_id: baseline|behavior_tree|model}`（供归档区分来源）。
        "intent_origin",
        # 地图边界：每轮由 `op=strategic` 写入（**每轮都新鲜**，持久反而会用到过期值）。
        "map_bounds",
    }

    def test_channels_do_not_declare_unknown_fields(self):
        """反向也要查：通道里声明了、dataclass 里没有、又不在临时清单里的键 = 死键。"""
        names = {field.name for field in fields(AdjutantGraphState)}
        extra = sorted(key for key in GraphStateDict.__annotations__
                       if key not in names and key not in self.TRANSIENT_CHANNELS)
        self.assertEqual(extra, [],
                         "通道里声明了既不是状态字段、也不在临时清单里的键：%s" % extra)

    def test_every_literal_state_write_is_declared(self):
        """**静态扫描**：节点里 `state["x"] = …` 写到的字面量键，必须跨轮能活下来。

        【为什么必须扫（迭代2 真机）】dataclass 字段守门只挡住"字段级"漏声明；
        还有一整类**纯动态键**（只在节点里写、从没进 dataclass）同样每轮归零。
        实测症状（it1 局）：同一个坏建造点被拒 **12 次**（`spot_rejected.count` 恒 1，
        永远到不了"3 次拉黑"的阈值）、已下发指纹清空（命令可每轮重发）、拥塞退避失效。
        """
        declared = set(GraphStateDict.__annotations__)
        names = {field.name for field in fields(AdjutantGraphState)}
        offenders = {}
        for file_name in sorted(os.listdir(GRAPH_DIR)):
            if not file_name.endswith(".py"):
                continue
            text = io.open(os.path.join(GRAPH_DIR, file_name),
                           encoding="utf-8", errors="replace").read()
            for raw_line in text.splitlines():
                # 注释里的示例（本仓注释大量引用 `state["x"] = …`）不算写入：
                # 在第一个 `#` 处截断再匹配（够用且不会把文档字串误判成代码）。
                code_part = raw_line.split("#", 1)[0]
                for match in _STATE_WRITE.finditer(code_part):
                    key = match.group(1) or match.group(2)
                    if key in declared or key in TRANSIENT_STATE_KEYS:
                        continue
                    offenders.setdefault(key, set()).add(file_name)
        self.assertEqual(
            {key: sorted(files) for key, files in offenders.items()}, {},
            "这些键写了却没声明成图通道/状态字段 → 每轮归零（要么加进 GraphStateDict+"
            "AdjutantGraphState，要么写进 TRANSIENT_STATE_KEYS 并说明理由）")

    def test_memory_and_cap_fields_are_channels(self):
        """点名钉住本次事故的五个字段（防有人"顺手"删掉注释里的说明后又被删掉声明）。"""
        for name in ("production_ledger", "army_cap", "combat_types",
                     "unattackable_targets", "enemy_types"):
            self.assertIn(name, GraphStateDict.__annotations__,
                          "%s 必须是图通道（漏了就会每轮归零）" % name)


if __name__ == "__main__":
    unittest.main()
