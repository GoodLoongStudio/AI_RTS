# 阶段 C3u：每轮增量账终于落盘 —— 以及它一路踩的坑（round-25）

日期：2026-10-07。状态：**needs-review —— 观测修通了（拖了五轮的遗留项），
但发现同 tick 重复行的新问题；本轮不改任何调度行为。**

上位：[C3t 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3t-revalidation.md)。

---

## 1. 为什么这条观测拖了五轮

round-20 就把"每轮 `planned`/`invalidations`/下发批次数落账"列为遗留项，
round-22/23/24 都提到它，直到本轮才真正落盘。原因是它连续踩了**三个**不同的坑，
每一个都表现为"代码看起来对、数据就是没有"：

| 版本 | 做法 | 为什么没落盘 |
|---|---|---|
| v1 | 在 `agent_runner` 的 tick 记录里加 `round_delta`，快照放**模块级字典**、按 `id(state)` 索引 | `TickResult.state` 是 `summary()` 生成的**新字典**，且 runner 每轮从检查点重建状态对象 ⇒ `id()` 每次都不同 ⇒ **永远拿不到"上一轮"** |
| v2 | 快照改存 `state["movement_stats_prev"]`（仍在 runner 里算） | 写进的是 `summary()` 的**视图快照**，回不到真实状态 |
| v3 | 把计算挪进图内（`movement.note_round_delta`），加进 `to_dict`/`from_dict`/`summary`/`GraphStateDict` | **仍然没有** —— 因为我把键加到了**另一个** tick 记录上，而 `rounds.jsonl` 是 `_archive_round` **单独构造**的 |

**v3 的坑最值得记**：我改了 `run_tick` 里那条 tick 记录，
而 `rounds.jsonl` 实际由 `_archive_round(tick, obs, result, metrics)` 写。
**同一个文件里有两处"tick 记录"**，我改错了那一处。
这是"埋点读错路径"这一类错误的**第三次**（前两次：`continuity_supervision`
没进 `summary`、`depleted_resources` 没进 `to_dict`）。

**共同病根**：把需要跨轮/跨层活下来的东西，放在**它活不下来的地方**；
或者**改了数据源，却以为改的是消费端**。

## 2. 现在的状态：通了，并且对得上账

`archive_62213f9e`（live2，`run_health` = OK / 0 tick 错误 / 文件齐全）：

```
有增量的轮数 = 248
  planned                   合计 1941   （checkpoint 累计 1941 ✔）
  allowed                   合计 1892   （1892 ✔）
  arrival_events             合计  917   （917 ✔）
  arrival_released_intents   合计  730   （730 ✔）
  invalidations              合计  128   （128 ✔）
  arrival_no_route           合计  109   （109 ✔）
  arrival_marker_kept        合计   27
  arrival_deduped            合计    1
```

**逐项与检查点里的累计值逐一相等** ⇒ 增量账**既完整又不重复**。

顺带确认到达释放修复在生产里持续生效：`arrival_released_intents = 730`。

## 3. ~~新发现的问题~~ 已定论：同 tick 多行 = 同一 tick 内的多轮决策

样例里出现（t=693 连续三条，且三条都带增量）：

```
t=693  {'planned': 1, 'allowed': 1}
t=693  {'planned': 1, 'allowed': 1}
t=693  {'planned': 1, 'allowed': 1}
```

**本轮内已量清**（`archive_62213f9e`）：

```
rounds.jsonl 行数=259  不同 tick=179  平均每 tick 1.45 行
每 tick 行数分布: {1: 137, 2: 21, 3: 4, 4: 17}
```

⇒ 一个 `server_tick` 会写 **1~4 行**，因为**决策轮比服务 tick 快**
（`coord_hz` 一 tick 内跑多轮）。每一行是**那一轮的增量**，所以：

- **写入端不用改**（逐轮增量本身是对的，信息量比按 tick 汇总更大）；
- **消费端必须按 tick 求和**：要"每 tick 的增量"就把同 tick 的各行相加。

这条口径现在写清楚了，**下一轮可以直接拿它判共享下发预算**，不再有"口径不清就下结论"
的风险（round-20/22 各吃过一次）。

## 4. 本轮改动

| 文件 | 改动 |
|---|---|
| [movement.py](source/adjutant_coordinator/graph/movement.py) | 新增 `note_round_delta(state)`（**图内**算增量，快照 `movement_stats_snapshot` 随检查点持久化）、`ROUND_DELTA_KEYS`、`ROUND_DELTA_SNAPSHOT_KEY` |
| [nodes.py](source/adjutant_coordinator/graph/nodes.py) | `node_arbitrate_intent` 末尾调用 `note_round_delta`（本轮生成/规划都已发生，增量才完整） |
| [state.py](source/adjutant_coordinator/graph/state.py) | 新增 `movement_round_delta` / `movement_stats_snapshot` 字段 + `to_dict` / `from_dict` / `summary` 三处都补 |
| [graph.py](source/adjutant_coordinator/graph/graph.py) | `GraphStateDict` 增补两个键（通道声明契约） |
| [agent_runner.py](source/adjutant_coordinator/deploy/agent_runner.py) | `_movement_delta` 改为**只读转发** `state["movement_round_delta"]`；**在 `_archive_round` 里**（不是另一处 tick 记录）写入 `round_delta` |
| 测试 | `test_roundtrip_preserves_movement_round_delta`（增量 + 基线快照 round-trip，并断言**必须进 `summary`**） |

## 5. 下一轮（round-26）

1. **用它判共享下发预算**：按 tick 求和后，看重规划（`invalidations`）/到达释放
   （`arrival_released_intents`）多的轮，是否伴随**接续变慢**。
   这是 round-23/24 悬着的判断（到达释放到底是"少白挡"还是"多挤占"）。
2. 若确认"多挤占"：给到达释放配**释放但不立刻重规划**的节流，
   **不回退释放本身**（回退会让 round-23 修的结构性错误重现）。
3. ⚠ 仍**不许**动任何阈值。

## 6. 未验证 / 边界

- live2 是**单局**；门禁没在本轮重测（本轮只修观测）。
- §2 的"增量合计 == 检查点累计"是**完整性**证据（不丢不重）；但
  **"每轮增量"与"接续延迟"之间的相关性尚未分析** —— 那是下一轮的事。
- 本轮改动全是观测/状态持久化，**没有**改任何调度判断或阈值；
  新增两个状态字段已按 round-23 的教训同步补了 `to_dict`/`from_dict`/`summary`/
  `GraphStateDict` **四处**，并加 round-trip 测试。
- 流程上继续执行 round-24 的规定：每次跑完先 `run_health.py`（本轮两次均 OK）。
