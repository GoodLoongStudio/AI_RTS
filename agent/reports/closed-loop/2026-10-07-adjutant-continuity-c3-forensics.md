# 阶段 C3 取证：到达之后为什么没有新指令（round-06）

日期：2026-10-07。状态：**needs-review —— 口径已修正、两条假设被证伪、线索收窄到一个可复现个案**。

上位：[C2 专报](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c2-gate.md)、
[主报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-fix-deepseek.md)。

---

## 1. 先修我自己口径里的两个缺陷（都会改变结论，必须先说）

### 1.1 "出生时的 arrival"被误算成"任务完成"

第一版把**每一个** `arrival` 都当作"一个任务完成、接下来该接续"。
实测（对照组档案 `archive_edf8bd9a`）：worker `Unit_19` 在 **tick 3486 生成、同一 tick 就有一条
`arrival`**，而它的第一条指令在 **tick 3514**。这类样本不是接续问题，是**出生事件**。

修正后的口径是**配对式**：`一条移动指令 → 它之后的第一次 arrival → 再之后的第一次移动指令`，
只有这个三元组才算一个接续样本；此前没有移动指令的 arrival 单列为 `no_prior_command`。

| 档案（共同窗口 1028..11868） | 旧："从未接续" | 新："从未接续" | `no_prior_command` | 接续 p50 | 接续 p95 |
|---|---|---|---|---|---|
| `edf8bd9a`（**关**监督） | 128 | **19** | 113 | 0.65s | **33.08s** |
| `8583b242`（**开**监督 1s/2s） | 130 | **0** | 132 | 0.88s | **31.78s** |

⇒ ① "约 20–25% 的到达之后从未接续"**不成立**，那是出生噪声；真实是 **19 / 409 = 4.6%（关监督）**、
**0（开监督）**。② p95 的结论**不变**（31–33 秒，门禁 ≤1s，FAIL）。
③ 顺带得到一个**监督层的真实战果**：开监督后"派出去就不管了"从 19 例降到 **0 例**
（与"监督只作废路线缓存"的设计一致 —— 它解决的是这一类，不是那 33 秒）。

### 1.2 样本列表被截断导致"晚到的到达全被误判"

`arrival_latency.analyse` 原本写 `samples[:400]`，而下游"哪些到达从未接续"是**从这份列表**里筛的
⇒ 第 400 个之后的到达全部被误判成 `never_continued`。已改为保留全量 + 报 `samples_total`。
（本轮数据恰好 < 400，所以上表数字不受影响；但这个缺陷会让**更长**的对局全部算错，必须修。）

## 2. 分层：33 秒的尾巴**不是**"合法的采集等待"

prompt §4 要求"受阻/等待资源/玩家接管/集结等有依据的等待单列"。按游戏侧 `unit_type` 分层：

| 组 | 战斗单位(combat) | 侦察(scout) | 工人(worker) |
|---|---|---|---|
| `edf8bd9a`（关监督） | n=385，p50 **0.63s**，p95 **33.08s**，≤1s 236 例 | n=5，p50 6.97s | **0 例** |
| `8583b242`（开监督） | n=507，p50 **0.85s**，p95 **31.78s**，≤1s 266 例 | n=9，p50 7.65s | **0 例** |

⇒ **样本 100% 是战斗单位 + 侦察**，一个工人样本都没有。所以那 31–33 秒**不是**采集往返、
**不是**工人建造，而是**作战单位推进**的停顿 —— 正是用户抱怨的那一类。

## 3. 两条假设被证伪（省下下一轮的时间）

| 假设 | 检验方法 | 结果 |
|---|---|---|
| "整段停顿是**全局**卡住（所有单位都停）" | [timeline_intents.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-06/timeline_intents.py) 按秒统计 `micro_control_added` / `intents_arbitrated` | **证伪**：停顿窗口内系统每秒仍产出 **5–14 条意图**、接受 3–14 条，没有一秒是 0（除收尾那秒） |
| "**线路饿死**导致某些兵种拿不到服务" | 同上，看 `movement_gate` 与线路轮转；`lanes.interleave` 逐轮从每条线各取一条 | **证伪**：闸门每秒 kept 2–14、blocked 多数为 0；`interleave` 是严格轮转，不存在"整条线被截掉" |

## 4. 线索收窄：一个可复现的个案（`Unit_22`，soldier）

