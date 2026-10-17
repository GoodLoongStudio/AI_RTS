# 阶段 C3j：静默归因到 `busy` + 到达即释放占用（round-15）

日期：2026-10-07。状态：**needs-review —— 找到并修掉"到达不结束意图"这个死锁；
门禁 p95 降到 20.4 秒（三轮连续下降），但仍未达标。**

上位：[C3i 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3i-silence.md)。

---

## 1. 先把"静默"归因到具体出口

round-14 观测到"到达后 20~30 秒生成侧一条推进意图都不产出"，本轮给军事轨
**四个出口**都加了逐条留痕（`advance_skipped`，带 `reason`），
外加每轮名额用尽一笔（`advance_batch_full`）。

实测（`archive_72501fe6`，修复前）：

| reason | 次数 | 占比 |
|---|---|---|
| **`busy`** | **1232** | **73.8%** |
| `not_combat` | 232 | 13.9% |
| `used` | 206 | 12.3% |
| `en_route` | 0 | 0% |
| `no_waypoint` | 0 | 0% |

名额用尽 151 轮。

⇒ 主因是 **`busy`**：`busy_units(state)` 把**任何持有活跃意图的单位**算成忙。

## 2. 死锁链条（代码级，可复算）

```
到达事件 → movement.note_arrival()   ← 只作废**路线缓存**，不碰意图
         → 那条 rule-fill-advance / bt-attack_move 意图**仍然活着**
           （state ∈ INTENT_LIVE_STATES）
         → busy_units(state) 里还有这个单位
         → rules_fallback._parallel_intents 军事轨第一道出口
           `if not _free(name) ... continue` 每轮跳过它
         → 静默到意图 expires_tick 到期
```

原先**只有侦察段**做了"到达即结束意图"（`nodes.py` 里那段注释写得很清楚：
"否则意图活到 TTL，专职无人机发不出下一跳"）—— 而同样的死锁对
`move` / `attack_move` 一样成立，只是没人给它们补上。

## 3. 修复

`node_ingest` 的到达分支：把"结束意图"的判据从 `action == ACTION_SCOUT`
放宽到 `action in MOVEMENT_SEGMENT_ACTIONS`。

| 项 | 说明 |
|---|---|
| `MOVEMENT_SEGMENT_ACTIONS` | `frozenset(STICKY_MOVE_ACTIONS)` = `{move, attack_move, scout}`。**故意引用**已有常量而不是再抄一份（项目口径：同一概念只允许一处定义；节点里已经有三处同组动作，再抄一份必然分叉） |
| 为什么**不含** `ACTION_ATTACK` | 点攻击驻留是"停在射程内持续输出"，到达（走到目标附近）不代表任务完成 —— 结掉会让单位打一下就走 |

守门测试（`test_graph_runtime_fake.ArrivalDedupTest`，4 例全绿），新增的那一例同时钉住两侧：
① 到达必须释放 `attack_move` 单位并置 `INTENT_COMPLETED` / `drop_reason="arrival"`；
② **点攻击驻留单位不许被结掉**（反向保护，防修过头）。

## 4. 实测：门禁连续三轮下降

同一共同窗口 `tick 1028..11868`：

| 组 | continued | p50 | **p95** | combat p95 | ≤1s 占比 | 长间隔(>10s) | 真停滞 |
|---|---|---|---|---|---|---|---|
| `707eb88f`（round-11） | 216 | 2.33s | **32.15s** | 32.15s | 42.3% | 80 | 61 |
| `a864c83a`（round-13，id 修复） | 385 | 1.10s | **27.35s** | 27.35s | 47.5% | 32 | 24 |
| **`d601c3c2`（round-15，到达即释放）** | 346 | **0.70s** | **20.43s** | **20.32s** | **61.8%** | **23** | **18** |

- **p50 2.33 → 0.70 秒**（快了三倍多）
- **≤1 秒占比 42.3% → 61.8%**
- **p95 32.15 → 20.43 秒**，真停滞例数 **61 → 18**
- 门禁仍 **FAIL**（目标 ≤1s）

