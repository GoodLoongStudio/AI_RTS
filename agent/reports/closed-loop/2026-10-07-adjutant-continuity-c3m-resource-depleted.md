# 阶段 C3m：gather 被 `ResourceDepleted` 拒绝 —— 字段名对不上（round-18）

日期：2026-10-07。状态：**needs-review —— 找到一个可复算的真缺陷并修掉（接受率 9% → 33%），
但**没有**修到底（仍有 110 条被拒），原因未查清。**

上位：[C3l 报告](agent/reports/closed-loop/2026-10-07-adjutant-continuity-c3l-ground-truth.md)。

---

## 1. 先纠正我上一轮的两处判断错误

### 1.1 "动得少的单位"是**工人**，不是"没被派出去的作战单位"

round-17 我看到 `Unit_2` "命令 48 条 / 接受 5 条"就下了"生成侧饿着它"的结论。
**错了，而且是两个错**：

- 那 48 条里 47 条是 **`gather`**（工人采集），不是作战推进；
- 更糟的是我的解析器把一个意图 id 里**多个单位名**只取了**最后一个**
  （`re.findall(...)[-1]`），于是 `Unit_2` 的战绩被严重低估 ——
  实际它有 **604 条 `attack_move` `Accepted`**。

**修正后的结论与本轮实际判定相反**：工人**不是**没拿到命令，而是**命令被权威拒绝**。

### 1.2 真正的判定要按**动作**看接受率，不是按单位看命令数

同一局（`archive_8c4158d1`）按动作统计：

| 动作 | 总数 | 接受 | 接受率 |
|---|---|---|---|
| `attack_move` | 1429 | 1402 | **98%** |
| `move` | 38 | 38 | 100% |
| `produce` | 37 | 37 | 100% |
| **`gather`** | **154** | **14** | **9%** |
| `build` | 22 | 10 | 45% |

⇒ **`gather` 是唯一的重灾动作**（9%），而 `attack_move` 几乎全通。
这解释了为什么工人"走一小段就停"：它们的采集命令压根没被接受。

## 2. 根因：副官与游戏**字段名对不上**，一个都没命中

`gather` 被拒的 `error_code` **全部**是 `ResourceDepleted`（140/140）。而游戏侧判据是
`UnitCommandService.cs:359`：

```csharp
if (!resource.Value.IsAvailable) return Rejected(..., CommandErrorCode.ResourceDepleted);
```

矿点采空后**不删除实体**（`ResourceA.gd`：*"采空不再删除实体：转入『耗尽等待』，
身份/位置/容量/再生计时全部保留"*），所以副官必须自己从观测里读"它是不是采空了"。
`DebugControlServer` **确实发了**这两个字段：

```gdscript
ore_entry["ore_remaining"] = ...   # resource_a + resource_b 的存量
if "depleted" in resource:
    ore_entry["ore_depleted"] = bool(resource.get("depleted"))
```

但 `observation_view.resource_available()` 检查的是**另一套名字**：

| 游戏实际发的 | 旧实现检查的 |
|---|---|
| `ore_remaining` | `remaining` / `amount` / `stock` / `left` |
| `ore_depleted` | `depleted` / `exhausted` |

**两组一个都不命中** ⇒ 落到函数末尾的 `return True`（注释写的是"观测缺存量字段时，
只要实体还在就当可用"）⇒ 副官持续把工人派往已采空的矿点 ⇒ 权威拒绝 ⇒
工人反复重发、每轮被拒，表现为"走一小段就停"。

**第二个缺陷**：`_nearest_resource` 的兜底分支

```python
if best is None:
    return _nearest_resource(unit, resources)   # ← 绕过了 cap，也绕过了可用性
```

"满了"（可以挤）与"空了"（派过去只会被拒）是两回事，这个兜底把**采空的矿重新引入**。

## 3. 修复

| 处 | 改动 |
|---|---|
| `observation_view.resource_available` | 同时认两套名字：`ore_depleted` / `ore_remaining` 与旧名；耗尽布尔优先，其次存量数值。注明矿点**会再生**（ready→depleted→ready），"耗尽"只表示**现在**别派 |
| `rules_fallback._nearest_resource` 兜底 | 兜底只在**可用**矿点里挑；全部采空时返回 `None`（让上层转岗/等待），**不硬派** |

