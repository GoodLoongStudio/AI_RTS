# 闭环报告：建筑维修"太慢"——`Structure.gd` 回血攒账丢帧（2026-10-10）

## 用户口径

"现在建筑维修的速度太慢了"。

## 结论速览

**不是需要调参的手感问题，是一个 68× 的实现缺陷。** 玩家实际拿到的是
**0.088 HP/s**（代码自己写的口径是 **6.0 HP/s**）、**15.075 金/HP**（口径 **0.25**）。

## 权威来源（单点，已核验无镜像）

`source/match/units/Structure.gd`：

```gdscript
const REPAIR_RATE_HP_PER_SEC := 6.0
const REPAIR_COST_PER_HP := 0.25
```

原始设计口径见 commit `6794720`："维修按秒回血 6HP/s 耗 0.25金/HP"。

排除的其它可能来源：两个常量在全仓库**只出现在 `Structure.gd`**；
`config/balance/*.json`、`config/godot/*.json`、C# 侧、
副官协调器（`source/adjutant_coordinator/`）与副官手册
（`docs/ai-adjutant-handbook/`）**都没有维修速率口径**。

## 根因

`Structure._process` 的攒账只累加**资金**，回血却只加**当帧**那一份：

```gdscript
var heal = min(REPAIR_RATE_HP_PER_SEC * delta, hp_max - hp)   # 当帧应回的血
_repair_debt += heal * REPAIR_COST_PER_HP                     # 只把这个血的"钱"攒起来
var owed := int(floor(_repair_debt))
if owed < 1:
    return                                                    # 钱没攒够 1 金 → 这帧什么都没发生
...
if player.subtract_resources({"resource_a": owed}, ...):
    _repair_debt -= owed
    set_hp_without_damage(min(hp + heal, hp_max))              # ← 只回当帧那份，前面几十帧攒的血全丢了
```

数学后果：每付 1 金只回 `RATE × delta` 点血（而不是 `1 / COST = 4` 点），于是

- 实际速率 ≈ `RATE² × COST × delta` ⇒ **随帧率变化**；
- 实际单价 ≈ `1 / (RATE × delta)`。

独立复核用**同一探针改帧率**测得旧实现：30fps **0.2927 HP/s** / 129fps **0.0725 HP/s**
—— **同一条代码差 4.0×**，坐实了帧率依赖。

## 修复

`source/match/units/Structure.gd:110`，**1 行行为改动**：

```gdscript
set_hp_without_damage(min(hp + owed / REPAIR_COST_PER_HP, hp_max))
```

只回**已付钱的那部分**血（`owed` 金 × `1/COST` = 4×`owed` HP），
残余小数仍留在 `_repair_debt` 里；付钱在回血之前（`subtract_resources` 成功才回血），
`set_repairing(false)` 仍清零债务（未结算的 <1 金双方都不结算，对称、无套利）。

### 第二处改动：补傀儡端守卫（复核发现，用户授权按工程判断处理）

`source/match/units/Structure.gd:84-90`，**1 行行为改动**（放在 `_repairing` 短路之后，
不维修时零额外开销）：

```gdscript
	if NetSession.is_client_puppet():
		return
```

理由：本文件 `present_repairing` 的注释自己写着"changes only presentation,
never client HP or economy"，但这条契约此前只靠**三个调用方**遵守
（`UnitActionsController` 转发、`NetSync` 服务器侧才 toggle、客户端只走 `present_repairing`），
`_process` 里**没有**局部强制；而 2026-09-12 的历史注释正记着
"客户端只本地 `set_repairing` ⇒ 玩家看到点了维修没反应"这类事故。
复核已实测：傀儡态直接调 `set_repairing(true)` 会本地 hp +16 / 资金 −4。
加这一行把"只表现"从调用方约定升级为**局部不变量**，权威端路径零行为变化。

## 基线 vs 修复后（同一把尺子实测）

`tests/automated/StructureRepairRateTest.gd`：真实对局，指挥中心打到 1 HP → 开启维修
→ 预热 1.5 s → 计量 10 s（**不撞满血截断**，全程可计量）。

