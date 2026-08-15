# 程序重构：传统规则 AI 公共边界迁移记录

## 1. 目标

在不增加敌方战术、不细化 AI 行为的前提下，把 `simple-clairvoyant-ai` 对 SceneTree、单位 `action`、资源字段和生产队列的直接访问，逐步迁移到与玩家和未来大模型 AI 共用的查询与命令边界。

本项拆成小型纵向切片逐个验收，避免一次性改写当前已能完成经济、建造、生产、进攻和胜负闭环的传统 AI。

## 2. Legacy 耦合清单

| 子系统 | 当前直接依赖 | 目标边界 | 状态 |
|---|---|---|---|
| 顶层资源优先级调度 | `Player.has_resources` | 绑定身份的 `GetOwnEconomy` | 已迁移 |
| EconomyController | 单位组遍历、直接采集 Action、直接生产与放置 | 己方查询、采集命令、生产命令、放置命令 | 已迁移 |
| DefenseController | 单位组遍历、直接放置 | 己方查询、放置命令 | 已迁移 |
| OffenseController | 全玩家/单位组遍历、直接队列与放置 | 受限观察、生产/放置/作战命令 | 部分迁移：生产后勤已完成，Legacy Battlegroup 待迁移 |
| IntelligenceController | 全知敌军遍历、直接移动 Action | 范围观察、移动命令 | 待迁移 |
| ConstructionWorksController | 施工现场遍历、直接分配 Worker | 己方查询、施工命令 | 待迁移 |
| AutoAttackingBattlegroup | 全知选敌、直接攻击/移动 Action | 受限观察、攻击/移动命令 | 待迁移 |

## 3. RAI-001A：经济准入纵向切片

- `WorldQueryRuntime.Initialize` 在创建权限 Grant 后，由对局组合根自动把每个非人类玩家绑定到自己的 `RuleAI` 标准会话。
- AI 只接收已绑定的会话，不提供“选择玩家并索取会话”的生产入口。
- 资源优先级调度通过 `GetOwnEconomy` 读取准确己方余额，不再调用继承自 `Player` 的 `has_resources`。
- 查询余额字段固定为 `resource_a/resource_b`，与经济交易和外置配置命名一致。
- 查询被拒绝或字段缺失时按资源不足处理，不绕过权限继续执行。
- `RuleAiEconomyQuerySmokeTest` 验证会话由 Match 注入、等额资源请求成功、超额请求失败。

本切片仅替换资源请求的准入读取。实际扣款仍由现有生产、建筑放置等权威交易入口完成，因此查询结果不是交易承诺，也不能替代最终原子扣款。

## 4. 后续顺序

1. 用己方实体查询替换各 Controller 的规划性 SceneTree 遍历；
2. 为生产、建筑放置、采集和施工补齐稳定实体 ID 命令入口；
3. 迁移 Controller 的执行写入并移除直接 `action` 赋值；
4. 最后迁移敌情观察与战斗编组，取消普通规则 AI 的默认全知扫描；
5. 完成人机经济、生产、移动、战斗和胜负闭环回归。

传统 AI 战术配置外置、阵营/指挥官/地图/玩法差异仍按《程序重构_传统AI外置配置约束》执行；本阶段不实现新的策略内容。

## 5. RAI-001B：施工观察与稳定 ID 命令

2026-08-15 接口评审接受以下契约：

- `ObservationField.Construction` 返回 `State`、`CompletedWork`、`RequiredWork` 和 `ActiveBuilderCount`；
- 非建筑以及未请求、未获授权的结果中，`Construction` 必须为空；
- 己方施工信息准确；敌方施工进度仍受字段权限和战争迷雾约束；
- 传统 AI 的命令 Adapter 由 Match 绑定固定玩家身份，只接受稳定 Worker/Site ID，不接受调用方传入 Player Node；
- Adapter 只负责身份与 Godot 参数转换，实际施工仍调用玩家共用的 `IConstructionService`。

已完成迁移：

- `ConstructionWorksController` 不再遍历 SceneTree，也不再读取或写入 `worker.action`；
- Controller 通过 `GetOwnForces(Type | Construction)` 选择 Worker 和未完工建筑；
- 施工命令可以用玩家明确的高优先级意图替换采集任务；施工结束后，既有 EconomyController 仍会让 Worker 恢复采集；
- 为保持原有简单策略，只要任一己方蓝图已有活动建造者，本轮就不再分配其他现场；
- Worker 退出、订单暂停或终结后，权威 `ActiveBuilderCount` 会立即更新，下一轮允许重新分配。

此前“AI 放置蓝图但不施工”的原因是桥接时把“已有 Worker 正在施工才跳过”扩大成了“任意 Worker 有任务都跳过”，而采集控制器又会持续占用 Worker。RAI-001B 删除了该 Legacy 判断，不再要求 Worker 先进入空闲状态。

自动验证：

