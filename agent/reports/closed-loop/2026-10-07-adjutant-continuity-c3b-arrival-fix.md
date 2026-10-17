# 阶段 C3 续：到达记账修复 + 门禁尾巴的重新定位（round-07）

日期：2026-10-07。状态：**needs-review —— 修掉一个真缺陷、证伪一条假设、把尾巴重新定位到游戏侧导航**。

上位：[C3 取证](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3-forensics.md)、
[C2 门禁](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c2-gate.md)。

---

## 1. 修掉一个真缺陷：到达事件被**永久键**吃掉

### 1.1 缺陷

[nodes.py](source/adjutant_coordinator/graph/nodes.py) 的到达去重原本用**永久键**：

```python
arrival_key = "%s|%s" % (unit, event.get("target") or [])
if arrival_key in seen_arrivals:      # seen_arrivals 是有界 list（保留最近 64 条）
    continue                          # ← 整段跳过：不 note_arrival、不做侦察段 COMPLETED
```

同一个单位**再次回到同一个目标点**时（工人在基地↔矿区之间往返，目标点每次相同），
第二次到达命中同一个 key → 被整段跳过。后果是**链条式**的：

```
到达不被记账 → 路线缓存不作废 → movement.unit_en_route 仍为真
  → rules_fallback._parallel_intents:  if _en_route(name): continue   ← 每轮跳过这个单位
  → 直到 HOP_HOLD_MAX_TICKS(1800 tick) 的第二道保险才放行
```

**实测量化**（对照档案 `archive_edf8bd9a`）：522 条 arrival 里 **48 条（9.2%）** 命中永久键；
工人 `Unit_19` 的 37 次到点里 **14 次**被吃掉。

### 1.2 修复

- 去重只挡"**同一条事件的重复投递**"：`unit|target` 键带**时间戳**，只在
  `ARRIVAL_DEDUP_TICKS = 60`（1 秒）内生效；过期键按窗口清理（有界，不再是长度 64 的 list）。
- 旧 checkpoint 里 `seen_arrivals` 是 list → **原地升级成 dict**，不丢历史。
- `note_arrival` 本身幂等（只作废路线 + 计一次数），重复调用无害。

守门测试（[test_graph_runtime_fake.py](source/adjutant_coordinator/tests/test_graph_runtime_fake.py) 的
`ArrivalDedupTest`，3 例，全绿）：
① **再次**到达同一个目标点必须仍作废路线（这一条直接复现旧 bug）；
② 同一条事件重复投递仍不许重复计数（保留原去重的理由）；
③ 去重表必须有界。

## 2. 但它**没有**改善门禁 —— 假设又被证伪（重要）

用**修好的产品代码**重跑同一套探针（`round-07/ab_fixed`，`match_id=1558a9ff`），
在**同一共同窗口** `tick 1028..11868` 内对照：

| 组 | 永久键命中率 | arrivals | 已接续 | p50 | **p95** | ≤1s 占比 | **combat p95** |
|---|---|---|---|---|---|---|---|
| 修复前 `ab_off` | 9.2% | 522 | 390 | 0.65s | **33.08s** | 60.8% | **33.08s** |
| 修复前 `ab_fine` | 10.5% | 648 | 516 | 0.88s | **31.78s** | 51.6% | **31.78s** |
| **修复后** `ab_fixed` | 8.7% | 839 | 741 | 1.57s | **32.38s** | 45.6% | **32.40s** |

（工具：[before_after.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-07/before_after.py)；
`dedup%` 是**按旧规则重算**的，所以三组可比 —— 修复后仍有 8.7% 的键碰撞，但它们
**不再被丢弃**，只是"1 秒内重复投递"才挡。）

⇒ **门禁仍 FAIL，p95 三次独立跑都钉在 31.8–33.1 秒。** 所以"到达被吃掉"虽然是真 bug，
**不是**那 33 秒的成因。到今天为止被证伪的假设已经有四条：

