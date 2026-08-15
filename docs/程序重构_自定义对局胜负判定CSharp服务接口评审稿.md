# 程序重构：自定义对局胜负判定 C# 服务接口评审稿

> 对应进度：`ARCH-014`
>
> 状态：接口评审中，尚未进入代码实现
>
> 日期：2026-08-15

## 1. 本轮目标

把旧 `MatchEndHandler.gd` 中“按仍存活单位所属玩家判断对局结束”的后台规则迁移为可独立测试的 C# 服务，同时保持当前 Demo 的胜利、失败、无 Human 对局结束、暂停和退出主菜单表现。

本轮只迁移旧项目已经存在的自定义对局歼灭规则，不实现战役任务目标、塔防/推进胜负条件、投降、观战、联盟变更或联网同步。

## 2. 旧实现审计结果

当前 `MatchEndHandler.gd` 同时承担了四类职责：

1. 监听单位生成和离开场景树；
2. 扫描 `units` 与 `players` SceneTree group 并推断存活玩家；
3. 把结果解释为 Human 胜利、Human 失败或无 Human 的普通结束；
4. 显示 UI、暂停 SceneTree、发送语音依赖的 Legacy Signal，并切换主菜单。

已确认的结构风险：

- 规则依赖 Godot Node 类型、对象引用和 SceneTree group，无法进行纯 C# 单元测试；
- 只在 `tree_exited` 时评估，没有显式的对局初始化边界；
- 当所有玩家同时没有存活单位时，`players.size() == 0` 不会产生任何结果；
- 只识别第一个 Human，核心结果没有胜方、败方或平局的结构化数据；
- 无 Human 时只显示 `Finish`，没有对外发送结构化结束通知；
- 使用 `setup_and_spawn_unit` 请求信号监听新单位，而不是消费权威的 `unit_spawned` 事实；
- 以界面是否可见充当幂等保护，规则状态和 UI 状态相互耦合；
- 建筑、未完工建筑和移动单位只要属于 `units` group，就都会被计入存活条件，这是隐式场景契约。

## 3. 推荐边界

### 3.1 Domain

新增 `AI_RTS.Domain.Match`：

- `MatchSideId`：标识胜负规则中的阵营侧；当前每位玩家默认独占一个 Side，未来联盟可让多个 `PlayerId` 归属同一个 Side；
- `MatchParticipant`：包含 `PlayerId`、`MatchSideId` 与是否为本机 Human 的展示信息；
- `MatchCombatant`：包含 `UnitId`、所有者和 `CountsForElimination`；
- `MatchResolutionKind`：`InProgress`、`Won`、`Draw`；
- `MatchResolution`：包含结果种类、胜方 Side 集合、仍存活 Side 集合和只增不减的版本号。

枚举项和字段均使用中文 XML 注释。领域对象不引用 Godot 类型、场景路径或 UI 文本。

### 3.2 Application

新增 `IMatchOutcomeRule` 与首个实现 `LastSurvivingSideRule`，由规则接收不可变快照并返回结果。新增 `MatchOutcomeService` 管理参与者、计入歼灭判定的实体、初始化门闩和一次性结束状态。

建议服务公开以下语义方法：

```text
RegisterParticipant(participant)
RegisterCombatant(combatant)
RemoveCombatant(unitId)
StartMatch()
GetSnapshot()
```

注册和移除均按稳定 ID 幂等处理。`StartMatch()` 之前只建表不判定，防止初始生成过程中把暂时没有单位的玩家误判出局。对局一旦从 `InProgress` 进入终态，后续生成或死亡事件不得改写结果。

### 3.3 GodotAdapter

新增 `MatchOutcomeRuntime`，职责限定为：

- 通过 `GodotStableIdentity` 把 Player/Unit Node 转换为稳定 ID；
- 在 Match 初始化完成后注册参与者和现有单位，再调用 `StartMatch()`；
- 消费权威 `unit_spawned` 与 `unit_died` 事实，更新 C# 服务；
- 仅在结果首次进入终态时发出一个结构化 Godot Signal。

`MatchEndHandler.gd` 暂保留为薄 UI 适配器，只负责：

- 把结构化终态映射为 `Victory`、`Defeat` 或 `Finish` 面板；
- 暂停 SceneTree；
- 兼容发送现有 victory/defeat 语音信号；
- 退出时解除暂停并切换主菜单。

这样，后续 UI 重做无需改胜负规则，后续新增地图规则也无需接触当前面板。

