# 程序重构：传统 RTS 命令与姿态接口评审稿

> 文档状态：命令语义已通过评审；Legacy HUD 隔离已实施，传统命令尚未编码
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
- 若单位具有碾压能力，ForceMove 可以令其冒着火力冲向敌人并按碰撞/伤害规则尝试碾压；ForceMove 本身不凭空赋予碾压能力；
- 新命令默认替换旧移动/工作订单，追加键或计划模式可以使用 Append；
- 多单位按独立 UnitOrderId 返回部分成功。
- ForceMove 属于玩家强烈明确意图，Human Presentation 应立即反馈命令是否接收；未来 AI 是否获得同等反馈仍由观察策略决定。

2026-08-12 后续评审已确认普通 Move 与 ForceMove 的交互来源不同，但单位执行语义基本相同，不能继续把普通右键移动仅作为未定义的临时映射。详细边界见 3.2 节。

### 3.2 普通移动与强制移动

建议命名为：

```csharp
MoveUnitsCommand(UnitIds, Destination, QueueMode)
ForceMoveUnitsCommand(UnitIds, Destination, QueueMode)
```

两者共同遵守以下执行规则：

- 以沿当前导航路径到达目的地为最高优先级，不因发现敌人而停下、转向对峙或追击；
- 具备移动射击能力的单位可以攻击武器射界内、路径附近的合法敌方目标；不具备移动射击能力的单位在移动期间完全不开火；
- 移动射击只能伴随推进，不得改变底盘路径或令单位停下；
- 若敌方碰撞体实际阻断导航，单位按碰撞、体积与碾压等级处理，而不是把任何接触都当成 AttackMove；
- 单位具备碾压能力时，会自动碾压等级较低且可碾压的敌方单位；同级或更高碾压等级单位及不可碾压固定建筑可以阻挡；
- 碾压能力、可碾压目标和等级来自单位能力/数值契约，Move 与 ForceMove 都不凭空赋予能力；
- HoldFire 会禁用伴随射击，但不影响移动与合法碾压。

两者差异主要属于 Human Input 与意图记录：

- 普通右键由点击对象决定 Move 或普通 Attack；
- ForceMove 进入显式地面选点状态，即使鼠标下方有敌方或己方实体，也把点击解析为地面目的地，解决密集单位遮挡地面的碾压操作；
- 输入层完成地面解析后，两者可以复用同一个移动执行策略，但订单仍保留 `Move` / `ForceMove` 类型，以支持反馈、回放、统计和 AI 操作点策略；
- ForceMove 不覆盖 HoldFire，也不比 Move 拥有更强的碾压、寻路或移动射击权限。

### 3.3 移动并攻击

建议命名为：

```csharp
AttackMoveCommand(UnitIds, Target, QueueMode)
```

`Target` 使用联合类型表达 `GroundTarget(WorldPosition)` 或敌方 `EntityTarget(UnitId)`：

- GroundTarget：沿路线推进到指定地面位置；
- EntityTarget：以指定敌方实体为最终攻击/追踪目标；目标失效后订单结束或按明确的失效策略处理，不能悄悄改成攻击其他最终目标；
- 推进途中发现符合目标选择策略的敌人时，可以离开路径交战，清除阻碍后继续原订单；
- AttackMove 与普通 Move 的核心差异是允许暂停推进、改变局部路径并处理遭遇敌人；
- AttackMove 不获得 ForceAttack 的停火覆盖权，不允许选择己方目标，也不自动获得对地强制开火能力；
- HoldFire 下不发生途中交战，实际表现退化为普通 Move；若最终 Target 是敌方实体，仍不得绕过 HoldFire 开火。

交战姿态影响 AttackMove 的离路范围和追击行为：

| 姿态 | 途中交战 | 离开推进路径 | 追击 | 清敌后行为 |
|---|---|---|---|---|
| Aggressive 侵略 | 感知范围内积极接敌 | 较宽，受配置上限限制 | 有限追击 | 返回原订单并继续推进 |
| Guard 警戒 | 处理路径警戒范围内敌人 | 较小 | 不追击脱离范围的敌人 | 逐渐回归原路径 |
| HoldGround 固守 | 只处理当前武器射程内敌人 | 不主动离路 | 不追击 | 沿下令时确定的较直接路径继续推进 |
| 任意姿态 + HoldFire | 不交战 | 不离路 | 不追击 | 作为普通移动执行 |

这里的“原路径”是可因地形变化重新求解的订单导航走廊，不要求保存 Godot 导航系统每一个历史拐点。HoldGround 的“较直接路径”也必须服从可通行地形，不能绕过桥梁损毁等动态导航约束。

