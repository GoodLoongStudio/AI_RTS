# 阶段 C3y：定论"漏处理 vs 观察缺失" —— 是**观察缺失**；一个候选实现失败并被关闭（round-29）

日期：2026-10-07。状态：**needs-review —— 到达账补齐并判定为"观察缺失"；
追出 30 秒拖尾的**新竞态**；该候选的第一版实现把对局打挂两次，按纪律**关闭**。**

上位：[C3x 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3x-replication.md)。

---

## 1. 到达账补齐：每个出口都有**不受日志上限影响**的计数

round-28 留的问题是：`Unit_18` 在 t=2458 的到达**在归档里没有任何 `arrival_seen` 记录**，
而按计数看"每条到达都记了账" —— 到底**漏处理**还是**观察缺失**？

修法：把到达账从"依赖 `_decide`（受 `MAX_DECISION_LOG = 512` 上限约束）"
改成写在 `movement_stats` 里的计数（`_bump_movement_stat`），覆盖**每一个出口**：

| 出口 | 计数 |
|---|---|
| 进入到达分支 | `arrival_events` |
| 事件里 `unit` 为空（旧条件 `unit and kind == "arrival"` 会**整条跳过**它） | `arrival_no_unit`（并显式 `continue`） |
| 被 1 秒去重窗口挡掉 | `arrival_deduped` |
| 走到正常路径 | `arrival_note` |
| 正常路径但当时没有路线 | `arrival_no_route` |

**口径**：`arrival_events == arrival_deduped + arrival_note + arrival_no_unit`。
守门测试 `test_every_arrival_is_accounted_by_counters_not_by_log` 钉住它。

## 2. 判定：**观察缺失**，不是漏处理

`acc1`（`4c0a0e0f`，`run_health` = OK / 223 ticks / 0 错误）：

```
arrival_events = 469
arrival_deduped = 3,  arrival_note = 466,  arrival_no_unit = 0
deduped + note + no_unit = 469   ← 与 arrival_events 完全相等
```

**对三个历史档案重算同一口径，差都是 0**：

| 档案 | `arrival_events` | `deduped` | `note` | 差 |
|---|---|---|---|---|
| `140b4c40`（round-27） | 764 | 0 | 764 | **0** |
| `0bf4bd7f`（round-28） | 617 | 1 | 616 | **0** |
| `62213f9e`（round-25） | 768 | 1 | 767 | **0** |

⇒ **没有一条到达被丢掉**。`Unit_18` 那条到达**确实被处理了**，只是**没在决策日志里留痕**。

## 3. 顺带揪出一个影响面更大的观测偏差

对照"到达分支进入数"与"决策日志条数"：

| 档案 | `arrival_events` | `arrival_seen` 条数 | **被挤掉** |
|---|---|---|---|
| `4c0a0e0f` | 469 | 432 | **37（7.9%）** |
| `140b4c40` | 764 | 692 | **72（9.4%）** |
| `0bf4bd7f` | 617 | 534 | **83（13.5%）** |

原因：`MAX_DECISION_LOG = 512`，超出的条目在**归档之前**就被丢掉。

| 数据源 | 是否完整 | 依据 |
|---|---|---|
| `events.jsonl`（到达事实） | **完整** | tick 范围覆盖全局 |
| `commands.jsonl`（命令账） | **完整** | 行数远超 512、tick 范围覆盖全局 |
| **`decisions.jsonl`（逐条决策）** | **有缺口 8~14%** | 上表 |

**对既有结论的影响（逐条核）**：
- **接续延迟门禁（p50/p95/≤1s）不受影响** —— 它走 `events.jsonl` + `commands.jsonl`，两者完整。
  ⇒ 这一路的主指标**站得住**。
- **round-16 的 `busy` 归因（73.8%）可能被偏差影响**（它数 `advance_skipped` 条数），
  标为"**未经完整数据复核**"。
- **每轮增量账不受影响**（走 `rounds.jsonl`，round-25 已对账相等）。

## 4. 追出 30 秒拖尾的**新竞态**（本轮最有价值的机制发现）

`Unit_18`（`archive_140b4c40`）：

```
t=2448  命令 Accepted  rule-fill-advance-Unit_18-2448
t=2458  arrival dist=0.22      ← 被处理了（§2 计数证明），但没留日志
t=2526  advance_skipped busy blocker=rule-fill-advance-Unit_18-2448
t=4262  才有新意图（30.07 秒 ≈ HOP_HOLD_MAX_TICKS = 1800 tick = 30.0 秒）
```

