# Tank 地面 AttackMove 纵向样例记录

> 日期：2026-08-13
>
> 范围：GroundTarget、三种交战姿态、HoldFire、传统 HUD 与订单恢复

## 1. 命令链路

```text
TraditionalUnitCommandHUD
  -> UnitActionsController
  -> UnitCommandGateway
  -> CommandRuntime
  -> UnitCommandService
  -> IUnitMovementPort.RequestGroundAttackMove
  -> LegacyMovementPort
  -> GroundAttackMoving Action
```

Application 只持有 `UnitId` 与 `WorldPosition`，不持有 Godot Node。当前 `GroundAttackMove` 是独立订单种类，不与 Move、ForceMove 或 TacticalWithdraw 混用。

## 2. 执行语义

- 推进目标在订单期间持续保存；
- 无临时敌人时沿导航路径推进；
- 发现合法敌人时按姿态创建临时交战子行为；
- 临时敌人失效或超出姿态约束后恢复原推进目的地；
- HoldFire 会中止临时交战并立即恢复纯移动；
- 停止命令将 GroundAttackMove 订单转为 Suspended。

## 3. 姿态

- Aggressive：视野范围内接敌，可按既有最大追击规则追近；
- Guard：使用本次订单的接敌锚点限制离路，不读写持久 GuardAnchor；
- HoldGround：只选择武器射程内目标，交战时暂停主动导航和避障速度；
- HoldFire：不选择敌人，表现为纯移动。

## 4. 导航修正

测试确认，仅把 `NavigationAgent3D.target_position` 设为无穷不能保证单位立即静止：避障服务器可能继续回调上一帧安全速度。Movement trait 因此增加显式 `suspend_motion/resume_motion`，固守交战会清零速度、暂停避障和物理导航，恢复推进时再统一开启。

## 5. 测试

- `CSharpCommandSmokeTest`：专用端口和订单类型；
- `TankGroundAttackMoveSmokeTest`：HoldFire 纯推进、HoldGround 射程接敌、原地交战及清敌后恢复；
- `TraditionalUnitCommandHudSmokeTest`：按钮可用、进入及取消地面目标模式；
- `tests/manual/TestGroundAttackMove.tscn`：人工观察三种姿态的离路和恢复表现。

当前自动化尚未对复杂障碍中的导航走廊、Guard 最大横向距离和 Aggressive 追击上限进行几何级验证。
