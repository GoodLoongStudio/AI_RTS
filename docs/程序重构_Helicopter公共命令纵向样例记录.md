# Helicopter 公共命令纵向样例记录

日期：2026-08-14

对应进度：`CMD-026A`

状态：已完成并通过人工验收

## 1. 目标与边界

本切片把现有 Helicopter 从 `UnitActionsController` 的 Legacy 分支接入与 Tank 相同的 C# 公共命令入口，验证命令契约不依赖地面单位实现。

本轮不修改 Rocket 数值、不增加对地强制攻击能力，也不扩展 Drone、Worker、采集和施工。飞行导航只修复 NavMesh 初始化竞态，不处理已延期的路径质量、RVO 或多单位优化。

## 2. 命令能力

| 命令 | Helicopter 行为 |
|---|---|
| 普通移动、强制移动 | 按 AIR 导航域计算编队目标并进入公共订单 |
| Stop | 清除当前移动或攻击 Action，不改变持续战斗策略；同时清除 NavigationAgent 旧速度 |
| 撤退 | 因 `CanReverse=false`，按已评审规则退化为普通移动 |
| 普通 Attack | 仅攻击合法敌方空中或地面目标；HoldFire 时稳定拒绝 |
| ForceAttack | 可临时覆盖 HoldFire 攻击合法实体目标 |
| 地面/实体 AttackMove | 可推进并按既有姿态、开火策略处理途中目标 |
| 地面 ForceAttack | 当前 `CanForceFireGround=false`，返回 `WeaponCannotForceFire` |
| 侵略、警戒、固守、停火 | 与 Tank 共用权威 `CombatPolicyStore` |

## 3. 输入层调整

`UnitActionsController` 原先在移动、Stop、策略、AttackMove 和 ForceAttack 等路径分别判断 `unit is Tank`。本轮集中为 `_is_migrated_command_unit()`，当前允许 Tank 与 Helicopter，未评审单位继续走 Legacy 路径。

传统命令 HUD 的可用提示同步改为 Tank 或 Helicopter。右下角 Legacy 通用菜单的 `X` 也改用统一 `StopUnits`，避免 Helicopter 无响应以及 Tank 仍只停止移动的语义分裂。

该类型白名单只是迁移期边界。待更多单位迁移后，应由统一能力描述替代脚本类型判断，而不是继续扩展硬编码列表。

## 4. 同步发现并修复的初始化缺陷

首轮测试中，Helicopter 已获得 `InProgress` 移动订单，但始终位于 `y=0`，NavigationAgent 的下一路径点等于当前位置。原因是：

1. AirNavigation 修改运行时参考碰撞体后立即烘焙，PhysicsServer 尚未同步新 Shape；
2. Movement 只在下一帧尝试一次 NavMesh 对齐，失败后不再重试；
3. 若直接在 `_ready()` 中等待导航完成，初始化随机微调又可能覆盖等待期间收到的玩家命令。

当前处理：

- AirNavigation 在参考碰撞体更新后等待两个 physics frame 再烘焙；
- Movement 在有限帧数内等待有效 Navigation Region，超时保留场景原坐标并明确告警；
- 导航初始化保持非阻塞，并保存初始化期间收到的最后移动目标；早到的 Stop 会禁止初始化随机微调；
- `Movement.stop()` 同时提交零速度，避免空中单位沿上一帧 RVO 安全速度继续漂移。

以上只解决导航就绪和命令丢失，不改变路径搜索、避障半径、脱困或编队算法。

## 5. 自动验证

新增 `HelicopterCommandSmokeTest`，覆盖：

- 传统 HUD Selection 识别；
- 普通右键移动进入公共订单并产生实际位移；
- 统一 Stop；
- 无倒车能力撤退退化为普通移动；
- HoldFire 拒绝普通 Attack；
- ForceAttack 临时覆盖停火并由 Rocket 命中；
- AttackMove 接收；
- 地面 ForceAttack 返回 `WeaponCannotForceFire`。

回归通过：

- `TankCommandBridgeSmokeTest`；
- `TankTacticalWithdrawSmokeTest`；
- `TankForceAttackSmokeTest`；
- `RuntimePlacementSmokeTest`；
- `MultiUnitCommandSmokeTest`。

Godot 无头退出仍报告已登记的 Navigation/Renderer RID 与 ObjectDB 清理警告，本切片没有扩大其处理范围。

## 6. 人工验收

打开 `tests/manual/TestHelicopterCommands.tscn` 并按 F6：

1. 选择蓝方 Helicopter，确认传统 RTS 命令栏可用；
2. 普通右键地面移动，再分别检查强制移动、移动并攻击与撤退；
3. 移动中点击传统 HUD“停止”，再用右下角 `X` 复验一次，两者均不应继续漂移；
4. 切换 HoldFire，普通右键红方建筑应拒绝；
5. HoldFire 下点击“强制攻击”再右键红方建筑，应发射 Rocket；Stop 后仍保持 HoldFire；
6. 点击“强制攻击”后右键地面，应显示拒绝，不能静默获得未声明的对地强制攻击能力。

## 7. 人工验收结果

2026-08-14 人工验收通过：Helicopter 的攻击、停火、撤退等运行正确。

## 8. 验收中新发现的语义边界

### 8.1 ForceMove 点击敌方建筑

验收时的 `ForceMove` 目标选择只在 `terrain_targeted` 中消费。右键命中建筑或单位时发布的是 `unit_targeted`，控制器没有 ForceMove 分支，因此会落回普通右键 Attack/Follow 等解释；这发生在导航、碰撞和未来碾压判定之前。

因此当前现象由两层问题构成：

1. Tank 与 Helicopter 都没有真正收到“移动到该实体位置”的 ForceMove；
2. 即使后续把实体点击转换为世界坐标，Tank 仍会受建筑 NavMesh/碰撞 footprint 阻挡，能否进入或摧毁该 footprint 应由 `CMD-023` 碾压/阻挡等级决定；Helicopter 的 AIR 导航则不应被地面建筑阻挡。

输入分派问题登记为 `CMD-029`，不能误报为当前已存在碾压等级判定。

2026-08-14 已完成代码修正：`Targetability` 将实体表面的实际世界点击坐标随 `unit_targeted(unit, target_position)` 发布；一次性 ForceMove 状态优先消费该坐标并提交公共 `ForceMove` 订单。自动测试已确认 Tank 与 Helicopter 均不再退化为普通 Attack/Follow，等待人工验收后关闭 `CMD-029`。

本修正不会使 Tank 穿过建筑碰撞或自动获得碾压能力。Tank 命令可被接收，但其合法可达位置仍由地面导航和未来 `CMD-023` 决定；Helicopter 则可按 AIR 导航移动到点击位置上空。

### 8.2 Helicopter 普通移动到矿石

非 Worker 点击矿石时没有采集交互，会落入通用 `MovingToUnit`。该 Action 使用二维距离，并在移动者与目标的 footprint 加间距后停止，没有区分 AIR 与 TERRAIN，因此 Helicopter 也停在矿石旁边。

这符合当前实现，但不建议作为最终规则。建议无采集/施工等交互的空中单位右键地面实体时，把意图解释为移动到点击位置或实体中心上空；地面单位仍按障碍与自身 footprint 保持合法距离。该跨导航域停止距离问题登记为 `CMD-030`，等待接口与输入语义评审后修改。
