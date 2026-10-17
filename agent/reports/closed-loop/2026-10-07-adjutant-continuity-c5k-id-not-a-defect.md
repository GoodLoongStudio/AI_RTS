# 阶段 C5k：读完游戏侧幂等缓存 —— round-48 的"机制未对齐"**不是缺陷**（round-49）

日期：2026-10-07。状态：**needs-review —— 补上 round-48 的关键缺口后，
结论**反转**：`rule-fill-advance` 每轮换 id **是与目标变化一致的**，不是缺陷。
我把一条合法的设计差异误读成了"未对齐"。**

上位：round-48 [C5j 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c5j-id-asymmetry.md)。

---

## 1. 补上缺口：游戏侧幂等缓存**在 GDScript 里，不在 C#**

round-48 我说"要读游戏侧 C# 的幂等缓存"。**读错了地方**：

- `source/csharp/**` 里**完全没有** `intent` / `IntentId`（全仓检索为空）；
- 真正的缓存在 **`source/net/DebugControlServer.gd`**：

```gdscript
# 幂等：同 intent_id 重复提交返回原回执（不重复下发、不重复扣费）。
var registry: Dictionary = _adjutant_intents.get(view_key, {})
if registry.has(intent_id):
    var prior: Dictionary = registry[intent_id]
    var replay: Dictionary = (prior.get("receipt", {}) as Dictionary).duplicate(true)
    replay["intent_id"] = intent_id
    replay["intent_replay"] = true
    return replay
```

⇒ **按 `intent_id` 去重是真实存在的**，而且是**游戏侧**（GDScript）。
C# 那层的 `CommandId` 是**每次新建的 Guid**，与幂等无关。

## 2. ⚠ 关键：注释本身就说明了"意图 id 必须随目标变"

`_adjutant_intent_evict_one` 上方的长注释（2026-09-11 实机实测）：

> "意图 id **必须带 tick**（`rule-build-<building>-<builder>-<tick>` /
> `bt-<action>-<unit>-<tick>`），否则重试会一直被游戏侧的幂等回执命中
> **最早那次结果** —— 那是"改了参数却毫无变化"的真凶。"

⇒ 与我 round-48 从 `_target_hash` 注释读到的**是同一条机制**，
而且**两处注释互相印证**。

## 3. ⭐ 但 `rule-fill-advance` 每轮换 id **是合法的** —— 结论反转

`military_waypoint` 的入参包含**单位当前位置**：

```python
origin = _pos2d(info) if info.get("pos") else base
point = military_waypoint(origin or base, bounds=..., state=state, unit=name)
```

而它的方向/半径是按**敌情与当前位置**算的。⇒ **单位一动，航点就变**
⇒ **目标变了，id 就必须变**（否则会踩注释里那条"新目标被当成旧命令丢掉"）。

所以：

| 轨 | id 机制 | 为什么这样是对的 |
|---|---|---|
| **bt 轨** | 槽位 + 目标哈希（每 ~3000 tick 换） | 目标**没变**时 id 稳定 ⇒ 幂等命中、不重置路径；目标变了 ⇒ 哈希变 ⇒ id 变 |
| **规则轨** | `tick`（每 ~140 tick 换） | 目标是**每轮按当前位置重算**的 ⇒ **每轮都可能是新目标** ⇒ id 必须跟着变 |

⇒ **两条轨的差异来自"目标从哪来"，不是"谁漏了机制"。**
我 round-48 把它写成"机制未对齐 / 语义相反"，**是误读**。

## 4. 那"每轮重置路径"这个担心呢？—— 有守卫

round-48 我担心"每轮新意图 ⇒ 每轮重置路径"。但 `rules_fallback` 在发前压令**之前**
有这道守卫：

```python
if _en_route(name):
    _note(state, "advance_skipped", unit=str(name), reason="en_route", ...)
    continue
```

⇒ **在途的单位根本不会拿到新命令**（这正是 round-06 立下的"到位再下一条"纪律）。
所以"每轮都发新命令"**不会**发生；只有在路线被作废（到达/路径失败/换版本）时才会重发，
**而那正是应该重发的时候**。

⇒ **不但不是缺陷，而且是自洽的。** round-48 的"机制未对齐"结论**撤回**。

## 5. 这轮的教训

**我把"两条路径实现方式不同"直接读成了"其中一条有缺陷"。**
这与 round-37/38 的教训**同族**（当时我把"侦察轨有 `reserve`、军事轨没有"
读成"疏漏"，实测证明军事轨**不该**有）。
两次都是：**看到不对称 ⇒ 假设是缺陷 ⇒ 实测/读码后否掉**。

**新纪律（第 4 次同类）**：**发现不对称时，先问"它们服务的输入是否不同"**，
再谈"谁漏了机制"。本轮如果我先问这一句（规则轨的目标是每轮重算的），
就不会写出 round-48 的那个结论。

## 6. 那 p50 阶梯（−62%）还能归因吗？

**不能**，而且本轮**没有**因此推进归因：

- §3 撤回了"规则轨未对齐"这个候选解释；
- 候选 α（稳定 id）在 bt 轨**确实是有效的机制**（它修的是"目标变了但 id 没变"），
  但**规则轨本来就不需要它**（目标变、id 也变）；
- ⇒ 阶梯更可能来自 **bt 轨的候选 α 本身**或 round-15 的 release/skip，
  但**仍然没有单变量对照**（round-48 §2 的三条障碍未变）。

## 7. 未验证 / 边界

- §3 的"单位一动航点就变"是从 `military_waypoint` 的**入参与文档**推断的，
  **没有**用实测数据核验"同一单位的连续 rule-fill 目标点是否真的每轮都不同"。
  **这是可以补的**（读 `commands.jsonl` 的 `target.pos`），留给下一轮。
- §4 的 `_en_route` 守卫是**读码确认**的（代码就在前压令之前）。
- 本轮**未改产品代码、未跑新局**。
