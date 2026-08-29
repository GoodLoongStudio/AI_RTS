# 规则 AI 智能化改造（供复核）

## Overview

给另一位 AI / 同事核对用的改造设计，不是操作手册。

**目标：** 把 `SimpleClairvoyantAI` 从「静态数量维持」改造成「会扩张经济、会主动进攻、会补兵回防」的规则 AI，体感对齐红警 3 简单~中等难度 AI 的下限：**会扩矿、会主动打、会补兵、不站桩、不白送**。

**硬约束（与现有架构的契约）：**
1. 不碰模拟层权威性——AI 产出的命令仍必须全部经 `RuleAiCommandGateway` 进入 `CommandRuntime`，服务器权威、客户端傀儡的联机架构不动（见 `docs/plan/联机Demo-架构设计-plan.md`）。
2. 不打破战争迷雾查询约束——rule AI 的一切信息必须来自 `WorldQueryRuntime` 的标准查询会话，禁止直接读场景树 Node。
3. 信息对等原则：AI 只允许比玩家多知道「开局出生点位置」这类玩家本来就能看到的公共知识，不允许迷雾内实时信息。
4. 全部行为参数上 `SimpleClairvoyantAI` 的 `@export`，为难度分级与自动化测试留口。

**改动范围：** 主要是 6 个策略层 GDScript 文件 + `WorldQueryRuntime.cs` 一次只读扩展 + 新增 3 个自动化测试。模拟层零改动（唯一例外见 Phase 2 的备选方案 B，单独评审）。

## Current State Analysis（读码结论，行号以当前 HEAD 为准）

### 架构现状

```
SimpleClairvoyantAI (Player 子类, 156 行)
 ├─ EconomyController        (249 行)  0.5s 轮询
 ├─ OffenseController        (399 行)  0.5s 轮询
 │   └─ AutoAttackingBattlegroup × N (258 行/个)
 ├─ DefenseController        (143 行)  0.5s 轮询
 ├─ IntelligenceController   (136 行)  0.5s 轮询
 └─ ConstructionWorksController (63 行)
控制器 → resources_required 信号(优先级 HIGH/MEDIUM/LOW) → 主脑仲裁 → provision
命令出口：每个控制器持 RuleAiCommandGateway（C#, Move/Halt/Attack/Construct/
          PlaceStructure/EnqueueProduction/Gather —— 注意：没有 AttackMove）
信息入口：WorldQueryRuntime 标准会话（GetOwnForces / ScanCircle /
          InspectOwnEntity / GetOwnEconomy / GetBattlefieldBounds）
权威守卫：SimpleClairvoyantAI._ready(): is_client_puppet → set_process(false)
```

### 五个结构性缺陷（“笨”的根源，均有代码证据）

| # | 缺陷 | 证据 |
|---|------|------|
| 1 | 经济封死：全场 1 基地 3 工人，永不开分矿 | `SimpleClairvoyantAI.gd` 默认 `expected_number_of_ccs=1`、`expected_number_of_workers=3`；`EconomyController._enforce_number_of_ccs` 只做「数量维持到 1」 |
| 2 | 兵力上限 8 | `expected_number_of_battlegroups=2 × units_in_battlegroup=4`；`OffenseController._is_units_production_allowed` 超编即停 |
| 3 | 进攻=站桩响应 | `AutoAttackingBattlegroup._refresh_combat`：只打 `VisibleNow` 敌人 → 无则走向 `LastKnown` 敌结构 → **连 LastKnown 都没有就地待机**。从不主动推进、无目标价值评估、残编不撤退 |
| 4 | 侦察无消费者 | `IntelligenceController` 仅让无人机沿固定航点巡逻（`_build_patrol_waypoints`），产出情报无任何下游 |
| 5 | 防御无响应 | `DefenseController` 只维持 1 反坦克塔 + 1 防空塔的「存在性」（`_enforce_number_of_ag_turrets/_aa_turrets`），无受袭响应逻辑 |

对比 RA3：其 AI 的下限是固定开局 build order + 持续扩矿 + 按比例出兵 + 周期性进攻波。上述 1/2/3 恰好全部缺失，因此体感“连红警 3 都不如”。

## Design（按阶段，每阶段独立可验证）

### Phase 1 — 经济解封（EconomyController.gd）

