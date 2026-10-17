# 阶段 C3c：游戏侧到达采样容差修复 + 门禁尾巴的又一次证伪（round-08）

日期：2026-10-07。状态：**needs-review —— 修掉一个可证明的采样缺陷、代价与收益都量到了；
门禁 p95 仍未改善，但成因范围进一步收窄。**

上位：[C3b 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3b-arrival-fix.md)、
[C2 门禁](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c2-gate.md)。

---

## 1. 缺陷：采样侧的"到达"判据比游戏侧**更宽**，而且报过就永久不再报

`DebugControlServer._fast_sample_movement`（[DebugControlServer.gd](source/net/DebugControlServer.gd:2971)）
决定何时发 `arrival` 事件。修前的两处写法：

```gdscript
# ① 容差更宽
arrive_eps = maxf(ARRIVAL_EPS_M /*1.5*/, float(agent_radius_value) * 1.25)
if finished or distance <= arrive_eps: ...      # radius=2.0 → 2.5 米
# ② 报过就永久不再报（直到目标坐标变化）
if bool(_fast_move_reported.get(unit_name, false)):
    return
```

而游戏自己结束这条订单的判据是 `Movement.gd:622/655` 的
`arrive_radius := maxf(float(radius), 0.35)`（radius=2.0 → **2.0 米**）。

于是有一条 **2.0~2.5 米的残留环**：

1. 单位压进 2.5 米 → 采样报 `arrival`（**早于**游戏认定到达）；
2. 锁存 `_fast_move_reported=true`；
3. 单位**再也压不进 2.0 米**（被挤住/被地形卡/走粗网格路）→ 游戏侧
   `is_navigation_finished()` **一次都不为真**（实测：**522 条 arrival 的
   `navigation_finished` 全部为 `false`**，`distance` 全在 0.1~2.47 米 —— 全靠容差报的）；
4. 目标坐标没变 → 锁存不解除 → **这条跳再也不报 arrival**；
5. 副官侧于是没有任何"到达"可用，路线缓存不作废 → `unit_en_route` 恒真 →
   `rules_fallback._parallel_intents` 每轮 `if _en_route(name): continue` 跳过它。

**注意游戏侧早就踩过并修过同一类锁存**：`Movement.gd:442` 的注释写着
"锁存本意是'一次到达只报一次'，但同目标被反复派差时它会吞掉后续 arrival…
（2026-09-23 实测：工人贴目标 0.15m、士兵距目标 60m 双双永久站桩）"，
并在那里 `_movement_end_emitted = false` 解除锁存。**DCS 采样器有自己的一份锁存，
没有跟着修** —— 这正是本轮修的东西。

## 2. 修复

| 处 | 改动 |
|---|---|
| 容差 | `maxf(1.5, radius*1.25)` → **`maxf(radius, ARRIVE_RADIUS_FLOOR_M /*0.35*/)`**，与 `Movement` 同一把尺子。新增常量并注明"与 Movement.gd:622/655 同源" |
| 锁存 | `_fast_move_reported` 从**布尔**改成**毫秒时间戳**；不再"报过就永久 return"，改由 `ARRIVAL_REEMIT_MS = 2000`（2 秒）的窗口抑制。副官侧 `note_arrival` 是幂等的，所以重复上报无害 |
| 一致性 | `path_failed` 分支也在写这个表，原来写 `true`（会被 `int()` 读成 1）→ 改为写当前时刻 |

验证：DCS 脚本在引擎里正常加载（`Adjutant connectivity smoke test completed: 0 failure(s)`，rc=0，
端口 24579 本次可用）；Python 侧回归见 §5。

## 3. 实测：修好了，但**代价与收益都要说清楚**

用同一套探针、同一共同窗口 `tick 1028..11868` 对照（工具
[round-08/sampler_signature.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-08/sampler_signature.py)）：

| 组 | arrivals | arrivals/秒 | `distance` max | `distance` p95 | **combat p95** | p50 |
|---|---|---|---|---|---|---|
| 修复前 `ab_off` | 522 | 2.89 | 2.47 | 1.68 | **33.08s** | 0.65s |
| 修复前 `ab_fine` | 648 | 3.59 | 2.49 | 1.69 | **31.78s** | 0.88s |
| 只修 Python（round-07） | 839 | 4.64 | 2.48 | 1.90 | 32.40s | 1.57s |
| **本轮（Python+GDScript）** | 264 | 1.46 | **1.91** | 1.71 | **32.45s** | 3.87s |

**收益（可证明）**：`distance` 上界从 **2.47 → 1.91 米**，正好等于 `max(radius, 0.35)`。
⇒ 采样"到达"与游戏"结束订单"现在是**同一把尺子**，那个提前量消失了。
（1.91 = 当前最"胖"的被采样单位半径；前几局 2.47 正是旧公式 `radius*1.25` 的产物。）

