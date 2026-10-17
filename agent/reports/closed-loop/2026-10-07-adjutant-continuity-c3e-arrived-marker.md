# 阶段 C3e：到达账判定 + 修掉"到达记号被重规划抹掉"（round-10）

日期：2026-10-07。状态：**needs-review —— 缺陷已定位并修复（有守门测试），
但门禁 p95 仍未改善，且因此排除了又一条假设。**

上位：[C3d 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3d-route-instrumentation.md)、
[C2 门禁](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c2-gate.md)。

---

## 1. 先判定"到达到底有没有记账"（C3d 留下的二选一）

埋点：`node_ingest` 的到达分支加**只读到达账**（`arrival_seen` 决策 + 4 个计数器）；
分析工具 [arrival_accounting.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-10/arrival_accounting.py)。

实测（`archive_aa061295`，654 条 arrival）：

| 计数 | 值 |
|---|---|
| `arrival_events` | 654 |
| `arrival_note`（真的调了 `note_arrival`） | **652** |
| `arrival_deduped`（被 1 秒去重窗口挡掉） | **2** |
| `arrival_no_route`（调了但当时没有路线可作废） | 192 |
| `planned` / `allowed` | 1123 / 1022 |

⇒ **"到达没被记账"不成立**：99.7% 的到达都正常调用了 `note_arrival`。
那么"单位还被当成在路上"就只剩一个可能：**记号被随后的重规划抹掉了**。

## 2. 找到了那个缺陷（代码级，可复算）

`movement.record_route` 原来**整条替换**路线记录：

```python
routes[str(plan.unit)] = plan.to_dict()      # ← arrived_tick / invalidated_* 全丢
```

链路：

```
note_arrival → ok=False + arrived_tick=T   （"这一跳结束了"的唯一信号）
  → 同一目标又被规划一次（record_route）
  → arrived_tick 清成 0、ok 写回 True
  → unit_en_route 又为真
  → rules_fallback._parallel_intents: if _en_route(name): continue  ← 每轮跳过它
  → 直到 HOP_HOLD_MAX_TICKS(1800 tick = 30 秒) 的第二道保险才放行
```

`hop_in_progress`（"在途"的权威判据）**也从不看 `arrived_tick`** —— 它只看
`ok` / `nav_revision` / `relay_point` 长度 / `last_replan_tick` 年龄。

这条链路与三处独立观察吻合：
- 门禁 p95 长期钉在 **31.8~33.1 秒**（≈30 秒保险 + 一轮）；
- 个案 `Unit_43`：到达 13674 → **13699 快照 `ok=True, arrived_tick=0`** → 空档 75.6 秒、位移 0.0 米；
- `archive_aa061295`：99.7% 的到达都记了账。

## 3. 修复（只保留事实，不改任何调度决策）

| 处 | 改动 |
|---|---|
| `record_route` | 同一目标（±0.5 米，与 `needs_replan` 同源容差）的重规划**继承** `arrived_tick` / `invalidated_*`，并把 `ok` 保持 `False`；换目标照旧全新记录。新增计数 `arrival_marker_kept` |
| `hop_in_progress` | 加守卫：`arrived_tick > 0 且 arrived_tick >= last_replan_tick` → **不是"在途"**（第二重保证） |
| 新增 `_same_target()` | 目标点比较的唯一实现（避免各处各写一个容差） |

守门测试（[test_safe_movement.py](source/adjutant_coordinator/tests/test_safe_movement.py) 的
`ArrivedHopNotInProgressTest`，3 例，全绿）：
① 同一目标重规划必须保留 `arrived_tick`、`ok` 保持 False、且 `hop_in_progress` 仍为 False；
② **换目标**必须算新的一跳（不许被保护误伤）；
③ 换网格版本仍要能重新规划（记号保留 ≠ 永久在途）。

## 4. 实测：修好了，但门禁 p95 **没动**

同一共同窗口 `tick 1028..11868`，工具同 C3c：