### 3.4 普通攻击与强制攻击

普通右键敌方实体建议显式建模为：

```csharp
AttackCommand(UnitIds, EntityTarget, QueueMode)
```

- 仅接受合法敌方实体，不接受己方实体或纯地面坐标；
- 追近并持续攻击明确目标，目标失效、订单替换、攻击者损失或规则拒绝时结束；
- 前往最终实体目标途中，具备移动射击能力的单位可以向射界内其他合法敌人伴随开火，但不得因此转向、停下或更换最终目标；不具备该能力的单位在追近途中不开火；
- 受 HoldFire 约束，不获得临时开火授权；
- 对敌方实体的追近、射程和开火表现可以与 ForceAttack 复用执行组件。

强制攻击命名为：

```csharp
ForceAttackCommand(UnitIds, Target, QueueMode)
```

`Target` 使用明确联合类型表达 `EntityTarget(UnitId)` 或 `GroundTarget(WorldPosition)`，不使用 `null` 或 Godot Node。

- 对实体目标：持续攻击该目标，直到目标丢失、不可攻击、订单取消或攻击者损失；
- 对地面目标：武器必须支持 Force Fire/Area Fire，否则逐单位返回 `WeaponCannotForceFire`；
- 不绕过射程、武器攻击域、冷却、弹药、视野/已知情报和路径规则；
- 允许显式选择友军或己方单位作为强制攻击目标，以支持阻止其被敌方利用等极端战术；实际伤害仍由友军伤害 Match Rule 决定；
- ForceAttack 临时覆盖 HoldFire，订单结束后恢复 HoldFire；
- ForceAttack 属于玩家强烈明确意图，Human Presentation 应立即反馈是否接受、目标/武器不支持等结果；
- 对地攻击可以用于炮击区域和建立火力封锁带，但持续封锁属于多个攻击订单或后续 Area Fire 设计，不由一次命令隐式无限执行。

普通 Attack 与 ForceAttack 的差异不应由攻击 Action 偶然决定：ForceAttack 额外允许地面目标和显式己方目标，并临时覆盖 HoldFire；对普通敌方实体的基础攻击过程则保持一致。

### 3.5 停止

继续采用已批准的 `HaltMovementCommand`：

- 停止当前位移；
- 不停止攻击；
- 途中工作任务转为 Suspended，且不自动恢复；
- 不等同于 CancelCurrentOrder 或 CancelAllOrders；
- 传统命令栏直接作用于当前 Selection，不依赖控制组。

### 3.6 战术撤退/倒车移动攻击

建议命名为：

```csharp
TacticalWithdrawCommand(UnitIds, Destination, QueueMode)
```

它不是 AI 副官的宏观“撤退意图”，而是明确的战术机动：

- 有倒车能力的车辆将车尾对齐实时导航路径的局部切线方向，按倒车速度移动；
- 路径转弯、动态避障或重寻路会令底盘朝向随当前路径方向更新；不锁定下令瞬间朝向，也不直接朝向最终目的地；
- 撤退中的攻击仍受 FirePolicy、射程、目标域、移动射击能力和武器相对底盘的射界限制；
- 无倒车语义的可移动单位自动降级为 ForceMove，避免仓促撤退时要求玩家按单位类型重复下令；不可移动建筑仍逐单位拒绝；
- 不自动猜测并锁定“最危险敌人”来控制底盘朝向；敌情变化只影响武器选目标，不改变车尾沿路径前进的规则。
- 撤退始终以移动为最高优先级，Aggressive/Guard/HoldGround 均不得令单位离开撤退路径、停下对峙或追击；允许开火时只进行不干扰撤退的伴随射击。

### 3.7 散开

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

Guard 不在点击姿态按钮时立即固定 `GuardAnchor`。其更新规则为：

- 当前无移动订单时，切换 Guard 后以当前位置为岗位点；
- 当前正在移动时，移动完成后以目的地/实际完成位置作为岗位点；
- Guard 状态下收到玩家移动命令，命令完成后以新位置作为岗位点；
- 移动被 Halt 或其他原因中断后，以中断时实际位置作为岗位点；
- 由带目标位置的 GuardAreaCommand 可以显式更新岗位区域。

追击范围、返回容差和索敌刷新间隔属于配置。

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

### 4.3 TargetSelectionPolicy

目标选择不并入 EngagementStance。预留独立、可组合的策略：

```csharp
public sealed record TargetSelectionPolicy(
    HostileTargetCategory AllowedCategories,
    TargetPriorityProfile PriorityProfile);
```

