# 阶段 C4a：军事轨逐出口追踪 —— 追到"`_room()` 在入口就把整条轨截断"（round-31）

日期：2026-10-07。状态：**needs-review —— 建成可复现的逐出口漏斗追踪；
它把 round-30 那句含糊的"卡在第二道闸"追成了**具体一行**；
并纠正了我自己两处误判。**

上位：[C3z 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3z-log-encoding.md)。

---

## 1. 本轮的主要产出：可复现的逐出口漏斗追踪

军事轨有**五处静默 `continue`/`break`**，只看最终输出无法区分是谁拦的。
新增 `_trace_gate(state, unit, gate, **extra)`：

- 仅在 `AIRTS_ADVANCE_TRACE` 给出文件路径时写；
- **不走 stdout** ⇒ 不受控制台编码限制（round-29 的 `⇒` 事故）；
- **不进 `decisions.jsonl`** ⇒ 不被 `MAX_DECISION_LOG` 挤掉（C-104）；
- 写失败静默；生产路径默认零成本。

埋点：`ordered`（循环输入）、`enter`、`no_waypoint`、`en_route`、`emitted_advance`。

## 2. 用它追出的**具体一行**：`for` 循环的第一句就是 `_room()` 的 `break`

单测场景（6 个忙作战单位 + 1 个刚到达的 `Unit_12`）的追踪：

```
LOOP-INPUT: {"count": 8, "start": 0,
             "units": "Unit_12,Unit_0,Unit_1,Unit_10,Unit_11,Unit_13,Unit_14,Unit_15"}

enter 记录: index 1..7 = Unit_0,Unit_1,Unit_10,Unit_11,Unit_13,Unit_14,Unit_15
            index 0 —— **完全没有记录**
```

三点结论：

1. **循环输入是对的**：8 个单位都在，`Unit_12`（刚到达）经到达优先排序后被放到 **index 0**；
2. **但 index 0 从未到达 `enter` 埋点**；
3. 而 `enter` 埋在 `for` 循环体的**第一道闸之后**，它上面的第一句正是：

```python
for index, name in enumerate(ordered_units):
    if not _room():
        _note(state, "advance_batch_full", emitted=len(out), remaining=total_units - index, ...)
        break                     # ← 整条军事轨在这里被截断
```

⇒ **`_room()` 在 index 0 上就返回假 ⇒ 整条军事轨本轮一条不产。**
`emitted=1` 说明那 1 条是**侦察轨**的意图（`rule-fill-scout-Unit_1-600`）。

**这就是 round-30 我说不清的"第二道闸"，现在是一个有名有姓的分支。**

## 3. 纠正 round-30 的两处误判（都记下来）

| round-30 我说过 | 实际 |
|---|---|
| "卡在第二道闸（下游某处）" | 是 **`_room()` 在循环第一句 `break`**，位置在**最前面**而不是下游 |
| 暗示"下游还有东西不让它产出" | 起因还叠着**测试自己的 bug**：我在同一个 `state` 上把 `_parallel_intents` 调了**两次**，而它会推进 `advance_cursor` ⇒ 第二次换了起点 |

**同类错误第 5 次**（前四次 round-23/25/29/30）——都是"**把有副作用的东西当纯查询用**"。
本轮固化成两条纪律：
① 被断言/被观测的函数若会改状态，**只调一次**；
② 观测点写在**函数内部**（本轮做法），不靠"再调一次看看"。

## 4. 生产局与单测的差异（重要，避免把单测结论外推）

在生产局（`trace2` / `1f157a6d`，`run_health` **OK** / 252 ticks / 0 错误）开了同一个追踪：

```
追踪总条数 = 1978
各出口: {'enter': 1646, 'emitted_advance': 332}
enter 的 index 分布: {0:178, 1:141, 2:114, 3:100, 4:87, 5:86, 6:74, 7:72, ...}
index=0 出现 178 次（10.8%），且随 index 单调递减
```

⇒ **生产里 `index=0` 是正常出现的**（分布形状也符合轮转预期）。
所以 §2 的"index 0 缺失"是**单测场景特有的**（那里侦察轨先把名额占满了），
**不能**外推成"生产里有的单位永远不被考虑"。

**但仍然有意义**：它说明 **`_room()` 的名额是全轨共享的，
而且它在循环第一句就 `break`** —— 一旦名额被先跑的那条轨用掉，
**整条军事轨这一轮一个单位都不看**（连"哪些单位被跳过"都不留痕，只记一条 `advance_batch_full`）。
这与 C-093 量到的"单位平均多等 2~3 轮"是**同一方向的机制**。

## 5. 下一轮（round-32）

1. **量 `_room()` 的截断频率与代价**：用本轮的追踪统计"每轮 `enter` 数 vs 应服务单位数"，
   看有多少轮是"跑到一半被名额截断"、有多少轮是"第一句就截断"。
   **先量，再谈改**。
2. 若截断普遍：考虑把"**刚到达的单位**"放在名额分配的最前面
   （现在它是排序最前，但 `_room()` 的判定发生在**看到它之前**吗？——需读 `_room()` 定义确认）。
3. ⚠ 仍**不许**动任何阈值；**不许**为了门禁数字改判据。

## 6. 未验证 / 边界

- §2 是**单测场景**的证据；§4 已说明生产里 `index=0` 正常 ⇒ **不外推**。
- `_room()` 的具体判据（它按什么算"名额"）**本轮没读**，所以 §5-2 的疑问留着。
- 本轮**没有**改任何调度判断或阈值；新增的是**只读追踪**、`import json/os`、
  以及测试纠正。
- 追踪在环境变量未设时完全不生效。
- 按 AGENTS.md 工作区边界要求核对：`check_workspace_target.py --mode develop`
  → `allowed_for_development: true`。
