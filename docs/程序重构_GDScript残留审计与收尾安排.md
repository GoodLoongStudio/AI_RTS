# 程序重构：GDScript 残留审计与收尾安排

## 1. 判定原则

本次重构不以 GDScript 文件数量归零为验收标准。Godot 场景表现、输入转接、导航与 Action 执行端可以暂时保留 GDScript，但必须满足：

- Domain/Application 的权威规则、状态和接口位于 C#；
- Human、传统 AI、冻结 AI HUD 和未来外部调用者不能直接修改权威状态或绕过公共命令；
- 保留的 GDScript 必须能被归类为表现层、Godot Adapter、导航/Action 执行端或明确冻结的 Legacy 功能；
- 每个临时桥接点都要有调用方向、保留原因和后续替换范围，不能以“已有脚本”为理由继续增加业务规则。

## 2. 审计结论

### 2.1 本次重构必须处理

| 项目 | 当前证据 | 风险 | 收尾要求 |
|---|---|---|---|
| 传统控制组 | `UnitGroupSelectionHandler.gd` 使用 `unit_group_1..9` SceneTree 组保存成员 | 成员状态没有稳定 ID/服务边界；Legacy AI HUD 与战役也读取同名组，ControlGroup 与 AI Squad 未真正分离 | 建立 C# `IControlGroupService`；按玩家、组号和稳定 UnitId 保存；Godot Adapter 只负责选择表现和清理失效 Node |
| Human 命令旁路 | `UnitActionsController.gd` 对未列入硬编码类型的单位及 Follow/MoveToUnit 等分支直接赋值 `unit.action` | Drone 等现有单位可以绕过订单、回执和权限边界 | 为旧项目实际存在的语义补公共命令或稳定拒绝；删除所有 Human 侧 Action 回退；补 Drone/混合选择测试 |
| 冻结 AI HUD 旁路 | `AICommandHUD.gd` 的 Defend/Stop 直接写 Action，并把 `unit_group_N` 当作 Squad | 冻结界面仍能绕过命令服务，也与玩家控制组耦合 | 执行必须改走公共命令或在冻结期明确禁用；AI Squad 使用独立身份，不再读取传统 ControlGroup 存储 |
| 菜单停止回退 | `GenericMenu.gd` 在找不到 Gateway 时直接清空 Action | 装配错误会静默退回旁路，形成双写来源 | 删除回退并返回可诊断错误；正常对局必须始终存在 Match 级 Runtime/Gateway |
| 自定义对局胜负规则 | `MatchEndHandler.gd` 在单位退出时扫描 `units` 组并从 Node 推断存活玩家 | 属于旧项目已有后台规则，尚无纯 C# 测试，后续任务/玩法难以扩展 | 建立 C# MatchOutcome 服务与 Godot 生命周期 Adapter；保持当前“最后存活玩家”Demo 语义 |
| Legacy 边界收口 | `Unit.gd`、Action、Navigation、ProductionQueue 等仍承担 Godot 执行或视图桥接 | 若没有允许清单，后续难以区分合理 Adapter 与遗漏迁移 | 建立逐类允许清单；自动搜索 Human/AI/HUD 的直接 Action、HP、资源、队列和生成写入 |

### 2.2 可以保留到本次重构结束

| 类别 | 代表文件 | 保留原因与边界 |
|---|---|---|
| 导航与单位执行端 | `Navigation.gd`、`Movement.gd`、`Unit.gd`、`units/actions/*.gd` | Godot 主线程、NavigationAgent 和场景 Action 的引擎适配；只能由 C# Application 通过 GodotAdapter 端口启动，不得成为 Human/AI 的公共入口 |
| 表现与 HUD | `HealthBar.gd`、`Minimap.gd`、`ResourcesBar.gd`、生产队列视图 | 读取权威快照或 Signal 并显示；不得自行决定扣款、伤害、订单或生产规则 |
| 放置预览与输入翻译 | `StructurePlacementHandler.gd`、传统命令 HUD | 可以收集鼠标/按钮意图；最终提交必须进入 C# Runtime 并使用其回执 |
| 规则 AI 策略脚本 | `simple-clairvoyant-ai/*.gd` | RAI-001 已确保查询和执行经过公共边界；策略外置、阵营/地图差异和进一步重写留给传统 AI 专项 |
| 调试工具 | `match/debug/*.gd` | 只在显式 Debug 场景/功能标记下使用；不得被普通玩家、规则 AI 或外部 Agent 获取 |
| 冻结战役/任务表现 | `campaign/*.gd`、AICommandHUD 的任务文本与信号 | 本轮不扩展；仅要求主项目装配不因延期功能报错，后续战役分支再迁移强类型任务和英雄控制 |

## 3. 明确延期范围

项目负责人于 2026-08-15 确认以下内容不属于本次重构完成条件：

- 散开、计划模式、复杂列队；
- 侵略/警戒/固守的大规模复杂战场验收，以及警戒追击细节；
- 目标类型过滤与优先级、碾压/阻挡等级；
- 新增友伤比例与更细移动射击、炮塔/车体约束；
- Worker 手动交付建筑的上下文右键规则；
- 战役、任务、英雄快捷操作及战役流程重构；
- Python、大模型、数据库、操作点执行和跨语言 Infrastructure；
- 传统 AI 的路线、战术、外置指挥官/阵营/地图配置；
- 导航振荡、RVO/footprint、多单位寻路优化和难以稳定复现的整体卡住缺陷。

这些项目必须保留接口预留和文档记录，但不得为了“看起来完整”在当前分支实现未经评审的新规则。

## 4. 收尾实施顺序

1. 固定 `.NET SDK` 策略，避免最终回归在不同开发机上使用漂移 SDK；
2. 实现稳定 ID 的 C# ControlGroup，并删除传统控制组对 `unit_group_N` 的依赖；
3. 清除 Human Controller、GenericMenu 和冻结 AI HUD 的直接 Action 命令旁路，补齐当前 Drone 等现有单位；
4. 将自定义对局现有胜负判定迁移到 C# 可测试服务；
5. 形成 Legacy GDScript 允许清单和自动搜索结果，确认剩余脚本均属于允许类别；
6. 执行 RAI-002 和 QA-005 完整回归，记录简单性能基线与 RID/ObjectDB 泄漏归因；
7. 由项目负责人完成公共接口和最终人工验收，随后准备独立需求/缺陷分支。

## 5. 当前传统控制组结论

当前 `Ctrl+1..9` 保存、`1..9` 召回功能来自旧模板的 `UnitGroupSelectionHandler.gd`。新输入服务只替换了按键识别、组合键优先级和冲突管理，没有迁移控制组成员状态本身。

因此它是“功能可用但实现仍为 Legacy”的典型残留。本次重构应保留玩家已经验收的操作表现，同时把成员集合迁移为 C# 稳定 ID 状态，并彻底区分：

- `Selection`：当前临时选中集合；
- `ControlGroup`：玩家本地持久编号集合；
- `Formation`：一次移动命令的空间落点关系；
- `AI Squad/Battlegroup`：AI 自身的战术成员关系。

四者不得继续共享同一个 Godot 节点组或生命周期规则。
