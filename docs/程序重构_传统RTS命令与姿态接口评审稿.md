# 程序重构：传统 RTS 命令与姿态接口评审稿

> 文档状态：待项目负责人评审，尚未编码
>
> 范围：传统单位操作、持续交战姿态、编队和计划模式；不实现 AI 副官推理

## 1. 现有问题结论

当前底部中央的移动、攻击、防守、侦察、撤退、停止按钮属于 Legacy `AICommandHUD`，并非传统 RTS 单位命令栏：

- 只要 Match 中存在 Human，`Match.gd` 就会动态创建 `AICommandHUD`，不限于战役；
- HUD 只获取 `unit_group_1..3`，普通框选单位若未加入控制组便无法执行其命令；
- 传统 Ctrl+数字控制组因此被错误当成“AI 作战小队”的成员容器；
- 防守直接将 `unit.action` 替换成 `WaitingForTargets`；停止直接将 `unit.action` 清空；
- 移动、侦察和撤退只是等待地图右键，真正执行依赖选中状态及旧 Human 输入；
- 攻击只等待敌方单位目标，HUD 自身没有稳定 Command API；
- HUD 占用物理键 Q/W/E/R/D/F，绕过 InputMap，并与镜头和未来传统命令快捷键冲突；
- AI 文本、战役目标信号、控制组选择、命令按钮和单位 Action 写入集中在同一脚本。

结论：不能把这组按钮逐项翻译成 C#。应冻结其执行能力，并建立独立传统 `UnitCommandHUD`；控制组、AI 小队和编队不再共用同一个概念。

## 2. 六类概念边界

| 类别 | 作用 | 是否改变游戏状态 | 生命周期 |
|---|---|---:|---|
| Selection | Human 当前选中的单位 ID | 否，本地交互状态 | 短暂 |
| ControlGroup | Ctrl+数字保存/召回 Selection | 否，本地交互状态 | 对局内持久 |
| UnitCommand | 强制移动、攻击、停止、撤退、散开等 | 是 | 一次订单或跨 Tick 订单 |
| UnitMode | 侵略、警戒、固守、停火等持续策略 | 是 | 持续到再次切换 |
| Formation | 为一批单位分配相对位置与朝向 | 是 | 单次订单或持续队形策略 |
| OrderPlan | 编辑多个尚未提交的命令/路点 | 提交前否，提交后是 | 编辑会话与已提交计划 |

AI Squad/Battlegroup 是 AI 控制器的战术组织，不是 ControlGroup、Selection 或 Formation。AI 可以把其成员 UnitId 提交给同一命令服务，但不能让玩家必须加入 AI Squad 才能操作单位。

## 3. 传统单位命令

### 3.1 强制移动

```csharp
ForceMoveUnitsCommand(UnitIds, Destination, QueueMode)
```

- 以到达位置为最高优先级，不因发现敌人而停下或主动追击；
- 不永久修改单位交战姿态；到达后恢复此前姿态；
- 能移动射击的单位是否开火由 FirePolicy 和单位能力决定；“强制移动”不等同于禁火；
- 新命令默认替换旧移动/工作订单，追加键或计划模式可以使用 Append；
- 多单位按独立 UnitOrderId 返回部分成功。

普通右键移动可暂时映射为 ForceMove，等自动交战行为建立后再决定是否增加非强制 Move。

### 3.2 强制攻击

```csharp
ForceAttackCommand(UnitIds, Target, QueueMode)
```

`Target` 使用明确联合类型表达 `EntityTarget(UnitId)` 或 `GroundTarget(WorldPosition)`，不使用 `null` 或 Godot Node。

- 对实体目标：持续攻击该目标，直到目标丢失、不可攻击、订单取消或攻击者损失；
- 对地面目标：武器必须支持 Force Fire/Area Fire，否则逐单位返回 `WeaponCannotForceFire`；
- 不绕过射程、武器攻击域、冷却、弹药、视野/已知情报和路径规则；
- 是否允许友军目标及是否造成友军伤害由独立 Match Rule 配置；
- 建议显式 ForceAttack 临时覆盖 HoldFire，订单结束后仍恢复 HoldFire。此项需要最终确认。

