# 技能基础规则 Implementation Plan

## Overview
按《策划文档_技能基础规则》落地一套可配置技能内核：触发、目标、效果序列、时间、消耗冷却、中断。具体英雄 QWER、技能点和对象模板内部不在本包。后续按步骤开发，每步等人验收。

## Current State Analysis
代码里没有 Skill 域、技能配置、技能 HUD。可复用：`UnitCommandGateway` / `UnitCommandService`、`WarheadDamageResolver`、`SimulationClock`、现有地面/单位 Targeting、`demo.balance.v1.json` 的 catalog 模式。缺失：效果执行器、状态/护盾、单位能量弹药、治疗、技能中断。

伤害仍走现有最小闭环（基础伤害 × 友伤 → 扣 HP）。护盾、属性层、对象模板内部本包只做接口或最小桩，不扩完整系统。

## Implementation Strategy
权威规则放 C#：`Domain/Skills` → `Application/Skills` → `GodotAdapter/Skills` → GDScript HUD/选目标。配置跟武器一样进 `demo.balance.v1.json`。冷却/持续用 `SimulationClock`，不绑物理帧。每步只交付一个可验收切片，配纯 C# 测试和一条冒烟。

## Implementation Steps

按验收顺序，前面通过再做后面。

| 步 | 名称 | 做什么 | 验收看什么 |
|---|---|---|---|
| 1 | 技能定义与配置骨架 | Domain 模型 + JSON `skills` + Loader 校验 | 一条最小技能定义能从 catalog 读出，非法配置整表拒绝 |
| 2 | 主动施放命令入口 | `CastSkill` 走 Gateway，不绕过命令层 | 选中单位后能对「自身」施放，回执 Accepted/Rejected |
| 3 | 即时伤害效果 | 效果「造成伤害」复用现有伤害解析 | 对自身或指定单位扣 HP，死亡走现有死亡逻辑 |
| 4 | 目标规则（单位/地面） | 复用现有 Targeting；过滤阵营、距离、存活 | 点敌扣血、点友/超距被拒；地面目标能记下位置 |
| 5 | 消耗与冷却 | 正式生效时扣消耗、开冷却；时间用模拟时钟 | 资源不足拒绝；冷却中拒绝；暂停不推进冷却 |
| 6 | 时间规则：顺序与延迟 | 效果 A → 延迟 → 效果 B | 能看到第二段在延迟后发生；暂停冻结延迟 |
| 7 | 恢复生命 | 基础效果「恢复生命」 | 受伤单位被治疗后 HP 上升，不超过上限 |
| 8 | 状态：持续改属性 | 状态 = 时长 + 属性修改 + 叠加规则（最小：移速） | 上状态后属性变，到期恢复；刷新/覆盖可配置 |
| 9 | 效果组合：同时 / 周期 / 条件 | 同时伤害+治疗；周期跳字；条件跳过 | 配置驱动，不写死技能脚本 |
| 10 | 被动 / 事件 / 条件触发 | 同一套目标+效果，无玩家确认 | 例如受伤时触发一次小治疗 |
| 11 | 中断规则 | 可配置阶段、是否退消耗、是否留冷却；已生效不回滚 | 施放前被停止则后续效果不发生 |
| 12 | 下达命令 / 触发事件 | 效果映射到已有 Move/Attack 与战场事件 | 技能能让单位移动或发事件，不新建命令体系 |
| 13 | 创建对象最小接入 | 只提供模板 ID、位置、方向、施法者 | 场上生成已有场景实例；模板内部行为暂不新建 |
| 14 | 演示技能配置 + HUD 槽 | 1～2 个配置技能挂到测试单位；按钮显示冷却 | 战役/测试关能手动点技能，验收整条链路 |

本包明确不做：英雄等级/技能点/QWER 键位、护盾完整数值、对象模板内部（弹道场/陷阱 AI）、区域/方向 Targeting、AI 自动放技能。

## Timeline
每步一次提交级改动 + 验收。预计 1～3 步先打通「能放、能伤」；5～8 形成可玩主动技能；9～14 补齐文档结构。

## Risk Assessment
- Targeting 文档曾写技能暂缓；本包只复用现有点地/点单位，不先做多段指示器。
- 护盾/复杂属性若硬做会和现有伤害闭环打架；状态先只改已有字段（如移速）。
- 创建对象若没有模板目录会空转；第 13 步只接现有 PackedScene。
- 暂停必须走 SimulationClock，避免和攻击间隔两套时间。