| # | 假设 | 证伪方式 |
|---|---|---|
| 1 | 监督层能修好接续 | C2 A/B：1350 次恢复只换 1.5 秒 |
| 2 | 整段停顿是全局卡住 | round-06：停顿窗口内每秒仍产出 5–14 条意图 |
| 3 | 线路饿死 | round-06：`lanes.interleave` 严格轮转，`blocked` 多为 0 |
| 4 | 到达被永久键吃掉导致 33 秒 | **round-07：修掉之后 p95 不动（33.08 → 32.38）** |

## 3. 尾巴重新定位：p95 数值**就是** `HOP_HOLD_MAX_TICKS`

三次独立跑的门禁 p95：**33.08 / 31.78 / 32.38 秒**。
而 [movement.py](source/adjutant_coordinator/graph/movement.py) 里

```python
#: 一条已批准的中继跳**最长复用时长**（tick，默认 1800 ≈ 30 秒）。
#: 为什么要有上限：复用是为了"别在半路改主意"，但也要防"卡在一条陈旧路线上永远不动"。
#: 到达 / 路径失败 / 遇敌 / 换网格都会自然作废它（note_arrival / invalidate_route），
#: 这里是第二道保险：超过它必须重新规划一次。
HOP_HOLD_MAX_TICKS = 1800        # = 30.0 秒
```

**`HOP_HOLD_MAX_TICKS / 60 = 30.0 秒`，而门禁 p95 一直落在 31.8–33.1 秒**（30 秒 + 一轮观测/规划的延迟）。
换句话说：这批单位的接续**不是**由"到达"触发的，而是**由那道"第二道保险"超时放行**触发的。
注释写得很清楚 —— 第二道保险**本不该**是常态。

这与 `Unit_22` 的个案完全吻合：它在 4175 到达后 **47 秒**没有任何 arrival 事件
（游戏侧不再产生"到点"），于是没有任何东西作废它的路线，只能等超时。

⇒ **下一个要查的层不是副官，而是游戏侧导航**：为什么这些单位走完一跳之后
**不再产生 arrival 事件**（`_fast_sample_movement` 的 `navigation_finished` 判据）。
副官侧"到达 → 作废路线 → 下一跳"这条链接是好的（本轮修复还让它更可靠），
但**输入信号（arrival）在这些场合根本不产生**。

## 4. 下一轮（round-08）的最小步骤

1. **读游戏侧到达判据**：`DebugControlServer._fast_sample_movement` 怎么决定
   `navigation_finished` / 何时发 `arrival`。重点看它是否只在**某个条件**下采样
   （例如单位进入新格、或 `is_navigation_finished()` 为真才发一次）。
2. **对 `Unit_22` 那 47 秒做端到端取证**：同一窗口内该单位的
   `navigation_finished` / `distance` / `target` 是否在变化（`fast_state` 快照里应当有）。
   判据：如果 `distance` 一直不动而 `navigation_finished=false`，那是**游戏侧卡住**，
   副官无论如何都救不了；如果 `navigation_finished=true` 但没发事件，那是**采样漏报**，
   属于我们该修的。
3. **不要把 `HOP_HOLD_MAX_TICKS` 调小**当修复：那只是把 30 秒换成更短的乱动
   （prompt §4 明令"未达到则继续定位，**不延长阈值**"，反向同样成立 —— 不许拿阈值当修复）。
4. 本轮修复照常保留：它修的是一个真缺陷（9.2% 的到达被吞），有守门测试，且不影响其它行为。

## 5. 未验证 / 边界

- 修复后的那局 `ab_fixed` 比前两局**跑得更久**（arrivals 839 vs 522/648），
  所以已按**共同 tick 窗口**裁剪；即便如此，三组 p95 差异都在 1.3 秒内，属噪声量级。
- p95 与 `HOP_HOLD_MAX_TICKS` 的吻合是**强相关**，但还没有直接读到
  "这批 hop 的 `hop_in_progress` 一直为真到超时"的逐条证据。round-08 第 2 步就是补它。
- `dedup%` 三组都在 8.7–10.5%：说明"同一单位回到同一目标点"在**每局**都稳定发生
  （主要是工人往返），所以这个修复对**每局**都有意义，只是它不解决 33 秒。