## 4. 当前 Demo 的判定规则

本轮建议严格保持“歼灭全部计分实体”的旧玩法：

1. 一个 Side 至少还有一个 `CountsForElimination == true` 的实体时，该 Side 存活；
2. 只剩一个 Side 存活时，该 Side 获胜；
3. 没有 Side 存活时判为 `Draw`，当前 UI 暂映射到 `Finish`；
4. 两个或更多 Side 存活时继续对局；
5. 本机 Human 所在 Side 获胜显示 `Victory`，其他 Side 获胜显示 `Defeat`；
6. 没有本机 Human 的调试/AI 对局统一显示 `Finish`，但 C# 快照仍保留真实胜方；
7. 本轮每个玩家各自属于一个 Side，不引入队友关系；
8. 当前 `units` group 中的移动单位、建筑和未完工建筑继续计入歼灭判定，以免迁移改变 Demo 胜负时机；资源节点、地图障碍和纯表现对象不计入；
9. 上述第 8 条不再由 group 隐式决定，而由注册时的 `CountsForElimination` 显式表达。

## 5. 事件与时序

建议采用“上游事实触发，下游服务立即重算”的事件驱动方式，不进行每帧或定时轮询：

```text
Match 完成玩家与初始单位装配
    -> Runtime 注册参与者与现有单位
    -> StartMatch
    -> 后续 unit_spawned / unit_died 更新存活表
    -> 规则首次产生终态
    -> Runtime 发出 match_resolved
    -> UI 映射、暂停与 Legacy 语音通知
```

同一个单位的重复死亡/退出通知应成为无副作用操作；终态只发布一次。生成事件必须使用 `unit_spawned`，不再监听表达“请求生成”的 `setup_and_spawn_unit`。

## 6. 延期而非写死的内容

- 战役任务、护送、占点、计时、防守波次和脚本胜负；
- 投降、断线、观战与重连；
- 联盟、共享胜利和中途外交变化；
- “只摧毁基地”“失去关键英雄”等不同可淘汰实体策略；
- 未完工蓝图是否应计入存活；
- 敌方蓝图的可见性、碰撞和挡路规则；
- 胜负后的慢动作、延迟结算、战绩统计和新 UI；
- 联机权威端、确定性 Tick 与回放同步。

这些内容通过 `IMatchOutcomeRule`、`MatchSideId` 和显式 `CountsForElimination` 扩展，不应在首个规则中加入地图名、单位类型名或玩家控制器类型分支。

## 7. 自动测试验收范围

纯 C# 测试至少覆盖：

1. `StartMatch()` 前不会误判；
2. 两方存活时保持进行中；
3. 移除一方最后一个计分实体后另一方获胜；
4. 同一玩家多个实体必须全部移除才出局；
5. 多玩家同 Side 的未来兼容行为；
6. 同时全灭得到 `Draw`；
7. 不计入歼灭判定的对象不影响结果；
8. 重复注册、重复移除和未知 ID 移除保持幂等；
9. 终态不可被后续生成事件改写；
10. 结果版本与胜方/存活方快照正确。

Godot 冒烟测试至少覆盖：

- Player/Unit 稳定 ID 装配；
- 初始单位不会触发提前结束；
- `unit_spawned`、`unit_died` 到 C# 服务的桥接；
- Human 胜利、Human 失败、无 Human 结束和平局的 UI 映射；
- 终态只暂停和通知一次；
- 现有 `TestPlayerVsAI` 胜负流程无回归。

## 8. 建议评审结论

建议本轮确认：

1. 采用规则计算、Godot 事实适配和 UI 副作用三层分离；
2. 当前使用 `LastSurvivingSideRule`，不把未来玩法写死在服务中；
3. 引入 `MatchSideId`，但当前仍是一名玩家一个 Side；
4. 使用显式 `CountsForElimination`，本轮保留未完工建筑计入存活的旧行为；
5. 同时全灭为 `Draw`，当前复用 `Finish` 面板；
6. 没有 Human 时仍保留真实结构化胜方，但界面显示 `Finish`；
7. 只消费 `unit_spawned`/`unit_died` 权威事实，不轮询 SceneTree；
8. 初始化完成后才开启判定，终态一次性且不可逆；
9. 保留现有 victory/defeat Legacy Signal 作为展示兼容层，不再作为核心结果；
10. 战役和特殊地图规则继续延期，通过新的规则接口在后续分支实现。