| 指标 | 代码口径 | 修复前实测 | 修复后实测 |
|---|---|---|---|
| 回血速率 | 6.0 HP/s | **0.116 HP/s**（同环境下慢 52×） | **5.997 HP/s**（偏 −0.05%） |
| 维修单价 | 0.25 金/HP | **12.908 金/HP** | **0.250 金/HP**（精确） |
| 逐帧账本恒等 | Δhp = 4 × Δ金 | **17/17 次结算违反** | **17/17 次结算干净** |

修复前（把 `:110` 临时改回旧实现后跑同一条测试）：

```
[INFO] 维修实测：10.00s 回血 1.16HP ⇒ 0.116 HP/s（口径 6.0）；花 15 金 ⇒ 12.908 金/HP（口径 0.25）
[INFO] 账本恒等：17 次结算，17 次违反（判据 Δhp = 4.0 × Δ金）
FAIL: 账本恒等被违反 17 次，前 3 条：扣 1 金却回 0.0851 HP（应 4.0000） | 扣 1 金却回 0.0861 HP（应 4.0000） | 扣 1 金却回 0.0907 HP（应 4.0000）
FAIL: 维修速率应为 6.0 HP/s（实际 0.116，容差 12%）
FAIL: 维修单价应为 0.25 金/HP（实际 12.908）
```

修复后：

```
[INFO] 维修实测：10.00s 回血 60.00HP ⇒ 5.997 HP/s（口径 6.0）；花 15 金 ⇒ 0.250 金/HP（口径 0.25）
[INFO] 账本恒等：17 次结算，0 次违反（判据 Δhp = 4.0 × Δ金）
Structure repair rate: 0 failure(s)
```

第一轮（3 s 窗口）读到 5.319 HP/s，差额是**整数金量化**：每次结算固定 +4 HP，
3 s 窗口只含 ~4.5 次结算 ⇒ 读数只在 {5.33, 6.67} 之间跳。独立复核指出这点后，
窗口加长到 10 s，读数稳定到 5.997。

### 换算成玩家感受（按 `config/balance/demo.balance.v1.json` 的 `maxHp`）

从 40% 血修满（缺口 = maxHp × 0.6）：

| 建筑 | maxHp | 缺口 | 耗时（改前 → 改后） | 花费（改前 → 改后） |
|---|---|---|---|---|
| 对地 / 防空塔 | 16 | 9.6 | 109 s → **1.6 s** | 145 金 → **2.4 金** |
| 机枪塔 | 24 | 14.4 | 164 s → **2.4 s** | 217 金 → **3.6 金** |
| 兵营 | 28 | 16.8 | 191 s → **2.8 s** | 253 金 → **4.2 金** |
| 车辆 / 飞机厂 | 32 | 19.2 | 218 s → **3.2 s** | 289 金 → **4.8 金** |
| 矿场 | 60 | 36.0 | 409 s → **6.0 s** | 543 金 → **9.0 金** |
| 指挥中心 | 80 | 48.0 | 545 s → **8.0 s** | 724 金 → **12 金** |

（由 `config/balance/demo.balance.v1.json` 独立核算，不依赖测试进程；
"改前耗时/花费"按 60 fps 的旧实现口径 0.088 HP/s / 15.075 金/HP 折算。）

⇒ 修复后就是 `Structure.gd` 自己写的 6 HP/s；改前是"修个指挥中心要 9 分钟、724 金"。

## 三层判据（第一轮只有第 3 层，独立复核判定"过松"后补前两层）

| # | 判据 | 容差 | 旧实现结果 | 新实现结果 |
|---|---|---|---|---|
| ① | 速率 6.0 HP/s（**测试自己钉死字面量**，不从实现读） | 12% | FAIL（0.116） | PASS（5.997） |
| ② | **逐帧账本恒等** `Δhp = 4 × Δ金`（唯一例外：被 `hp_max` 夹住的收尾那一笔） | **0** | **17/17 违反** | **0/17 违反** |
| ③ | 单价 0.25 金/HP | 12% | FAIL（12.908） | PASS（0.250） |

判据②是最锋利的门：与帧率、窗口长度、金粒度**全都无关**。
它单独就足以抓住这个缺陷（复核方独立实现的同类判据也是旧实现 12/12 违反、新实现 0/12）。