**代价与代价的解释（必须写出来，不能只报好的一面）**：arrivals **522 → 264（-49%）**。
其中大部分是**被去掉的假到达**（旧的提前量本来就多发了一遍），但也要承认：
容差收紧后，卡在 **1.91~2.47 米**之间的单位不再触发任何 arrival。
我加的 2 秒重报窗口只能救"仍然在**新**容差之内"的单位，救不了这一圈里的。
**p50 从 0.65s 升到 3.87s** 大概就是这个来源（少了一批"提前到达"）。

**门禁结论：仍然 FAIL（combat p95 = 32.45s vs 目标 1.0s）。** 这是第 5 条被证伪的假设：

| # | 假设 | 证伪方式 |
|---|---|---|
| 1 | 监督层能修好接续 | C2 A/B：1350 次恢复只换 1.5 秒 |
| 2 | 整段停顿是全局卡住 | round-06：停顿窗口内每秒仍产 5–14 条意图 |
| 3 | 线路饿死 | round-06：`lanes.interleave` 严格轮转 |
| 4 | 到达被 Python 侧永久键吃掉 | round-07：修完 p95 不动 |
| 5 | **采样容差过宽导致副官瞎等** | **round-08：容差对齐、假到达消失，p95 仍 32.45 秒** |

## 4. 成因范围进一步收窄（下一轮的起点）

现在的证据指向一个**更具体**的问题：这些跳的接续是**被 `HOP_HOLD_MAX_TICKS` 放行的**，
但**不是**简单的"30 秒整点"——`Unit_22` 的放行发生在 tick 6881，而它最后一条 advance
指令在 tick 3812（差 3069 tick ≈ 51 秒），说明放行点是
**`record_route` 时的 `last_replan_tick` + 1800**，而那个值并不等于"指令下发时刻"。

⇒ 下一轮要读的是**路线记录的时间戳来源**：

1. `record_route(plan)` 写入的 `last_replan_tick` 是**规划那一刻**的 tick，
   而 `hop_in_progress` 判断 `tick - last_replan_tick >= HOP_HOLD_MAX_TICKS`；
   对"被 `_en_route` 跳过"的单位，**没有任何东西刷新它**，所以放行时刻 = 规划时刻 + 30 秒。
2. 要回答的问题因此变成：**在这些单位身上，`_en_route` 为什么在 30 秒里一直为真？**
   两个可查的地方：
   - `movement.record_route` 是否在"同一单位被反复规划"时**刷新** `last_replan_tick`
     （如果只在真正重规划时刷新，那么被跳过的单位时间戳是冻住的）；
   - `previous_route(state, unit)` 的 `ok` 字段在到达之后**是否真的**被写成 `False`。
     round-07 的守门测试证明"到达 → `ok=False`"这条链是通的，但**生产档案里**
     需要一条直接证据：找到 `Unit_22` 在 4175 之后 `routes["Unit_22"].ok` 的值。

**这条直接证据只能从档案里取**（`rounds.jsonl` 存的是摘要，`decisions.jsonl` 不写 routes），
所以下一轮要给 runner 加一个**只读**的路线快照点（或在 `movement_gate` 决策里带上
`en_route`），而不是继续猜。

## 5. 测试与校验

```powershell
# 改动文件解析
Godot_v4.7.1-stable_mono_win64_console.exe --headless --path . --quit-after 200 `
  res://tests/automated/AdjutantConnectivitySmokeTest.tscn
#   → [DBGCTL] 调试控制端点已启动 127.0.0.1:24579；completed: 0 failure(s)；rc=0
python -X utf8 -m unittest <14 个模块>     # 376 tests，仅剩 2 个既有迁移口径失败，新增失败 0
python -X utf8 agent/runs/.../round-01/nav_sparsity_local.py --out .../round-08/ab_gd `
  --runner --observe-seconds 240 --with-ai false      # rc=0
python -X utf8 agent/runs/.../round-08/sampler_signature.py <archive_ec936afd>
```

## 6. 未验证 / 边界

- 每组**各 1 局**，且各局时长不同（arrivals 264~839），已按共同 tick 窗口裁剪；
  组间差异仍可能含局间差异，结论只对**数量级/机制**负责。
- `dist>2.5m = 0` 在三组都为 0，所以 **2.47 → 1.91 这个变化不能只归因于本轮修复**：
  也可能是这一局的单位半径分布不同。要钉死它，应当在同一局里对照（做不到），
  或直接读单位半径与 `distance` 的关系。**这一点我标注为未完全验证。**
- 容差收紧后"1.91~2.47 米里卡住的单位不再报到达"是**已知缺口**，下一轮必须处理：
  可选方向是"停滞检测"（同一跳连续 N 次采样位移 < 阈值 → 发 `path_failed` 或让到宽容差报一次），
  但**不能**靠把容差再放宽回去（那会退回本轮修掉的病）。
