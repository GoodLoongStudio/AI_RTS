# 阶段 C4c：给"到达释放"装上可分辨的账（round-33）

日期：2026-10-07。状态：**needs-review —— 把"到达释放"从单一累计值
拆成"调用/命中/空转"三笔账，追出两个此前分不清的事实；
同时纠正本轮第一版埋点的一个口径错误。**

上位：[C4b 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c4b-quota.md)。

---

## 1. 为什么要拆这笔账

round-32 钉死了拖尾的形状：**30 秒 = `HOP_HOLD_MAX_TICKS` 超时放行**（不是恢复）。
那么 30 秒拖尾只可能来自两种情形，而此前**分不出来**：

- **① 到达分支根本没被走到** ⇒ `_close_movement_intents` 一次都不会被调用；
- **② 走到了，但当时没有可结束的移动段意图** ⇒ 被调用、但结束 0 条。

此前只有一个 `arrival_released_intents`（**只在成功时 +1**），**两种情形都看不到**。
round-23/29 因此反复在猜。

**新增三笔账**（都写进 `movement_stats`，随检查点持久化）：

| 计数 | 含义 |
|---|---|
| `arrival_close_calls` | `_close_movement_intents` 被调用了几次 |
| `arrival_close_matched` | 通过前三个过滤（活跃 + 移动段动作 + 含该单位）的**合格**意图数 |
| `arrival_close_empty` | 被调用但**一条都没结束**的次数 |

## 2. ⚠ 第一版埋点的口径错误（本轮自己抓到的）

第一版我把 `arrival_close_candidates` 记成 `len(intents)` —— 那是**整份活跃意图表**。
实测累计 **1,270,833**，把信号完全淹没。

⇒ 计数必须落在**通过三个 `continue` 之后**。改成 `matched` 后信号立刻清晰。
**这是"埋点口径"类错误的又一次**（前几次：`arrival_seen` 被日志上限挤掉、
`depleted_resources` 没进 `to_dict`、`round_delta` 放进程内字典）——
共同病根是"**计数/快照的位置不在它该在的地方**"。

## 3. 实测（`591dbd61`，`run_health` = OK / 412 ticks / 0 错误）

```
arrival_events              339      ← 进入到达分支
arrival_note                339
arrival_no_route             36      ← 其中 36 条当时无路线可作废
arrival_deduped              0

arrival_close_calls         678      ← _close 被调了 678 次
arrival_close_matched       246      ← 合格意图合计 246 条
arrival_released_intents    246      ← **与 matched 完全相等**
arrival_close_empty         437      ← 64.5% 的调用"一条都没结束"
```

两条确定的结论：

1. **`matched == released`（246 = 246）** ⇒
   **凡是走到"合格"这一步的意图，100% 都被释放了**。
   `_close_movement_intents` 内部**没有漏**（round-23 那条链是通的）。
2. **`calls (678) > events (339)`** ⇒ `_close` 平均每次到达被调 **2.0 次**。
   这与代码一致：正常路径 `note_arrival` 之后调一次，**去重/无路线出口也各调一次**
   （round-23 的修复就是让三条出口都调）。**不是重复执行，是三条出口的设计。**

## 4. ⚠ 但 `empty = 437` 的解释要注意——它**大部分是正常的**

不能把 437 当成"437 次释放失败"。`_close` 的口径是**只结束移动段意图**
（`MOVEMENT_SEGMENT_ACTIONS`），而绝大多数到达**本来就没有**在途的移动段意图
（单位在打点驻留、采集、建造…）。所以"空转"是**预期**的常态。

**要判定 30 秒拖尾属于①还是②，必须把"空转"与"该单位随后被 `busy` 挡住"关联起来**
—— 也就是：**空转的那次到达之后，这个单位有没有被它自己的意图挡到超时。**
本轮**没有**做这个关联（近预算上限），**所以 30 秒拖尾的归属仍未定论。**

这是本轮的**主要遗留**，也是下一轮的第一件事。

## 5. 顺带记录的逐例事实（`archive_81893e7b` / `Unit_18`，30.9 秒）

```
t=1995  命令 Accepted  rule-fill-advance-Unit_18-1995
t=2121  命令 Accepted  rule-fill-advance-Unit_18-2121
t=2121  命令 Accepted  rule-fill-advance-Unit_18-2121      ← **同一 intent_id 出现两条**
t=2125  arrival dist=0.42 target=[52.39,44.33]
t=3978  命令 Accepted  rule-fill-advance-Unit_18-3978      ← 30.9 秒后
```

- **同一 `intent_id` 被下发了两条命令**（t=2121 两条），
  而 `intent_id` 的设计意图是"一条意图一条命令"。这是**下发去重**的问题，
  与 `_close` 无关，但值得单列（下一轮可查 `sent` 去重键）。
- 该局 `arrival_seen` 里**没有** Unit_18 在 t=2125 的记录 ——
  但 round-29 已证 `arrival_seen` 会被 `MAX_DECISION_LOG` 挤掉 7.9~13.5%，
  所以这**不能**当作"到达没被处理"的证据（本轮的新计数给出的 `events == note` 才是）。

## 6. 下一轮（round-34）

1. **把"空转"与"随后被 `busy` 挡到超时"关联**（§4 的遗留）：
   对每个 30 秒拖尾样本，查它那次到达的 `_close` 是"空转"还是"命中"。
   若是**空转** ⇒ 属于情形②（到达时没有可结束的移动段意图，
   但随后又有意图把它算成 `busy`）⇒ 说明**"同轮重建意图"的竞态（C-105）是真凶**；
   若是**命中** ⇒ 释放了却仍被挡 ⇒ 去查 `busy_units` 与释放的**对象同一性**。
2. 顺带查 §5 的"同一 `intent_id` 下发两条命令"。
3. ⚠ 仍**不许**动任何阈值；**不许**为了门禁数字改判据。

## 7. 未验证 / 边界

- §4 的归属**未定论**（本轮明确写出，不含糊）。
- `arrival_close_calls (678)` 与 `arrival_events (339)` **不能按 2:1 直接解释**：
  去重/无路线出口调 `_close` 时**不计** `arrival_events`，所以两个数的分母不同。
  本轮**没有**把三个出口各自计数分开（`arrival_close_calls` 没有标注来源出口）。
- 本轮改的是**只读计数**，**没有**改任何调度判断或阈值。
- 回归：`test_graph_runtime_fake` 35 例通过；全量见本轮交付说明。
- 按 AGENTS.md 工作区边界要求核对：`check_workspace_target.py --mode develop`
  → `allowed_for_development: true`。