判据①的价值：把 `REPAIR_RATE_HP_PER_SEC` 6→4 这类"只调常量"的回归也挡住
（只靠单价判据会漏，因为单价与速率解耦）。

## 为什么 40×~68× 的缩水能活这么久

既有 `StructureRepairSellSmokeTest:42-45` 的断言只有 `hp > damaged_hp` 与
`resource_a < funds_before`：按缺陷实现 2 秒能回 0.3 HP，**照样通过**。
判据太弱 ⇒ 缺陷无人发现。按 AGENTS.md 第 5 条，这属于**判据过弱**（不是行为回归）。

## 改动文件

| 文件 | 改动 | 归属 |
|---|---|---|
| `source/match/units/Structure.gd:110` | 回血口径 1 行 + 根因注释 | **本次（我）** |
| `source/match/units/Structure.gd:84-90` | 傀儡端守卫 1 行 + 注释（复核发现，用户授权按工程判断处理） | **本次（我）** |
| `tests/automated/StructureRepairRateTest.gd` / `.tscn` | 新增三层判据测试 | **本次（我）** |
| `tests/automated/HeavyTankShellSpeedTest.gd` | 收尾改走 `SmokeTestExit`（消泄漏） | 本次（我，弹速任务） |
| `config/full_regression_suite.json` | 新增套件 `structure-repair-rate` | **本次（我）** |
| `agent/plans/2026-10-10-structure-repair-speed.md` | 计划 | **本次（我）** |
| `Structure.gd`（同文件其它 hunk）维修状态图标、`source/net/NetSync.gd` +4 行 | **并行 Agent 未提交工作，我原样保留** | 他人 |

⚠️ `Structure.gd` 的 `git diff --stat` 是 **53 insertions / 3 deletions**，其中只有
`:102-110` 属于本次修复；其余是并行 Agent 的维修图标表现层改动（`REPAIR_ICON_TEXTURE`、
`_repair_icon`、`present_repairing()`、`_repair_icon_anchor_height()`）与 `NetSync.gd` 的下发/应用。
独立复核也独立发现了这一点并追问归属 —— 结论：**不是我改的，我也没动它**。

工作区归属校验（`tools/check_workspace_target.py --mode develop`）：
全部改动文件 `decision=allow, role=development-source`。

## 证据：命令与退出码

```
python tools/run_targeted_godot_tests.py \
  --godot G:/AIRTS/godot_mono_471/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64_console.exe \
  --ids structure-repair-rate,structure-repair-sell,heavy-tank-shell-speed,heavy-tank-howitzer,automatic-construction
```

最终：**4/5 通过 + 1 项偶发**（`automatic-construction` 本轮新观测为 2/3 通过，见"范围外既有失败"第 3 条）。

| 套件 | 修复前 | 最终 |
|---|---|---|
| `structure-repair-rate`（新增） | **rc=1** | **rc=0** |
| `structure-repair-sell` | rc=0 | rc=0 |
| `heavy-tank-shell-speed` | — | rc=0（**日志干净**） |
| `heavy-tank-howitzer` | — | rc=0 |
| `automatic-construction` | — | **偶发**（同代码 3 连跑 绿/绿/红，与本改动无因果） |

### 反向验证（我自己做的，已恢复）

把 `Structure.gd:110` 临时改回 `min(hp + heal, hp_max)` → 同一条测试 **rc=1**，
判据② `17/17 违反`。恢复后：

```
SHA256 = FEAB31C0A368E9109662CF4CBE6968DD9B53D38DAFC0EA3F77D4101835D8F91A  (match=True)
size   = 9387 bytes (expect 9387)
line110 = set_hp_without_damage(min(hp + owed / REPAIR_COST_PER_HP, hp_max))
```

与改前**字节级一致**（该哈希也正是独立复核改前/改后双方记录的哈希）。

## 独立复核（Verifier 子代理）

方法与申报方**完全不同**：真实 `Match.tscn` + `PlainAndSimple` + HUMAN vs AI
（`NetSession.passive_ai_test=true` 消干扰），墙钟逐帧采样 `hp` / `resource_a`，
**不读 `_repair_debt`、不复用本条测试**。探针：`tests/automated/_IndepVerifyRepairSpeed.gd`。