- `_enforce_number_of_ccs` 从「数量维持」改为**条件触发扩张**：
  - 触发条件（全部满足才请求建新 CC）：`CC 数 < max_command_centers` 且 `GetOwnEconomy` 余额 ≥ `expansion_resource_threshold` 且 现有 CC 的工人已饱和（无 idle worker 可分配）。
  - 选址：用 `ScanCircle` 找「距现有 CC 最远且资源簇未饱和」的落点（resource 实体在查询中的 kind/字段名实现时核对 `WorldQueryRuntime.cs` 的 field 映射）。
- 工人目标数改为按基地数缩放：`worker_target = CC 数 × workers_per_command_center`。
- 新增 `@export`：`max_command_centers=3`、`workers_per_command_center=6`、`expansion_resource_threshold`（占位值，需实测 `BalanceConfigRuntime` 的产出曲线后定）。

### Phase 2 — 进攻主动性（AutoAttackingBattlegroup.gd，信息源涉及 1 次查询扩展）

**信息源（评审点 A）：** 敌方出生点作为公共知识注入。两个候选方案：
- 方案 A1（推荐）：`WorldQueryRuntime` 新增只读查询 `GetSpawnPoints(sessionId)`——出生点本来就是玩家开局可见的公共信息，对 AI 是同等信息，不算迷雾违规；改动小、语义干净。
- 方案 A2：Match 开局时由 IntelligenceController 把敌方出生点写入其内部记忆并当作 LastKnown 使用。零查询层改动，但把「公共知识」伪装成「侦察成果」，语义脏，且侦察被歼会丢失出生点信息（荒谬）。
- **不采用**：解除迷雾约束让 AI 直接看实时敌军——违反硬约束 2/3。

**行为改动（`_refresh_combat`）：** `ATTACKING` 态下的目标链改为：
1. 延续当前目标（现状保留）；
2. `VisibleNow` 敌人按新价值序（Phase 4）选取；
3. `LastKnown` 敌结构（现状保留）；
4. **新增兜底：向敌方出生点 `Move`**——用现有 `Move` + 0.5s 刷新重评估模拟 attack-move（行进途中每轮刷新发现 `VisibleNow` 敌人立即转 `Attack`）。任何状态下编组都不允许静止待机。

**备选方案 B（单独评审，本 plan 默认不做）：** 在 `CommandRuntime`/`UnitCommandService` 增加真正的 `AttackMove` 指令（模拟层改动）。收益：移速中遇敌自动交战、对人类玩家快捷键也有用；代价：动权威模拟层。若 Phase 2 上线后观察到「风筝拉扯导致编组来回摆动」，再升级。

### Phase 3 — 兵力与波次（SimpleClairvoyantAI.gd + OffenseController.gd + AutoAttackingBattlegroup.gd）

- 参数：`expected_number_of_battlegroups` 2→3、`expected_number_of_units_in_battlegroup` 4→6（`@export` 默认值）。
- 残编撤退：`AutoAttackingBattlegroup` 新增 `RETREATING` 态——成员存活 < `retreat_threshold`(0.5) 时全员 `Move` 回集结点（主 CC 位置，`GetOwnForces` 查询）；`OffenseController` 将残编不计入战斗力、停止其生产配额占用，直至重新满编转回 `ATTACKING`。
- 波次节奏：满编即出击（现状）保留；损失由现有 `_number_of_additional_units_required` 补足逻辑自然形成「打光→补满→再出击」的攻击波。

### Phase 4 — 目标价值（AutoAttackingBattlegroup.gd）

- 目标选择从「最近优先」改为「价值序 + 同权重取近」：`Worker(采集车) > 生产建筑(工厂/CC) > 防御塔 > 其他结构 > 其他单位`。kind 字段查询结果已携带（`entity.get("kind")`），权重表做成常量。
- 集火机制（`_current_target_id` 延续）现状已满足，保留。

### Phase 5 — 防御响应（DefenseController.gd，与 OffenseController 协同）

- 每 0.5s 对每个己方建筑 `ScanCircle(defense_radius)`（半径占位 40m，实测调）；发现 `VisibleNow` 敌人 → 通过主脑（两个控制器同为 `SimpleClairvoyantAI` 子节点，直接方法调用即可，无需新基础设施）请求 OffenseController 派**最近的非撤退编组**回防至受威胁点。
- 威胁解除判定：连续 `threat_clear_rounds`(3) 轮无敌人 → 编组恢复原任务。为防抖动，回防请求带 30s 最短执行时间。

### Phase 6 — 兵种配比（OffenseController.gd）

