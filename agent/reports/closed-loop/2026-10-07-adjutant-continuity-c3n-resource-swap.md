# 阶段 C3n：剩余 `ResourceDepleted` 归因 + 换矿（round-19）

日期：2026-10-07。状态：**needs-review —— 补上运行时证据、排除"观测缺字段"、
判定剩下的是竞争/滞后，并用"换矿"把 gather 接受率推到 53%。**

上位：[C3m 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3m-resource-depleted.md)。

---

## 1. 补上 round-18 缺的**运行时证据**（这是本轮第一件事）

round-18 修"字段名对不上"时只有**代码证据**（两侧字段名逐字对照）——
现有产物里资源实体出现次数**都是 0**，无法证明副官到底收到了什么。
本轮给探针加了原始回包落盘（`report["resource_entities"]` / `resource_shapes`），
跑一局后拿到 **16 个资源实体**，字段组合固定：

```
['kind','name','ore_capacity','ore_depleted','ore_regen_cycles',
 'ore_remaining','pos','regen_remaining_ms','resource_kind']

{"name":"ResourceA",  "ore_capacity":30000, "ore_depleted":false, "ore_remaining":30000, ...}
{"name":"ResourceA2", "ore_capacity":500,   "ore_depleted":false, "ore_remaining":500,   ...}
```

⇒ **round-18 的修复依据成立**（观测确实带 `ore_remaining`/`ore_depleted`，
旧实现确实不认这两个名字）。这条假设**从代码证据升级为运行时证据**。

## 2. 判定剩下的成因：**竞争/滞后**，不是"挑错了矿"

工具 [depleted_race_check.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-19/depleted_race_check.py)
看接受/拒绝随时间的**翻转次数**（若系统性地一直挑错矿，应该是一路全拒、翻转≈1）：

| 档案 | gather | 接受 | 拒绝 | 翻转次数 | 前 60 条序列（A=接受 R=拒绝） |
|---|---|---|---|---|---|
| `8c4158d1`（修复前） | 148 | 13 | 135 | **75** | `AARRRRRRRR…(47 个 R)…AAAAARRRRRRRR` |
| `8d032e38`（字段名后） | 155 | 50 | 105 | **55** | `AAARRRRRAAARARRARRRRRRAARRAARRRRRRAAARRRARRRRRRRARRRAAAAAAAA` |

**翻转 55/75 次**、序列 A/R 交错 ⇒ 我们**确实在挑有存量的矿**，
但命令**发出去之后矿被采空了**。两条成因都符合这个特征：

- **竞争**：每节点最多 2 个工人（`RESOURCE_WORKERS_PER_NODE`），但一个 `ore_capacity=500`
  的小矿，2 个人几秒就能采空；
- **滞后**：矿在两次观测之间被采空（探针采样间隔实测 ≈2.5 秒）。

顺带记下两条读数：**被重复下发的 gather intent 只有 4 个**（不是刷屏重试），
拒因 **105/105 全是 `ResourceDepleted`**（没有别的错误码混进来）。

## 3. 修复：按「单位 × 矿点」记**限时**账 → 下一轮直接换矿

实测已经说明：这种情况下**重发同一条命令只会继续被拒**，唯一正确的动作是**换矿**。
所以按仓库里既有的模式（`ban_unattackable_target` 那套）做了对称的一档：

| 处 | 改动 |
|---|---|
| `placement.py` | 新增 `REJECT_RESOURCE = "resource"` 与 `RESOURCE_KINDS`；把 `ResourceDepleted` / `ResourceTargetNotFound` / 中文原文归到这一类 |
| `rules_fallback.py` | 新增 `RESOURCE_BAN_TICKS = 900`（15 秒）、`ban_depleted_resource()`（按 `单位 × 矿点`，有界 256、按时间清理）、`resource_usable_by()`（只读账本判"这个矿对这个单位现在能不能用"）；采集轨挑矿后若命中拉黑账，**在候选里重挑别的矿** |
| `nodes.py` | 拒绝处理新增 `RESOURCE_KINDS` 分支：记 `resource_depleted` 决策 + 写账本 |