| 项 | 复核实测 | 判定 |
|---|---|---|
| 速率（不限帧 / 30 / 144） | **5.9918 / 5.9761 / 5.9963 HP/s**（极差 0.34%） | **证实**（口径 6.0，偏差 ≤0.4%，帧率无关） |
| 单价 | **0.2500 金/HP**（三档一致） | **证实** |
| 账本恒等 | 逐帧 Δhp = 4 × Δmoney，12/12 干净；旧实现 12/12 违反 | **证实** |
| 边界：资金耗尽 | 给 10 金 → hp 1→41（+40 = 4×10 精确），余额归 0，`is_repairing()` false，之后 2.5 s 静止 | **证实** |
| 边界：满血停止 | 75→80 停在 **80.0000**，之后资金不变 | **证实** |
| 边界：傀儡端（真实客户端入口） | `NetSync.gd:506` → `present_repairing` 3 s：hp 40→40、资金 698→698、图标可见 | **证实"只表现"** |
| 反向验证 | 旧实现 0.1044 / 0.2927 / 0.0725 HP/s（帧率差 4.0×） | **证实探针可区分（57–82×）** |

`VERDICT: CONFIRMED`

复核提出的 3 项待处理，我的处置：

1. **判据过松**（3 s/20% 抓不住 <20% 回归）→ **已修**：10 s 窗口 + 12% 容差 + 零容差账本恒等（见上表三层判据）。
2. **`heavy-tank-shell-speed` 日志泄漏（43 实例 + 9 资源）是它自己造成的**（直接 `get_tree().quit()` 没回收 Match）→ **已修**：改走 `SmokeTestExit.request(..., a_match)`，现在**唯一日志干净**的套件。
3. **`Structure._process` 缺 `is_client_puppet()` 守卫** → **已修**（用户指示"按正常情况判断"，我判断该加）。
   加在 `_repairing` 短路之后（不维修时零额外开销）。复核自己的探针复跑 `--phase=edges`：

   | | 傀儡态 + 直接 `set_repairing(true)` 3s | 探针 rc |
   |---|---|---|
   | 加守卫前 | hp **+16.000**、资金 **−4** | **rc=1**（该阶段唯一一条 FAIL） |
   | 加守卫后 | hp **+0.000**、资金 **−0** | **rc=0, failures=0** |

   即：复核的独立探针直接变成了这次修复的验证证据。权威端路径未受影响
   （`structure-repair-rate` 仍 5.998 HP/s、17/17 账本干净；`structure-repair-sell` 仍绿）。

### 复核确认的两处残余（性质：既有的小粒度问题，非本次引入）

1. **满血收尾最多多收 ~0.75 金**：最后一笔结算若被 `hp_max` 夹住，1 金可能只买到 1 HP
   （复核实测"75→80 花 2 金"，应为 1.25）。旧实现同样存在，且被 ≤1 金/次封顶；
   从 20% 修满 80 HP 的总账是 16 金，收尾误差 ≤6%。**不修**（要改成非整数金或退款，收益不抵复杂度）。
2. **`set_repairing(false)` 清零未结算的 <1 金债务** ⇒ 玩家损失 <1 金的"进度"，
   反过来也意味着玩家永远不会为没拿到的血付钱 ⇒ 对称、无套利。

## 未验证项

- **未做可见实例截图**：本改动无视觉形状变化（血条上升节奏变快，图标/材质不变）。
  维修图标 `RepairStatusIcon` 是并行 Agent 尚未提交的工作。建议实机"点维修看血条"一次。
- **未跑全量回归套件**（只跑定向 5 项）。
- **真机双进程联机未测**：傀儡态是进程内构造的，没跑真客户端/服务器双端。
- **傀儡端守卫没有进入回归套件**：验证证据来自复核的临时探针
  （`tests/automated/_IndepVerifyRepairSpeed.gd --phase=edges`，下划线前缀=仓库约定的临时探针）。
  要变成常驻门禁需在测试里构造 ENet 傀儡态，成本高于这 1 行守卫本身 ⇒ 本次只留
  探针 + 代码注释 + 本报告作为证据，如实标注。
- 极低帧率/抖动帧率区间未扫；满血收尾多收钱的长期货币影响未做统计。
- 弹速的**改前值 10.0 只有 git 证据**（`git show HEAD:` 为 10.0），未在运行时复测改前弹速。

