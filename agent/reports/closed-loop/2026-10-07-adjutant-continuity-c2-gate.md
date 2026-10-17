# 阶段 C2：到达→接续调度门禁与 A/B 对照（round-05）

日期：2026-10-07。状态：**needs-review —— 门禁未通过，且已证明"监督层不足以解决它"**。

> ⚠ **round-06 修正（必读）**：本文档 §3 表格里的 `never_continued`（128 / 130）是**旧口径**的
> 产物，已被证伪 —— 其中大部分是"**出生时的 arrival**"（单位生成同 tick 就有 arrival，
> 此前根本没有我们的移动指令），不是接续失败。修正后的配对式口径给出 **19（关监督）/ 0（开监督）**。
> **p95 = 31–33 秒、门禁 FAIL 的结论不变**，且分层后确认尾巴**全是战斗单位**（没有工人），
> 所以不是"合法采集等待"。详见 [C3 取证](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3-forensics.md)。
> 本文档保留原样以便对照"口径修正前后"的差别。

上位报告：[2026-10-07-adjutant-continuity-fix-deepseek.md](agent/reports/closed-loop/2026-10-07-adjutant-continuity-fix-deepseek.md)
本文件是 prompt §4 要求的**公开工程门禁的第一次实测**：
**到达事实 → 合法接续调度 p95 ≤ 1s**。

---

## 1. 口径（改口径等于改验收，必须写在最前面）

| 项 | 口径 | 来源 |
|---|---|---|
| 到达事实 | 游戏侧 `kind=arrival` 事件 + `server_tick` | `events.jsonl`（权威端产生，不是副官推测） |
| 接续调度 | 该单位在到达之后**第一次**被下发移动指令的 `issued_tick` | `commands.jsonl`，`action ∈ MOVEMENT_ACTIONS` |
| 归并 | 同一 `(unit, intent_id)` 只算一次（副官会对同目标反复下发，不归并会把延迟压到 0） | `commands.jsonl` 的 `intent_id` |
| 单位归属 | `commands.jsonl` 的 `unit_ids` **实测普遍为空**，单位名在 `intent_id` 里（`rule-fill-advance-Unit_33-4375`），取最后一个 `Unit_<n>` | 实测（不兜这层会把 1281 个到达算成 0 次接续） |
| 秒数 | `server_tick / 60`（游戏时钟权威；墙钟只作旁证） | `progress.GAME_TICKS_PER_SECOND` |
| 迟到上限 | 超过 120s 的"接续"不算接续（记 `never_continued`） | 本脚本常量 |

工具：[arrival_latency.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-05/arrival_latency.py)（独立可跑，不 import 产品包）。
另有交叉验证：[continuity_metrics.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-04/continuity_metrics.py)
按 0.25s 采样的坐标序列算"移动事件之间的间隔"。

## 2. A/B 设计

| 组 | 开关 | 含义 |
|---|---|---|
| `off`（对照） | `AIRTS_CONTINUITY_RESOLVE=off` | **完全关掉**连续行动监督（`node_ingest` 写 `disabled=True` 报告，不发恢复） |
| `fine`（处理） | `AIRTS_CONTINUITY_RESOLVE=fine` | 诊断 1s / 恢复 2s（比产品默认 2s/5s 更早介入） |

同一探针、同一 `--with-ai false` 配置、同一验收端口段、各跑一局真实对局（约 3–5 分钟）。
开关经 `--continuity` 传给 runner 子进程（`nav_sparsity_local.py`），**产品默认行为未改**。

**归属判定**（避免拿别人的局当证据）：对照组档案 `archive_edf8bd9a`、处理组 `archive_8583b242`，
由 `runner.out` 里的 `match_id` 与档案名逐字对上（[match_id_map.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-05/match_id_map.py)）。

