# 阶段 C3h：候选 α —— 前压意图 id 跟着目标走（round-13）

日期：2026-10-07。状态：**needs-review —— 门禁首次出现实质改善（p95 32.2 → 27.4 秒、
停滞例数 80 → 32），但仍远未达标。**

上位：[C3g 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3g-stall-chain.md)。

---

## 1. 做了什么（候选 α）

round-12 把停滞追到：**`bt-attack_move` 的意图 id 跨轮重复，而下发按 id 去重**。
根因在 [behavior_tree.py](source/adjutant_coordinator/graph/behavior_tree.py)：

```python
def _advance_slot(bb):
    return int(bb.get("server_tick") or 0) // ADVANCE_HOLD_TICKS   # 900 tick = 15 秒
```

`ADVANCE_HOLD_TICKS = 900`，所以 id 序号在**15 秒内恒定**；而 `_advance_waypoint`
是按**单位当前位置**重算的 —— 单位一动，航点就变，**id 却不变**。
游戏按 `intent_id` 做幂等缓存 ⇒ **新目标被当成旧命令丢掉**，
单位静置到下一个槽位（最多 15 秒）或更久（行为树分支切换）。

**修复**：id 序号改成 **槽位 + 目标哈希**

```python
def _target_hash(point, span=4096):      # 取整到 0.5 米再哈希
    ...
def _advance_slot(bb, point=None):
    return slot * TARGET_HASH_SPAN + _target_hash(point, span=TARGET_HASH_SPAN)
```

语义：
- **同一槽位 + 同一目标** ⇒ 同一 id（幂等，重复上报命中同一回执，**不会每轮重置路径**）；
- **同一槽位 + 换了目标** ⇒ **换 id**（新目标能真正下发）。

取整到 0.5 米是为了让"航点在原地轻微抖动"不换 id —— 这一点很关键，
否则会退化成 round-06 那种"每轮改令、单位原地打转"。

## 2. 守门测试（2 例，全绿）

| 测试 | 钉住的性质 |
|---|---|
| `test_advance_intent_id_changes_when_the_waypoint_changes` | 换了位置 ⇒ 换航点 ⇒ **必须换 id**（否则新目标被幂等缓存吃掉） |
| `test_advance_intent_id_is_stable_for_the_same_waypoint` | 同一目标 + 同一槽位内推进 300 tick ⇒ **id 不变**（不许每轮重置路径） |

第二例是**反向保护**：只修"换目标换 id"很容易顺手写成"每轮换 id"，
那会把 round-06 修好的"半路不许改令"重新破坏掉。

## 3. 实测：门禁第一次出现实质改善

同一共同窗口 `tick 1028..11868`、同一套工具：

| 组 | continued | p50 | **p95** | combat p95 | ≤1s 占比 | 长间隔 | **真停滞** |
|---|---|---|---|---|---|---|---|
| `707eb88f`（round-11，改前） | 216 | 2.33s | **32.15s** | 32.15s | 42.3% | 80 | 61 |
| **`a864c83a`（round-13，改后）** | 385 | **1.10s** | **27.35s** | 27.35s | **47.5%** | 32 | **24** |

**机制侧同时得到确认**（不是只看结果数字）：

| 指标 | 改前 | 改后 |
|---|---|---|
| 每个单位拿到过的**不同**前压意图 id 数（平均） | **33.0** | **50.8** |
| 生成轮数 / 有意图单位数 | 196 / 46 | 171 / 50 |

⇒ 同样规模的部队，**id 的多样性显著上升**，说明"换了目标就换 id"确实生效了
（改前同一目标反复复用同一个 id）。

**门禁判定：仍 FAIL**（combat p95 = 27.35s vs 目标 1.0s）。
但这是十二轮以来**第一次**看到 p95 实质下降（32.2 → 27.4 秒）、
停滞例数明显减少（61 → 24），而且方向与机制解释一致。

## 4. 还剩什么（下一轮的方向）

改后仍有一批 **24 例真停滞、中位 28.13 秒**，说明"重复 id"只是**其中一条**通路。
剩下这条通路的形态还没查到，但线索已经很窄：

1. **`ADVANCE_HOLD_TICKS = 900`（15 秒）本身**：槽位每 15 秒才换一次，
   而"到达之后该规划下一跳"完全依赖新意图 —— 于是**最坏 ~15 秒**的空等是内建的。
   实测停滞中位 **28.13 秒** ≈ 两个槽位。这与"id 换不换"无关，是**槽位时长**决定的。
   ⇒ 下一轮该量：停滞单位在空档内**换了几个槽位**、每个槽位是否都真的下发了命令。
2. **到达之后没有"立刻拿新目标"的机制**：现在靠行为树下一轮重算，
   而重算出来的航点如果与上一个**取值相同**（取整到 0.5 米后），id 就不变 ⇒ 仍被吞。
   ⇒ 候选 β（到达只认游戏侧订单结束）仍然值得做，但要先把
   `navigation_finished` 逐条落账（round-12 的未验证项）。

**建议 round-14 做**：把 `navigation_finished` 与"槽位序号"逐条落账
（`_note`），先回答"到达后那 28 秒里到底换了几个槽位、有没有下发"，
再决定是动槽位时长还是动到达判据。**不要**直接调小 `ADVANCE_HOLD_TICKS`
（那是拿阈值当修复，与 prompt §4 的纪律冲突）。

## 5. 改动清单与校验

| 文件 | 改动 |
|---|---|
| [behavior_tree.py](source/adjutant_coordinator/graph/behavior_tree.py) | 新增 `_target_hash` / `TARGET_HASH_SPAN`；`_advance_slot(bb, point)` 把目标哈希并入 id 序号；`_advance()` 传入航点 |
| [test_behavior_tree.py](source/adjutant_coordinator/tests/test_behavior_tree.py) | 新增 2 例（换目标必换 id / 同目标必同 id） |

```powershell
python -X utf8 -m unittest test_behavior_tree ...   # 40 tests，仅 1 个既有迁移口径失败
python -X utf8 nav_sparsity_local.py --out .../round-13/ab_id --runner `
    --observe-seconds 240 --with-ai false            # rc=0
python -X utf8 round-12/gap_classify.py <archive_a864c83a> --from-tick 1028 --to-tick 11868
```

## 6. 未验证 / 边界

- **各 1 局**。`707eb88f` 与 `a864c83a` 是两局不同的对局（时长、兵力、遭遇都不同），
  所以 32.2 → 27.4 秒**不能**当成严格的 A/B —— 但"机制侧不同 id 数 33.0 → 50.8"
  是**同一口径的代码行为证据**，与结果同向，所以我给出"实质改善"的判断而不是"证明修好"。
- 真停滞判据仍是"空档内 0 次到点 + 位移 ≤0.5 米" ⇒ 等价于**没有证据表明它动过**，
  不等于证明完全静止（同 round-12 的边界）。
- 槽位时长 `ADVANCE_HOLD_TICKS = 900` 与停滞中位 28 秒的量级吻合，是**强相关**，
  但"停滞单位在空档内换了几个槽位"本轮**没有逐条量**，是本轮遗留的下一步。
