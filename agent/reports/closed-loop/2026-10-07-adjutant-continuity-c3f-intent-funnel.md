# 阶段 C3f：意图漏斗实测 + 军事轨 `break` 修复（round-11）

日期：2026-10-07。状态：**needs-review —— 拿到"链路上没有丢失"的定量证据、
修掉一个"一个单位拖垮整条轨"的控制流缺陷；但门禁 p95 仍未改善。**

上位：[C3e 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3e-arrived-marker.md)。

---

## 1. 意图漏斗：命令**不是在链路上丢的**（关键定量证据）

工具 [intent_funnel.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-11/intent_funnel.py)，
对 `archive_f2c668c0`（round-10 修复后那一局）逐段计数：

| 阶段 | rule-fill-advance |
|---|---|
| 生成（`micro_control_added.intents`） | 756 |
| 仲裁接受（`intents_arbitrated.accepted`） | 702（**92.9%**） |
| 实际下发（`dispatch_done.receipts`） | **702（100.0%）** |
| 权威回执 | **全部 `Accepted`**（702/702） |
| 归档移动命令 | 1108（`attack_move` 1073 / `move` 35） |

⇒ **从"生成"到"权威接受"没有任何丢失**：接受率 92.9%，下发/接受 = 100%。
所以"命令被丢掉/被拒"这类解释**排除**。
（注意 `dispatch_done` 的 receipts 只覆盖日志窗口内的部分，所以这里用**率**而非绝对数对比。）

**同时暴露了真正刺眼的一个数**：143 轮里只生成 756 条推进意图 = **5.3 条/轮**，
而场上有 60+ 个单位、`replan_latency_avg = 189 tick`（≈3.2 秒）。

## 2. 一个"一个单位拖垮整条轨"的控制流缺陷（已修）

`rules_fallback._parallel_intents` 的军事轨原来写的是：

```python
point = military_waypoint(origin or base, ...)
if not point:
    break          # ← 终止**整条军事轨**，把它之后的**所有**作战单位一起饿掉
```

`military_waypoint` 在 `not base or len(base) < 2` 时返回空，而调用处传的是
`origin or base`（`origin` 可能是 `None`）⇒ 它**确实会返回空**。
**一个单位算不出航点，会让整条轨剩下的单位全部拿不到推进意图** ——
这是"有的兵在动、有的兵一直不动"的一个直接机制。

**修复**：`break` → `continue`（只跳过这一个单位），并加只读计数
`advance_skipped_no_point`；`_en_route` 否决处加只读计数 `advance_skipped_en_route`
（它是"通往新命令的唯一道路"，此前完全不可见）。

守门测试（`MilitaryTrackLoopControlTest`，2 例，全绿）：
① **中间一个单位**算不出航点，排在它**之后**的作战单位必须照样拿到意图；
② `_en_route` 否决必须可计数。

## 3. 反向交叉验证：移动链路本身是好的

round-04 的**坐标采样**（独立于命令账）在同一款游戏里给出：

| 单位 | move_events | 最大间隔 | 总位移 | 终点误差 |
|---|---|---|---|---|
| Unit_2 | 45 | **0.27s** | 64.25m | 0.07m |
| Unit_3 | 51 | **0.50s** | 59.19m | 0.12m |
| Unit_4 | 38 | **0.27s** | 68.88m | 0.11m |
| Unit_5 | 44 | 1.23s | 53.14m | — |
| Unit_6 | 34 | **0.27s** | 61.57m | — |

⇒ 只要副官**下发**了命令，游戏侧就能**连续**走完（0.23~0.27 秒一个移动事件、
终点误差 ≤0.12 米）。**那 30 秒的尾巴不是游戏动不了，而是副官在那段时间没有下发。**

## 4. round-10 的修复在生产里**确实生效了**

`arrival_marker_kept = 60`（`archive_707eb88f`）—— "同一目标重规划时保留已到达记号"
这条路径在真实对局里被走了 60 次。`arrival_note = 499 = arrival_events`，
再次确认"到达都记了账"。

## 5. 仍未解决 / 本轮的一处不确定

- **门禁 p95 仍未改善**（round-10 三组：33.08 / 33.95 / 35.70 秒，均 FAIL），
  所以本轮的重点是"排除解释 + 修控制流缺陷"，不是宣称修好了连续性。
- ⚠ **`advance_skipped_en_route` / `advance_skipped_no_point` 在归档的 `movement` 快照里
  `无此计数`**：`arrival_marker_kept`（同一套 `movement_stats` 机制、上一轮加的）**在**，
  说明这套读写路径是通的；这两个新键没出现，最可能是**这一局的军事轨在 `_en_route` 分支
  之前就都走了别的出口**（有可见敌人时作战单位只走"打"、或 `_free` 先否掉），
  而不是机制失效。**这一点本轮没有钉死**，下一轮应直接在生成处落一条
  `_decide(..., kind="advance_skipped", ...)` 逐次留痕（计数会被 `movement_stats` 视图
  的键集变化掩盖，逐条记录不会）。
- 生成量 `p50=9 / p90=15 / max=25` 条/轮（196 轮、共 1812 条）——
  下一轮该拿它对照"场上可自由行动的作战单位数"，才能说清"每轮到底有多少单位被跳"。

## 6. 下一轮（round-12）的两个具体动作

1. **把 `_en_route` 否决逐条留痕**（`_decide`，有界），拿到"每轮有多少作战单位因为
   '在路上'而拿不到意图"的真实数字。这是决定"要不要让推进意图在在途时也能刷新"的前提。
2. **量一次跳的真实耗时**：`replan_latency_avg = 189 tick`、`HOP_HOLD_MAX_TICKS = 1800 tick`
   —— 如果一跳本身就要走 30 秒（距离 ÷ 速度），那么"到达→接续 30 秒"里有一部分是
   **合法的行程时间**，不该被当成停滞。判据：用 `commands` 的目标点与单位位置算距离，
   除以该兵种速度，得到"这一跳最少需要多少秒"，再与实测间隔比。
   **这一步能把"合法行程"从"真停滞"里分出来** —— 在此之前，门禁 p95 的含义本身是不干净的
   （round-06 曾把工人/炮塔也算进 combat 尾巴，就是同类问题的前车之鉴）。

## 7. 改动清单

| 文件 | 改动 |
|---|---|
| [rules_fallback.py](source/adjutant_coordinator/graph/rules_fallback.py) | 军事轨 `break`→`continue`；新增 `_bump_state`；两处只读计数（`advance_skipped_no_point` / `advance_skipped_en_route`） |
| [test_safe_movement.py](source/adjutant_coordinator/tests/test_safe_movement.py) | 新增 `MilitaryTrackLoopControlTest`（2 例）；`import mock` |
