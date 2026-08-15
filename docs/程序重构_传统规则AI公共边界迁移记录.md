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