工具：[unit_forensics.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-06/unit_forensics.py)
（`--worst 40 --limit 3` 直接给到最差样本 + 空档内到点轨迹）。

**事实（全部来自档案，可逐条复算）**：

```
Unit_22 是 soldier，tick 3608 生成于 (41.2, 40.0)
它的全部移动指令（commands.jsonl）：
  t=3632  attack_move  Accepted  rule-fill-advance-Unit_22-3632
  t=3812  attack_move  Accepted  rule-fill-advance-Unit_22-3812
  t=6881  attack_move  Accepted  bt-attack_move-Unit_22-7      ← 空档 51.2 秒！
  t=7046  attack_move  Accepted  rule-fill-advance-Unit_22-7046
它的全部到点（events.jsonl 的 arrival）：
  t=3745 (47.34, 49.13) → t=3931 (47.64, 51.88) → t=4175 (46.86, 61.40)   [Δ=9.5m]
  t=7029 (55.89, 69.03)  ← 从这里开始恢复正常，之后每 5–20 秒到一次点
```

- **它确实在走**（3931→4175 位移 9.5 米），所以这不是"假停滞"。
- 到达 4175 之后，它**连续 47 秒没有任何到点、也没有任何新指令**。
- 同期（4175–4650）决策账里提到 `Unit_22` 的次数 = **0**。
  ⇒ 它**不是被闸门拦下、不是被仲裁丢掉、也不是被拒绝** —— 它**根本没被生成过意图**。
- 同一档案在 tick 6881 之后又能正常继续（`bt-attack_move` 接手），说明能力/路径都没坏。

⇒ 因此**下一个要看的点非常具体**：`4175–4650` 之间，是什么条件让
"给 Unit_22 生成一条新 advance"这件事**没有发生**。两个待验假设：

1. **旧意图仍然活着并抑制新建**：`intents_arbitrated` 的 `merged`/判重把同单位新意图合并掉了，
   而旧意图的 `target` 恰好就是它已到达的点 → 每轮"已完成"却不换目标（`hop_in_progress` /
   `needs_replan` 的某个分支）。
2. **advance 目标点被"已到达"判定吃掉**：规则地板算出的前沿点离它当前位置 ≤ `ARRIVE_RADIUS_M`(3m)，
   于是新意图每轮一生成就被 `_movement_progress` 判 `completed`，净效果=没有新任务。

两者都能解释"决策账里 0 次提及"——因为**意图压根没进仲裁**（假设 2）
或进了但被合并（假设 1）。区分它们只需要在下一轮把该窗口的 `micro_control_added.intents`
原样打出来看 `Unit_22` 在不在里面。

## 5. 下一轮（round-07）的最小验证步骤

1. 对 `edf8bd9a` 的 `4175–4650` 窗口，打印**每一轮** `micro_control_added.intents` 的完整列表，
   看 `Unit_22` 是否出现在生成侧：
   - 出现 → 是**判重/合并**（假设 1），去看 `intent_already_tracked` 与 `merged`；
   - 不出现 → 是**生成侧根本没选它**（假设 2），去看前沿点与 `ARRIVE_RADIUS_M` 的关系。
2. 复现脚本已经就绪，不需要新起真实对局：本轮的三个脚本都只读档案
   （[unit_forensics.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-06/unit_forensics.py)、
   [timeline_intents.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-06/timeline_intents.py)、
   [latency_tiers.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-06/latency_tiers.py)）。
3. **不要**先动监督层：C2 已证明它对 p95 没有作用（1350 次恢复 ≈ 1.5 秒噪声），
   而它对"派出去就不管了"有效（19→0）—— 保持现状，去修 33 秒那一半。

## 6. 未验证 / 边界

- 每个 A/B 组仍只有 **1 局**，结论只对数量级负责。
- 分层用的 `unit_type` 取自 `events.jsonl` 的 `unit_spawned`；档案里没出现的单位会落到
  `unknown`（本轮 `unknown`=0，说明覆盖完整）。
- "空档内 0 次到点"是**强**证据（单位没走完任何一段），但"确实一动不动"没有直接的位置采样，
  因为本局的探针只采了 13 个单位的坐标、不含 `Unit_22`。下一轮若要钉死"静止 vs 缓慢移动"，
  应把 `--observe-seconds` 的采样面扩到全部机动单位（当前 `nav_sparsity_local.py` 采的是全量
  tactical，但报告只落 `samples_moved` 摘要 + 前 13 个）。
