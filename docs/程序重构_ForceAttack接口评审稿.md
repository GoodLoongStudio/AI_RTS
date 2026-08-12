# 程序重构：ForceAttack 接口评审稿

> 日期：2026-08-12  
> 状态：待接口评审  
> 范围：强制攻击命令、目标联合类型、即时回执与异步订单状态；本稿不实现攻击算法和最终 UI

## 1. 目标

`ForceAttack` 表达玩家、规则 AI 或未来大模型 AI 的强烈明确攻击意图。所有调用方提交同一套 Application 命令；Human HUD 只负责选择目标和显示经过权限过滤的结果，不直接写入 `unit.action`。

本命令与自动索敌不同：它可以显式指定敌方、友军、己方或地面目标，并临时覆盖 `HoldFire`。但它不绕过所有权、武器能力、攻击域、射程、冷却、弹药、视野/已知情报和路径规则。

## 2. 现有代码能力与缺口

### 2.1 已有能力

- `AutoAttacking` 可以追近敌方实体，并在射程内切换为 `AttackingWhileInRange`；
- Tank 只能攻击 TERRAIN 域，Helicopter 可攻击 TERRAIN 与 AIR 域；
- CannonShell 生成时立即对实体目标扣血，Rocket 跟踪实体目标并在动画事件时扣血；
- 目标退出 SceneTree 后，现有攻击 Action 和 Rocket 会自行释放；
- 伤害写入点只执行 `target_unit.hp -= attack_damage`，本身不检查阵营。

### 2.2 当前缺口

- `AutoAttacking.is_applicable` 明确拒绝同玩家目标，无法表达显式友军/己方攻击；
- Projectile 都要求 `target_unit`，不存在地面坐标、爆炸半径或区域伤害契约；
- 武器能力只有 damage、interval、range、attack_domains，缺少 `CanForceFireAtGround` 等能力；
- 没有 `FirePolicy` 权威状态，因此尚不能可靠实现“临时覆盖 HoldFire，结束后恢复”；
- 命令服务的单位快照只有 Owner 与 CanMove，无法校验武器和目标；
- 当前等待/攻击 Action 直接扫描全局 `units`，没有接入战争迷雾或调用方信息权限；
- 攻击者和目标水平位置重合时，`looking_at` 可持续报错，已登记为 `LEGACY-COMBAT-001`。

## 3. 命令 DTO

```csharp
public sealed record ForceAttackCommand(
    IReadOnlyList<UnitId> UnitIds,
    AttackTarget Target,
    QueueMode QueueMode);

public abstract record AttackTarget;

public sealed record EntityAttackTarget(UnitId TargetUnitId) : AttackTarget;

public sealed record GroundAttackTarget(WorldPosition Position) : AttackTarget;
```

第一阶段尚未实现 Queue/计划系统时，Gateway 可固定提交 `QueueMode.Replace`，但 Domain/Application DTO 保留该字段，避免日后通过 UI 参数改变核心接口。

`AttackTarget` 不得包含 Godot Node、NodePath、Variant 或 `null`。Godot Adapter 负责把运行时 Node 注册为稳定 `UnitId`。

## 4. 接收时校验

命令按攻击者逐单位校验，因此允许 `PartiallyAccepted`。建议校验顺序如下：

1. 命令单位集合非空，Target 结构有效；
2. 攻击者存在且属于命令发出者；
3. 攻击者具备至少一个武器；
4. Entity Target 存在、仍可作为伤害目标，并符合武器攻击域；
5. Ground Target 坐标为有限值，且武器支持对地强制开火；
6. 发出者当前被授权引用该目标信息；
7. 攻击端口当前可以接收订单。

射程外不属于接收失败：可移动攻击者接受命令后尝试接近，不可移动攻击者若目标当前在射程外则拒绝 `TargetOutOfRange`。动态地形导致后续无法接近属于异步 `Unreachable`，不回改最初的即时回执。

## 5. 建议错误码

在公共 `CommandErrorCode` 中增加：

| 错误码 | 含义 |
|---|---|
| `InvalidAttackTarget` | Target 联合类型或地面坐标无效 |
| `UnitCannotAttack` | 攻击者没有可用武器 |
| `TargetNotFound` | 实体目标不存在或已经失效 |
| `TargetNotDamageable` | 实体存在，但不是当前规则下的伤害目标 |
| `WeaponCannotTargetDomain` | 武器不能攻击目标的 TERRAIN/AIR 等域 |
| `WeaponCannotForceFire` | 武器不支持向无实体的地面位置开火 |
| `TargetNotObservable` | 发出者无权引用该实时目标信息 |
| `TargetOutOfRange` | 不可移动攻击者无法覆盖目标位置 |
| `AttackUnavailable` | Legacy/引擎攻击端口暂时无法接收订单 |