- 施工核心测试覆盖活动建造者在开始、暂停、恢复和单位失效时的计数；
- 查询核心测试覆盖己方施工详情和敌方字段权限裁剪；
- Godot 规则 AI 冒烟覆盖绑定命令 Adapter、初始完成建筑观察和稳定 ID 施工拒绝路径；
- 实际“AI 蓝图—派遣 Worker—完成建筑”仍需 `TestPlayerVsAI` 人工观察，避免自动测试注入大量资源改变 AI 请求优先级。

2026-08-15 人工验收：AI 会为蓝图正确派遣 Worker、完成建筑并继续生产攻击单位，RAI-001B 通过。

## 6. RAI-001C：防御建筑规划与稳定类型放置

- `DefenseController` 通过 `GetOwnForces(Position | Type)` 统计对地/防空炮塔，并读取己方 Worker 与 CommandCenter；
- 移除单位组遍历、Node 类型判断、生成事件订阅、死亡 Node 回调和 `Player.has_resources` 断言；
- 固定身份的 `RuleAiCommandGateway.PlaceStructure` 只接受稳定 `UnitTypeId` 与世界变换；
- Adapter 从受信任 asset manifest 解析实际 PackedScene，调用玩家共用的 `StructurePlacementRuntime`，返回时删除 Node，只保留稳定施工现场 ID 与问题码；
- DefenseController 仍维持一座对地炮塔和一座防空炮塔，围绕第一个 CommandCenter 随机尝试合法候选位置；
- 已放下但未完工的蓝图计入当前建筑数量，不会重复下单；被摧毁后由定时查询重新发现缺口。

该切片不实现敌情分析、威胁方向选址或更多炮塔战术。候选位置改为由规则 AI 生成，最终合法性、视野、占地、友军驱逐和原子扣款仍由公共放置服务复验。

2026-08-15 人工验收：敌方 AI 会建造炮塔；炮塔损失后会重新放置并施工补充；完工炮塔正常工作。RAI-001C 通过。

## 7. RAI-001D：生产观察与 Worker 补充

2026-08-15 接口评审接受以下契约：

- `ObservationField.Production` 返回 `QueueLimit` 以及按权威顺序排列的非终态 `Items`；
- 每个项目返回稳定 `ItemId`、`ProductTypeId`、`State`、`CompletedWork` 和 `RequiredWork`；
- 非生产建筑返回空值，生产建筑的空队列必须明确返回 `items = []`；
- 生产信息属于己方准确情报。普通玩家与规则 AI 即使外部 Grant 误授字段，也不能读取当前可见敌方的生产队列；全知调试会话允许读取；
- `RuleAiCommandGateway.EnqueueProduction` 只接受生产建筑稳定 ID 与产品稳定类型 ID，身份固定为 Match 注入的规则 AI；
- Adapter 解析受信任配置后仍调用玩家共用的 `IProductionService`，队列容量、建筑归属、施工完成状态与原子扣款不会被绕过。

已完成迁移：

- `EconomyController` 通过己方查询统计已部署 Worker 与所有生产队列中的 Worker，不再把生成事件或直接队列节点当作规划真相；
- Worker 补充通过稳定 ID 生产命令入队，不再调用 `production_queue.produce`；
- CommandCenter 数量统计、缺口发现和放置改用己方查询及稳定类型放置命令，不再保存建筑 Node、监听建筑死亡或直接调用放置 Runtime；
- 初始资源不足时，既有资源优先级队列会保留请求，采集入账后再执行；最终扣款仍由权威生产/放置服务复验；
- Worker 的资源点选择与采集 Action 暂时保留 Legacy Node 链路，明确划入后续 RAI-001E，避免本切片同时改变经济策略。

自动验证：

- 查询核心测试覆盖己方显式空队列、误授权限仍不能读取敌方队列、全知调试读取；
- Godot 查询与规则 AI 冒烟覆盖生产字段序列化、空队列键、未知产品稳定拒绝；
- 既有生产队列冒烟继续覆盖入队、推进、完成、取消与退款链路；
- `dotnet build` 与 76 项纯 C# 测试通过；相关 Godot 冒烟均为 0 failure，退出时仍存在已登记的 RID/ObjectDB 基线泄漏。

2026-08-15 人工验收：AI 完成采集后能补足 Worker，Worker 损失后会重新生产补充，采集—返程—交付循环无回归。RAI-001D 通过。

## 8. RAI-001E：活动订单观察与 Worker 采集规划

2026-08-15 接口评审接受以下契约：

- `ObservationField.Order` 返回己方单位当前仍可变化的活动订单；空闲单位成功返回且 `Order` 明确为空；
- 活动订单包含稳定 `OrderId`、`Kind`、非终态 `State` 和可空原始目标意图；
- 实体目标返回稳定实体 ID、实体种类以及下令时确认的类型，位置目标返回世界坐标；这些字段是命令意图快照，不是目标实时状态查询；
- 普通玩家、规则 AI 和未来 Agent 不能读取敌方活动订单，即使外部 Grant 误授字段也由查询服务裁剪；全知调试会话允许读取；
- 固定身份 `RuleAiCommandGateway.Gather` 只接受稳定 Worker ID 集合与资源节点 ID，继续调用所有命令来源共用的 `IUnitCommandService`；
- AI 只从以 Worker 为中心的范围查询中选择当前可见资源；成功空集合表示范围内没有可用观察结果，不是查询错误；
- `Suspended` 订单保持暂停，EconomyController 不会自动恢复或覆盖；资源耗尽导致活动订单结束后，规则 AI 下一轮可以主动选择新资源。

