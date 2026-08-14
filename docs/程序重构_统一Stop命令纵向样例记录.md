# 统一 Stop 命令纵向样例记录

## 1. 目标

`CMD-017` 将玩家的“停止”建模为单一命令，而不是由 HUD 分别调用 `HaltMovement` 和 `CancelForceAttack` 后拼接结果。Human、规则 AI 与未来大模型 AI 可使用同一个入口，并获得同一个 `CommandId` 下的逐单位回执。

## 2. 已确认语义

| 当前订单/状态 | Stop 后结果 | 说明 |
|---|---|---|
| Move、ForceMove、AttackMove、TacticalWithdraw | `Suspended` | 保留原订单身份，不自动恢复 |
| 普通 Attack、实体/地面 ForceAttack | `Cancelled` | 取消玩家当前指定的攻击目标，但不改变持续战斗策略 |
| 侵略/警戒/固守 | 不改变 | 属于持续交战姿态 |
| 自由开火/停火 | 不改变 | 属于持续开火策略 |
| 无活动订单 | 接受、无订单 ID | 幂等操作 |
| 采集 | `Suspended` | Worker Gather 已实现：保留目标、阶段和载荷，停止移动、计时器与交付，不自动恢复 |
| 施工 | 预定为 `Suspended` | 尚未具备保留阶段的暂停桥；当前必须明确拒绝，不能返回假成功 |

## 3. 架构实现

- Application 新增 `StopUnitsCommand`、`IUnitCommandService.Stop` 与 `IUnitStopPort`。
- Godot Adapter 的 `LegacyStopPort` 只调用一次 `request_legacy_stop`，防止同一单位发生部分副作用和双命令回执错配。
- `UnitActionsController` 的停止按钮现在只调用 `UnitCommandGateway.StopUnits`。
- `HaltMovement` 与 `CancelForceAttack` 作为精细底层能力暂时保留，不再由玩家停止按钮组合调用。
- 执行端不认识统一停止时稳定返回 `UnitCannotStop`；所有权和失效单位仍使用公共校验。

## 4. 测试记录

2026-08-14：

- `dotnet build OpenRTS.csproj`：0 警告、0 错误；
- 纯 C# 回归：覆盖移动暂停、普通/强制 Attack 取消及停火策略不变；
- `TankForceAttackSmokeTest`：0 失败，实体及地面 ForceAttack 可由统一 Stop 取消；
- `TankOrdinaryAttackSmokeTest`：验证统一 Stop 取消普通 Attack；切换停火用于隔离自主重新索敌，Stop 本身不修改该策略；
- `TankCommandBridgeSmokeTest`：0 失败，移动订单由统一 Stop 转为 `Suspended`；
- Godot 退出时仍报告既有 Navigation RID/ObjectDB 泄漏，继续归入导航专项，不计为 CMD-017 回归。

## 5. 验收状态

2026-08-14 人工复验通过：ForceAttack 可被正确停止，自主重新索敌符合预期。普通 Attack 的视觉取消受当前低动画帧数限制不够明显，其订单和 Action 结果由自动测试覆盖。`CMD-017` 在已迁移 Tank 范围内完成；采集/施工任务暂停随对应单位迁移归入 `CMD-026`。

## 6. 验收中发现并修复的回归

2026-08-14 人工测试发现：对远距离地面下达 ForceAttack 后，Tank 会先接近射程；此时 Stop 虽已把订单改为 `Cancelled`，但单位仍会沿旧导航目标前进到射程内。

根因不是 NavigationMesh 尺寸或路径计算，而是 `ExplicitGroundForceAttacking` 直接启动了 `Movement`，却没有在 Action 退出时撤销该导航目标。现已增加 `_exit_tree()` 清理，无论 Stop、替换命令还是单位销毁导致 Action 退出，均会调用 `Movement.stop()`。

`TankForceAttackSmokeTest` 已改为真实等待接近运动开始，在 Stop 后继续观察世界坐标；修复后订单为 `Cancelled`，且 0.35 秒观察期内位移小于 0.02，测试为 0 失败。远距离实体 ForceAttack 使用的 `FollowingToReachDistance` 原本已有同类退出清理，本次复核未发现相同遗漏。

## 7. 普通 Attack 语义修订

2026-08-14 复核传统 RTS 表现后确认：Stop 应取消玩家当前下达的普通 Attack。此前观察到“停止后仍攻击”，通常是单位在原有侵略/警戒/固守与开火策略下立刻重新发现目标，并非旧 Attack 订单仍在执行。

因此 Stop 现在会把普通 `Attack` 订单转为 `Cancelled` 并清除 `OrdinaryAttacking` Action，但不会修改交战姿态、开火策略或武器冷却。已经发射的投射物继续正常结算；若策略允许，自主索敌可以立即建立新的执行行为。玩家若要求持续不再开火，仍应使用停火命令。