“友军目标”本身不作为错误。显式 `ForceAttack` 可以选中己方或盟友；是否产生伤害由版本化 Match Rule 决定。Demo 若要满足已确认的自毁/防止被利用场景，应把显式强制攻击的友军伤害规则设为启用。

## 6. 即时回执与异步状态

`CommandResult` 只回答“权威执行层是否接收订单”，不承诺开火、命中或摧毁目标：

```text
Accepted
  -> AcquiringTarget / MovingIntoRange / Firing
  -> TargetDestroyed | TargetLost | Unreachable | Cancelled | UnitLost
```

现有 `UnitOrderState` 建议扩展：

- `AcquiringTarget`：正在验证/跟踪实体或前往射程；
- `Firing`：至少已进入一次可开火状态；
- `Completed`：一次性地面强制攻击已完成规定射击次数；
- 继续复用 `TargetLost`、`Unreachable`、`Cancelled`、`UnitLost`。

Entity ForceAttack 不应因“第一发命中”完成；默认持续到目标失效、订单被替换/取消或攻击者损失。Ground ForceAttack 必须是有限订单，建议 DTO 后续增加明确的 `FireCount` 或 `Duration`，不能隐式无限封锁。

Human 可以立即获得接受/拒绝反馈；未来 AI Adapter 是否看到该回执、逐单位原因或异步状态，必须经过观察与操作点策略过滤，不能因为内部 `CommandResult` 存在而自动泄露给 AI。

## 7. FirePolicy 关系

- `HoldFire` 阻止自主索敌和自主开火；
- 显式 `ForceAttack` 为该订单创建临时开火授权；
- 临时授权属于订单，不修改单位持久 `FirePolicy`；
- ForceAttack 结束、取消或被替换后，若持久策略仍为 `HoldFire`，单位立即恢复禁火；
- 普通右键敌方目标是否也覆盖 HoldFire，需要单独定义为普通 Attack 或映射为 ForceAttack，不能由 UI 偶然决定。

因此按既有实施顺序，应先建立 `EngagementStance` 与 `FirePolicy` 的权威状态，再迁移 ForceAttack 执行链路。

## 8. 地面强制攻击建议

现有 Tank/Helicopter 都没有地面目标弹道。第一版建议：

- 先完成 Entity ForceAttack 纵向样例和 FirePolicy 临时覆盖；
- `GroundAttackTarget` DTO 与 `WeaponCannotForceFire` 错误码同步进入接口；
- 在拥有落点弹道、爆炸/命中规则和明确武器能力前，现有单位对 Ground Target 均返回 `WeaponCannotForceFire`；
- 后续可先为 Tank 炮定义 `CanForceFireAtGround=true`、有限 `FireCount=1`，再增加区域伤害；
- Helicopter Rocket 当前依赖移动实体目标，不能因为视觉上是火箭就默认支持地面轰炸。

这样可以保证接口完整，又不会用临时假弹道伪装功能已经实现。

## 9. 视野与信息权限

UI 点不到隐藏目标不等于 Application 已完成权限校验。统一命令服务未来会被规则 AI、外部 Python Adapter 和大模型 AI 调用，因此需要独立的 `ITargetInformationPolicy`：

```csharp
TargetReferenceResult CanReference(
    MatchId matchId,
    PlayerId issuerPlayerId,
    UnitId targetUnitId,
    long simulationTick);
```

该策略只判断“调用方是否有权引用此目标”，不把完整单位情报返回给调用方。失去实时视野后的最后已知位置攻击，应显式转为 `GroundAttackTarget(lastKnownPosition)`，并再次承担地面强制开火能力和信息时效成本，不能继续用隐藏实体 `UnitId` 跟踪。

## 10. 第一阶段实现边界

建议下一纵向样例只包含：

1. C# `EngagementStance` / `FirePolicy` 状态与设置命令；
2. Tank Entity ForceAttack，允许敌方及显式己方目标；
3. ForceAttack 临时覆盖 HoldFire，订单结束后恢复；
4. 目标失效转为 `TargetLost`；
5. 水平位置重合时不调用无效 `looking_at`；
6. Ground Target 返回稳定的 `WeaponCannotForceFire`，不实现假地面炮击；
7. 传统 HUD 增加“强制攻击”目标模式及即时反馈；
8. 多单位、敌我目标、HoldFire、目标中途损失和重合位置自动化测试。

Helicopter、炮塔、区域伤害、弹药、完整战争迷雾策略和最终 UI 放在后续切片。

## 11. 待确认项

1. 第一阶段是否接受“接口支持 Ground Target，但现有单位稳定拒绝”，待 Tank 地面弹道切片再开放？
2. Demo 的显式 ForceAttack 是否默认允许对己方/盟友造成完整伤害？
3. Entity ForceAttack 是否持续到目标失效，而 Ground ForceAttack 默认一次射击后完成？
4. 普通右键敌方单位是否继续作为普通 Attack，只有点击“强制攻击”才临时覆盖 HoldFire？