⚠ 但 `busy` 占比**几乎没变**（修复前 73.8%、修复后 **73.8%**，977 次）。
这说明：`busy` 里**还有一大块不是"移动段意图活过到达"** ——
`busy_units` 把**所有**活跃意图都算上（采集、建造、生产、点攻击驻留…），
而军事轨只关心作战单位。所以本轮修掉的是 `busy` 中"移动段"那一部分
（效果确凿：p95 -7 秒），**剩下那部分没有归因清楚，我不能说它也被修了**。

## 5. 下一轮（round-16）

1. **把 `busy` 拆开**：留痕时带上"占住它的意图动作与 intent_id"，
   这样 `busy` 就能分成"移动段残留"（应为 0）/"点攻击驻留"（合法）/"采集建造"（与本轨无关）。
   修完之后"移动段残留"若仍非 0，说明还有路径没走到释放分支 —— 那就是真 bug。
2. **再压 p95**：现在真停滞 18 例、中位 22.15 秒。按 §5-1 归因后再决定动哪里。
3. 仍然**不许**动任何阈值（`ADVANCE_HOLD_TICKS` / `HOP_HOLD_MAX_TICKS` / TTL 都不许调）。

## 6. 改动清单与校验

| 文件 | 改动 |
|---|---|
| [nodes.py](source/adjutant_coordinator/graph/nodes.py) | 新增 `MOVEMENT_SEGMENT_ACTIONS`（引用 `STICKY_MOVE_ACTIONS`，放在其定义之后，避免模块级前向引用）；到达分支按动作结束意图 |
| [rules_fallback.py](source/adjutant_coordinator/graph/rules_fallback.py) | 军事轨四个出口逐条 `advance_skipped`（带 `reason`：`busy`/`used`/`suspended`/`not_combat`/`en_route`/`no_waypoint`）+ `advance_batch_full` |
| [test_graph_runtime_fake.py](source/adjutant_coordinator/tests/test_graph_runtime_fake.py) | 新增"到达结束移动意图并释放单位 + 点攻击驻留不受影响" |
| [test_safe_movement.py](source/adjutant_coordinator/tests/test_safe_movement.py) | 出口留痕断言放宽为"含 `no_waypoint` 且其它出口也带原因" |
| 新增脚本 | `skip_reasons.py`（出口归因） |

```powershell
python -X utf8 -c "from adjutant_coordinator.graph import nodes; print(sorted(nodes.MOVEMENT_SEGMENT_ACTIONS))"
#   → ['attack_move', 'move', 'scout']   （验证模块级定义顺序正确）
python -X utf8 -m unittest test_graph_runtime_fake test_safe_movement ...   # 174→ 全绿（除既有 2 例）
python -X utf8 nav_sparsity_local.py --out .../round-15/ab_release --runner `
    --observe-seconds 240 --with-ai false                                     # rc=0
```

## 7. 未验证 / 边界

- **各 1 局**，三组是不同对局（兵力/时长/遭遇都不同），所以 32.15→27.35→20.43
  是**三次不同对局的读数**，不是严格 A/B。但三组都朝同一方向、且两轮的机制侧证据
  （id 多样性 ↑、`busy` 归因）都与结果同向，所以我给出"实质改善、连续三轮下降"的判断。
- **`busy` 占比没变**这一点必须如实说：它说明剩余的 `busy` 里还有非移动段成分，
  本轮**没有**归因清楚。
- "到达即释放"会不会让单位在半路被改令？不会直接导致：释放的是**意图占用**，
  而"半路不许改令"由 `movement.hop_in_progress`（路线缓存 + `HOP_HOLD_MAX_TICKS`）
  把关，两者是**不同**的机制。但这条推理**尚未用真实对局专门验证**
  （本轮的 p50/p95 改善与"没有出现新的抖动迹象"是间接支持）。
