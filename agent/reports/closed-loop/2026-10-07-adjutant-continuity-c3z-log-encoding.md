# 阶段 C3z：修掉日志编码隐患；候选重新启用后卡在**第二道闸**（round-30）

日期：2026-10-07。状态：**needs-review —— 产品级日志隐患已修（有验证）；
候选"刚到达跨过 busy"已重新启用且**确认生效**，但它在军事轨里**不是唯一一道闸**，
本轮未能产出可采信的绩效读数。**

上位：[C3y 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3y-arrival-accounting.md)。

---

## 1. 产品级修复：日志再也不会打挂对局

**问题（round-29 实测）**：`agent_runner._log` 直接
`print("[runner] " + line)`。stdout 是 **GBK**（中文 Windows 控制台默认）时，
日志载荷里只要有一个 GBK 编不出的字符（`⇒` U+21D2、`→` U+2192、emoji…），
`print` 就抛 `UnicodeEncodeError`。该调用点在 **tick 循环里** ⇒ 每轮都挂 ⇒
`rounds.jsonl`/`events.jsonl` **一条不写**、**整局作废**。

**这是产品级隐患，不只影响我**：任何人在任意 `_note`/日志字段写个箭头就能打挂真实对局。

**修复**：`_log` 三级降级，核心原则是"**日志永远不许把调用方打挂**"：
1. 先原样 `print`（控制台支持 UTF-8 时输出保持干净）；
2. `UnicodeEncodeError` 时降级为 `backslashreplace` 再打一次（**信息不丢**，只是转义显示）；
3. 再失败（stdout 已关闭等）静默放弃 —— 日志是旁路，绝不能影响指挥链。
落盘那份本就用 `encoding="utf-8"`，与 stdout 编码无关。

**验证**（不是"看起来对"）：把 stdout 换成 GBK 严格模式的流，打印含 `⇒`/`→` 的日志：

```
GBK 下 _log 是否不再抛异常: True
控制台实际收到: [runner] {"msg": "\u521a\u5230\u8fbe ...", "sym": "a\u21d2b\u2192c"}
```

⇒ 不再抛异常，且字符以 `\u21d2` 形式**完整保留**。

## 2. 候选重新启用：确认**它自己生效了**

`ARRIVAL_BUSY_OVERRIDE = True`（round-29 关闭 → 本轮打开）。
本文件的日志载荷也**改成纯 ASCII**（双保险：不走降级路径，输出保持干净）。

用一次性探针（写文件、避开控制台编码）确认四个条件：

```
Unit_12 recent=True busy=True en_route=False susp=False
```

⇒ 条件全部满足，`advance_busy_overridden = 1` —— **这一层确实放行了**。

## 3. ⚠ 但它卡在**第二道闸**：放行之后军事轨**仍然不产出推进意图**

同一次调用里：

```
outputs = 1
  id = rule-fill-scout-Unit_1-600   units = ['Unit_1']     ← 只有侦察轨的意图
override count = 1                                        ← 我的闸确实放行了
```

**没有任何 `rule-fill-advance-*` 意图**。也就是说：

- 第一道闸（`busy`）被我的候选打开了；
- 但 `Unit_12` 走完这道闸之后，**下游还有东西没让它产出推进意图**。

⇒ round-29 追出的竞态（"同轮释放→重建意图→下轮重新 busy"）**最多只是链条的一环**，
不是全部。**本轮没有继续往下猜**（近上下文预算上限），只把位置钉在这里。

## 4. 本轮的一个自省：同一类错误又出现了一次

为了让探针看到中间值，我一度把 `_en_route(name)` **调用两次**（一次打日志、一次判断）。
而 `_en_route` → `hop_in_progress` → `previous_route` **会顺手清理过期路线**（有副作用），
所以两次调用返回**不同结果** ⇒ "有调试信息"和"没调试信息"行为不一致。

已改成**只调一次并缓存**（`en_route = bool(_en_route(name))`），并把这条教训写进注释。
这与 round-23/25/29 那几次"把有副作用的东西当纯查询用"是**同一类错误**。

## 5. 下一轮（round-31）：不要猜，查第二道闸

`_parallel_intents` 的军事轨在放行 `busy` 之后还有几处会静默 `continue`/不产出。
下一轮**逐个出口加不加日志上限的计数**（沿用 round-29 的 `_bump_movement_stat` 手法），
把"放行后为什么不产出"定位到具体那一行，再谈改。

**明确不做**的事：
- 不为了让它产出而放宽别的闸（那会重演"改判据"）；
- 不在没有定位前再动这个候选；
- 仍**不许**动任何阈值。

## 6. 未验证 / 边界

- §3 只证明了"**第一道闸被打开、但没有产出**"；**下游是哪一道闸未定位**。
- 本轮**没有**任何可采信的绩效读数（门禁未测）⇒ 候选仍标为**未验证**。
- 日志编码修复有**直接验证**（GBK 流实测），可以算已修。
- 改动文件：`agent_runner.py`（`_log` 三级降级）、`rules_fallback.py`
  （候选启用 + `ARRIVAL_PRIORITY_WINDOW_TICKS` + ASCII 日志 + `_en_route` 只调一次）。
- 按 AGENTS.md 工作区边界要求核对：`check_workspace_target.py --mode develop`
  → `allowed_for_development: true`。
