# 阶段 C5l：⚠ 命令账**不记录目标点** ⇒ round-49 的推断**无法用归档核验**（round-50）

日期：2026-10-07。状态：**needs-review —— 我按计划去核验"规则轨目标是否每轮都变"，
结果发现**这条核验在当前归档下做不到**：`commands.jsonl` **没有 `target` 字段**。
这是一处**观测缺口**（不是我推断对了或错了），需要补埋点才能判。**

上位：round-49 [C5k 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c5k-id-not-a-defect.md)。

---

## 1. 我原本要核验什么

round-49 我从 `military_waypoint` 的**入参**推断：

> "目标是每轮按单位当前位置重算的 ⇒ 目标变则 id 必须变 ⇒
> `rule-fill-advance` 每轮换 id 是**合法的**。"

这是**推断**。本轮计划**直接量**相邻两条 `rule-fill-advance` 的 `target.pos` 位移：
若普遍 > 0.5m ⇒ 目标确实在变（推断成立）；
若普遍 < 0.5m 而 id 仍每轮变 ⇒ **那才是真问题**。

## 2. 结果：**做不到** —— 命令账里根本没有目标点

写了 [target_stability.py](agent/runs/2026-10-07-adjutant-continuity-fix/round-50/target_stability.py)，
在 3 个档案上跑，全部返回 **"没有可用的 rule-fill-advance 目标样本"**。
查一条真实记录的全部键：

```
['accepted', 'action', 'command_id', 'error_code', 'expires_tick', 'generation',
 'intent_id', 'issued_tick', 'order_id', 'reason', 'server_tick', 'status',
 'task_id', 'unit_ids']
```

**没有 `target`**（也没有 `target_pos` / `pos` / `destination`）。

### 2.1 定位到根因

`agent_runner.py:1965` 用**固定字段清单**构造归档记录：

```python
archive.command({
    "server_tick": ..., "intent_id": ..., "command_id": ...,
    "action": ..., "unit_ids": ..., "issued_tick": ..., "expires_tick": ...,
    "status": ..., "accepted": ..., "reason": ..., "error_code": ...,
    "order_id": ..., "generation": ..., "task_id": ...,
})          # ← 清单里没有 target
```

⇒ **目标点在写档这一步被丢掉了**，与意图/回执里有没有它无关
（我没有继续追 `Receipt` 是否携带 `target` —— 见 §5）。

## 3. 这是一个**观测缺口**，不是"推断被证实或证伪"

必须说清楚：**本轮既没有证实也没有否定 round-49 的推断**。
它仍然只是**推断**（依据是 `military_waypoint` 的入参与文档）。

**要判定它，需要补埋点**：在 §2.1 那个字段清单里加上目标（或加一个哈希/取整后的目标，
避免档案膨胀）。**这属于"改产品代码"**，应当作为一个**明确的观测候选**来做，
而不是顺手加。

## 4. 为什么这个缺口值得单列（影响面不止本轮）

同一个缺口会挡住**一整类分析**：

| 想回答的问题 | 是否受阻 |
|---|---|
| "目标是否每轮变"（本轮） | **受阻** |
| "改写令是否真的换了目的地" | **受阻** |
| "同一目标被反复下令几次"（幂等回放是否发生） | **受阻** |
| "单位实际到位点 vs 命令目标点的偏差" | **受阻**（`events.jsonl` 有到达点，但命令目标点没有） |

而**不**受阻的：命令的**动作/状态/时序/单位/id**（这些都在）。
⇒ 这也解释了为什么我此前几轮**总是绕开"目标"**去分析行为 ——
不是我没想，是**归档里没有**。

## 5. 未验证 / 边界

- §2.1 的根因是**读代码确认**的（字段清单就在那里）。
- 我**没有**继续追 `Receipt` / `submit_command` 是否**携带** `target`
  —— 本轮预算用在了"发现缺口"上。**这是下一步的第一件事**
  （若回执本来就不带目标，那补埋点要动的地方更深）。
- 本轮**未改产品代码、未跑新局**（只读分析）。
- `target_stability.py` **没有产出任何结论**，它的价值是"把缺口暴露出来"；
  等埋点补上后可以直接复用。

## 6. 下一轮（round-51）

1. **追清 `target` 从图内意图到回执的完整链路**：
   `make_intent` 有 `target` → 送网关 → `Receipt` → `archive.command`。
   确定**它是在哪一步丢的**（是回执不带、还是归档没抄）。
2. 若确实在归档层丢 ⇒ 提出一个**最小观测改动**：把目标（或取整后的目标）
   加进 `archive.command` 的字段清单。**这是纯观测、不改行为**，
   但要按纪律**先量档案体积影响**（`commands.jsonl` 现在 406~1776 行/局）。
3. ⚠ 不许盲目乘倍率；判据口径的最终选择仍待用户（C-163）。