### 3.3 停止

继续采用已批准的 `HaltMovementCommand`：

- 停止当前位移；
- 不停止攻击；
- 途中工作任务转为 Suspended，且不自动恢复；
- 不等同于 CancelCurrentOrder 或 CancelAllOrders；
- 传统命令栏直接作用于当前 Selection，不依赖控制组。

### 3.4 战术撤退/倒车移动攻击

建议命名为：

```csharp
TacticalWithdrawCommand(UnitIds, Destination, FacingPolicy, QueueMode)
```

它不是 AI 副官的宏观“撤退意图”，而是明确的战术机动：

- 有倒车能力的车辆保持车体/主武器朝向威胁方向，按倒车速度移动；
- 可以按 FirePolicy 和武器能力继续攻击；
- 无倒车语义的步兵、飞行单位或建筑返回 `UnsupportedMovementMode`，或由产品规则明确降级为 ForceMove；
- `FacingPolicy` 可选择保持当前朝向、面向指定世界方向，或面向明确威胁 UnitId；
- 不建议自动猜测“最危险敌人”，否则同一命令会因隐藏信息产生不可预测行为。

### 3.5 散开

```csharp
ScatterUnitsCommand(UnitIds, Center, Radius, QueueMode, Seed)
```

- 从单位群中心或指定 Center 向外分配可导航位置；
- 目标槽位按 UnitId 和 Seed 确定，保证测试、回放和网络同步可重复；
- 每个单位独立获得目标和 UnitOrderId；无可用槽位的单位可部分失败；
- Radius、最小间距和最大寻位次数进入版本化配置，不写死在 UI；
- 散开只生成移动订单，不创建永久 AI 小队。

## 4. 持续交战策略

从实现角度不建议把四个按钮塞进一个 enum。`停火` 与“是否追击/返回岗位”是正交规则，应拆为两个轴。

### 4.1 EngagementStance

```csharp
public enum EngagementStance
{
    Aggressive,
    Guard,
    HoldGround
}
```

| 姿态 | 主动索敌 | 自主移动 | 追击 | 脱离后行为 |
|---|---:|---:|---:|---|
| Aggressive 侵略 | 感知范围内 | 是 | 是，受追击上限约束 | 保持新位置/继续搜索 |
| Guard 警戒 | 警戒范围内 | 是 | 是，受岗位半径约束 | 返回 GuardAnchor |
| HoldGround 固守 | 仅武器范围内 | 否 | 否 | 保持原位 |

Guard 在切换时记录 `GuardAnchor`，或由带目标位置的 GuardAreaCommand 明确设置。追击范围、返回容差和索敌刷新间隔属于配置。

Aggressive 也应有最大追击距离或时间，防止单位被一个目标引到地图另一端；上限可以比 Guard 大，但不建议无限追击。

### 4.2 FirePolicy

```csharp
public enum FirePolicy
{
    FireAtWill,
    HoldFire
}
```

- HoldFire 禁止自主开火，不影响移动、采集、施工和编队；
- 解除 HoldFire 后恢复原 EngagementStance，不需要猜测之前是侵略、警戒还是固守；
- 将来若需要“只还击”，可增加 ReturnFire，不必改写三个移动姿态；
- UI 可以把“停火”表现为第四个醒目按钮，但底层是独立开关，不是第四种 EngagementStance。

## 5. 列队与控制组

“列队”建议解释为 Formation，而不是“加入作战小队”。

```csharp
SetFormationCommand(UnitIds, FormationSpec)
MoveFormationCommand(UnitIds, Destination, Facing, QueueMode)
```

`FormationSpec` 初期可包含 Line、Column、Wedge、Box、Loose，并带间距。实现规则：

