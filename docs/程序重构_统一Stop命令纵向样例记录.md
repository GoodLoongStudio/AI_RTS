# 统一 Stop 命令纵向样例记录

## 1. 目标

`CMD-017` 将玩家的“停止”建模为单一命令，而不是由 HUD 分别调用 `HaltMovement` 和 `CancelForceAttack` 后拼接结果。Human、规则 AI 与未来大模型 AI 可使用同一个入口，并获得同一个 `CommandId` 下的逐单位回执。

## 2. 已确认语义

| 当前订单/状态 | Stop 后结果 | 说明 |
|---|---|---|
| Move、ForceMove、AttackMove、TacticalWithdraw | `Suspended` | 保留原订单身份，不自动恢复 |
| 实体/地面 ForceAttack | `Cancelled` | Stop 是显式强制攻击的特殊取消入口 |
| 普通 Attack | 保持 `InProgress` | Stop 不代替禁火命令 |
| 侵略/警戒/固守 | 不改变 | 属于持续交战姿态 |
| 自由开火/停火 | 不改变 | 属于持续开火策略 |
| 无活动订单 | 接受、无订单 ID | 幂等操作 |
| 采集/施工 | 预定为 `Suspended` | 对应单位尚未迁移，接入时必须保留任务且不自动恢复 |

## 3. 架构实现

- Application 新增 `StopUnitsCommand`、`IUnitCommandService.Stop` 与 `IUnitStopPort`。
- Godot Adapter 的 `LegacyStopPort` 只调用一次 `request_legacy_stop`，防止同一单位发生部分副作用和双命令回执错配。
- `UnitActionsController` 的停止按钮现在只调用 `UnitCommandGateway.StopUnits`。
- `HaltMovement` 与 `CancelForceAttack` 作为精细底层能力暂时保留，不再由玩家停止按钮组合调用。
- 执行端不认识统一停止时稳定返回 `UnitCannotStop`；所有权和失效单位仍使用公共校验。

## 4. 测试记录

2026-08-14：

- `dotnet build OpenRTS.csproj`：0 警告、0 错误；
- 纯 C# 回归：14/14 通过，覆盖移动暂停、ForceAttack 取消、普通 Attack 保留及停火策略不变；
- `TankForceAttackSmokeTest`：0 失败，实体及地面 ForceAttack 可由统一 Stop 取消；
- `TankOrdinaryAttackSmokeTest`：0 失败，统一 Stop 不清除普通 Attack；
- `TankCommandBridgeSmokeTest`：0 失败，移动订单由统一 Stop 转为 `Suspended`；
- Godot 退出时仍报告既有 Navigation RID/ObjectDB 泄漏，继续归入导航专项，不计为 CMD-017 回归。

## 5. 验收状态

代码和自动测试已完成，等待人工确认传统 HUD 只产生一次 Stop 反馈，且移动、强制攻击、普通攻击和持续策略的视觉行为符合第 2 节。

## 6. 验收中发现并修复的回归

2026-08-14 人工测试发现：对远距离地面下达 ForceAttack 后，Tank 会先接近射程；此时 Stop 虽已把订单改为 `Cancelled`，但单位仍会沿旧导航目标前进到射程内。

根因不是 NavigationMesh 尺寸或路径计算，而是 `ExplicitGroundForceAttacking` 直接启动了 `Movement`，却没有在 Action 退出时撤销该导航目标。现已增加 `_exit_tree()` 清理，无论 Stop、替换命令还是单位销毁导致 Action 退出，均会调用 `Movement.stop()`。

`TankForceAttackSmokeTest` 已改为真实等待接近运动开始，在 Stop 后继续观察世界坐标；修复后订单为 `Cancelled`，且 0.35 秒观察期内位移小于 0.02，测试为 0 失败。远距离实体 ForceAttack 使用的 `FollowingToReachDistance` 原本已有同类退出清理，本次复核未发现相同遗漏。