- 出兵从「每工厂固定一种」改为按权重轮转：primary:secondary = `unit_ratio`=2:1（`@export`）。实现点是 `_provision_unit` / `EnqueueProduction` 的类型选择处。
- （可选，P2）克制转型：`IntelligenceController` 增加 `get_enemy_composition_summary()`（`VisibleNow`+`LastKnown` 的 kind 直方图），OffenseController 刷新时读取并微调权重。注意这要求 Intelligence 首次真正产出情报——是缺陷 4 的顺手修复。

### Phase 7 — 难度分级（SimpleClairvoyantAI.gd）

- `@export enum Difficulty {EASY, NORMAL, HARD}` → 参数表覆盖：`workers_per_command_center`、`expected_number_of_battlegroups/units_in_battlegroup`、`retreat_threshold`、开局第一波出击延迟（4/3/2 分钟）。
- **收入倍率（RA3 式资源作弊）明确列为非目标**：需动 `EconomyRuntime`/资源账户，跨入模拟层且不公平感强。若未来要做，单独开 plan 评审。

## 实现顺序与验证

顺序：1 → 2 → 3 → 4 → 5 → 6 → 7，每阶段一个可对局验证的增量。

自动化（沿用 `tests/automated/RuleAi*SmokeTest.gd` 既有模式，headless + 世界查询断言）：
- 新增 `RuleAiExpansionSmokeTest.gd`：模拟 5 分钟后 AI `CC ≥ 2`、`worker ≥ 10`（P1）。
- 新增 `RuleAiAggressionSmokeTest.gd`：编组满编且无可见敌人时，编组中心到敌方出生点的距离随时间单调递减；任意时刻编组中心速度不得长期为 0（P2/不站桩）。
- 新增 `RuleAiDefenseSmokeTest.gd`：AI 建筑受击后 T+3s 内有编组成员进入威胁半径（P5）。
- 回归：现有 `RuleAi*SmokeTest` 全绿；联机 Demo 本机双进程验收不回归（AI 命令仍全走网关，对账应无 diff）。

对局验证（以图交付）：每阶段跑一局 人 vs AI，出录屏/截图 + 服务器 headless 10 分钟稳定性对账。

## Risks

1. **快照带宽（最大风险）**：AI 作战单位 8 → 18+，10Hz 全量快照体积上升。上线前用 `godot-rts-terrain/tools/bandwidth_budget.py` 复算带宽预算；必要时再评估 AI 单位聚合/降频（不在本 plan 内）。
2. **服务器 CPU**：查询频率不变（0.5s）、实体数 ×2~3，预计仍在毫秒级以下；部署后观察 headless 帧耗时确认。
3. **会话边界纪律**：新增信息（出生点）必须走 `WorldQueryRuntime` 正规会话。这是评审重点——任何「为了方便直接 get_node 读敌军」的实现都应被拒。
4. **无 AttackMove 的模拟局限**：Phase 2 的「移动+重评估」在敌人撤退拉扯时可能出现编组来回摆动；观察对局，必要时升级为备选方案 B。
5. **数值依赖**：`expansion_resource_threshold`、`defense_radius` 等阈值依赖 `BalanceConfigRuntime` 实测产出/射程曲线，本文占位值均需标定后回填。

## Non-goals

- 不做 ML / 行为树框架重写（现有「信号 + 资源请求 + 命令网关」架构承载力足够）。
- 不动模拟层权威性、确定性与联机协议。
- 不做收入作弊；不新增任何迷雾外实时信息。

## 附：涉及文件清单

| 文件 | 行数 | 改动类型 |
|------|------|----------|
| `source/match/players/simple-clairvoyant-ai/SimpleClairvoyantAI.gd` | 156 | 参数、难度、控制器间消息仲裁 |
| `source/match/players/simple-clairvoyant-ai/EconomyController.gd` | 249 | P1 扩张与工人缩放 |
| `source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd` | 258 | P2 兜底推进、P3 撤退态、P4 目标价值 |
| `source/match/players/simple-clairvoyant-ai/OffenseController.gd` | 399 | P3 波次、P5 协同、P6 配比 |
| `source/match/players/simple-clairvoyant-ai/DefenseController.gd` | 143 | P5 威胁检测 |
| `source/match/players/simple-clairvoyant-ai/IntelligenceController.gd` | 136 | P2 出生点消费、P6 情报输出（可选） |
| `source/csharp/GodotAdapter/Queries/WorldQueryRuntime.cs` | — | P2 只读扩展 `GetSpawnPoints`（方案 A1） |
| `tests/automated/RuleAi{Expansion,Aggression,Defense}SmokeTest.gd` | 新增 | 阶段断言 |