⚠ **必须裁窗口**：两组对局时长天然不同（实测 181s vs 292s），而"对局越久越乱"是真实的
（后期多线交火）。所以最终对照只在**共同游戏时钟窗口 `tick 1028..11868`** 内比较。

## 3. 结果（共同窗口 `tick 1028..11868`）

| 组 | 到达数 | 已接续 | **从未接续** | p50 (s) | **p95 (s)** | p99 (s) | max (s) | ≤1s 占比 | 门禁 |
|---|---|---|---|---|---|---|---|---|---|
| `off`（关监督） | 522 | 394 | 128 | **0.617** | **33.05** | 43.53 | 49.17 | 62.4% | **FAIL** |
| `fine`（1s/2s） | 648 | 518 | 130 | 0.75 | **31.57** | 39.37 | 50.08 | 54.8% | **FAIL** |

处理组的监督确实在跑（同一档案）：**191 轮** `continuity_supervision` 决策、
**恢复请求 1350 次**、`diagnose` 386、`unexplained_fail` 1157、单轮最多 10 次恢复、43 个闲置单位。

## 4. 结论（三条，都要按原样写进上位报告）

1. **门禁远未达到**：两组的 p95 都在 **31–33 秒**，目标是 1 秒；约 **20–25% 的到达之后根本没有接续**
   （128 / 130 例）。"走一小段后等很久"现在有了 L1 级的公开数字，不再依赖观感。
2. **监督层（阶段 C1）不足以解决它，这是实测结论而不是推测**：把监督从"完全关掉"开到
   "1s/2s 更早介入"，p95 只从 33.05s 动到 31.57s（噪声量级），p50 反而从 0.62s 升到 0.75s，
   `never_continued` 从 128 变成 130（没有改善）。
   ⇒ `recover` 现在只做"作废路线缓存"，而在那 30 秒里**单位根本没被排进新的移动任务** ——
   瓶颈在**任务生成/组队层**，不在路由缓存层。
3. **对照组本身也是重要数据**：即使把监督完全关掉，中位接续仍有 **0.617s**（62% 在 1s 内）。
   也就是说"多数接续是快的"，坏的是**尾部**（p95 30s+）。这解释了为什么用户觉得"有时正常、
   有时卡很久"，也说明下一轮应该**盯着尾部**（那是同一批单位在同一局里的少数事件），
   而不是去优化中位。

## 5. 下一轮的切入点（按证据排序）

1. **在任务生成层找 tail 的原因**：拿 `never_continued` 那 130 个到达，
   逐个查它对应的单位在这一轮之后**为什么没有新意图**（规则阶梯没选它 / 被更高级任务占住 /
   在 `squad_unverified` 排队 / 被 `protected_unit` 排除 / 目标被判不可达）。
   ⚠ 注意 `navphasec` 局里 `protected_unit` 有 547 次 —— 先分清"工人本来就不该动"与"该动没动"。
2. **到达即优先服务**（prompt §3-C 原文"arrival/任务完成触发下一段优先服务"）：
   现在到达只是作废路线、等常规轮转。要在本轮就把该单位排到队首。
3. 把 `never_continued` 本身做成**可告警指标**（当前只在离线分析里可见）。

## 6. 未验证 / 边界

- 每组只有 **1 局**，样本量不足以做统计显著性判断；结论只对"数量级差异"负责
  （33s → 32s 在单局噪声内，所以我说"没有改善"，不说"更差了"）。
- 两组都只跑了 `PlainAndSimple`、`--with-ai false`（无接敌压力）。
  接敌/撤退/回防场景下的接续延迟**未测**。
- `commands.jsonl` 的 `status` 在收尾快照里普遍是 `PendingAuthority`（权威回执未合并回来），
  所以本口径量的是"**下发尝试**"，不是"权威确认接受"；真实位移的交叉验证来自坐标序列。
- 本轮**没有**改任何产品默认行为：`AIRTS_CONTINUITY_RESOLVE` 不设时，阈值仍是 2s/5s/10s。
