# Tank 实体 ForceAttack 纵向样例记录

> 日期：2026-08-12  
> 范围：Tank 实体强制攻击、订单级停火覆盖、组合停止和传统 HUD；不实现地面弹道

## 1. 命令链路

```text
TraditionalUnitCommandHUD
  -> UnitActionsController
  -> UnitCommandGateway
  -> Match/CommandRuntime
  -> UnitCommandService
  -> IUnitAttackPort
  -> LegacyAttackPort
  -> ExplicitForceAttacking Action
```

Application 使用 `EntityAttackTarget(UnitId)`，不持有 Godot Node。Adapter 负责注册攻击者和目标，并把 Legacy 目标失效事件转换为权威订单状态。

## 2. 已实现语义

- Tank 可以显式强制攻击敌方、己方或友军实体；
- 显式己方/友军攻击使用现有完整基础伤害，不进行减伤；
- ForceAttack 持续到目标失效/死亡、攻击者死亡、订单被替换或玩家停止；
- 持久 `HoldFire` 不阻止显式 ForceAttack，且命令不会修改持久 FirePolicy；
- ForceAttack 结束后单位继续服从原有 `HoldFire`；
- 普通右键敌方目标仍是普通 Attack，Tank 处于 HoldFire 时不会执行；
- 攻击域按攻击者逐单位校验，Tank 当前只接受 TERRAIN 目标；
- 地面 Target DTO 已接入，但 Tank 稳定返回 `WeaponCannotForceFire`；
- 显式攻击目标死亡或退出 SceneTree 后，订单进入 `TargetLost`；
- 新 ForceMove/ForceAttack 订单会按现有订单替换规则取消旧订单。

## 3. 停止语义

底层 `HaltMovement` 没有改名或扩大语义。传统 HUD 的“停止”执行两个独立请求：

1. `HaltMovement`：停止当前导航；仅当活动订单为 ForceMove 时把它转为 Suspended；
2. `CancelForceAttack`：只取消活动的 ForceAttack；没有显式攻击时作为幂等无操作接受。

因此普通 `WaitingForTargets/AutoAttacking` 没有 ForceAttack 订单，不会被组合停止误取消。后续若策划要求独立“取消当前任务”，应新增命令，不能继续扩张停止含义。

## 4. 订单分类

`UnitOrderSnapshot` 新增 `UnitOrderKind`：

- `ForceMove`；
- `ForceAttack`。

订单分类用于精确决定暂停、取消和异步事件处理。它不是 UI 按钮名称，也不包含 Godot Action 类型。

## 5. 当前限制

- 本切片只迁移 Tank；Helicopter、炮塔等待各自能力和缺陷测试；
- 友伤倍率仍为完整伤害，后续通过版本化 `FriendlyFireDamageMultiplier` 进入数值管理；
- 地面/WorldObject ForceAttack 没有落点弹道和目标身份注册，当前不伪造视觉效果；
- 目标信息权限策略尚未接入；本地 Human 点击只提供交互限制，未来 AI/Python Adapter 仍需 `ITargetInformationPolicy`；
- ForceAttack 当前订单状态使用 `InProgress/TargetLost/Cancelled/UnitLost`，更细的 `AcquiringTarget/Firing` 延后实现。

## 6. 自动化验证

- `CSharpCommandSmokeTest`：友军实体接收、订单分类、选择性取消、地面稳定拒绝；
- `TankForceAttackSmokeTest`：HoldFire 临时覆盖、己方完整伤害、组合停止、普通右键受停火限制、目标死亡及地面拒绝；
- `TraditionalUnitCommandHudSmokeTest`：强制攻击目标模式可进入和取消；
- 原有移动、策略、Gateway、Campaign 测试继续回归。

## 7. 手动验收

运行 `tests/manual/TestForceAttack.tscn`：

1. 选择己方初始 Tank，点击“停火”；
2. 等待片刻，确认它不会普通攻击敌方建筑；
3. 点击“强制攻击”，右键红方 CommandCenter，确认攻击仍执行；
4. 攻击途中点击“停止”，确认显式攻击结束，且 HUD 仍显示停火；
5. 点击“强制攻击”，右键另一辆蓝方 FriendlyTarget，确认可以造成己方伤害；
6. 重新运行场景，点击“强制攻击”后右键地面，确认返回拒绝且说明当前武器不支持；
7. 解除停火后普通右键红方目标，确认普通攻击恢复。

本场景是程序灰盒验收资源，不代表最终地图、阵营提示或 UI 设计。

2026-08-12 人工验收结果：通过；命令反馈与视觉表现符合预期。
