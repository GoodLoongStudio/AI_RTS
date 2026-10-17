# 阶段 C5o：幂等回放**确实在发生**，且归档把"缓存回执"当成新命令（round-53）

日期：2026-10-07。状态：**needs-review —— 用 round-52 补的目标埋点顺带查出：
**同一 `intent_id` 被重复下发（约 3~4%）**，其中**确有回放**
（`runner.out` 里 `intent_replay=true` 占 **3.4%**）。
而归档只留 `runner.out` 的**一部分字段** ⇒ **`commands.jsonl` 完全看不到回放**，
于是"回放的 Accepted"被当成了"新命令成功"。**

上位：round-52 [C5n 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c5n-target-instrumented.md)。

---

## 1. 怎么发现的

round-52 给 `dispatch_done` 加了 `pos` 后，顺手按 `intent_id` 统计重复：

| archive | dispatch 条数 | 不同 `intent_id` | **重复下发的多余条数** |
|---|---|---|---|
| `a37385dc` | 1502 | 1442 | **60（4.0%）** |
| `ab487d43` | 1776 | 1717 | **59（3.3%）** |

**最多的一条**：`bt-scout-Unit_1-19` 在 `a37385dc` 里被下发 **10 次**，
目标**恒为 `[40.0, 0.9]`**，状态**全部 `Accepted`**：

```
t=11405  Accepted  pos=[40.0, 0.9]
t=11649  Accepted  pos=[40.0, 0.9]
t=11709  Accepted  pos=[40.0, 0.9]
t=11709  Accepted  pos=[40.0, 0.9]
t=11793  Accepted  pos=[40.0, 0.9]   ← 同一 tick 三次
...
```

## 2. ⚠ 第一层：`commands.jsonl` **没有**回放标记

我先在 `commands.jsonl` 里查 `intent_replay` ⇒ **0**。
但 `intent_replay` 在**整个 runner 里根本没出现过**（全文件检索为空）——
因为 `archive.command`（`:1965`）用**固定字段清单**，**清单里没有这个字段**。

⇒ 与我 round-50 发现的"目标点丢失"是**同一个病根**：
**归档只抄自己列出的字段，回执里多出来的信息一律丢掉。**

## 3. ⭐ 第二层：`runner.out` 保留了原样回执 ⇒ 回放**确实在发生**

`runner.out` 里另有一路 `{"kind":"receipt", ...}` 是**原样回执**。查它：

```
receipt 条数=794  其中 intent_replay=true 的 = 27   （3.4%）
receipt 的键 = [accepted, action, command_id, expires_tick, generation,
                intent_action, intent_id, issued_tick, match_id, ok,
                plan_version, player_id, reason, request_id, result,
                rules_version, server_tick, status, task_id]
```

**27 条回执是缓存回放**（游戏侧 `DebugControlServer.gd:2235` 在命中幂等账本时
设 `replay["intent_replay"] = true`）。

⇒ **结论**：当 runner 把**同一个 `intent_id`** 再发一次时，
**游戏返回的是缓存里的旧回执，并没有重新执行命令**。
而 runner 把这条 `ok/accepted` 当作**新命令成功**记了下来。

## 4. 为什么这件事重要

1. **它给"命令账的成功数"打了一个折扣**：`commands.jsonl` 里的 `Accepted`
   有约 **3.4%**（以 `runner.out` 为准）不是"这次真的执行了"，
   而是"游戏说这条我以前收过"。
2. **它是一条真实的浪费**：重复下发消耗传输与仲裁预算，
   却**不产生任何新动作** —— 而 C-117 已证"名额/预算本就紧张"（45~61% 的轮被吃满）。
3. **`commands.jsonl` 与 `runner.out` 的口径不一致**：
   前者是"我们以为发了什么"，后者才含"游戏实际怎么回的"。
   ⇒ 以 `commands.jsonl` 为唯一依据的分析，**会把回放算成成功**。

## 5. 但我**没有**证明"重复下发有害"到什么程度

必须说清边界：

- 27 条回放是 `runner.out` 的口径；`dispatch_done` 的重复是 60 条。
  **两个数不能直接相减**（前者按回执行数、后者按 dispatch 条数，
  且账本有淘汰）。**回放占重复的比例我没有算准。**
- **重复下发本身不一定是 bug**：对**长时间意图**（`bt-scout-*` 存活 900 tick）
  重发可能是**有意的心跳**。我**没有**读生成侧的去重逻辑来确认意图。
- 本轮**没有**验证"回放的那几次如果真执行了会不会更好"。

## 6. 下一轮（round-54）

1. **读生成/仲裁侧的去重逻辑**：确定"同 `intent_id` 重发"是**有意的**（心跳/重试）
   还是**意外的**（去重键没生效）。这决定 §5 的第一条边界。
2. 若确有意外重发 ⇒ 用 `_remember_order`（round-14 已建的"已下发指纹"）
   或 `lanes` 的去重账来定位**哪条路径绕过了它**。
3. ⚠ 不许盲目乘倍率；判据口径的最终选择仍待用户（C-163）。

## 7. 未验证 / 边界

- §3 的 27 条是**一局**的读数（`runner.out` 794 条回执）。
- §2 的"病根同源"是**读码 + 两处字段清单对比**得出的，是硬的。
- 本轮**未改产品代码、未跑新局**（只读两个已有运行产物）。
