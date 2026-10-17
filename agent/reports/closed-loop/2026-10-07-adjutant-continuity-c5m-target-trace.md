# 阶段 C5m：`target` 丢失链路的完整追查（round-51）

日期：2026-10-07。状态：**needs-review —— 追清了。**两个独立原因叠加**：
① 游戏回执**本来就不带**目标点；② 每轮归档时 `intents` 是**空的**（意图已清）。
⇒ 想把目标补进归档，**不是"抄一个字段"，而是要动到归档时机或另开一路数据**。**

上位：round-50 [C5l 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c5l-no-target-in-archive.md)。

---

## 1. 追查路径与结论

链路：`make_intent`（**有** `target`）→ 送网关 → `Receipt` → `archive.command`。

| 环节 | 是否携带目标 | 依据 |
|---|---|---|
| `make_intent` | ✅ 有 | 意图字面量里有 `target` |
| 网关/DCS 回执 | ❌ **不带** | `DebugControlServer.gd` 设的字段是 `intent_id` / `intent_action` / `generation` / `command_id` / `item_id` / `producer` / `scene` / `queue_size` / `ok` / `accepted` / `reason` / `source` —— **没有目标** |
| `Receipt`（Python 侧） | ❌ 不带 | 只有 `command_id` / `status` / `accepted` / `reason` / `raw`；`_settle` **原样返回**，不附加目标 |
| `archive.command`（`:1965`） | ❌ 抄的是回执 | 固定字段清单，**清单里没有目标** |

⇒ **第一层原因**：`archive.command` 拿的是**回执**，而回执里从来没有目标
（不是"归档漏抄了"，是**上游就没有**）。

## 2. 我上轮漏看的一路：`rounds.jsonl` 其实**设计上**带位置

`_compact_intents` **确实**把目标位置写出来了：

```python
out.append({
    ...,
    "scene": str(target.get("scene", "")),
    "pos": (target.get("pos") or [])[:2] or None,
    ...
})
```

**但实测 `rounds.jsonl` 里 `intents` 是空的**：

| archive | `rounds.jsonl` 的 intent 条数 | 带 `pos` |
|---|---|---|
| `ab487d43` | **0** | 0 |
| `81893e7b` | **0** | 0 |

（我上轮第一次查用的是键名 `target`，而它写的是 `pos` —— **我的查法错了**；
改正后才发现真正的问题是"条数为 0"。）

**第二层原因**：`_archive_round` 读的是
`(getattr(result, "state", {}) or {}).get("active_intents")`，
而**归档发生在每轮末尾**，那时活跃意图已经清空（round-30 就观察到过
"意图在轮末消失"这一现象）。⇒ **两路都拿不到目标。**

## 3. 所以要补目标，需要动的是"时机/通路"，不是"抄个字段"

候选（**均未实施**，按纪律先列出、先量代价）：

| 方案 | 做什么 | 代价/风险 |
|---|---|---|
| **A** | 在**下发那一刻**（`node_dispatch_to_godot`，意图还在）把目标写进一条**独立的轻量流**（或复用 `decision_log`） | 要新增一路数据；但时机正确、数据最全 |
| **B** | 让 `archive.command` 从**图内意图表**里按 `intent_id` 反查目标，而不是只抄回执 | 归档时意图可能已清（§2）⇒ **不可靠** |
| **C** | 让 DCS 回执**回带**目标（游戏侧改） | 动游戏侧协议；影响面最大，**最后考虑** |

**我倾向 A**，但它要新增观测通路 —— **按 prompt §4（一轮一个明确候选）应当单独一轮做**，
并且**先量档案体积影响**（`commands.jsonl` 现 406~1776 行/局）。

## 4. 未验证 / 边界

- §1 的"DCS 回执不带目标"是**读 `.gd` 里 `receipt[...] =` 的全部赋值**得出的；
  我**没有**核验是否有别处（例如 C# 侧或另一个函数）往回执里塞目标。
- §2 的"归档时 `active_intents` 为空"是**从实测条数为 0 反推**的；
  我**没有**在归档点直接打点确认（那需要改代码或加追踪）。
- 方案 A/B/C **均未实施**，本轮**未改产品代码、未跑新局**。
- `target_stability.py`（round-50 写的）**在当前归档下仍然无法工作**，
  等目标数据可读后可直接复用。
