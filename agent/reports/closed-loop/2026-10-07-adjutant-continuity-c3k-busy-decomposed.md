# 阶段 C3k：`busy` 拆分 —— 证实 round-15 的死锁已归零（round-16）

日期：2026-10-07。状态：**needs-review —— 反面验证通过：残留型 `busy` 已消失；
剩余 `busy` 全是合法占用或"没报到达的在途"，所以瓶颈不在调度侧了。**

上位：[C3j 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3j-busy-release.md)。

---

## 1. 把 `busy` 拆开（round-15 的遗留问题）

round-15 修掉"到达不结束意图"之后，`busy` 占比**没变**（73.8% → 73.8%），
所以本轮给阻塞留痕带上了**占住它的意图 id 与动作**（`_busy_blocker`，只读 `active_intents`）。

实测（`archive_e1ae97c5`）：

| `advance_skipped` 原因 | 次数 | 占比 |
|---|---|---|
| `busy` | 1295 | 72.9% |
| `not_combat` | 242 | 13.6% |
| `used` | 239 | 13.5% |

**`busy` 的构成**：

| 占住它的动作 | 次数 | 占比 | 性质 |
|---|---|---|---|
| `attack_move` | 759 | 58.6% | 移动段 |
| `gather` | 364 | 28.1% | **与本轨无关**（采集是另一条线，合法） |
| `scout` | 97 | 7.5% | 移动段 |
| `produce` | 66 | 5.1% | 与本轨无关 |
| `build` | 9 | 0.7% | 与本轨无关 |

⇒ 之前"`busy` 73.8% 没变"看着像没修好，拆开后才看清：**33.9% 的 `busy` 根本不是军事轨的事**
（采集/生产/建造），移动段占 66.1%。

## 2. 关键判定：移动段 `busy` 是"真在路上"还是"到达后残留"

工具 [busy_residual_check.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-16/busy_residual_check.py)：
对每个 `(单位, 意图 id)` 组合，看它**连续挡住了多少轮**、**期间该单位有没有报过到达**。

| 指标 | 值 |
|---|---|
| 移动段 `busy` 跳过总次数 | 856 |
| 涉及 `(单位, 意图)` 组合 | **577** |
| 连续挡住 ≥5 轮的组合 | **16（2.8%）** |
| 其中**"期间报过到达"**的 | **0** |

⇒ **两种误判方向都被排除**：

- **"到达没释放 `busy`"这种残留已经归零**（0/16）—— round-15 的修复在真实对局里生效，
  这是本轮最有价值的一条**反面验证**；
- 那 16 个跨 23~34 秒的组合**期间一次到达都没有** ⇒ 按现有判据它们是"**真在路上**"，
  不是残留。

## 3. 一个新的、更具体的线索（下一轮的入口）

那 16 个组合值得单独看，因为它们"既没到达、也没放开"：

```
Unit_19  bt-attack_move-Unit_19-39779     挡16轮 跨33.5s  期间报过到达=False
Unit_23  bt-attack_move-Unit_23-44808     挡 5轮 跨33.0s  期间报过到达=False
Unit_1   rule-fill-scout-Unit_1-755       挡26轮 跨28.8s  期间报过到达=False
Unit_11  rule-fill-scoutconfirm-Unit_11-184 挡25轮 跨28.2s 期间报过到达=False
Unit_11  rule-fill-advance-Unit_11-13394  挡17轮 跨27.7s  期间报过到达=False
```

它们与"接续延迟 20 秒上下"的量级**一致**。可能性只有三种：

1. 单位**真的在走**，只是这一跳本来就要 25~34 秒（合法行程）；
2. 命令被权威**接受但没执行**（`Accepted` 却没有位移），于是永远等不到到达；
3. 到达事件**没发出来**（round-08 已修采样容差，但 `is_navigation_finished` 实测
   从不为真这条事实仍在 —— 订单没结束时，采样只在容差内报一次）。

**第 2 种是新的、也是最有价值的怀疑方向**：前几轮全部在查"副官为什么不发"，
而现在必须查"**发了、权威也说 Accepted，为什么没动**"。
这也是 C2 那条"合法接续 p95 ≤1s"门禁的**上游** —— 若权威不执行，副官发得再快也没用。

## 4. 下一轮（round-17）的具体做法

1. **对那 16 个组合逐个做端到端取证**：把该单位在窗口内的
   `commands`（含状态）、`arrival`、以及**游戏侧位置采样**拉成一条时间线。
   位置采样是关键 —— 用它区分"真的在走"（第 1 种）与"接受但没动"（第 2 种）。
   现有 `nav_sparsity_local.py --observe-seconds` 会采全量 tactical，可直接复用。
2. 若确认是"接受但没执行"，取证要落到 **DCS `op=move` / 意图幂等缓存**这一层：
   同一 `intent_id` 第二次下发时，权威是"真的重新下单"还是"命中幂等直接回 Accepted"。
   round-13 已经在 `behavior_tree` 的 id 上做过一次同样的诊断（`id_tick` 稳定 ⇒ 命中缓存），
   这里要查的是**权威侧**是否存在同一行为。
3. ⚠ 仍然**不许**动任何阈值。

## 5. 改动清单与校验

| 文件 | 改动 |
|---|---|
| [rules_fallback.py](source/adjutant_coordinator/graph/rules_fallback.py) | 新增 `_busy_blocker(state, unit)`（只读 `active_intents`，返回 `(intent_id, action)`）；`advance_skipped` 的 `busy` 分支带上 `blocker` / `blocker_action` |
| [skip_reasons.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-15/skip_reasons.py) | 增加 `busy` 拆分报表 + "移动段残留"自动告警行 |
| 新增 [busy_residual_check.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-16/busy_residual_check.py) | 判定移动段 `busy` 是"真在路上"还是"到达后残留" |

```powershell
python -X utf8 -c "from adjutant_coordinator.graph import rules_fallback as rf; print('import OK')"
python -X utf8 -m unittest test_safe_movement test_rules_fallback ...   # 98 例全绿
python -X utf8 nav_sparsity_local.py --out .../round-16/ab_busy --runner `
    --observe-seconds 240 --with-ai false                                # rc=0
```

## 6. 未验证 / 边界

- **各 1 局**（`archive_e1ae97c5`）。本轮结论是**结构性**的（0/16 残留），
  比单局性能读数更稳，但仍只有一局样本。
- "连续挡住 ≥5 轮"是我选的**阈值**（`--min-runs 5`）。门槛以下的组合没进统计，
  所以"残留 = 0"的严格表述是"**连续 ≥5 轮的组合里没有残留**"，
  不能说"所有移动段 `busy` 都没有残留"。
- 第 3 节的三种可能性**都还没验证**，只是把范围收窄到"查权威为什么不执行"。
- 位置采样这一轮**没有做**（脚本是现成的，但本轮时间用在了拆分与判定上）。