## Success Criteria
- 新技能优先 JSON 配置，不写新执行体系。
- 主动技能：选目标 → 校验 → 生效扣费进 CD → 效果按序列改世界。
- 暂停冻结冷却、延迟、状态剩余时间。
- 每步有核心测试或冒烟，人工能复现。

## Progress Tracking
✅ 差距分析与开发顺序  
✅ 第 1 步：技能定义与配置骨架  
✅ 第 2 步：主动施放命令入口  
✅ 第 3 步：即时伤害效果  
✅ 第 4 步：目标规则  
✅ 第 5 步：消耗与冷却  
✅ 第 6 步：时间规则：顺序与延迟  
✅ 第 7 步：恢复生命  
✅ 第 8 步：状态：持续改属性  
✅ 第 9 步：效果组合：同时 / 周期 / 条件  
✅ 第 10 步：被动 / 事件 / 条件触发  
✅ 第 11 步：中断规则  
✅ 第 12 步：下达命令 / 触发事件  
✅ 第 13 步：创建对象最小接入  
✅ 第 14 步：演示技能配置 + HUD 槽  

## 第 9 步实现要点（对照策划第 5、6 节）

策划要求多个效果之间只用：顺序、同时、延迟、持续、周期、条件、重复。第 6 步已有顺序+延迟；第 8 步已有持续（状态时长）。本步只补 **同时、周期、条件**，重复次数与周期一起配置。

- **同时**：`timing: simultaneous` 与上一条在同一模拟毫秒执行；仍按 JSON 书写顺序套用。不得与 `delayMilliseconds > 0` 同时出现。缺省 `afterPrevious`（相对上一条的首次触发时刻加延迟）。
- **周期 + 重复**：`periodMilliseconds` 与 `repeatCount` 必须成对；首次在该条效果的计划时刻，之后每隔一个周期再执行，共 `repeatCount` 次。后续条目的延迟相对上一条的**首次**时刻，不被周期拉长。
- **条件**：`condition` 为 `always`（缺省）、`targetAlive`、`targetWounded`。不满足则跳过该次执行，命令仍可 Accepted。周期每一跳单独判条件。本步不做技能级条件触发（第 10 步）。
- **不做**：新基础效果类型、周期跳字 UI、状态上的周期/事件触发、复杂数值表达式。

演示技能：`demo_self_burst`、`demo_self_ticks`、`demo_self_heal_if_wounded`。

## 第 10 步实现要点（对照策划第 2 节）

策划：被动、事件、条件触发不需要玩家确认目标，但仍用同一套目标规则和效果序列。主动入口继续拒绝这些触发。

- **装配**：技能声明 `equippedUnitTypeIds`；单位快照 `TypeId` 匹配则 `EquipAutomaticSkills`。测试也可 `GrantSkill`。不新建第二套执行器，生效仍走扣费、冷却、时间线。
- **事件**：`trigger: event` + `event: unitDamaged`。`NotifyUnitDamaged` 后尝试生效。本步只允许 `target: self`。
- **条件**：`trigger: condition` + `activationCondition`（`targetAlive` / `targetWounded`）。`EvaluateAutomaticSkills` 在模拟推进时检查，成立且冷却就绪才生效。
- **被动**：`trigger: passive`。装配后每次评估都尝试生效（靠冷却限制频率），用于持续状态。
- **不做**：玩家点选确认、区域/方向自动索敌、AI 主动放技能、状态上的独立触发系统、新的基础效果。

演示技能：`demo_on_damage_heal`（装配到 `tank`）、`demo_wounded_regen` 与 `demo_passive_slow`（目录可加载，测试里显式授予，避免改所有坦克手感）。

## 第 11 步实现要点（对照策划第 6、10、11 节）

策划：可配置允许中断的阶段、触发中断的情况、尚未发生的效果停止、是否退消耗、是否留冷却；**已经生效的效果不回滚**。消耗与冷却仍在**正式生效**时发生。时间规则里的「施放前等待」用 `castDelayMilliseconds` 表达。

- **施放前**：`castDelayMilliseconds > 0` 时先 Accepted，不扣费、不开冷却、不执行效果。到期才正式生效。此阶段被中断则后续效果不发生。
- **正式生效后**：只取消时间线上尚未执行的段；已结算的伤害/治疗/状态保留。
- **阶段** `beforeActivation` / `afterActivation`；**原因** `stop` / `death`。未声明 `interrupt` 的技能保持现状（停止不取消延迟段）。
- **退消耗 / 留冷却** 只作用于已经正式生效的施放。施放前中断本来就没扣费、没进 CD。
- **不做**：蓄力条 UI、独立引导订单、移动自动打断（只用停止和死亡）、按已执行段比例退费。

