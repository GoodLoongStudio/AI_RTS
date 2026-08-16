# 实体 ForceMove 输入纵向样例记录

## 1. 目标

`CMD-029` 修正一次性 ForceMove 状态下点击单位或建筑时的输入解释。实体点击必须产生位置意图，并使用鼠标命中实体表面的世界坐标，不能退化为普通 Attack、Follow 或 MoveToUnit。

## 2. 输入契约

`MatchSignals.unit_targeted` 的运行时参数为：

| 参数 | 含义 |
|---|---|
| `unit` | 被鼠标命中的实体，供普通交互、Attack 和 ForceAttack 等目标型命令使用 |
| `target_position` | 物理拾取返回的实体表面世界坐标，供 ForceMove 等位置型命令使用 |

`Targetability` 是该坐标的权威输入来源。`UnitActionsController` 在 ForceMove 目标选择状态下优先消费 `target_position`，清除一次性状态并调用既有公共 `ForceMoveUnits` 边界；目标高亮只是表现，不影响命令是否结束分派。

## 3. 边界

- 本项不实现碾压等级、阻挡等级或建筑摧毁，相关规则仍属于 `CMD-023`；
- Tank 获得正确 ForceMove 订单后，仍可能被建筑 NavMesh footprint 或物理碰撞阻挡；
- Helicopter 使用 AIR 导航，不应因地面建筑碰撞而被挡在 footprint 外；
- 普通右键实体、ForceAttack 和 AttackMove 继续使用实体目标语义；
- `UnitVoicesController` 同时监听地面与实体目标信号，因此接收位置参数时采用兼容签名，不改变语音触发次数。

## 4. 自动验证

新增 `tests/automated/EntityForceMoveSmokeTest.tscn`，覆盖：

1. Helicopter 点击敌方建筑产生 `ForceMove` 订单；
2. Helicopter 的 NavigationAgent 使用实际点击坐标的水平位置；
3. Tank 点击敌方建筑产生 `ForceMove`，Action 为 `Moving` 而非普通 Attack；
4. 两类单位都返回 `Accepted`；
5. HoldFire 隔离条件下目标建筑不因本命令直接受伤。

2026-08-14 Godot 4.7 Mono 无头测试通过，输出 `Entity ForceMove smoke test completed: 0 failure(s)`。退出时仍有已登记的 RID/ObjectDB 清理告警，与本项功能断言分开处理。

## 5. 人工验收

运行 `tests/manual/TestHelicopterCommands.tscn`：

1. 将蓝方 Tank 与 Helicopter 切换为停火；
2. 单选 Helicopter，点击“强制移动”，再右键红方建筑；应反馈接受并飞到点击位置上空；
3. 单选 Tank 重复操作；应反馈接受并尝试接近点击点，但允许被建筑 footprint 挡住；
4. 两次操作均不应解释为对建筑普通攻击。

## 6. 人工验收结果

2026-08-14 人工验收通过：ForceMove 可把敌方建筑作为位置目标，Helicopter 正常停在建筑上方。

Tank 会贴紧敌方建筑并来回踱步。该现象发生在正确 ForceMove 订单进入地面导航之后，已并入导航专项，不作为 `CMD-029` 输入分派失败。

当前状态：已完成。
