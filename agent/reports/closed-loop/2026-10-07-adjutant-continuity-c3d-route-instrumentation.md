# 阶段 C3d：路线状态取证埋点（round-09）

日期：2026-10-07。状态：**needs-review —— 埋点已落地并验证可用；拿到 1 条全局定量证据；
per-unit 的"到达后 ok 仍为真"**还没有抓到**（埋点的候选过滤有盲区，原因已定位）。

上位：[C3c 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3c-sampler-fix.md)。

---

## 1. 本轮做了什么

round-08 的交接要求是"要一条**直接证据**：`routes[unit].ok` 在到达之后到底是不是 false"，
并指出"`rounds.jsonl` 只存摘要、`decisions.jsonl` 不写 routes，所以需要加只读快照点"。

本轮加了它：[nodes.py](source/adjutant_coordinator/graph/nodes.py) 的
`_route_ok_snapshot(state, focus=…)`，挂在 `movement_gate` 决策账上（**只读**，有界 8 个样本）：

| 字段 | 含义 |
|---|---|
| `ok_count` / `not_ok_count` | `routes` 里 `ok=true/false` 的单位数（排除 `squad\|` / `survival\|` 前缀） |
| `en_route_units` | AI 授权单位里"仍在路上"的数量（`ok && tick-last_replan_tick < HOP_HOLD_MAX_TICKS`） |
| `routes` | 每个采样单位：`ok` / `last_replan_tick` / `arrived_tick` / `invalidated_reason` / `invalidated_tick` |
| `focus` | 本轮候选意图里出现的单位（采样优先收它们） |

## 2. 拿到的证据

### 2.1 全局：`en_route_units` 恒等于 `ok_count`（每一行都相等）

```
tick     ok      not_ok  en_route  planned
683      1       0       1         1
1363     2       1       2         2
1981     5       2       5         2
2625     10      7       10        7
3255     17      8       17        7
3926     8       21      8         5
4613     1       28      1         2
5257     4       25      4         1
6915     14      15      14        9
7569     20      15      20        8
8831     16      31      16        8
11420    10      40      10        5
17674    13      37      13        9
```

**每一行的 `en_route_units` 都等于 `ok_count`**（22 行采样，无例外）。
⇒ 在这批数据里，`movement.unit_en_route` 等价于 **`routes[unit].ok` 为真且时间戳未过 30 秒**。
也就是说：**`ok=true` 的单位就是被 `rules_fallback._parallel_intents` 里
`if _en_route(name): continue` 每轮跳过的那些**。这条链条现在有**定量**支撑，
不再是靠读代码推理。

另一条同样重要的读数：`ok_count` 在 **tick 3255 达到 17**，随后在 **3926–4613 之间塌到 1**
（`not_ok` 从 8 涨到 28）。也就是说"在路上"的单位会**成批**积压然后**成批**放行 —— 与
"停一大段、然后大家一齐动"的玩家观感一致。

### 2.2 per-unit：抓到一条（有盲区，已修盲区后再取）

埋点第一版**有一个致命盲区**：`movement_gate` 的决策账只在 `blocked or queries` 时写，
而 `focus` 来自**本轮候选意图**。被 `_en_route` 跳过的单位**不进候选** →
**恰恰在卡住的那些轮次里没有快照**（实测：想查的单位在整个 52 秒空档里只出现过 1 次）。

已修（本轮内）：
- `focus` 补上 `_stopped_units(state)` —— 从阶段 C 的 `continuity_units` 台账里取
  "停住 ≥ 2 秒"的单位（按停止时长降序、有界 8 个）；
- 触发条件从 `if blocked or queries` 放宽到 `if blocked or queries or en_route_units`
  —— 只要还有单位在路上就写一笔。

修完那一局（`archive_8469ba76`）拿到的最干净个案：**`Unit_43`**

```
最差样本：arrival_tick=13674 → 下一条指令 18210，空档 75.60 秒
空档窗口内到点次数 = 1，总位移 = 0.0 米   ← 完全没有再动过
路线快照：
  tick    ok?    arrived   replanned invalidated en_route_all
  13699   ok     0         13699     -           16
```

**这条快照本身就是关键证据**：在到达事实（13674）**之后**的 13699，
这个单位的路线是 **`ok = true` 且 `last_replan_tick = 13699`**，
而 `arrived_tick = 0`（**没有被标成已到达**）、`invalidated_reason` 为空。

⇒ 机制假设**得到支持**：到达之后它的路线**又被重新规划成 `ok=true`**，
于是 `unit_en_route` 为真 → `_parallel_intents` 每轮 `continue` 跳过它 →
`last_replan_tick + HOP_HOLD_MAX_TICKS = 13699 + 1800 = 15499` 那道保险到期后才放行。
与该单位"整段空档位移 0.0 米"完全吻合：**它不是没被调度，而是被当作"还在路上"。**

⚠ 仍要说清的边界：这条快照是**单点**（13699），且窗口内后续轮次没有再采到该单位
（队列有界/候选不含它）。所以"`ok` 一直为 true 到 15499"是**由单点 + 时间戳推算**，
不是逐轮实证。下一轮应当让快照**按停止单位持续采样**（现在已修），再复核一次。

## 3. 下一轮（round-10）：从"取证"转到"修"

现在链条已经够清楚，可以动产品了。**要修的不是 `HOP_HOLD_MAX_TICKS`**（那是保险，
调它只是把 30 秒换成别的数字），而是**为什么到达之后路线又被规划成"在路上"**：

1. `note_arrival` 在 13674 到底有没有被调用？
   - **有** → 那么它在 13699 之前被 `record_route` 覆盖（新一轮规划把它写回 `ok=true`），
     而**没有任何"到达"再发生** → 单位被永久当成在路上。修法：路线记录里保留
     "这条跳的到达已经确认过"的状态，**已到达的跳不许再作为"在途"复用**
     （复核 `hop_in_progress` 的判据是否该先看 `arrived_tick`）。
   - **没有**（被去重/事件丢失）→ 那是投递问题，沿 `fast_events` 的 `seq` 游标查丢包。
2. 两个方向都不许用"延长/缩短阈值"糊过去（prompt §4 明令）。

## 3b. 已完成的埋点增强（本轮）

| 改动 | 目的 |
|---|---|
| `_route_ok_snapshot(state, focus)` | 只读快照：`ok`/`last_replan_tick`/`arrived_tick`/`invalidated_reason` |
| `focus` 补 `_stopped_units` | 让"卡住的单位"被**主动**采样，而不是等它出现在候选里 |
| 触发条件补 `or en_route_units` | "还有单位在路上"的那些轮次也要留痕 |

三者都**不改任何调度/决策行为**。

## 4. 未验证 / 边界

- 本轮**没有**改任何调度/决策逻辑；只加了一个只读快照点（有界、`focus` 优先）。
- 全局那条 `en_route_units == ok_count` 是在**一局**的 22 个采样点上的读数；
  `unit_en_route` 还包含 `nav_revision` 相等与 `relay_point` 长度这两个条件，
  本快照没有逐条复算它们，所以严格说是"在这批数据里二者相等"，不是恒等式证明。
- 两组各 1 局的老问题不变：结论只对数量级/机制负责。
- `Unit_23` 的 52 秒空档里"单位是否真的静止"仍只有间接证据（空档内只有 2 次到点、
  位移 2.0 米），没有逐 0.25 秒坐标采样（探针只采了前 13 个单位）。