**竞态链条**（读代码确认了两处引用的确是同一个对象 `state["active_intents"]`，
所以问题不是"释放写错了地方"，而是**释放之后又被重新占用**）：

1. `node_ingest` 的到达分支 `_close_movement_intents` 把该单位的移动段意图标成 `completed`（round-23 修的链）；
2. **同一轮**接着跑的 `node_tactical_agent` 又为这个单位**新建一条意图**（它刚到达、路线已作废 ⇒ 正是"该发下一跳"的时候）；
3. 下一轮看到的是"**新意图**活着" ⇒ 单位重新算 `busy` ⇒ 被挡到 TTL 或 `HOP_HOLD_MAX_TICKS`。

**这与 round-23/25 那两次"改了数据源却以为改的是消费端"不同** ——
这是"**改对了，但下一步立刻把它撤销了**"。

## 5. 候选实现：**做了，但打挂了对局两次 → 按纪律关闭**

实现草案：军事轨里让"**刚到达（窗口 300 tick）且不在途且未挂起**"的单位跨过 `busy`。
（三点边界：窗口有限；仍要求 `_en_route` 为假，守住"半路不许改令"；`suspended` 不抢。）

**但第一版把对局打挂了两次（都在 16~36 tick 内）**，`run_health` 两次都判**不可用**：

- **真根因**：我在日志载荷里放了 `⇒`（U+21D2），而 runner 的 `_log` 要
  `print` 到 **GBK 控制台** → `UnicodeEncodeError` → 每轮抛异常 → 归档残缺；
- 期间我**误判过一次**原因（以为是 lambda 形参遮蔽内建 `str`，其实那处形参叫 `name`）——
  这个误判来自我没有先把 traceback 取出来看，而是先猜。

**按 prompt §4（一轮一个明确候选；未验证的不算成果）本轮关闭它**：
`ARRIVAL_BUSY_OVERRIDE = False`，实现留在树里但**不生效**；
两个相关测试用 `skipUnless(rf_arrival_override_enabled())` 跟着开关走
（**不把"未启用"伪装成"通过"**）。测试结果：`Ran 139, OK (skipped=2)`。

**`run_health` 的价值在本轮被两次证明**：它两次拦下了"归档残缺却看起来跑完了"的运行，
我没有采信任何来自它们的读数。这是 round-24 立下该规定的直接回报。

## 6. 下一轮（round-30）

1. **重新做 §5 的候选**，且**第一步先解决日志约束**：
   runner 的日志载荷只允许 **GBK 可编码**字符（或先修 `_log` 的编码）。
   建议顺手修 `_log`（`print` 前用 `errors="replace"` 或设置 stdout 编码）——
   否则任何人在日志里写个箭头都会打挂对局，这是**产品级隐患**，不只影响我。
2. 候选重新实现后：先用 `run_health` 确认 `tick_error == 0`，**再**看门禁。
3. 给 §3.1 的三处结论标注不确定性（`busy` 占比、round-23/27 的个例判定）。
4. ⚠ 仍**不许**动任何阈值；**不许**为了门禁数字改判据。

## 7. 未验证 / 边界

- §5 的候选**未验证**（这是本轮明确关闭它的理由），**没有**任何性能读数。
- §4 的竞态链条是**读代码 + 一条逐例时间线**支撑的，**没有**用集成测试复现
  （单元级测试无法复现"同一轮内先释放后重建"的时序）。
- §3 的"被挤掉 8~14%"是**对照计数**得出，不是直接观测淘汰过程；
  但三个档案一致、且 `MAX_DECISION_LOG=512` 是已知机制。
- 本轮改动：`nodes.py`（到达账计数 + 一处显式 `continue`）、
  `rules_fallback.py`（计数辅助 + **关闭状态**的候选 + `ARRIVAL_PRIORITY_WINDOW_TICKS`）、
  `test_graph_runtime_fake.py`（+1 例）、`test_safe_movement.py`（+2 例，均 skip）。
- 按 AGENTS.md 工作区边界要求核对：`check_workspace_target.py --mode develop`
  → `allowed_for_development: true`，"Target belongs to the primary source checkout"。