**为什么是"限时"而不是像工地那样"几乎永久"**（`SITE_BAN_TICKS = 180000`）：
矿点**会再生**（`ResourceUnit`：ready → depleted → ready，实测 `regen_remaining_ms = 90000`），
永久拉黑会把一个本会恢复的矿废掉。15 秒足够换矿，又不至于误伤。

守门测试（[test_resource_allocation.py](source/adjutant_coordinator/tests/test_resource_allocation.py)
的 `DepletedResourceBanTest`，4 例，全绿）：
① 拉黑**按单位**且**限时**（别的单位仍可用；窗口过期自动恢复）；
② 账本有界（≤256）；③ 两处常量必须相等（`rules_fallback` 不能 import `placement`，会成环，
所以各留一份，用测试钉住）；④ 权威错误码必须被归类。

## 4. 实测：接受率 9% → 33% → **53%**，拒绝数 140 → 110 → **38**

| 组 | `gather` 接受 | `gather` 总 | 被拒 | `attack_move` | `build` |
|---|---|---|---|---|---|
| `8c4158d1`（原始） | **9%** | 154 | **140** | 98% | 45% |
| `8d032e38`（字段名修复后） | **33%** | 163 | 110 | 100% | 54% |
| **`0d944f08`（换矿后）** | **53%** | 81 | **38** | **100%** | 32% |

三轮都朝同一方向（9 → 33 → 53），且**绝对拒绝数降了 73%**（140 → 38）。

⚠ 但要如实说：`gather` 总条数同时从 154 降到 81（**发得少了**）。这不奇怪 ——
现在会避开刚被拒的矿、并在没有可用矿时返回 `None`（让上层转岗/等待），
而不是硬派。所以"接受率上升"里有一部分是**分母变小**。两个数一起看才诚实。

## 5. 仍未解决 / 下一轮

- 仍有 **38 条**被拒（15% 的 gather 总量）。竞争/滞后这条链**不会**因为换矿而消失 ——
  换矿只是"被拒之后别再撞同一棵树"。要真正压掉它，得让"派工"知道**在途工人会带走多少存量**
  （现在只按 `cap` 限人数，没有按 `ore_remaining` 折算"还能供几个人采多久"）。
- `build` 的接受率在第三局掉到 32%（45% → 54% → 32%），**本轮没查**（另一条链）。
- 门禁（到达→接续 p95）本轮**没有重测** —— 本轮都在修采集链，
  而采集链与"作战单位接续"是两条线；下轮应把门禁×采集一起量一次。

## 6. 改动清单与校验

```powershell
python -X utf8 -m unittest test_resource_allocation        # 19 例全绿
python -X utf8 -c "from adjutant_coordinator.graph import rules_fallback as rf, placement as pl; print(rf.RESOURCE_BAN_TICKS == pl.RESOURCE_BAN_TICKS)"   # True
python -X utf8 nav_sparsity_local.py --out .../round-19/ab_res --runner --observe-seconds 200 --with-ai false
#   → report 里有 resource_entities(16) / resource_shapes
```

## 7. 未验证 / 边界

- **各 1 局**，三局是**不同对局**，所以 9%→33%→53% 是三个独立读数、不是严格 A/B；
  但方向一致、机制侧证据（原始回包字段、翻转模式）与之同向。
- §4 那条"分母同时变小"必须和接受率一起读，否则会高估这次修复。
- "竞争/滞后"是从**翻转模式**推断的（A/R 交错 + 重复下发很少），
  不是直接观测到"矿被谁采空的那一刻"。要钉死需要把 `ore_remaining` 的**时间序列**落盘
  （现在只有单次快照 + 每次探针的 16 个实体，没有逐秒变化）。
- 探针的采样间隔实测 ≈2.5 秒；把它当作"观测滞后"的上界时要注意它本身也是被测对象的一部分。