演示技能：`demo_windup_pulse`。

## 第 12 步实现要点（对照策划第 4 节「下达命令 / 触发事件」）

策划：效果只复用已有基础命令和统一战场事件，不新建命令体系。

- **issueCommand**：`command` 仅为 `move` 或 `attack`。由施法者走现有 `Move` / `Attack` 入口；地面落点或单位目标来自这次 `CastSkill` 已确认的目标。
- **emitEvent**：写入现有 `IBattlefieldEventLog`，种类 `skillEmitted`。默认不抢 Space 跳转；地面技能用确认坐标。
- **不做**：新命令种类、ForceMove/撤退映射、技能专用事件总线、重要事件默认抢镜头。

演示技能：`demo_ground_mark`（正式记事件）、`demo_issue_move`、`demo_issue_attack`。

## 第 13 步实现要点（对照策划第 8 节）

策划：技能若要在场上产生持续物，只用「创建对象 + 对象模板」。技能层只提供模板、位置、方向、所属施法者与必要初始参数。生命周期、碰撞、AI 由对象模板负责，本步不展开。

- **createObject**：`templateId` 必须是已有 `unitTypes` 稳定 ID（本步复用现有 PackedScene，不新建模板）。
- **位置**：来自本次已确认的地面落点；自身技能则用施法者坐标。
- **方向**：由施法者指向落点的水平朝向；重合则朝向 0。
- **所属**：生成实例挂到施法者所在玩家下，走现有 `setup_and_spawn_unit`。
- **不做**：对象模板内部、投射物/陷阱 AI、区域或方向 Targeting、新单位类型资源。

演示技能：`demo_spawn_drone`（地面 8m，生成已有 `drone` 场景）。

## 第 14 步实现要点（对照计划验收）

把 1～2 条已配置主动技能挂到测试单位，传统 HUD 出槽并显示冷却；点按钮走现有 `CastSkill`，不新建命令体系、不做 QWER。

- **装配**：`equippedUnitTypeIds` 对主动技能同样生效；`EquipAutomaticSkills` 写入同一装配表。HUD 只展示 `trigger: active`。
- **槽位**：只选中一个己方单位时显示；冷却剩余毫秒来自模拟时钟。
- **施放**：自身技能点按钮即提交；单位技能进入一次点选，再走 `CastSkill`。
- **不做**：英雄键位、技能点、多段指示器、AI 自动点主动技能。

演示挂载：`demo_self_heal`、`demo_unit_pulse` → `tank`。

## Related Files
- `docs/策划文档/策划文档_技能基础规则.md`
- `docs/策划文档/策划文档_伤害计算规则.md`
- `docs/策划文档/策划文档_目标选择与Targeting规则.md`
- `config/balance/demo.balance.v1.json`
- `source/csharp/Domain/Skills/SkillDefinitions.cs`
- `source/csharp/Application/Configuration/BalanceConfigLoader.cs`
- `source/csharp/Application/Configuration/BalanceCatalogContracts.cs`
- `source/csharp/Application/Commands/`
- `source/csharp/Application/Skills/SkillInstantEffectExecutor.cs`
- `source/csharp/Application/Skills/SkillTargeting.cs`
- `source/csharp/Application/Skills/SkillCastJournal.cs`
- `source/csharp/Application/Skills/SkillCooldownStore.cs`
- `source/csharp/Application/Skills/SkillEffectTimeline.cs`
- `source/csharp/Application/Skills/SkillEffectConditions.cs`
- `source/csharp/Application/Skills/SkillLoadoutStore.cs`
- `source/csharp/Application/Skills/SkillWorldActions.cs`
- `source/csharp/GodotAdapter/Skills/GodotSkillObjectSpawnPort.cs`
- `source/match/SimulationClock.gd`
- `source/csharp/Application/Combat/WarheadDamageResolver.cs`
- `source/csharp/Application/Skills/SkillStatusService.cs`
- `source/csharp/GodotAdapter/Combat/LegacyDamagePort.cs`
- `source/csharp/GodotAdapter/Combat/LegacyMoveSpeedPort.cs`
- `source/match/SimulationClock.gd`
- `source/match/players/human/UnitActionsController.gd`
- `source/match/hud/TraditionalUnitCommandHUD.gd`
- `source/match/hud/TraditionalUnitCommandHUD.tscn`
- `source/csharp/Application/Skills/SkillHudSlots.cs`
