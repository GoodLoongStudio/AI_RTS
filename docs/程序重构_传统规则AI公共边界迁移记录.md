# 程序重构：传统规则 AI 公共边界迁移记录

## 1. 目标

在不增加敌方战术、不细化 AI 行为的前提下，把 `simple-clairvoyant-ai` 对 SceneTree、单位 `action`、资源字段和生产队列的直接访问，逐步迁移到与玩家和未来大模型 AI 共用的查询与命令边界。

本项拆成小型纵向切片逐个验收，避免一次性改写当前已能完成经济、建造、生产、进攻和胜负闭环的传统 AI。

## 2. Legacy 耦合清单

| 子系统 | 当前直接依赖 | 目标边界 | 状态 |
|---|---|---|---|
| 顶层资源优先级调度 | `Player.has_resources` | 绑定身份的 `GetOwnEconomy` | 已迁移 |
| EconomyController | 单位组遍历、直接采集 Action、直接生产与放置 | 己方查询、采集命令、生产命令、放置命令 | 待迁移 |
| DefenseController | 单位组遍历、直接放置 | 己方查询、放置命令 | 待迁移 |
| OffenseController | 全玩家/单位组遍历、直接队列与放置 | 受限观察、生产/放置/作战命令 | 待迁移 |
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