| 组 | arrivals | continued | never | p50 | p95 | combat p95 | ≤1s 占比 |
|---|---|---|---|---|---|---|---|
| `before_r9`（`d1778c9f`） | 395 | 323 | 0 | 2.22s | 32.45s | 32.45s | 38.2% |
| `before_r10count`（`aa061295`） | 418 | 284 | 0 | 2.62s | 33.95s | 33.95s | 33.5% |
| **`after_fix`（`f2c668c0`）** | 333 | 250 | **18** | **1.32s** | **35.70s** | **35.70s** | **45.0%** |

- **中位确实变好了**：p50 **2.62 → 1.32 秒**，≤1s 占比 **33.5% → 45.0%**。
- **尾部没有变好**：p95 **32.45 → 35.70 秒**（在单局噪声内，但**绝不是改善**）。
- ⇒ 第 6 条被证伪的假设：**"到达记号被抹掉"不是那 30 秒尾巴的成因**。

| # | 假设 | 证伪方式 |
|---|---|---|
| 1 | 监督层能修好接续 | C2 A/B：1350 次恢复只换 1.5 秒 |
| 2 | 整段停顿是全局卡住 | round-06：每秒仍产 5–14 条意图 |
| 3 | 线路饿死 | round-06：`interleave` 严格轮转 |
| 4 | 到达被 Python 侧永久键吃掉 | round-07：修完 p95 不动 |
| 5 | 采样容差过宽导致副官瞎等 | round-08：容差对齐，p95 仍 32.45 秒 |
| 6 | **到达记号被重规划抹掉导致每轮跳过** | **round-10：修完 p50 变好、p95 仍 35.7 秒** |

## 5. 这条负结果把问题推到哪里（下一轮的起点）

修完之后，"单位被当成在路上"这条解释已经被排掉（`ok=False` 会保留、`hop_in_progress` 会否掉）。
那么这些单位**不是被跳过**，而是**被生成了意图却拿不到有效推进点**。
下一个要看的是规则地板生成侧的**返回值**，而不是"有没有进生成侧"：

1. `rules_fallback._parallel_intents` 里 `point = military_waypoint(...)`；
   `if not point: break` —— 这个 `break` 会**把该单位之后的所有单位一起跳过**（不只是它自己）。
   要量的是：这些 30 秒空档里，`military_waypoint` 对这些单位**是不是返回了 None**。
2. 若确实返回 None：`base` 缺失？`bounds` 非法？候选格全被判"已覆盖"？
   （`explore_frontier` 那条路会把出发格记成 covered，**全图 covered 时会没有候选**。）
3. 若返回了有效点：那就是意图生成了但**被闸门/仲裁丢掉**——`movement_gate` 的
   `blocked_reasons` 已经落账，可以直接查（本局 `stale_nav_revision` 曾一次 49 条）。

**建议的埋点**（下一轮第一件事，仍然是只读）：在 `_parallel_intents` 里对
"无可见敌人的军事轨"记一笔 `military_waypoint` 返回空的**次数与单位**，
以及 `break` 发生的时刻——这样"生成侧给了但没用"和"生成侧没给"就能分开。

## 6. 未验证 / 边界

- 三组各 1 局；`after_fix` 的 p95 比前两组高 2~3 秒，在单局噪声范围内 —— 我说"没改善"，
  不说"变差了"。中位改善（2.62→1.32）也是单局读数，同样只作参考。
- `after_fix` 出现了 18 条 `never_continued`（前两组为 0）。这是**记号保留**的副作用之一：
  `hop_in_progress` 为假之后单位要等**新的规划**，如果新规划迟迟不来，样本会落到
  `never_continued` 而不是"慢接续"。下一轮要区分这两类（都是"没接上"，但成因可能不同）。
- `arrival_no_route = 192`（约 29% 的到达在到达时**没有路线可作废**）——这条线本轮没查，
  可能是另一条独立的小问题（路线在到达前就被清掉）。