守门测试（[test_resource_allocation.py](source/adjutant_coordinator/tests/test_resource_allocation.py)
的 `ResourceDepletionFieldNamesTest`，3 例，全绿）：
① 游戏字段名必须被认（`ore_depleted` / `ore_remaining`）；
② 旧字段名必须继续认（不破坏别处喂进来的观测）；
③ 兜底不得把采空矿重新引入，且"唯一矿点采空 ⇒ `None`"。

## 4. 实测：接受率**翻了三倍多，但没修到底**

同一套探针、同一配置，修复前后各一局：

| 动作 | 修复前 `8c4158d1` | 修复后 `8d032e38` |
|---|---|---|
| `gather` | 14/154 = **9%** | **53/163 = 33%** |
| `attack_move` | 1402/1429 = 98% | 846/846 = **100%** |
| `move` | 100% | 100% |
| `produce` | 100% | 100% |
| `build` | 45% | 54% |

⇒ 修复**确实生效**（接受率 ×3.7），但**剩余的 110 条仍然是 `ResourceDepleted`**。
所以"字段名对不上"是**真缺陷**，但**不是全部原因**。

## 5. 未解决的疑点（下一轮的入口）

剩下的 `ResourceDepleted` 只有几种可能，本轮**没能区分**：

1. **观测里其实没有这两个字段**：我试图从探针报告与 `runner.out` 里确认资源实体的形状，
   **两边都没有资源实体**（`ore_remaining` / `ore_depleted` / `resource` 出现次数**都是 0**），
   所以**无法从现有产物验证**"副官到底收到了什么"。要钉死必须直接看一次
   `op=tactical` 的原始回包（本轮没做）。
2. **竞争**：多个工人被派到同一个还有少量存量的矿，先到的采空，后到的被拒。
   ——这与"每轮重发"叠加就会持续产生拒绝。
3. **观测滞后**：矿点在两次观测之间被采空。

## 6. 下一轮（round-19）的具体做法

1. **先取证再改**：跑一局时把一次 `op=tactical` 的**原始回包**（含 `resource` 实体）
   落盘，确认 `ore_remaining` / `ore_depleted` 是否真的在、值是多少。
   这是唯一能区分上面 1/2/3 的办法。
2. 若字段在、值也对 ⇒ 是**竞争/滞后**，那就要在派工时**把"已派人次"计入存量估算**
   （现在只按 `cap` 限制人数，没有按"剩余存量够采多久"限制）。
3. ⚠ 仍**不许**动任何阈值。

## 7. 改动清单与校验

```powershell
python -X utf8 -c "from adjutant_coordinator.graph import observation_view as ov; print(ov.resource_available({'kind':'resource','ore_depleted':True,'ore_remaining':0}))"
#   → False
python -X utf8 -m unittest test_resource_allocation test_safe_movement test_rules_fallback ...
#   → 15 + 196 例全绿（仅既有 2 例 balance 迁移失败）
python -X utf8 nav_sparsity_local.py --out .../round-18/ab_depleted --runner `
    --observe-seconds 240 --with-ai false          # rc=0
```

## 8. 未验证 / 边界

- **各 1 局**，两局是**不同对局**，所以 9% → 33% 不是严格 A/B；但"字段名对不上"
  是**代码级可复算**的事实（两侧字段名逐字对照），不是统计推断。
- **本轮没能验证观测里到底有没有 `ore_remaining`**（现有产物都不含资源实体）。
  修复的依据是"DCS 源码确实发这两个字段 + 旧实现确实不认它们"，属于**代码证据**，
  不是**运行时证据** —— 这个区别很重要，round-19 第一件事就是补运行时证据。
- `build` 45%/54% 的低接受率**本轮没查**（是另一个动作、另一条链）。
- 我把 round-17 的两处判断错误写进 §1，因为它们的结论（"生成侧饿着工人"）
  与本轮实测相反，留着会误导后续轮次。