- Formation 计算器只输出 `UnitId → WorldPosition/Facing` 槽位，不直接访问 Node；
- 单位能力、半径和移动域不同，可以拆分子队形或逐单位拒绝；
- 队形移动不要求单位同时到达；每个单位仍有独立订单状态；
- 单位损失后是否立即重排应由 `ReflowPolicy` 控制，避免所有单位在战斗中频繁换位；
- Ctrl+数字 ControlGroup 仅保存选择集合，不自动创建或修改 Formation；
- AI Battlegroup 只保存 AI 战术成员关系，也不自动成为 Formation。

## 6. 计划模式

计划模式不是一种单位 Action，建议作为 Human 输入/Application 编辑会话：

```text
BeginPlan
  → Add/Remove/Reorder planned commands
  → Validate preview
  → CommitPlan or CancelPlan
```

- Commit 前不改变权威游戏状态，也不产生 UnitOrderId；
- Commit 后为每个单位生成有序订单链，共享 PlanId，并返回逐命令/逐单位结果；
- 默认不假定计划模式会暂停游戏。是否暂停单人对局属于 Match Rule/UI 决策；多人对局通常不能由单个玩家暂停；
- 计划中的路径线、序号和预览属于 Presentation；计划 DTO 不包含 Line2D、NodePath 或鼠标回调；
- 若地形在编辑和提交之间变化，Commit 必须重新校验；执行过程中仍可能因动态地形进入 Unreachable；
- 未来大模型可提交相同计划 DTO，但仍受操作点、权限和观察限制。

## 7. AICommandHUD 屏蔽建议

在传统命令实现前先隔离 Legacy HUD：

1. 普通 Match、TestOneUnit 和传统 RTS 测试默认不创建 AICommandHUD；
2. 战役原型只有在任务数据显式启用时才创建；
3. 提供隐藏/显示设置，隐藏后释放鼠标拦截、键盘快捷键和焦点；
4. Legacy HUD 暂停直接写 `unit.action`，后续若保留只通过标准 Command API；
5. CampaignController 目前依赖其 squad 信号，屏蔽时需要兼容 Feature Flag，不能直接删除节点；
6. 新建独立传统 UnitCommandHUD，始终读取当前 Selection，不读取 `unit_group_1..3`；
7. 新 HUD 只负责发命令和显示过滤后的结果，不保存领域状态。

第一步建议只做 Feature Flag 和默认关闭，不立即设计最终 UI 视觉。

## 8. 建议实施顺序

1. 屏蔽普通对局的 Legacy AICommandHUD，保留战役显式开关；
2. 将 CommandRuntime 提升到 Match 级，Human Gateway 变成薄适配器；
3. 建立独立传统 UnitCommandHUD，先接 HaltMovement 与 ForceMove；
4. 实现 EngagementStance 与 FirePolicy 状态，不先实现完整攻击算法；
5. 迁移 ForceAttack，并增加多单位、敌我目标与 HoldFire 测试场景；
6. 实现 TacticalWithdraw 与 Scatter；
7. 独立实现 Formation；
8. 最后实现 OrderPlan 编辑与提交。

## 9. 待评审问题

1. ForceAttack 是否应临时覆盖 HoldFire，执行完成后恢复 HoldFire？本文建议“是”。
2. TacticalWithdraw 对不支持倒车的单位应拒绝，还是降级为 ForceMove？本文建议“拒绝并部分成功”，避免静默改变战术含义。
3. Aggressive 是否接受“较大但有限”的追击上限，而不是无限追击？本文建议有限。
4. GuardAnchor 是否在切换警戒姿态时取单位当前位置；若玩家指定区域，则用独立 GuardAreaCommand 更新？本文建议是。
5. 计划模式第一版是否只做实时队列编辑，不暂停游戏？本文建议是。
6. “列队”是否确认指 Formation 队形，而非控制组或 AI 作战小队？
7. Legacy AICommandHUD 是否按“普通对局默认关闭、战役任务显式开启且可隐藏”处理？
