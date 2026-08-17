# Tank 地面 ForceAttack 纵向样例记录

日期：2026-08-14

状态：代码与自动化测试完成，等待人工视觉验收。

## 1. 命令链路

```text
TraditionalUnitCommandHUD
  → UnitActionsController
  → UnitCommandGateway.ForceAttackGround
  → CommandRuntime
  → UnitCommandService.ForceAttack(GroundAttackTarget)
  → IUnitAttackPort.RequestGroundForceAttack
  → LegacyAttackPort
  → ExplicitGroundForceAttacking Action
```

核心命令与订单不依赖 Godot 坐标类型。Godot Adapter 只在端口边界转换 `WorldPosition` 与 `Vector3`。

## 2. 显式武器能力

`UnitCommandSnapshot.CanForceFireGround` 是独立能力，不根据单位是否拥有通用桥接方法推断：

- Tank 首轮设置为 `true`；
- 其他单位默认 `false`；
- 同一批命令可以部分接受；
- 不支持的单位返回 `WeaponCannotForceFire`。

这样后续可以分别评审火炮、导弹、步兵和飞行单位，而不会因继承公共 `Unit.gd` 自动获得空地开火能力。

## 3. 持续订单语义

地面炮击使用独立 `GroundForceAttack` 订单类型：

- 纯坐标本身不会失效；
- 近距离立即持续开火；
- 超出射程时先移动到射程边缘；
- 接近移动完成只是订单内部步骤，订单保持 `InProgress`，不会进入 `Arrived`；
- 玩家停止或新命令替换后进入 `Cancelled`；
- 攻击者失效后进入 `UnitLost`；
- `HoldFire` 被当前显式订单临时覆盖，但持久策略仍为 `HoldFire`。

桥梁、建筑和剧情地块等可能失效的对象未来应使用带稳定对象 ID 的 `WorldObjectAttackTarget`，不能用纯坐标伪装成可失效目标。

## 4. 命中与友伤边界

首轮不创造未经评审的爆炸半径：

- 每发落点只检查可伤害单位的 footprint 是否覆盖目标坐标；
- 覆盖落点的敌我单位都会受到完整基础伤害；
- 空白地面仍持续播放炮击表现，可作为封锁点；
- 多个单位同时覆盖落点时都会受击；
- 未来 AoE 半径、衰减和 `FriendlyFireDamageMultiplier` 进入版本化数值管理，不写死在当前命令 DTO。

## 5. 停止语义

`CancelForceAttack` 同时识别实体 `ForceAttack` 与地面 `GroundForceAttack`。Legacy 桥接只会移除对应显式攻击 Action，不修改持续开火策略。

`CMD-017` 已将 HUD“停止”改为单次 `StopUnits`：地面 `GroundForceAttack` 进入 `Cancelled`，持续开火策略保持不变。底层 `CancelForceAttack` 仍作为精细能力保留。

## 6. 自动化验证

- 纯 C#：支持与不支持地面炮击的单位在同批命令中返回 `PartiallyAccepted`；
- 支持单位创建 `GroundForceAttack` 独立订单；
- 停火策略保持不变；
- Tank 近距离炮击造成 footprint 落点伤害；
- 订单持续为 `InProgress`；
- 取消后停止伤害并进入 `Cancelled`；
- 远距离接近的 `movement_finished` 不会误报 `Arrived`。

## 7. 人工验收

运行 `tests/manual/TestForceAttack.tscn`：

1. 选择 Tank，切换停火；
2. 点击“强制攻击”后右键近处空白地面；
3. 确认 Tank 面向落点并持续开火；
4. 对远处地面重复操作，确认 Tank 先接近射程再开火；
5. 点击“停止”，确认炮击立即结束；
6. 确认停止后持久策略仍为停火。

2026-08-14 人工验收通过：可对地强制攻击、停止后终止炮击，停火临时覆盖且停止后仍保持停火。

同日后续验收发现远距离接近阶段 Stop 后仍继续移动。已定位为 Action 退出时未撤销 `Movement` 目标，并补充 `_exit_tree()` 清理与真实位移回归测试；等待人工复验远距离接近途中停止。