## 日志干净度（如实记录）

`heavy-tank-shell-speed` = **干净**；`structure-repair-rate` / `structure-repair-sell` /
`heavy-tank-howitzer` / `automatic-construction` 均命中 `forbidden_output_patterns` 的
ObjectDB / RID / resources 泄漏。

- `structure-repair-rate` 的泄漏数字与既有 `structure-repair-sell` **完全相同**，
  两者共用夹具 `tests/manual/TestAllUnits.tscn` ⇒ **夹具既有属性**，不是本次引入
  （`heavy-tank-howitzer` 也是既有泄漏项）。
- **刻意不换夹具**：候选方案是改用 `Match.tscn`（我的弹速测试用它 + `SmokeTestExit` 已证干净），
  但 `tools/probe_repair_online.gd:19` 明确警告 `passive_ai_test` 局**很快判胜利并拆掉 Match**，
  而 10 s+ 的维修窗口需要长时间稳定环境；夹具换成真实对局会引入
  "提前胜利拆局 / AI 打伤被测建筑污染速率"的**偶发假红**风险。
  确定性优先于日志干净度 ⇒ 保留夹具，如实记录泄漏归属。

## 范围外既有失败（只报告，未修）

1. **`economy-account`（`EconomyAccountSmokeTest`）rc=1，2 failure**
   根因：`source/match/Match.gd:585 _grant_growth_starting_bonus()`（成长"资源储备"
   开局赠款 +1200）让玩家开局余额不为 0，而用例仍断言 `human.resource_a == grant_a`
   （`:56`、`:64`）。属**判据过期**。修法应是断言 `before_a + grant_a`，需单独授权。
2. **`repair-sell-targeting`（`RepairSellTargetingSmokeTest`）rc=1，2 failure**
   `:144` 在 `add_child(occluder)`（`:145`）**之前**读 `occluder.global_position`
   ⇒ 节点未进树、`get_global_transform` 报错、遮挡体落原点 ⇒ "射线兜底穿透"用例必失败。
   属该测试自身的编写顺序问题。改前改后失败项**完全一致**，未被本次改动影响。
3. **`automatic-construction`（`AutomaticConstructionSmokeTest`）偶发失败（本轮新观测）**
   同代码连跑 3 次：**绿 / 绿 / 红**（2/3 通过）。失败项是
   `FAIL: 应在主基地周围找到合法兵营落点` —— 建筑放置搜索，非确定性。
   与本次改动**无因果**：`Structure._process` 的新守卫在 `_repairing == false` 时
   第一行就 `return`，不可达；而该用例全程不维修。另在同一环境的
   `[AUTOSPOT] FAIL ... issues=ConstructionInProgress×1` 也指向同一放置搜索子系统。
   ⇒ 记为**既有 flake**，需独立任务排查（不在本次范围）。

## 并行工作区风险

`git status` 显示大量其它 Agent 的未提交改动。本次只改 `Structure.gd` 的回血一行
（并保留同文件他人未提交的图标 hunk 原样不动），未回滚、未清理任何他人工作。
`Structure.gd` 有并行 Agent 在改 ⇒ **行级冲突风险存在**。
反向验证期间该文件被临时改过一次，已核对 SHA256 恢复为字节级一致。

## candidate / champion

单候选单轮：candidate = "按已付资金折算回血（`owed / REPAIR_COST_PER_HP`）"，
一次到位；三层判据全绿、反向验证可区分、独立复核 `CONFIRMED` ⇒ 晋级 champion。
连续未提升轮数：0。

## 相邻发现（未改，供决策）

`source/csharp/Domain/Economy/ResourceAccount.cs` 的 `ResourceChangeReason` 里
**没有 `RepairCost`**：维修支出 book 在 `ScriptedAdjustment`
（唯一允许负数的兜底原因，见 `InMemoryResourceAccountService.DeltasMatchReason`）。
后果：账本里**分不出"维修花了多少钱"**，对局报告的 `repair_spent` 目前是
`DemoMatchReports.gd:622` 按造价**估算**的。若希望报告显示真实维修开销，
需要加 `RepairCost` 原因 + C# 用例，属独立任务。
