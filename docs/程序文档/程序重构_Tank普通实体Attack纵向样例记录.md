# Tank 普通实体 Attack 纵向样例记录

> 日期：2026-08-13
>
> 范围：普通右键敌方实体、停火拒绝、订单状态和 ForceAttack 边界

## 1. 命令规则

- `AttackCommand(UnitIds, EntityAttackTarget)` 只接受敌方实体；
- 己方或友军目标返回 `InvalidAttackTarget`；
- HoldFire 返回 `FirePolicyPreventsAttack`，不创建不可执行订单；
- 武器、攻击域、目标可受伤性和所有权逐单位校验；
- ForceAttack 继续允许显式己方目标并临时覆盖 HoldFire。

## 2. 执行与订单

普通右键敌人不再直接写 `AutoAttacking`。Tank 经 C# 命令服务创建 `UnitOrderKind.Attack`，Adapter 通过独立 `OrdinaryAttacking` 行为完成追近和射程内攻击。

目标死亡或退出 SceneTree 时，普通 Attack 的订单进入 `TargetLost`；攻击者损失进入 `UnitLost`；新命令按统一订单替换规则取消旧 Attack。

统一 Stop 会取消当前普通 Attack 订单并清除其 `OrdinaryAttacking` Action，但不改变交战姿态、开火策略或武器冷却。策略允许时 Tank 可由自主待命逻辑立即重新发现敌人，因此视觉上的继续射击不代表旧订单未取消。

## 3. 当前限制

- 只迁移 Tank，其他单位仍保留 Legacy 普通攻击路径；
- 当前没有最后已知位置、战争迷雾丢失目标或情报权限策略；
- 普通 Attack 追近时的机会射击尚未接入，明确最终目标不会被其他敌人替换；
- 更细的 `MovingIntoRange/Firing` 状态延后。

## 4. 验证

- `CSharpCommandSmokeTest`：敌我关系、停火拒绝、专用订单和端口授权；
- `TankOrdinaryAttackSmokeTest`：停火拒绝、己方拒绝、伤害和目标失效订单；
- `TankForceAttackSmokeTest`：ForceAttack 仍覆盖停火；
- `tests/manual/TestOrdinaryAttack.tscn`：人工验证普通右键与强制攻击差异。
