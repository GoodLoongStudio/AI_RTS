# Tank 实体 AttackMove 纵向样例记录

日期：2026-08-13

## 目标

在不改变地面 AttackMove 已评审语义的前提下，让同一“移动并攻击”入口可选择敌方实体作为最终目标，并保持最终目标身份、途中接敌和目标失效反馈彼此独立。

## 接口链路

```text
TraditionalUnitCommandHUD / UnitActionsController
  -> UnitCommandGateway.EntityAttackMoveUnits
  -> CommandRuntime.EntityAttackMoveUnits
  -> IUnitCommandService.EntityAttackMove
  -> IUnitMovementPort.RequestEntityAttackMove
  -> Unit.request_legacy_entity_attack_move
  -> GroundAttackMoving（共享接敌与恢复推进执行器）
```

Application 层只持有稳定的 `UnitId`，不持有 Godot Node。`EntityAttackMove` 使用独立订单种类，不能与普通 Attack、GroundAttackMove 或 ForceAttack 混淆。

## 已实现规则

- 目标必须是可受伤害的敌方实体；当前敌我关系仍以不同 Owner 判定，联盟接口待后续扩展。
- 执行单位必须同时具备移动、攻击能力，并能攻击目标所属域。
- HoldFire 下命令仍被接收并追踪最终目标，但不会开火。
- 侵略、警戒、固守继续复用已评审的 AttackMove 接敌范围和追击边界。
- 途中目标被清除后恢复追踪原最终目标，不会把途中目标变成新的最终目标。
- 最终目标移动会刷新导航点；其死亡或退出运行时后订单进入 `TargetLost`。
- 首版不保存最后已知位置，也不把战争迷雾中的暂时不可见视为目标失效。
- 停止命令可将该订单转为 `Suspended`，且不会自动恢复。

## 验证

- `dotnet build OpenRTS.csproj`：0 warning，0 error；
- `CSharpCommandSmokeTest`：验证敌我关系、HoldFire 接收、专用端口与订单类型，0 failure；
- `TankEntityAttackMoveSmokeTest`：验证移动目标追踪、HoldFire 不开火、恢复开火以及目标死亡转 `TargetLost`，0 failure；
- Godot 无头退出仍报告既有 RID/ObjectDB 资源泄漏，本切片未引入复杂性能优化或处理该既有缺陷。

## 人工验收

运行 `tests/manual/TestEntityAttackMove.tscn`：选择 Tank，点击“移动并攻击”，再右键敌方单位。观察 Tank 处理中途敌人后继续追踪原目标；切换停火时只推进不射击；目标死亡后不再前往其最后位置。