其中 `HostileTargetCategory` 应使用可组合 Flags 或等价集合，候选项至少预留：

- CombatUnit：作战单位；
- Worker：采集/施工单位；
- DefensiveStructure：炮塔等防御建筑；
- ProductionStructure：生产建筑；
- EconomyStructure：资源类建筑；
- Objective：桥梁、任务目标等可攻击世界对象。

实施约束：

- 初版默认 `AllHostileTargets`，保持所有合法敌方目标均可被自主攻击；
- 当前不增加最终 UI 按钮，等待 UI/策划确认交互布局；
- `AllowedCategories` 决定是否允许自主选择，`PriorityProfile` 只在多个合法目标之间排序；
- 显式普通 Attack/ForceAttack 的明确实体目标不应被自主目标过滤器擅自改写；是否允许玩家显式攻击被过滤类别，后续作为独立规则评审；
- 目标分类来自稳定能力标签或世界对象类型，不使用具体 Godot 场景名和节点路径判断；
- 策略必须可由 Human、传统 AI 和未来大模型 AI 通过同一命令接口设置，并接受所有权与信息权限校验。

## 5. 列队与控制组

“列队”确认解释为 Formation，而不是“加入作战小队”。典型交互是玩家用鼠标拖拽方阵的方向、宽度和纵深；它可以单独整理阵型，也可以同时指定移动终点，本质上仍是为每个单位计算独立目标位置。

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

由于拖拽预览、槽位分配、混合半径、朝向、导航与重排策略均较复杂，Formation 推迟到核心移动、攻击、姿态和公共 CommandRuntime 稳定后实施。

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
- 计划模式不暂停游戏时间；其他玩家与 AI 可以继续观察、决策和执行命令；
- 计划中的路径线、序号和预览属于 Presentation；计划 DTO 不包含 Line2D、NodePath 或鼠标回调；
- 若地形在编辑和提交之间变化，Commit 必须重新校验；执行过程中仍可能因动态地形进入 Unreachable；
- 未来大模型可提交相同计划 DTO，但仍受操作点、权限和观察限制。

## 7. AICommandHUD 屏蔽建议

在传统命令实现前先隔离 Legacy HUD：

1. 当前阶段仍创建 AICommandHUD 以兼容 CampaignController，但默认隐藏；
2. HUD 提供独立显示/隐藏按钮，隐藏后释放鼠标拦截、键盘快捷键和焦点；
3. UI/策划确认最终策略后，再决定普通 Match 是否完全不创建、战役是否通过任务数据显式启用；
4. Legacy HUD 暂停直接写 `unit.action`，后续若保留只通过标准 Command API；
5. CampaignController 目前依赖其 squad 信号，屏蔽时需要兼容 Feature Flag，不能直接删除节点；
6. 新建独立传统 UnitCommandHUD，始终读取当前 Selection，不读取 `unit_group_1..3`；
7. 新 HUD 只负责发命令和显示过滤后的结果，不保存领域状态。

当前已完成默认隐藏和独立切换按钮，不代表最终 UI 视觉方案。

## 8. 建议实施顺序

1. 默认隐藏 Legacy AICommandHUD 并保留切换按钮（已完成）；
2. 将 CommandRuntime 提升到 Match 级，Human Gateway 变成薄适配器；
3. 建立独立传统 UnitCommandHUD，先接 HaltMovement 与 ForceMove；
4. 实现 EngagementStance 与 FirePolicy 状态，不先实现完整攻击算法；
5. 迁移 ForceAttack，并增加多单位、敌我目标与 HoldFire 测试场景；
6. 实现 TacticalWithdraw 与 Scatter；
7. 核心命令稳定后再独立实现鼠标拖拽 Formation；
8. 最后实现 OrderPlan 编辑与提交。

## 9. 评审结论

1. ForceAttack 临时覆盖 HoldFire，结束后恢复；允许对地和显式己方目标，并向 Human 及时反馈；
2. TacticalWithdraw 对不支持倒车的可移动单位降级为 ForceMove；
3. Aggressive 采用较大但有限的追击上限；
4. GuardAnchor 在移动完成或中断时更新；无移动时使用切换位置；
5. 计划模式不暂停游戏，其他 AI/玩家继续操作；
6. Formation 使用鼠标调整方阵长宽，可替代一次移动，但推迟实现；
7. Legacy AICommandHUD 当前默认隐藏并提供切换按钮，最终创建策略等待 UI/策划确认；
8. Demo 关闭鼠标边缘滚屏，只保留键盘镜头平移。
