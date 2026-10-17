# 建筑维修速率修复（用户报"太慢"）

用户口径：现在建筑维修的速度太慢了。

## 结论：不是"调参"，是 `Structure.gd` 的回血攒账丢帧

`source/match/units/Structure.gd` 的 `_process`（唯一权威来源）：

- 口径常量：`REPAIR_RATE_HP_PER_SEC = 6.0`、`REPAIR_COST_PER_HP = 0.25`
  （原始设计见 commit 6794720："维修按秒回血 6HP/s 耗 0.25金/HP"）。
- 缺陷：`_repair_debt += heal * COST` 只累加**资金**，而回血写的是
  `set_hp_without_damage(min(hp + heal, hp_max))` —— 只有**当帧**那一份 `heal`，
  前面几十帧攒进债务的血全部被丢弃。
- 数学后果：每花 1 金才回 `RATE × delta` 点血 ⇒
  实际速率 ≈ `RATE² × COST × delta`，**随帧率变化**（60fps 0.15、30fps 0.30、144fps 0.06 HP/s），
  单价从 0.25 金/HP 劣化成 `1 / (RATE × delta)`（60fps ≈ 10 金/HP）。

## 基线（修复前，实测）

`tests/automated/StructureRepairRateTest.gd`（新增），真实 `TestAllUnits` 对局，
指挥中心打到 20% 血后开启维修，跳过 1.5s 预热、计量 3.0s：

```
[INFO] 维修实测：3.00s 回血 0.27HP ⇒ 0.088 HP/s（口径 6.0）；花 4 金 ⇒ 15.075 金/HP（口径 0.25）
FAIL: 维修速率应为 6.0 HP/s（实际 0.088）
FAIL: 维修单价应为 0.25 金/HP（实际 15.075）
Structure repair rate: 2 failure(s)
```

⇒ 实测 **0.088 HP/s（慢 68×）**、**15.075 金/HP（贵 60×）**。这就是玩家感到的"太慢"。

## 为什么一直没被发现

既有 `StructureRepairSellSmokeTest` 的断言只有 `hp > damaged_hp`：
按缺陷实现 2 秒能回 0.3HP，照样通过。判据太弱 ⇒ 40× 级缩水存活。

## 改动

只改一处：回血按**已付资金**折算 —— `owed / REPAIR_COST_PER_HP`
（1 金 = 4 HP，与 `REPAIR_COST_PER_HP = 0.25` 自洽），残余小数仍留在 `_repair_debt` 里。

## 步骤

1. [x] S0：定位权威来源与唯一性（常量只存在于 `Structure.gd`，无 config/C#/副官镜像表）。
2. [x] S1：新增 `StructureRepairRateTest` 钉死"速率 + 单价"两个口径；跑出基线（FAIL，0.088 HP/s）。
3. [x] S2：修 `_process` 的回血口径。
4. [x] S3：复测 —— `structure-repair-rate` / `structure-repair-sell` /
   `heavy-tank-shell-speed` / `heavy-tank-howitzer` / `automatic-construction` 全绿 rc=0；
   10s 窗口实测 **5.997 HP/s、0.250 金/HP、账本恒等 17/17 干净**。
5. [x] S4：独立复核（Verifier 自写墙钟探针 + 边界 + 反向验证）⇒ `VERDICT: CONFIRMED`
   （5.976–5.999 HP/s、帧率无关）。
   - 复核提出的"判据过松"**已修**：加零容差账本恒等（旧实现 17/17 违反）+ 10s 窗口 + 12% 容差。
   - 复核提出的"`heavy-tank-shell-speed` 日志泄漏"是它自己 `quit()` 造成的，**已修**。
   - 复核提出的"`Structure._process` 缺 `is_client_puppet()` 守卫" → 用户指示"按正常情况判断"，
     我判断**该加**（文件自己声明"client 绝不改 hp/经济"，但只靠调用方约定）⇒ 已加
     `Structure.gd:90`；复核探针 `--phase=edges` 由 rc=1 转 **rc=0**（hp +16/−4 → +0/−0）。
6. [x] S5：闭环报告 `agent/reports/closed-loop/2026-10-10-structure-repair-speed.md`。

## 新观测（范围外，仅记录）

`automatic-construction`（`AutomaticConstructionSmokeTest`）**偶发失败**：
同代码 3 连跑 绿/绿/红，失败项 `应在主基地周围找到合法兵营落点`（放置搜索，非确定性）。
与本改动无因果（守卫在 `_repairing == false` 时不可达）。需独立任务排查。

## 已知范围外失败

`repair-sell-targeting`（`RepairSellTargetingSmokeTest`）本就失败，与本任务无关：
`RepairSellTargetingSmokeTest.gd:144` 在 `add_child(occluder)`（:145）**之前**读
`occluder.global_position` ⇒ 节点未进树、`get_global_transform` 报错、遮挡体落在原点，
于是"射线兜底穿透遮挡体"用例必失败。属该测试自身的编写顺序问题，需单独授权再修。

预算：单候选一轮；一行改动、可回滚。