已完成迁移：

- Gather 订单在创建时保存资源节点稳定 ID 与 `resource_a/resource_b` 类型，不依赖后续 Node 读取；
- Godot 世界快照在统一单位/资源注册表中登记稳定身份，并把权威活动订单复制到查询 DTO；
- `EconomyController` 不再保存 Worker Node，不再读取或写入 `worker.action`，不再订阅 `action_changed/tree_exited/unit_spawned`；
- Controller 通过己方 `Position | Type | Construction | Production | Order` 快照完成经济规划；
- 对无活动订单 Worker，Controller 使用受视野限制的圆形范围查询寻找最近资源，并依据现有 Gather 目标类型平衡两种资源分配；
- 施工、移动、暂停 Gather 等任何现有活动订单都不会被经济刷新覆盖；订单进入终态并从活动索引移除后，Worker 才会重新获得 Gather。

自动验证：

- 命令核心测试验证 Gather 订单保留资源稳定 ID 与类型；
- 查询核心测试验证己方订单准确、空闲显式为空、误授权不泄漏敌方订单、全知调试可诊断；
- Godot 规则 AI 冒烟验证 Worker 获得稳定 ID Gather、目标类型可观察、未知资源 ID 被拒绝，以及 Stop 后跨刷新周期仍保持 `Suspended`；
- `dotnet build` 为 0 警告、0 错误，77 项纯 C# 测试全部通过；WorldQuery、RuleAI Economy 与 Worker Gather 冒烟均为 0 failure；
- Godot 退出时的 RID/ObjectDB 泄漏仍属于已登记基线，不归因于本切片。

2026-08-15 人工验收：初始 Worker 采集、返程和交付正常；施工后恢复采集、资源重新分配以及 Worker 生产补充符合预期。RAI-001E 通过。

## 9. RAI-001F：进攻生产后勤迁移

本切片只迁移 `OffenseController` 的生产建筑规划和作战单位生产，不修改 `AutoAttackingBattlegroup` 的编组、全知索敌或直接 Action。战斗执行留给 RAI-001G 单独评审，避免把生产回归与战争迷雾语义混在同一改动中。

已完成迁移：

- 主、次生产建筑和产品由现有 `OffensiveStructure` 配置映射为稳定 `vehicle_factory/aircraft_factory` 与 `tank/helicopter` 类型；本切片不新增战术配置；
- `OffenseController` 通过 `GetOwnForces(Position | Type | Construction | Production)` 统计建筑蓝图、完工生产者和全部相关队列项目；
- 生产建筑放置复用固定身份 `PlaceStructure`，不再实例化临时建筑、读取 NavMap、直接调用 `StructurePlacementRuntime` 或调用 `Player.has_resources`；
- 作战单位生产复用固定身份 `EnqueueProduction`，不再读取或调用 `production_queue`；
- 蓝图已经计入工厂数量；只有 `Construction=Completed` 且存在生产观察的建筑能接收单位生产；
- 已排队项目与待处理资源请求共同抵扣当前 Legacy 编组缺口，主、次工厂不会在同一缺口上重复下单；
- 主次建筑类型相同时，共享类型级待放置数量，不会重复建立相同工厂；
- 资源请求真正执行时重新读取己方快照：建筑已经存在则丢弃过期放置请求，生产缺口已经消失则丢弃过期入队请求；
- 工厂损失由定时己方查询发现并重新请求放置，不再依赖建筑 Node 的死亡回调；
- `AutoAttackingBattlegroup` 的 Node 成员、生成信号、敌方玩家遍历和直接战斗 Action 被明确保留为 RAI-001G 边界。

自动验证：

- 新增 `RuleAiOffenseLogisticsSmokeTest`，覆盖稳定类型工厂蓝图放置、只对完工工厂入队 Tank、工厂损失后补建；
- 为缩短自动回归时间，测试先验证 AI 自己放置蓝图，再注入一座测试用已完工工厂验证生产；自然施工全过程留给人工验收；
- `RuleAiEconomyQuerySmokeTest` 继续验证对局组合根和其他规则 AI Controller 能正常启动；
- `dotnet build` 为 0 警告、0 错误，77 项纯 C# 测试全部通过；Godot 后勤冒烟为 0 failure；
- Godot 退出时的 RID/ObjectDB 泄漏仍属于已登记基线。候选位置在导航/地表尚未稳定时可能暂时返回 `SurfaceNotBuildable`，Controller 会在下一刷新周期重新请求，不在本切片展开导航专项。

2026-08-15 人工验收通过：运行 `TestPlayerVsAI.tscn` 后，AI 的生产建筑放置、施工、作战单位生产、现有编组进攻及生产建筑损失后的补建均符合预期，未发现明显重复超产。
